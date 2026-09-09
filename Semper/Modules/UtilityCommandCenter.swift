import Foundation
import Observation

enum UtilityCommandResult: Equatable {
    case completed
    case confirmationRequired(String)
    case unavailable(String)
    case failed(String)
    case cancelled
}

@MainActor
struct UtilityActionHandler {
    let descriptor: UtilityActionDescriptor
    let disabledReason: () -> String?
    let perform: () async throws -> Void
}

@Observable
@MainActor
final class UtilityCommandCenter {
    let registry: ModuleRegistry
    private(set) var running: Set<UtilityActionID> = []
    private(set) var lastResult: UtilityCommandResult?
    private var drainingModules: Set<UtilityModuleID> = []
    @ObservationIgnored private var handlers: [UtilityActionID: UtilityActionHandler] = [:]
    @ObservationIgnored private var tasks: [UtilityActionID: Task<Void, Error>] = [:]
    @ObservationIgnored private let admissionReason: (UtilityModuleID) -> String?

    private struct AdmissionFailure: Error {
        let reason: String
    }

    init(registry: ModuleRegistry, admissionReason: @escaping () -> String? = { nil }) {
        self.registry = registry
        self.admissionReason = { _ in admissionReason() }
    }

    init(registry: ModuleRegistry, moduleAdmissionReason: @escaping (UtilityModuleID) -> String?) {
        self.registry = registry
        self.admissionReason = moduleAdmissionReason
    }

    func register(_ additions: [UtilityActionHandler]) throws {
        try registry.register(actions: additions.map(\.descriptor))
        for handler in additions { handlers[handler.descriptor.id] = handler }
    }

    func disabledReason(for id: UtilityActionID) -> String? {
        availabilityReason(for: id, checkingRunning: true)
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
        guard !Task.isCancelled else { return finish(.cancelled) }
        if let reason = disabledReason(for: id) { return finish(.unavailable(reason)) }
        guard let handler = handlers[id] else { return finish(.unavailable("This action has no handler.")) }
        if let message = handler.descriptor.confirmationMessage, !confirmed {
            return finish(.confirmationRequired(message))
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
            try await handler.perform()
            try Task.checkCancellation()
        }
        tasks[id] = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return finish(.completed)
        } catch is CancellationError {
            return finish(.cancelled)
        } catch let failure as AdmissionFailure {
            return finish(.unavailable(failure.reason))
        } catch {
            return finish(.failed(error.localizedDescription))
        }
    }

    func cancelAndDrain(module: UtilityModuleID) async {
        drainingModules.insert(module)
        defer { drainingModules.remove(module) }
        let owned = tasks.filter { registry.actionMetadata(for: $0.key)?.module == module }.map(\.value)
        for task in owned { task.cancel() }
        for task in owned { _ = await task.result }
    }

    private func finish(_ result: UtilityCommandResult) -> UtilityCommandResult {
        lastResult = result
        return result
    }
}
