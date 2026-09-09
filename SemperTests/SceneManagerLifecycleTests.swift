import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Scene manager lifecycle")
struct SceneManagerLifecycleTests {
    @Test("Queries and preparation do not activate any domain")
    func dormantQueries() async throws {
        try await withManager { manager, probe, _, _ in
            #expect(manager.availableScenes().count == 1)
            await manager.prepare()
            let domains = try await manager.pendingDomains()
            #expect(domains.isEmpty)
            #expect(probe.prepared.isEmpty)
            #expect(probe.audioBegins == 0)
            #expect(probe.adapter.writeLog.isEmpty)
        }
    }

    @Test("Power-only apply and restore never admit audio")
    func powerOnly() async throws {
        try await withManager { manager, probe, scene, _ in
            _ = try await manager.applyScene(id: scene.id)
            #expect(probe.prepared == [[.power]])
            #expect(probe.audioBegins == 0)
            #expect(try await manager.pendingDomains() == [.power])
            _ = try await manager.restoreScene()
            #expect(probe.prepared == [[.power], [.power]])
            #expect(probe.audioBegins == 0)
            #expect(!manager.hasPendingRestore)
        }
    }

    @Test("Audio admission is balanced only for selected or pending audio controls")
    func selectedAudio() async throws {
        try await withManager(audio: true) { manager, probe, scene, _ in
            _ = try await manager.applyScene(id: scene.id)
            _ = try await manager.restoreScene()
            #expect(probe.prepared == [[.audio], [.audio]])
            #expect(probe.audioBegins == 2)
            #expect(probe.audioEnds == 2)
        }
    }

    @Test("A suspended manager can reserve Presentation without enabling ordinary mutations")
    func suspendedReservation() async throws {
        try await withManager { manager, probe, scene, gate in
            await manager.cancelAndDrain()
            let token = try await manager.reservePresentation()
            #expect(gate.activeSharedPermitCount == 1)
            #expect(probe.prepared.isEmpty)
            await #expect(throws: SceneManagerError.stopped) { try await manager.applyScene(id: scene.id) }
            let preview = try await manager.previewPresentation(scene, token: token)
            #expect(preview.canApply)
            #expect(probe.adapter.writeLog.isEmpty)
            #expect(throws: MutationAdmissionError.self) { try gate.acquire(owner: .awayMode, mode: .exclusive) }
            try await manager.releasePresentation(token)
            #expect(gate.activeSharedPermitCount == 0)
            #expect(manager.isSuspended)
        }
    }

    @Test("Presentation reservation rejects ordinary mutation and wrong tokens")
    func reservationAdmission() async throws {
        try await withManager { manager, probe, scene, gate in
            let token = try await manager.reservePresentation()
            await #expect(throws: SceneManagerError.presentationReserved) { try await manager.applyScene(id: scene.id) }
            await #expect(throws: SceneManagerError.presentationReserved) { try await manager.restoreScene() }
            #expect(throws: SceneManagerError.presentationReserved) { try manager.setShortcut(nil, for: scene.id) }
            manager.delete(scene: scene)
            manager.saveCurrent(named: "Other")
            manager.keepCurrentSetup()
            #expect(manager.scenes == [scene])
            #expect(probe.captures == 0)
            await #expect(throws: SceneManagerError.invalidPresentationToken) {
                try await manager.previewPresentation(scene, token: UUID())
            }
            await #expect(throws: SceneManagerError.invalidPresentationToken) {
                try await manager.releasePresentation(UUID())
            }
            #expect(gate.activeSharedPermitCount == 1)
            try await manager.releasePresentation(token)
        }
    }

    @Test("Reviewed Presentation apply enforces transaction ownership through recovery")
    func presentationRecovery() async throws {
        try await withManager { manager, probe, scene, gate in
            let token = try await manager.reservePresentation()
            let preview = try await manager.previewPresentation(scene, token: token)
            probe.adapter.setCurrentValue(.awake(.displayAndSystem), for: .awakeMode)
            await #expect(throws: SceneApplyError.previewChanged) {
                try await manager.applyPresentation(scene, token: token, expectedPreview: preview)
            }
            probe.adapter.setCurrentValue(.awake(.off), for: .awakeMode)
            let report = try await manager.applyPresentation(scene, token: token, expectedPreview: preview)
            let id = try #require(report.transactionID)
            #expect(try await manager.pendingPresentationTransaction(token: token)?.id == id)
            await #expect(throws: SceneApplyError.self) { try await manager.releasePresentation(token) }
            await #expect(throws: SceneManagerError.presentationTransactionMismatch) {
                try await manager.restorePresentation(transactionID: UUID(), token: token)
            }
            await manager.shutdown()
            #expect(gate.activeSharedPermitCount == 1)
            #expect(manager.hasPendingRestore)
            await #expect(throws: SceneManagerError.stopped) { try await manager.reservePresentation() }
            let restored = try await manager.restorePresentation(transactionID: id, token: token)
            #expect(restored?.journalCleared == true)
            try await manager.releasePresentation(token)
            #expect(gate.activeSharedPermitCount == 0)
            #expect(probe.audioBegins == 0)
        }
    }

    @Test("Presentation keep-current is scoped and preserves reservation until release")
    func presentationKeepCurrent() async throws {
        try await withManager { manager, _, scene, gate in
            let token = try await manager.reservePresentation()
            let report = try await manager.applyPresentation(scene, token: token)
            let id = try #require(report.transactionID)
            await #expect(throws: SceneManagerError.presentationTransactionMismatch) {
                try await manager.keepCurrentPresentation(transactionID: UUID(), token: token)
            }
            try await manager.keepCurrentPresentation(transactionID: id, token: token)
            #expect(!manager.hasPendingRestore)
            #expect(gate.activeSharedPermitCount == 1)
            try await manager.releasePresentation(token)
            #expect(gate.activeSharedPermitCount == 0)
        }
    }

    @Test("Failed Presentation apply retains ownership of incomplete rollback")
    func failedApplyRecoveryOwnership() async throws {
        try await withManager { manager, probe, _, _ in
            let audio: SceneControl = .audioOutputVolume(deviceID: "test")
            probe.adapter.seed(audio, value: .number(0.2))
            probe.adapter.failWrites(for: audio, matching: .number(0.6))
            probe.adapter.failWrites(for: .awakeMode, matching: .awake(.off))
            let scene = SemperScene(
                name: "Incomplete",
                actions: [
                    .init(control: audio, target: .number(0.6), importance: .required),
                    .init(control: .awakeMode, target: .awake(.system), importance: .required),
                ])
            let token = try await manager.reservePresentation()
            await #expect(throws: SceneApplyError.self) { try await manager.applyPresentation(scene, token: token) }
            let transaction = try #require(try await manager.pendingPresentationTransaction(token: token))
            #expect(transaction.sceneID == scene.id)
            #expect(manager.hasPendingRestore)
            probe.adapter.clearWriteFailures(for: audio)
            probe.adapter.clearWriteFailures(for: .awakeMode)
            let restored = try await manager.restorePresentation(transactionID: transaction.id, token: token)
            #expect(restored?.journalCleared == true)
            try await manager.releasePresentation(token)
            #expect(probe.audioBegins == probe.audioEnds)
        }
    }

    @Test("Ordinary recovery remains bounded after shutdown", arguments: [false, true])
    func ordinaryRecoveryAfterShutdown(keepingCurrent: Bool) async throws {
        try await withManager { manager, probe, scene, gate in
            _ = try await manager.applyScene(id: scene.id)
            await manager.shutdown()
            let prepared = probe.prepared.count
            _ = try await manager.recoverPendingScene(keepingCurrent: keepingCurrent)
            #expect(!manager.hasPendingRestore)
            #expect(manager.isSuspended)
            #expect(manager.isShutDown)
            #expect(gate.activeSharedPermitCount == 0)
            #expect(probe.prepared.count == prepared + (keepingCurrent ? 0 : 1))
            await #expect(throws: SceneManagerError.stopped) { try await manager.applyScene(id: scene.id) }
            await #expect(throws: SceneManagerError.stopped) { try await manager.reservePresentation() }
            manager.saveCurrent(named: "Blocked")
            #expect(probe.captures == 0)
            await #expect(throws: SceneManagerError.restoreUnavailable) {
                try await manager.recoverPendingScene(keepingCurrent: keepingCurrent)
            }
        }
    }

    @Test("Ordinary recovery cannot bypass Presentation or Away ownership")
    func ordinaryRecoveryOwnership() async throws {
        try await withManager { manager, probe, scene, gate in
            let token = try await manager.reservePresentation()
            _ = try await manager.applyPresentation(scene, token: token)
            for keeping in [false, true] {
                await #expect(throws: SceneManagerError.presentationReserved) {
                    try await manager.recoverPendingScene(keepingCurrent: keeping)
                }
            }
            let pending = try #require(try await manager.pendingPresentationTransaction(token: token))
            _ = try await manager.restorePresentation(transactionID: pending.id, token: token)
            try await manager.releasePresentation(token)
            _ = try await manager.applyScene(id: scene.id)
            await manager.shutdown()
            let permit = try gate.acquire(owner: .awayMode, mode: .exclusive)
            let writes = probe.adapter.writeLog.count
            for keeping in [false, true] {
                await #expect(throws: SceneManagerError.mutationsBlocked) {
                    try await manager.recoverPendingScene(keepingCurrent: keeping)
                }
            }
            #expect(probe.adapter.writeLog.count == writes)
            #expect(manager.hasPendingRestore)
            gate.release(permit)
            _ = try await manager.recoverPendingScene(keepingCurrent: false)
        }
    }

    @Test("Pending ordinary scenes block Presentation before domain startup")
    func pendingBlocksReservation() async throws {
        try await withManager { manager, probe, scene, gate in
            _ = try await manager.applyScene(id: scene.id)
            let prepared = probe.prepared
            await #expect(throws: SceneApplyError.self) { try await manager.reservePresentation() }
            #expect(gate.activeSharedPermitCount == 0)
            #expect(probe.prepared == prepared)
            _ = try await manager.restoreScene()
        }
    }

    @Test("Shutdown drains UI-created apply before return and rejects late operations")
    func shutdownDrainsUIApply() async throws {
        try await withManager { manager, probe, scene, _ in
            let entered = ManagerLatch()
            let release = ManagerLatch()
            probe.prepareHook = {
                entered.open()
                await release.wait()
            }
            manager.apply(scene: scene)
            await entered.wait()
            var finished = false
            let shutdown = Task {
                await manager.shutdown()
                finished = true
            }
            for _ in 0..<10 { await Task.yield() }
            #expect(!finished)
            release.open()
            await shutdown.value
            #expect(probe.adapter.writeLog.isEmpty)
            #expect(!manager.isBusy)
            #expect(manager.onScenesChanged == nil)
            await #expect(throws: SceneManagerError.stopped) { try await manager.applyScene(id: scene.id) }
            manager.apply(scene: scene)
            for _ in 0..<10 { await Task.yield() }
            #expect(probe.adapter.writeLog.isEmpty)
        }
    }

    @Test("Caller cancellation is forwarded and drain requires explicit resume")
    func callerCancellation() async throws {
        try await withManager { manager, probe, scene, _ in
            let entered = ManagerLatch()
            let release = ManagerLatch()
            var cancelled = false
            probe.prepareHook = {
                entered.open()
                await release.wait()
                cancelled = Task.isCancelled
            }
            let apply = Task { try await manager.applyScene(id: scene.id) }
            await entered.wait()
            apply.cancel()
            release.open()
            await #expect(throws: CancellationError.self) { try await apply.value }
            #expect(cancelled)
            await manager.cancelAndDrain()
            await #expect(throws: SceneManagerError.stopped) { try await manager.applyScene(id: scene.id) }
            probe.prepareHook = nil
            try manager.resume()
            _ = try await manager.applyScene(id: scene.id)
            _ = try await manager.restoreScene()
        }
    }

    @Test("Shutdown prevents a suspended capture from persisting or calling its completion")
    func shutdownDrainsSave() async throws {
        try await withManager { manager, probe, _, _ in
            let entered = ManagerLatch()
            let release = ManagerLatch()
            probe.captureHook = {
                entered.open()
                await release.wait()
            }
            var completed = false
            var changed = false
            manager.onScenesChanged = { changed = true }
            manager.saveCurrent(named: "New scene") { _ in completed = true }
            await entered.wait()
            let shutdown = Task { await manager.shutdown() }
            for _ in 0..<10 { await Task.yield() }
            release.open()
            await shutdown.value
            #expect(manager.scenes.count == 1)
            #expect(!completed)
            #expect(!changed)
        }
    }

    private func withManager(
        audio: Bool = false,
        _ operation: (SceneManager, ManagerProbe, SemperScene, MutationAdmissionGate) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneManagerTests-\(UUID())")
        let library = FileSceneLibraryStore(directory: directory)
        let journal = FileSceneJournalStore(directory: directory)
        let probe = ManagerProbe()
        let control: SceneControl = audio ? .audioOutputVolume(deviceID: "test") : .awakeMode
        let before: SceneValue = audio ? .number(0.2) : .awake(.off)
        let target: SceneValue = audio ? .number(0.6) : .awake(.system)
        probe.adapter.seed(control, value: before)
        let scene = SemperScene(name: "Test", actions: [.init(control: control, target: target, importance: .required)])
        probe.captured = scene.actions
        try library.saveScenes([scene])
        defer {
            do { try FileManager.default.removeItem(at: directory) } catch {
                Issue.record(error, "Could not remove scene manager fixtures")
            }
        }
        let gate = MutationAdmissionGate()
        let manager = SceneManager(
            adapters: .init(audio: probe.adapter, display: probe.adapter, power: probe.adapter),
            prepareDomains: { domains in
                probe.prepared.append(domains)
                await probe.prepareHook?()
            },
            captureCurrent: {
                probe.captures += 1
                await probe.captureHook?()
                return probe.captured
            },
            beginAudioTransaction: { probe.audioBegins += 1 }, endAudioTransaction: { probe.audioEnds += 1 },
            libraryStore: library, journalStore: journal, mutationAdmission: gate)
        try await operation(manager, probe, scene, gate)
        await manager.shutdown()
    }
}

@MainActor
private final class ManagerProbe {
    let adapter = SceneControlAdapterMock()
    var prepared: [Set<SceneControlDomain>] = []
    var captured: [SceneAction] = []
    var captures = 0
    var audioBegins = 0
    var audioEnds = 0
    var prepareHook: (() async -> Void)?
    var captureHook: (() async -> Void)?
}

@MainActor
private final class ManagerLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
