import Foundation
import Observation

enum PresentationDuration: TimeInterval, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200

    var id: TimeInterval { rawValue }
    var title: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        }
    }
}

struct PresentationDraft: Sendable {
    let duration: PresentationDuration
    let keepsDisplayAwake: Bool
    let scene: SemperScene?
    let workspacePlan: WorkspaceRestorePlan?
    var controlNames: [SceneControl: String] = [:]
    var deviceNames: [String: String] = [:]
}

@MainActor
protocol PresentationWorkspaceHandling: AnyObject {
    func reserveForPresentation(_ plan: WorkspaceRestorePlan, token: UUID) throws
    func releasePresentationReservation(_ token: UUID, keepingCurrent: Bool) throws
    func apply(_ plan: WorkspaceRestorePlan, ownerToken: UUID?) async -> WorkspaceOperationReceipt
    func reverse(_ receipt: WorkspaceOperationReceipt, ownerToken: UUID?) async -> WorkspaceOperationReceipt
}

@MainActor
struct PresentationDependencies {
    let reserve: () async throws -> UUID
    let release: (UUID) async throws -> Void
    let preview: (SemperScene, UUID) async throws -> ScenePreviewReport
    let apply: (SemperScene, UUID, ScenePreviewReport) async throws -> SceneApplyReport
    let pending: (UUID) async throws -> SceneTransaction?
    let restore: (UUID, UUID) async throws -> SceneRestoreReport?
    let keepCurrent: (UUID, UUID) async throws -> Void
    let acquireAwake: (Date, Bool) throws -> AwakeLeaseToken
    let releaseAwake: (AwakeLeaseToken) -> Bool
    var pendingAwakeCleanup: () -> Bool = { false }
    var retryAwakeCleanup: () -> Bool = { true }
}

enum PresentationError: LocalizedError {
    case busy, invalidSelection, previewRequired, workspacePartial, deadlineReached
    case recoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .busy: "A Presentation operation is still running."
        case .invalidSelection: "Choose available settings and preview the selected windows before continuing."
        case .previewRequired: "Review an available preview before starting Presentation."
        case .workspacePartial: "Some selected windows could not be moved and verified. Earlier changes are being restored."
        case .deadlineReached: "The Presentation duration elapsed while preparing the session."
        case .recoveryRequired(let reason): reason
        }
    }
}

@Observable
@MainActor
final class PresentationController {
    enum Phase: Equatable {
        case idle, preparing, preview, starting, active, restoring, recoveryRequired
    }

    private(set) var phase: Phase = .idle
    private(set) var draft: PresentationDraft?
    private(set) var scenePreview: ScenePreviewReport?
    private(set) var workspaceReceipt: WorkspaceOperationReceipt?
    private(set) var restoreReport: SceneRestoreReport?
    private(set) var deadline: Date?
    private(set) var message: String?
    private(set) var isBusy = false
    private(set) var reservation: UUID?
    @ObservationIgnored private let dependencies: PresentationDependencies
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var workspace: (any PresentationWorkspaceHandling)?
    @ObservationIgnored private var workspaceReserved = false
    @ObservationIgnored private var sceneTransactionID: UUID?
    @ObservationIgnored private var awakeLease: AwakeLeaseToken?
    @ObservationIgnored private var operation: Task<Void, Error>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var stopTask: Task<Void, Error>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var shutDown = false

    init(dependencies: PresentationDependencies, now: @escaping @MainActor () -> Date = Date.init) {
        self.dependencies = dependencies
        self.now = now
    }

    var canStart: Bool {
        phase == .preview && !isBusy && (scenePreview?.canApply ?? true)
    }

    var retainedModules: Set<UtilityModuleID> {
        guard reservation != nil else { return [] }
        var result: Set<UtilityModuleID> = [.scenes]
        if workspaceReserved { result.insert(.workspace) }
        if awakeLease != nil || dependencies.pendingAwakeCleanup() { result.insert(.awake) }
        for action in draft?.scene?.actions ?? [] {
            if action.control.domain == .audio { result.insert(.sound) }
            if action.control.domain == .display { result.insert(.displays) }
        }
        return result
    }

    func prepare(_ draft: PresentationDraft, workspace: (any PresentationWorkspaceHandling)? = nil) async throws {
        guard !shutDown, reservation == nil, stopTask == nil else { throw PresentationError.busy }
        guard (draft.workspacePlan == nil) == (workspace == nil),
            draft.scene?.actions.allSatisfy({ $0.control.domain != .power }) ?? true,
            draft.workspacePlan?.steps.allSatisfy(\.canRestore) ?? true
        else { throw PresentationError.invalidSelection }
        try await perform {
            self.phase = .preparing
            self.message = nil
            self.draft = draft
            self.workspace = workspace
            self.workspaceReceipt = nil
            self.restoreReport = nil
            do {
                self.reservation = try await self.dependencies.reserve()
                try Task.checkCancellation()
                guard let token = self.reservation else { throw PresentationError.busy }
                if let plan = draft.workspacePlan, let workspace {
                    try workspace.reserveForPresentation(plan, token: token)
                    self.workspaceReserved = true
                }
                if let scene = draft.scene {
                    self.scenePreview = try await self.dependencies.preview(scene, token)
                } else {
                    self.scenePreview = nil
                }
                try Task.checkCancellation()
                self.phase = .preview
            } catch {
                self.message = error.localizedDescription
                await self.recoverAfterFailure()
                throw error
            }
        }
    }

    func start() async throws {
        guard !shutDown, canStart, let draft, let token = reservation else {
            throw PresentationError.previewRequired
        }
        try await perform {
            self.phase = .starting
            let deadline = self.now().addingTimeInterval(draft.duration.rawValue)
            self.deadline = deadline
            do {
                try Task.checkCancellation()
                self.awakeLease = try self.dependencies.acquireAwake(deadline, draft.keepsDisplayAwake)
                self.scheduleExpiry(at: deadline)
                if let scene = draft.scene, let preview = self.scenePreview {
                    do {
                        let result = try await self.dependencies.apply(scene, token, preview)
                        self.sceneTransactionID = result.transactionID
                    } catch {
                        let pending = try await self.dependencies.pending(token)
                        self.sceneTransactionID = pending?.id
                        throw error
                    }
                }
                try Task.checkCancellation()
                guard self.now() < deadline else { throw PresentationError.deadlineReached }
                if let plan = draft.workspacePlan, let workspace = self.workspace {
                    let result = await workspace.apply(plan, ownerToken: token)
                    self.workspaceReceipt = result
                    guard result.outcome == .completed else { throw PresentationError.workspacePartial }
                }
                try Task.checkCancellation()
                guard self.now() < deadline else { throw PresentationError.deadlineReached }
                self.phase = .active
                self.message = "Presentation is active. Later manual changes will be preserved during restore."
            } catch {
                self.message = error.localizedDescription
                await self.recoverAfterFailure()
                throw error
            }
        }
    }

    func stop() async throws {
        if let stopTask { return try await stopTask.value }
        expiry?.cancel()
        expiry = nil
        let pending = operation
        pending?.cancel()
        let task = Task { @MainActor in
            if let pending { _ = await pending.result }
            self.isBusy = true
            defer { self.isBusy = false }
            try await self.cleanup(keepingCurrent: false)
        }
        stopTask = task
        defer { stopTask = nil }
        try await task.value
    }

    func keepCurrent() async throws {
        guard !isBusy, stopTask == nil, reservation != nil else { throw PresentationError.busy }
        expiry?.cancel()
        expiry = nil
        try await perform { try await self.cleanup(keepingCurrent: true) }
    }

    func shutdown() async throws {
        shutDown = true
        try await stop()
    }

    func checkExpiry() async throws {
        guard phase == .starting || phase == .active, let deadline, now() >= deadline else { return }
        try await stop()
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async throws {
        guard operation == nil, stopTask == nil else { throw PresentationError.busy }
        try Task.checkCancellation()
        let id = UUID()
        operationID = id
        isBusy = true
        let task = Task { @MainActor in try await action() }
        operation = task
        defer {
            if operationID == id {
                operation = nil
                operationID = nil
                isBusy = stopTask != nil
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func recoverAfterFailure() async {
        let failure = message
        let task = Task { @MainActor in try await self.cleanup(keepingCurrent: false) }
        do {
            try await task.value
            message = failure
        } catch {
            message = [failure, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func cleanup(keepingCurrent: Bool) async throws {
        expiry?.cancel()
        expiry = nil
        guard let token = reservation else {
            phase = .idle
            deadline = nil
            return
        }
        phase = .restoring
        var failures: [String] = []
        if workspaceReserved, let workspace, let receipt = workspaceReceipt, receipt.needsRecovery, !keepingCurrent {
            let latest = await workspace.reverse(receipt, ownerToken: token)
            workspaceReceipt = latest
            if latest.needsRecovery {
                failures.append(
                    latest.requiresManualRecovery
                        ? "Some windows need manual recovery. Review their results before keeping the current setup."
                        : "Some windows could not be restored. Reconnect the original displays and retry.")
            }
        }
        do {
            if sceneTransactionID == nil { sceneTransactionID = try await dependencies.pending(token)?.id }
            if let transactionID = sceneTransactionID {
                if keepingCurrent {
                    try await dependencies.keepCurrent(transactionID, token)
                    sceneTransactionID = nil
                } else {
                    let report = try await dependencies.restore(transactionID, token)
                    restoreReport = report
                    if report?.journalCleared ?? true { sceneTransactionID = nil }
                    else { failures.append("The scene restore record still needs recovery.") }
                }
            }
        } catch {
            if case SceneRestoreError.incomplete(let report) = error { restoreReport = report }
            failures.append(error.localizedDescription)
        }
        if let lease = awakeLease {
            if dependencies.releaseAwake(lease) { awakeLease = nil }
            else { failures.append("Presentation could not release its Awake request. Retry cleanup.") }
        } else if dependencies.pendingAwakeCleanup() {
            if !dependencies.retryAwakeCleanup() || dependencies.pendingAwakeCleanup() {
                failures.append("Presentation could not release its incomplete Awake request. Retry cleanup.")
            }
        }
        if workspaceReserved, let workspace, keepingCurrent || failures.isEmpty {
            do {
                try workspace.releasePresentationReservation(token, keepingCurrent: keepingCurrent)
                workspaceReserved = false
            } catch { failures.append(error.localizedDescription) }
        }
        if failures.isEmpty {
            do {
                try await dependencies.release(token)
                reservation = nil
                workspace = nil
                phase = .idle
                deadline = nil
                message = keepingCurrent
                    ? "Kept the current setup and ended Presentation."
                    : "Presentation ended. Owned settings were restored where available; later manual changes were preserved."
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty {
            phase = .recoveryRequired
            message = failures.joined(separator: "\n")
            throw PresentationError.recoveryRequired(failures.joined(separator: "\n"))
        }
    }

    private func scheduleExpiry(at deadline: Date) {
        expiry?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self else { return }
            do { try await checkExpiry() }
            catch { message = error.localizedDescription }
        }
    }
}
