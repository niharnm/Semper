import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Semper

@Suite("Presentation controller")
@MainActor
struct PresentationControllerTests {
    @Test("Preparing a preview reserves ownership without writes or Awake assertions")
    func previewIsNonmutating() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }

        try await fixture.prepare()

        #expect(fixture.controller.phase == .preview)
        #expect(fixture.controller.canStart)
        #expect(fixture.trace.events == [.sceneReserve, .workspaceReserve, .scenePreview])
        #expect(fixture.backend.activeIDs.isEmpty)
        #expect(fixture.controller.deadline == nil)
        #expect(fixture.controller.workspaceReceipt == nil)
        #expect(fixture.controller.retainedModules == [.scenes, .workspace, .sound, .displays])
        try await fixture.controller.stop()
    }

    @Test("Cancellation after reservation acquisition releases ownership without applying changes")
    func cancellationDuringPreparation() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        let gate = PresentationGate()
        fixture.reserveGate = gate
        let prepare = Task { try await fixture.prepare() }
        #expect(await gate.waitUntilSuspended())

        prepare.cancel()
        gate.resume()
        await #expect(throws: CancellationError.self) { try await prepare.value }

        #expect(fixture.controller.phase == .idle)
        #expect(fixture.controller.reservation == nil)
        #expect(fixture.trace.events == [.sceneReserve, .scenePending, .sceneRelease])
        #expect(fixture.backend.activeIDs.isEmpty)
    }

    @Test("Start requires a successful reviewed preview")
    func startRequiresPreview() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        await #expect(throws: PresentationError.self) { try await fixture.controller.start() }
        fixture.previewUnavailable = true
        try await fixture.prepare()

        #expect(!fixture.controller.canStart)
        await #expect(throws: PresentationError.self) { try await fixture.controller.start() }
        #expect(!fixture.trace.events.contains(.sceneApply))
        #expect(fixture.backend.activeIDs.isEmpty)
        try await fixture.controller.stop()
    }

    @Test("Start passes the reviewed preview and cleanup reverses Workspace, Scene, then Awake")
    func applyAndReverseOrder() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        let preview = try #require(fixture.controller.scenePreview)
        fixture.trace.events = []

        try await fixture.controller.start()

        #expect(fixture.controller.phase == .active)
        #expect(fixture.receivedPreview == preview)
        #expect(fixture.trace.events == [.awakeAcquire, .sceneApply, .workspaceApply])
        #expect(fixture.backend.timeouts == [1800, 1800])
        #expect(fixture.controller.deadline == fixture.clock.current.addingTimeInterval(1800))
        fixture.trace.events = []
        try await fixture.controller.stop()

        #expect(fixture.trace.events == [.workspaceReverse, .sceneRestore, .awakeRelease, .workspaceRelease, .sceneRelease])
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.controller.reservation == nil)
        #expect(fixture.controller.retainedModules.isEmpty)
        #expect(fixture.backend.activeIDs.isEmpty)
        #expect(fixture.workspace.ownerTokens.allSatisfy { $0 == fixture.token })
        #expect(fixture.sceneTokens.allSatisfy { $0 == fixture.token })
    }

    @Test("An apply failure discovers its pending transaction and restores it")
    func applyFailureRestoresPendingTransaction() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        fixture.applyFailsAfterWriting = true
        try await fixture.prepare()
        fixture.trace.events = []

        await #expect(throws: PresentationFixture.Failure.self) { try await fixture.controller.start() }

        #expect(fixture.trace.events == [.awakeAcquire, .sceneApply, .scenePending, .sceneRestore, .awakeRelease, .workspaceRelease, .sceneRelease])
        #expect(fixture.restoredIDs == [fixture.transactionID])
        #expect(fixture.pendingTransaction == nil)
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.backend.activeIDs.isEmpty)
    }

    @Test("A partial Workspace apply reverses its recorded changes and earlier Scene writes")
    func partialWorkspaceApplyRestores() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        fixture.workspace.appliedReceipt = fixture.workspace.makeReceipt(outcome: .partial, recovery: fixture.workspace.pendingRecovery)
        try await fixture.prepare()
        fixture.trace.events = []

        await #expect(throws: PresentationError.self) { try await fixture.controller.start() }

        #expect(fixture.trace.events == [.awakeAcquire, .sceneApply, .workspaceApply, .workspaceReverse, .sceneRestore, .awakeRelease, .workspaceRelease, .sceneRelease])
        #expect(fixture.workspace.reversedIDs == [fixture.workspace.appliedReceipt.operationID])
        #expect(fixture.controller.workspaceReceipt?.needsRecovery == false)
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.controller.reservation == nil)
        #expect(fixture.backend.activeIDs.isEmpty)
    }

    @Test("Cancellation after Scene writes shields recovery from cancellation")
    func cancellationAfterSceneWrite() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        let gate = PresentationGate()
        fixture.sceneApplyGate = gate
        try await fixture.prepare()
        let start = Task { try await fixture.controller.start() }
        #expect(await gate.waitUntilSuspended())

        start.cancel()
        #expect(await fixture.trace.waitFor(.sceneApplyCancelled))
        gate.resume()
        await #expect(throws: CancellationError.self) { try await start.value }

        #expect(fixture.restoredIDs == [fixture.transactionID])
        #expect(fixture.restoreWasCancelled == [false])
        #expect(fixture.controller.reservation == nil)
        #expect(fixture.backend.activeIDs.isEmpty)
        #expect(!fixture.trace.events.contains(.workspaceApply))
    }

    @Test("Cancellation after Workspace writes drains reverse cleanup")
    func cancellationAfterWorkspaceWrite() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        let gate = PresentationGate()
        fixture.workspace.applyGate = gate
        try await fixture.prepare()
        let start = Task { try await fixture.controller.start() }
        #expect(await gate.waitUntilSuspended())

        start.cancel()
        #expect(await fixture.trace.waitFor(.workspaceApplyCancelled))
        gate.resume()
        await #expect(throws: CancellationError.self) { try await start.value }

        #expect(fixture.workspace.reversedIDs == [fixture.workspace.appliedReceipt.operationID])
        #expect(fixture.workspace.reverseWasCancelled == [false])
        #expect(fixture.restoreWasCancelled == [false])
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.backend.activeIDs.isEmpty)
    }

    @Test("Expiry during a suspended start cancels it and waits for recovery")
    func expiryDuringStart() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        let gate = PresentationGate()
        fixture.workspace.applyGate = gate
        try await fixture.prepare()
        let start = Task { try await fixture.controller.start() }
        #expect(await gate.waitUntilSuspended())
        fixture.clock.current = fixture.clock.current.addingTimeInterval(1801)
        var expiryFinished = false
        let expiry = Task {
            defer { expiryFinished = true }
            try await fixture.controller.checkExpiry()
        }

        #expect(await fixture.trace.waitFor(.workspaceApplyCancelled))
        #expect(!expiryFinished)
        gate.resume()
        await #expect(throws: (any Error).self) { try await start.value }
        try await expiry.value

        #expect(fixture.controller.phase == .idle)
        #expect(fixture.controller.reservation == nil)
        #expect(fixture.workspace.reversedIDs == [fixture.workspace.appliedReceipt.operationID])
        #expect(fixture.backend.activeIDs.isEmpty)
    }

    @Test("Wake expiry restores the active session even after its Awake lease expires")
    func activeExpiry() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        try await fixture.controller.start()
        fixture.clock.current = fixture.clock.current.addingTimeInterval(1801)
        fixture.scheduler.fire()
        #expect(!fixture.awake.hasLease(for: .presentation))

        try await fixture.controller.checkExpiry()

        #expect(fixture.controller.phase == .idle)
        #expect(fixture.restoredIDs == [fixture.transactionID])
        #expect(fixture.workspace.reversedIDs.count == 1)
        #expect(fixture.backend.activeIDs.isEmpty)
    }

    @Test("Retry reverses the latest receipt and retains unresolved modules")
    func retryUsesLatestReceipt() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        let partial = fixture.workspace.makeReceipt(outcome: .partial, recovery: fixture.workspace.pendingRecovery)
        let restored = fixture.workspace.makeReceipt(outcome: .completed, recovery: .none)
        fixture.workspace.reverseResults = [partial, restored]
        try await fixture.prepare()
        try await fixture.controller.start()

        await #expect(throws: PresentationError.self) { try await fixture.controller.stop() }

        #expect(fixture.controller.phase == .recoveryRequired)
        #expect(fixture.controller.workspaceReceipt?.operationID == partial.operationID)
        #expect(fixture.controller.retainedModules.contains(.workspace))
        #expect(fixture.controller.retainedModules.contains(.scenes))
        #expect(!fixture.controller.retainedModules.contains(.awake))
        #expect(fixture.controller.reservation == fixture.token)
        try await fixture.controller.stop()
        #expect(fixture.workspace.reversedIDs == [fixture.workspace.appliedReceipt.operationID, partial.operationID])
        #expect(fixture.restoredIDs == [fixture.transactionID])
        #expect(fixture.controller.retainedModules.isEmpty)
    }

    @Test("Manual window recovery remains owned until explicit acceptance")
    func manualRecoveryRequiresAcceptance() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        fixture.workspace.reverseResults = [fixture.workspace.makeReceipt(outcome: .partial, recovery: .manualRecoveryRequired)]
        try await fixture.prepare()
        try await fixture.controller.start()

        await #expect(throws: PresentationError.self) { try await fixture.controller.stop() }
        #expect(fixture.controller.workspaceReceipt?.requiresManualRecovery == true)
        #expect(fixture.controller.reservation == fixture.token)
        #expect(fixture.workspace.reservedToken == fixture.token)
        #expect(!fixture.trace.events.contains(.workspaceKeep))

        try await fixture.controller.keepCurrent()

        #expect(fixture.trace.events.contains(.workspaceKeep))
        #expect(fixture.controller.reservation == nil)
        #expect(fixture.controller.phase == .idle)
    }

    @Test("Keep Current accepts owned Scene and Workspace changes but ends Awake")
    func keepCurrentAcceptsWithoutRestoring() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        try await fixture.controller.start()
        fixture.trace.events = []

        try await fixture.controller.keepCurrent()

        #expect(fixture.trace.events == [.sceneKeep, .awakeRelease, .workspaceKeep, .sceneRelease])
        #expect(fixture.workspace.reversedIDs.isEmpty)
        #expect(fixture.restoredIDs.isEmpty)
        #expect(fixture.keptIDs == [fixture.transactionID])
        #expect(fixture.backend.activeIDs.isEmpty)
        #expect(fixture.controller.reservation == nil)
    }

    @Test("Retry after accepted Workspace ownership is released cannot reverse those changes")
    func retryAfterKeepCurrentReleaseFailure() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        try await fixture.controller.start()
        fixture.sceneReleaseFails = true

        await #expect(throws: PresentationError.self) { try await fixture.controller.keepCurrent() }

        #expect(fixture.workspace.reservedToken == nil)
        #expect(fixture.controller.reservation == fixture.token)
        #expect(!fixture.controller.retainedModules.contains(.workspace))
        fixture.sceneReleaseFails = false
        try await fixture.controller.stop()

        #expect(fixture.workspace.reversedIDs.isEmpty)
        #expect(fixture.restoredIDs.isEmpty)
        #expect(fixture.keptIDs == [fixture.transactionID])
        #expect(fixture.controller.reservation == nil)
    }

    @Test("Keep Current acceptance survives failed Awake cleanup and a later Stop")
    func keepCurrentSurvivesAwakeReleaseFailure() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        try await fixture.controller.start()
        fixture.backend.failingReleaseIDs = fixture.backend.activeIDs

        await #expect(throws: PresentationError.self) { try await fixture.controller.keepCurrent() }

        #expect(fixture.keptIDs == [fixture.transactionID])
        #expect(fixture.workspace.reservedToken == nil)
        #expect(!fixture.controller.retainedModules.contains(.workspace))
        #expect(fixture.controller.retainedModules.contains(.awake))
        #expect(fixture.controller.reservation == fixture.token)
        fixture.backend.failingReleaseIDs = []
        try await fixture.controller.stop()

        #expect(fixture.workspace.reversedIDs.isEmpty)
        #expect(fixture.restoredIDs.isEmpty)
        #expect(fixture.controller.reservation == nil)
        #expect(fixture.backend.activeIDs.isEmpty)
    }

    @Test("Scene recovery failure retains its reservation and required modules")
    func sceneFailureRetainsOwnership() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        fixture.restoreFails = true
        try await fixture.prepare()
        try await fixture.controller.start()

        await #expect(throws: PresentationError.self) { try await fixture.controller.stop() }

        #expect(fixture.controller.phase == .recoveryRequired)
        #expect(fixture.controller.restoreReport?.journalCleared == false)
        #expect(fixture.controller.retainedModules.isSuperset(of: [.scenes, .sound, .displays]))
        #expect(fixture.controller.reservation == fixture.token)
        #expect(!fixture.trace.events.contains(.sceneRelease))
        fixture.restoreFails = false
        try await fixture.controller.stop()
        #expect(fixture.controller.reservation == nil)
    }

    @Test("Foreign scene recovery is refused and other Awake owners remain untouched")
    func preservesUnrelatedOwnership() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        _ = try fixture.awake.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        _ = try fixture.awake.acquireLease(owner: .scene, keepsDisplayAwake: false)
        try await fixture.prepare()
        try await fixture.controller.start()
        fixture.foreignTransactionAppeared = true

        await #expect(throws: PresentationError.self) { try await fixture.controller.stop() }

        #expect(fixture.restoredIDs.isEmpty)
        #expect(fixture.keptIDs.isEmpty)
        #expect(fixture.controller.reservation == fixture.token)
        #expect(fixture.awake.hasLease(for: .awayMode))
        #expect(fixture.awake.hasLease(for: .scene))
        #expect(!fixture.awake.hasLease(for: .presentation))
        fixture.foreignTransactionAppeared = false
        try await fixture.controller.stop()
    }

    @Test("A stale Presentation lease token cannot release its replacement")
    func staleLeaseCannotReleaseReplacement() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        try await fixture.controller.start()
        fixture.clock.current = fixture.clock.current.addingTimeInterval(1801)
        fixture.scheduler.fire()
        let replacementDeadline = fixture.clock.current.addingTimeInterval(60)
        _ = try fixture.awake.acquireLease(owner: .presentation, keepsDisplayAwake: false, deadline: replacementDeadline)
        let replacementIDs = fixture.backend.activeIDs

        try await fixture.controller.checkExpiry()

        #expect(fixture.controller.reservation == nil)
        #expect(fixture.backend.activeIDs == replacementIDs)
        #expect(fixture.awake.leaseState(for: .presentation)?.deadline == replacementDeadline)
    }

    @Test("Concurrent stop callers wait for one reverse operation")
    func concurrentStopDrainsOnce() async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        try await fixture.controller.start()
        let gate = PresentationGate()
        fixture.workspace.reverseGate = gate
        let first = Task { try await fixture.controller.stop() }
        #expect(await gate.waitUntilSuspended())
        var secondFinished = false
        let second = Task {
            defer { secondFinished = true }
            try await fixture.controller.stop()
        }
        await Task.yield()
        #expect(fixture.controller.isBusy)
        #expect(!secondFinished)
        #expect(fixture.workspace.reversedIDs.count == 1)
        second.cancel()
        gate.resume()
        try await first.value
        try await second.value

        #expect(fixture.workspace.reversedIDs.count == 1)
        #expect(fixture.controller.phase == .idle)
        #expect(!fixture.controller.isBusy)
    }

    @Test("Failed Awake acquisition without a token retains cleanup ownership")
    func awakeAcquisitionCleanupWithoutToken() async throws {
        let fixture = PresentationFixture()
        defer {
            fixture.backend.failAllReleases = false
            fixture.awake.shutdown()
        }
        _ = try fixture.awake.acquireLease(owner: .scene, keepsDisplayAwake: false)
        let unrelatedIDs = fixture.backend.activeIDs
        fixture.backend.failDisplayAcquisition = true
        fixture.backend.failAllReleases = true
        fixture.backend.releaseAttempts = []
        try await fixture.prepare()

        await #expect(throws: AwakeLeaseError.self) { try await fixture.controller.start() }

        #expect(fixture.controller.phase == .recoveryRequired)
        #expect(fixture.controller.reservation == fixture.token)
        #expect(fixture.controller.retainedModules.contains(.awake))
        #expect(!fixture.awake.hasLease(for: .presentation))
        #expect(fixture.awake.hasPendingLeaseCleanup(owner: .presentation))
        #expect(fixture.awake.hasLease(for: .scene))
        #expect(unrelatedIDs.isDisjoint(with: fixture.backend.releaseAttempts))
        #expect(!fixture.trace.events.contains(.sceneRelease))
        #expect(!fixture.trace.events.contains(.sceneApply))
        fixture.backend.failAllReleases = false
        try await fixture.controller.stop()
        #expect(!fixture.awake.hasPendingLeaseCleanup(owner: .presentation))
        #expect(fixture.backend.activeIDs == unrelatedIDs)
        #expect(unrelatedIDs.isDisjoint(with: fixture.backend.releaseAttempts))
        #expect(fixture.controller.reservation == nil)
    }

    @Test("Failed active or expired Awake release remains owned until token retry succeeds", arguments: [false, true])
    func awakeReleaseFailureRetainsModule(expired: Bool) async throws {
        let fixture = PresentationFixture()
        defer { fixture.awake.shutdown() }
        try await fixture.prepare()
        try await fixture.controller.start()
        fixture.backend.failingReleaseIDs = fixture.backend.activeIDs
        if expired {
            fixture.clock.current = fixture.clock.current.addingTimeInterval(1801)
            fixture.scheduler.fire()
        }

        await #expect(throws: PresentationError.self) { try await fixture.controller.stop() }

        #expect(fixture.controller.phase == .recoveryRequired)
        #expect(fixture.controller.retainedModules.contains(.awake))
        #expect(fixture.controller.reservation == fixture.token)
        #expect(fixture.pendingTransaction == nil)
        #expect(fixture.awake.hasPendingLeaseCleanup(owner: .presentation))
        fixture.backend.failingReleaseIDs = []
        try await fixture.controller.stop()
        #expect(!fixture.awake.hasPendingLeaseCleanup(owner: .presentation))
        #expect(fixture.backend.activeIDs.isEmpty)
        #expect(fixture.controller.reservation == nil)
    }
}

@MainActor
private final class PresentationFixture {
    enum Failure: Error { case rejected, foreignTransaction }
    let token = UUID()
    let transactionID = UUID()
    let trace = PresentationTrace()
    let clock = PresentationClock()
    let backend = PresentationPowerBackend()
    let scheduler = PresentationAwakeScheduler()
    let awake: AwakeService
    let workspace: PresentationWorkspaceFake
    let scene = SemperScene(name: "Presentation", actions: [
        SceneAction(control: .audioOutputVolume(deviceID: "output-a"), target: .number(0.6), importance: .required),
        SceneAction(control: .displayBrightness(displayID: "display-a"), target: .number(0.8), importance: .required),
    ])
    var previewUnavailable = false
    var applyFailsAfterWriting = false
    var restoreFails = false
    var sceneReleaseFails = false
    var foreignTransactionAppeared = false
    var reserveGate: PresentationGate?
    var sceneApplyGate: PresentationGate?
    var receivedPreview: ScenePreviewReport?
    var pendingTransaction: SceneTransaction?
    var restoredIDs: [UUID] = []
    var keptIDs: [UUID] = []
    var sceneTokens: [UUID] = []
    var restoreWasCancelled: [Bool] = []
    lazy var controller = PresentationController(dependencies: dependencies, now: { [clock] in clock.current })

    init() {
        awake = AwakeService(
            backend: backend, scheduler: scheduler, now: { [clock] in clock.current },
            workspaceNotificationCenter: NotificationCenter(), conditionMonitor: PresentationConditionMonitor())
        workspace = PresentationWorkspaceFake(trace: trace)
    }

    func prepare() async throws {
        try await controller.prepare(
            PresentationDraft(duration: .thirtyMinutes, keepsDisplayAwake: true, scene: scene, workspacePlan: workspace.plan),
            workspace: workspace
        )
    }

    private var dependencies: PresentationDependencies {
        PresentationDependencies(
            reserve: { [unowned self] in
                trace.events.append(.sceneReserve)
                if let reserveGate { await reserveGate.suspend() }
                return token
            },
            release: { [unowned self] token in
                try requireToken(token)
                try Task.checkCancellation()
                guard pendingTransaction == nil else { throw Failure.rejected }
                trace.events.append(.sceneRelease)
                if sceneReleaseFails { throw Failure.rejected }
            },
            preview: { [unowned self] scene, token in
                try requireToken(token)
                trace.events.append(.scenePreview)
                return ScenePreviewReport(
                    sceneID: scene.id,
                    entries: scene.actionsInApplyOrder.map {
                        SceneTransactionEntry(control: $0.control, importance: $0.importance, snapshotValue: .number(0.3), targetValue: $0.target)
                    },
                    skippedOptional: [],
                    requiredFailures: previewUnavailable ? [.init(control: scene.actions[0].control, reason: .capability(.unsupported))] : []
                )
            },
            apply: { [unowned self] scene, token, preview in
                try requireToken(token)
                trace.events.append(.sceneApply)
                receivedPreview = preview
                pendingTransaction = SceneTransaction(
                    id: transactionID, sceneID: scene.id, sceneName: scene.name, startedAt: clock.current,
                    entries: preview.entries.map {
                        var entry = $0
                        entry.phase = .applied
                        entry.appliedValue = entry.targetValue
                        return entry
                    }
                )
                if let sceneApplyGate {
                    await withTaskCancellationHandler { await sceneApplyGate.suspend() } onCancel: {
                        Task { @MainActor [trace] in trace.events.append(.sceneApplyCancelled) }
                    }
                }
                try Task.checkCancellation()
                if applyFailsAfterWriting { throw Failure.rejected }
                return SceneApplyReport(transactionID: transactionID, sceneID: scene.id, applied: [], skippedOptional: [])
            },
            pending: { [unowned self] token in
                try requireToken(token)
                trace.events.append(.scenePending)
                try Task.checkCancellation()
                if foreignTransactionAppeared { throw Failure.foreignTransaction }
                return pendingTransaction
            },
            restore: { [unowned self] transactionID, token in
                try requireToken(token)
                restoreWasCancelled.append(Task.isCancelled)
                try Task.checkCancellation()
                guard !foreignTransactionAppeared, pendingTransaction?.id == transactionID else { throw Failure.foreignTransaction }
                trace.events.append(.sceneRestore)
                let report = SceneRestoreReport(
                    transactionID: transactionID, sceneID: scene.id,
                    outcomes: restoreFails ? [.failed(scene.actions[0].control, reason: "Unavailable")] : [],
                    journalCleared: !restoreFails
                )
                if restoreFails { throw SceneRestoreError.incomplete(report) }
                restoredIDs.append(transactionID)
                pendingTransaction = nil
                return report
            },
            keepCurrent: { [unowned self] transactionID, token in
                try requireToken(token)
                guard !foreignTransactionAppeared, pendingTransaction?.id == transactionID else { throw Failure.foreignTransaction }
                trace.events.append(.sceneKeep)
                keptIDs.append(transactionID)
                pendingTransaction = nil
            },
            acquireAwake: { [unowned self] deadline, keepsDisplayAwake in
                trace.events.append(.awakeAcquire)
                return try awake.acquireLease(owner: .presentation, keepsDisplayAwake: keepsDisplayAwake, deadline: deadline)
            },
            releaseAwake: { [unowned self] token in
                trace.events.append(.awakeRelease)
                if awake.leaseState(for: .presentation) == nil { return awake.retryReleaseLease(token) }
                return awake.releaseLease(token)
            },
            pendingAwakeCleanup: { [unowned self] in awake.hasPendingLeaseCleanup(owner: .presentation) },
            retryAwakeCleanup: { [unowned self] in
                awake.retryPendingLeaseCleanup(owner: .presentation)
            }
        )
    }

    private func requireToken(_ token: UUID) throws {
        sceneTokens.append(token)
        guard token == self.token else { throw Failure.rejected }
    }
}

@MainActor
private final class PresentationWorkspaceFake: PresentationWorkspaceHandling {
    private let trace: PresentationTrace
    let plan: WorkspaceRestorePlan
    let pendingRecovery: WorkspaceRecoveryState
    var appliedReceipt: WorkspaceOperationReceipt
    var reverseResults: [WorkspaceOperationReceipt] = []
    var applyGate: PresentationGate?
    var reverseGate: PresentationGate?
    var reservedToken: UUID?
    var ownerTokens: [UUID?] = []
    var reversedIDs: [UUID] = []
    var reverseWasCancelled: [Bool] = []
    private var latestReceipt: WorkspaceOperationReceipt?

    init(trace: PresentationTrace) {
        self.trace = trace
        let display = WorkspaceDisplay(id: "display-a", name: "Display", visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let application = WorkspaceApplication(pid: 42, bundleID: "test.slides", name: "Slides", launchDate: Date(timeIntervalSince1970: 1))
        let window = WorkspaceWindowID(application: application, token: UUID())
        let before = CGRect(x: 10, y: 10, width: 600, height: 400)
        let after = CGRect(x: 100, y: 100, width: 800, height: 600)
        let placement = WorkspacePlacement(id: UUID(), applicationBundleID: application.bundleID, applicationName: application.name, label: "Slides", displayID: display.id, displayName: display.name, relativeFrame: before)
        let step = WorkspacePreviewItem(placement: placement, boundWindowID: window, currentFrame: before, targetFrame: after, reason: nil)
        plan = WorkspaceRestorePlan(id: UUID(), arrangementID: UUID(), selectedSlotIDs: [step.id], displays: [display], steps: [step], ownerID: UUID(), generationID: UUID())
        pendingRecovery = .pending(WorkspaceRecoveryChange(windowID: window, display: display, before: before, after: after))
        appliedReceipt = WorkspaceOperationReceipt(operationID: UUID(), planID: plan.id, reversesOperationID: nil, outcome: .completed, issue: nil, steps: [WorkspaceStepReceipt(step: step, outcome: .applied, observation: nil, recovery: pendingRecovery)], ownerID: plan.ownerID)
    }

    func reserveForPresentation(_ plan: WorkspaceRestorePlan, token: UUID) throws {
        guard plan.id == self.plan.id, reservedToken == nil else { throw PresentationFixture.Failure.rejected }
        trace.events.append(.workspaceReserve)
        reservedToken = token
    }

    func releasePresentationReservation(_ token: UUID, keepingCurrent: Bool) throws {
        ownerTokens.append(token)
        guard token == reservedToken, keepingCurrent || latestReceipt?.needsRecovery != true else { throw PresentationFixture.Failure.rejected }
        trace.events.append(keepingCurrent ? .workspaceKeep : .workspaceRelease)
        reservedToken = nil
    }

    func apply(_ plan: WorkspaceRestorePlan, ownerToken: UUID?) async -> WorkspaceOperationReceipt {
        ownerTokens.append(ownerToken)
        #expect(ownerToken == reservedToken)
        #expect(plan.id == self.plan.id)
        trace.events.append(.workspaceApply)
        latestReceipt = appliedReceipt
        if let applyGate {
            await withTaskCancellationHandler { await applyGate.suspend() } onCancel: {
                Task { @MainActor [trace] in trace.events.append(.workspaceApplyCancelled) }
            }
        }
        return appliedReceipt
    }

    func reverse(_ receipt: WorkspaceOperationReceipt, ownerToken: UUID?) async -> WorkspaceOperationReceipt {
        ownerTokens.append(ownerToken)
        #expect(ownerToken == reservedToken)
        #expect(receipt.operationID == latestReceipt?.operationID)
        reversedIDs.append(receipt.operationID)
        reverseWasCancelled.append(Task.isCancelled)
        trace.events.append(.workspaceReverse)
        if let reverseGate { await reverseGate.suspend() }
        let next = reverseResults.isEmpty ? makeReceipt(outcome: .completed, recovery: .none) : reverseResults.removeFirst()
        let result = WorkspaceOperationReceipt(
            operationID: next.operationID, planID: next.planID, reversesOperationID: receipt.operationID,
            outcome: next.outcome, issue: next.issue, steps: next.steps, ownerID: next.ownerID
        )
        latestReceipt = result
        return result
    }

    func makeReceipt(outcome: WorkspaceOperationOutcome, recovery: WorkspaceRecoveryState) -> WorkspaceOperationReceipt {
        let stepOutcome: WorkspaceStepOutcome
        switch recovery {
        case .none: stepOutcome = .restored
        case .pending: stepOutcome = outcome == .completed ? .applied : .failed(.writeFailed)
        case .manualRecoveryRequired: stepOutcome = .failed(.manualRecoveryRequired)
        case .manualChangePreserved: stepOutcome = .skipped(.manualChangePreserved)
        }
        return WorkspaceOperationReceipt(
            operationID: UUID(), planID: plan.id, reversesOperationID: latestReceipt?.operationID,
            outcome: outcome, issue: nil,
            steps: plan.steps.map { WorkspaceStepReceipt(step: $0, outcome: stepOutcome, observation: nil, recovery: recovery) },
            ownerID: plan.ownerID
        )
    }
}

@MainActor
private final class PresentationTrace {
    enum Event: Equatable {
        case sceneReserve, scenePreview, sceneApply, scenePending, sceneRestore, sceneKeep, sceneRelease
        case workspaceReserve, workspaceApply, workspaceReverse, workspaceRelease, workspaceKeep
        case awakeAcquire, awakeRelease, sceneApplyCancelled, workspaceApplyCancelled
    }
    var events: [Event] = []

    func waitFor(_ event: Event) async -> Bool {
        for _ in 0..<100 {
            if events.contains(event) { return true }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return events.contains(event)
    }
}

@MainActor
private final class PresentationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func suspend() async {
        if resumed { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async -> Bool {
        for _ in 0..<100 {
            if continuation != nil { return true }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return continuation != nil
    }

    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PresentationClock {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
}

@MainActor
private final class PresentationPowerBackend: PowerAssertionCreating {
    var activeIDs: Set<PowerAssertionID> = []
    var failingReleaseIDs: Set<PowerAssertionID> = []
    var failAllReleases = false
    var failDisplayAcquisition = false
    var releaseAttempts: [PowerAssertionID] = []
    var timeouts: [TimeInterval?] = []
    private var nextID: PowerAssertionID = 1

    func createAssertion(kind: PowerAssertionKind, reason: String, timeout: TimeInterval?) throws(PowerAssertionError) -> PowerAssertionID {
        if failDisplayAcquisition, kind == .preventIdleDisplaySleep { throw .creationFailed(kIOReturnError) }
        let id = nextID
        nextID += 1
        activeIDs.insert(id)
        timeouts.append(timeout)
        return id
    }

    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        releaseAttempts.append(id)
        if failAllReleases || failingReleaseIDs.contains(id) { throw .releaseFailed(kIOReturnError) }
        activeIDs.remove(id)
    }
}

@MainActor
private final class PresentationConditionMonitor: AwakeConditionMonitoring {
    func availableApplications() -> [AwakeApplication] { [] }
    func snapshot(for conditions: AwakeStopConditions) -> AwakeConditionSnapshot {
        AwakeConditionSnapshot(selectedApplicationRunning: nil, battery: .unknown)
    }
    func start(
        conditions: AwakeStopConditions,
        onChange: @escaping @MainActor @Sendable (AwakeConditionSnapshot) -> Void
    ) throws(AwakeConditionMonitorError) {}
    func stop() {}
}

@MainActor
private final class PresentationAwakeScheduler: AwakeExpiryScheduling {
    private var handler: (@MainActor @Sendable () -> Void)?
    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }
    func cancelScheduledExpiry() { handler = nil }
    func fire() { handler?() }
}
