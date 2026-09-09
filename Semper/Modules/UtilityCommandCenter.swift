import Foundation
import Observation

enum UtilityCommandResult: Equatable {
    case completed
    case accepted
    case confirmationRequired(String)
    case unavailable(String)
    case failed(String)
    case cancelled
}

enum UtilityActionOutcome: Equatable, Sendable {
    case completed
    case accepted
}

enum UtilityActionHistoryResult: Equatable, Sendable {
    case completed, accepted, confirmationRequired, unavailable, failed, cancelled

    var displayText: String {
        switch self {
        case .completed: "Completed"
        case .accepted: "Accepted"
        case .confirmationRequired: "Confirmation requested"
        case .unavailable: "Unavailable"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct UtilityActionHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let actionID: UtilityActionID
    let timestamp: Date
    let result: UtilityActionHistoryResult
}

struct UtilityModuleAttention: Identifiable, Equatable {
    let id: UtilityModuleID
    let reasons: [String]
}

@MainActor
struct UtilityActionHandler {
    let descriptor: UtilityActionDescriptor
    let disabledReason: () -> String?
    let performOutcome: () async throws -> UtilityActionOutcome

    init(
        descriptor: UtilityActionDescriptor, disabledReason: @escaping () -> String?,
        perform: @escaping () async throws -> Void
    ) {
        self.descriptor = descriptor
        self.disabledReason = disabledReason
        performOutcome = {
            try await perform()
            try Task.checkCancellation()
            return .completed
        }
    }

    init(
        descriptor: UtilityActionDescriptor, disabledReason: @escaping () -> String?,
        performOutcome: @escaping () async throws -> UtilityActionOutcome
    ) {
        self.descriptor = descriptor
        self.disabledReason = disabledReason
        self.performOutcome = performOutcome
    }
}

@Observable
@MainActor
final class UtilityCommandCenter {
    static let maximumRecentActions = 8
    let registry: ModuleRegistry
    private(set) var running: Set<UtilityActionID> = []
    private(set) var lastResult: UtilityCommandResult?
    private(set) var recentActions: [UtilityActionHistoryEntry] = []
    private var drainingModules: Set<UtilityModuleID> = []
    @ObservationIgnored private var handlers: [UtilityActionID: UtilityActionHandler] = [:]
    @ObservationIgnored private var tasks: [UtilityActionID: Task<UtilityActionOutcome, Error>] = [:]
    @ObservationIgnored private let admissionReason: (UtilityModuleID) -> String?
    @ObservationIgnored private let now: () -> Date

    private struct AdmissionFailure: Error {
        let reason: String
    }

    init(
        registry: ModuleRegistry, admissionReason: @escaping () -> String? = { nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.admissionReason = { _ in admissionReason() }
        self.now = now
    }

    init(
        registry: ModuleRegistry, moduleAdmissionReason: @escaping (UtilityModuleID) -> String?,
        now: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.admissionReason = moduleAdmissionReason
        self.now = now
    }

    func register(_ additions: [UtilityActionHandler]) throws {
        try registry.register(actions: additions.map(\.descriptor))
        for handler in additions { handlers[handler.descriptor.id] = handler }
    }

    func disabledReason(for id: UtilityActionID) -> String? {
        availabilityReason(for: id, checkingRunning: true)
    }

    func attentionItems(lifecycleFailures: [UtilityModuleID: String]) -> [UtilityModuleAttention] {
        registry.modules.compactMap { module in
            guard let state = registry.state(for: module.id),
                state.presence == .added || lifecycleFailures[module.id] != nil
            else { return nil }
            var reasons: [String] = []
            func append(_ reason: String) {
                let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reason.isEmpty,
                    !reasons.contains(where: { $0.caseInsensitiveCompare(reason) == .orderedSame })
                else { return }
                reasons.append(reason)
            }
            if let failure = lifecycleFailures[module.id] { append(failure) }
            switch state.runtime {
            case .limited(let reason), .failed(let reason): append(reason)
            default: break
            }
            switch state.permission {
            case .denied: append("Permission denied.")
            case .restricted: append("Permission restricted.")
            case .revoked: append("Permission revoked.")
            default: break
            }
            return reasons.isEmpty ? nil : UtilityModuleAttention(id: module.id, reasons: reasons)
        }
    }

    private func availabilityReason(for id: UtilityActionID, checkingRunning: Bool) -> String? {
        guard let descriptor = registry.actionMetadata(for: id) else { return "This action is no longer available." }
        let presence = registry.state(for: descriptor.module)?.presence
        if case .unsupported(let reason) = presence { return reason }
        guard presence == .added else { return "Add this module in Modules first." }
        guard !drainingModules.contains(descriptor.module) else { return "This module is stopping." }
        guard !registry.pausedModuleIDs.contains(descriptor.module) else {
            return "Resume this module in Modules first."
        }
        guard registry.action(for: id) != nil else { return "This module is stopping." }
        guard !checkingRunning || !running.contains(id) else { return "This action is already running." }
        guard let handler = handlers[id] else { return "This action has no handler." }
        return admissionReason(descriptor.module) ?? handler.disabledReason()
    }

    @discardableResult
    func execute(_ id: UtilityActionID, confirmed: Bool = false) async -> UtilityCommandResult {
        guard !Task.isCancelled else { return finish(.cancelled, for: id) }
        if let reason = disabledReason(for: id) { return finish(.unavailable(reason), for: id) }
        guard let handler = handlers[id] else { return finish(.unavailable("This action has no handler."), for: id) }
        if let message = handler.descriptor.confirmationMessage, !confirmed {
            return finish(.confirmationRequired(message), for: id)
        }
        running.insert(id)
        let task = Task { @MainActor in
            defer {
                running.remove(id)
                tasks[id] = nil
            }
            try Task.checkCancellation()
            if let reason = availabilityReason(for: id, checkingRunning: false) {
                throw AdmissionFailure(reason: reason)
            }
            return try await handler.performOutcome()
        }
        tasks[id] = task
        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return finish(outcome == .completed ? .completed : .accepted, for: id)
        } catch is CancellationError {
            return finish(.cancelled, for: id)
        } catch let failure as AdmissionFailure {
            return finish(.unavailable(failure.reason), for: id)
        } catch {
            return finish(.failed(error.localizedDescription), for: id)
        }
    }

    func cancelAndDrain(module: UtilityModuleID) async {
        drainingModules.insert(module)
        defer { drainingModules.remove(module) }
        let owned = tasks.filter { registry.actionMetadata(for: $0.key)?.module == module }.map(\.value)
        for task in owned { task.cancel() }
        for task in owned { _ = await task.result }
    }

    private func finish(_ result: UtilityCommandResult, for id: UtilityActionID) -> UtilityCommandResult {
        lastResult = result
        if handlers[id] != nil, registry.actionMetadata(for: id) != nil {
            let historyResult: UtilityActionHistoryResult =
                switch result {
                case .completed: .completed
                case .accepted: .accepted
                case .confirmationRequired: .confirmationRequired
                case .unavailable: .unavailable
                case .failed: .failed
                case .cancelled: .cancelled
                }
            recentActions.insert(
                UtilityActionHistoryEntry(id: UUID(), actionID: id, timestamp: now(), result: historyResult), at: 0)
            if recentActions.count > Self.maximumRecentActions {
                recentActions.removeLast(recentActions.count - Self.maximumRecentActions)
            }
        }
        return result
    }
}
