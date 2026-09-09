import Foundation
import Synchronization
import Testing
@testable import Semper

@Suite("Scene preview and scoped recovery")
struct ScenePreviewTests {
    @Test("Preview and apply share snapshots, ordering, and optional skips")
    func previewMatchesApplyWithoutWriting() async throws {
        let fixture = Fixture()
        let display = SceneControl.displayBrightness(displayID: "display-a")
        let contrast = SceneControl.displayContrast(displayID: "display-a")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(display, value: .number(0.2))
        fixture.mock.seed(contrast, capability: .writeOnly, value: .number(0.3))
        let scene = SemperScene(name: "Preview", actions: [
            SceneAction(control: contrast, target: .number(0.6), importance: .optional),
            SceneAction(control: display, target: .number(0.8), importance: .required),
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
        ])

        let preview = try await fixture.coordinator.preview(scene)

        #expect(preview.sceneID == scene.id)
        #expect(preview.canApply)
        #expect(preview.entries.map(\.control) == [.awakeMode, display])
        #expect(preview.entries.map(\.snapshotValue) == [.awake(.off), .number(0.2)])
        #expect(preview.entries.allSatisfy { $0.phase == .pending && $0.appliedValue == nil })
        #expect(preview.skippedOptional == [.init(control: contrast, reason: .capability(.writeOnly))])
        #expect(fixture.mock.writeLog.isEmpty)
        #expect(fixture.journal.loadCount == 0)
        #expect(fixture.journal.saved.isEmpty)
        #expect(fixture.journal.clearCount == 0)

        let applied = try await fixture.coordinator.apply(scene, expectedPreview: preview)

        #expect(fixture.journal.saved.first?.entries == preview.entries)
        #expect(applied.applied.map(\.control) == preview.entries.map(\.control))
        #expect(applied.applied.map(\.snapshotValue) == preview.entries.map(\.snapshotValue))
        #expect(applied.skippedOptional == preview.skippedOptional)
    }

    @Test("Preview collects required capability, target, and read failures just as apply does")
    func requiredFailureParity() async throws {
        let fixture = Fixture()
        let volume = SceneControl.audioOutputVolume(deviceID: "output-a")
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(.awakeMode, capability: .readOnly, value: .awake(.off))
        fixture.mock.seed(.audioOutputDevice, value: .text("output-a"))
        fixture.mock.rejectTarget(for: .audioOutputDevice, reason: "Device disconnected")
        fixture.mock.seed(volume, value: .number(0.3))
        fixture.mock.failReads(for: volume)
        let scene = SemperScene(name: "Unavailable", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: volume, target: .number(0.7), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output-b"), importance: .required),
            SceneAction(control: display, target: .number(0.8), importance: .optional),
        ])

        let preview = try await fixture.coordinator.preview(scene)

        #expect(!preview.canApply)
        #expect(preview.entries.isEmpty)
        #expect(preview.requiredFailures.map(\.control) == [.awakeMode, volume, .audioOutputDevice])
        #expect(preview.skippedOptional == [.init(control: display, reason: .capability(.unsupported))])
        await #expect(throws: SceneApplyError.requiredPreflightFailed(failures: preview.requiredFailures)) {
            try await fixture.coordinator.apply(scene)
        }
        #expect(fixture.mock.writeLog.isEmpty)
        #expect(fixture.journal.saved.isEmpty)
        #expect(fixture.journal.clearCount == 0)
    }

    @Test("Preview preserves prerequisite promotion and missing-prerequisite refusal")
    func prerequisitesMatchApply() async throws {
        let fixture = Fixture()
        let volume = SceneControl.audioOutputVolume(deviceID: "output-b")
        fixture.mock.seed(volume, value: .number(0.3))
        fixture.mock.seed(.audioOutputDevice, value: .text("output-a"))
        fixture.mock.require(volume, beforeWriting: .audioOutputDevice)
        let route = SceneAction(control: .audioOutputDevice, target: .text("output-b"), importance: .required)
        let scene = SemperScene(name: "Route", actions: [
            route,
            SceneAction(control: volume, target: .number(0.7), importance: .optional),
        ])
        let preview = try await fixture.coordinator.preview(scene)
        #expect(preview.canApply)
        #expect(preview.entries.map(\.importance) == [.required, .required])
        _ = try await fixture.coordinator.apply(scene, expectedPreview: preview)
        #expect(fixture.journal.saved.first?.entries == preview.entries)

        let missing = SemperScene(name: "Missing snapshot", actions: [route])
        let missingPreview = try await fixture.coordinator.preview(missing)
        #expect(!missingPreview.canApply)
        #expect(missingPreview.requiredFailures.map(\.control) == [.audioOutputDevice])
        var optionalRoute = route
        optionalRoute.importance = .optional
        let optionalPreview = try await fixture.coordinator.preview(
            SemperScene(name: "Optional route", actions: [optionalRoute])
        )
        #expect(optionalPreview.canApply)
        #expect(optionalPreview.entries.isEmpty)
        #expect(optionalPreview.skippedOptional.map(\.control) == [.audioOutputDevice])
    }

    @Test("Preview leaves even a settled journal untouched")
    func previewDoesNotClearSettledJournal() async throws {
        let transaction = Self.settledTransaction()
        let fixture = Fixture(transaction: transaction)
        fixture.mock.seed(.awakeMode, value: .awake(.off))

        _ = try await fixture.coordinator.preview(Self.awakeScene())

        #expect(fixture.journal.transaction == transaction)
        #expect(fixture.journal.loadCount == 0)
        #expect(fixture.journal.saved.isEmpty)
        #expect(fixture.journal.clearCount == 0)
        #expect(fixture.mock.writeLog.isEmpty)
    }

    enum PreviewChange: CaseIterable, Sendable {
        case snapshot, target, control, sceneID, optionalAvailability, importance
    }

    @Test("Apply rejects changed reviewed preflight before touching the journal", arguments: PreviewChange.allCases)
    func rejectsChangedPreview(change: PreviewChange) async throws {
        let transaction = Self.settledTransaction()
        let fixture = Fixture(transaction: transaction)
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(display, capability: .unsupported, value: .number(0.2))
        var scene = Self.awakeScene()
        scene.actions.append(SceneAction(control: display, target: .number(0.8), importance: .optional))
        let preview = try await fixture.coordinator.preview(scene)
        switch change {
        case .snapshot:
            fixture.mock.setCurrentValue(.awake(.displayAndSystem), for: .awakeMode)
        case .target:
            scene.actions[0].target = .awake(.displayAndSystem)
        case .control:
            scene.actions.removeFirst()
        case .sceneID:
            scene.id = UUID()
        case .optionalAvailability:
            fixture.mock.setCapability(.readWrite, for: display)
        case .importance:
            scene.actions[0].importance = .optional
        }

        await #expect(throws: SceneApplyError.previewChanged) {
            try await fixture.coordinator.apply(scene, expectedPreview: preview)
        }

        #expect(fixture.journal.transaction == transaction)
        #expect(fixture.journal.saved.isEmpty)
        #expect(fixture.journal.clearCount == 0)
        #expect(fixture.mock.writeLog.isEmpty)
    }

    @Test("Scoped restore and abandon reject a different or missing transaction", arguments: [false, true])
    func scopedMismatchIsNonmutating(hasTransaction: Bool) async throws {
        let fixture = Fixture()
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        let actual: UUID?
        if hasTransaction {
            actual = try await fixture.coordinator.apply(Self.awakeScene()).transactionID
        } else {
            actual = nil
        }
        let before = fixture.journal.transaction
        let saves = fixture.journal.saved.count
        let writes = fixture.mock.writeLog
        let expected = UUID()
        let mismatch = SceneRestoreError.transactionMismatch(expected: expected, actual: actual)

        await #expect(throws: mismatch) {
            try await fixture.coordinator.restore(expectedTransactionID: expected)
        }
        await #expect(throws: mismatch) {
            try await fixture.coordinator.abandonPendingTransaction(expectedTransactionID: expected)
        }

        #expect(fixture.journal.transaction == before)
        #expect(fixture.journal.saved.count == saves)
        #expect(fixture.journal.clearCount == 0)
        #expect(fixture.mock.writeLog == writes)
    }

    @Test("Matching scoped restore and abandon preserve their existing effects")
    func matchingScopedRecovery() async throws {
        let fixture = Fixture()
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        let scene = Self.awakeScene()
        let first = try #require(try await fixture.coordinator.apply(scene).transactionID)
        let restored = try #require(try await fixture.coordinator.restore(expectedTransactionID: first))
        #expect(restored.transactionID == first)
        #expect(restored.journalCleared)
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.off))

        let second = try #require(try await fixture.coordinator.apply(scene).transactionID)
        let writes = fixture.mock.writeLog
        try await fixture.coordinator.abandonPendingTransaction(expectedTransactionID: second)
        #expect(fixture.journal.transaction == nil)
        #expect(fixture.mock.writeLog == writes)
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.system))
    }

    @Test("Preview holds the operation gate and cancellation releases it without mutation")
    func previewBusyAndCancellation() async throws {
        let fixture = Fixture()
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.makeReadsCancellationAware()
        let suspension = fixture.mock.suspendNextRead(for: .awakeMode)
        let scene = Self.awakeScene()
        let previewTask = Task { try await fixture.coordinator.preview(scene) }
        #expect(await suspension.waitUntilSuspended())

        await #expect(throws: SceneApplyError.operationInProgress) {
            try await fixture.coordinator.preview(scene)
        }
        await #expect(throws: SceneApplyError.operationInProgress) {
            try await fixture.coordinator.apply(scene)
        }
        await #expect(throws: SceneRestoreError.operationInProgress) {
            try await fixture.coordinator.restore()
        }
        await #expect(throws: SceneRestoreError.operationInProgress) {
            try await fixture.coordinator.abandonPendingTransaction()
        }
        previewTask.cancel()
        await suspension.resume()
        await #expect(throws: CancellationError.self) { try await previewTask.value }
        #expect(fixture.mock.writeLog.isEmpty)
        #expect(fixture.journal.saved.isEmpty)
        #expect(fixture.journal.clearCount == 0)
        #expect(try await fixture.coordinator.preview(scene).canApply)
    }

    @Test("Cancellation between mutation and readback retains rollback ownership", arguments: [false, true])
    func cancellationAfterMutationBeforeReadback(rollbackFails: Bool) async throws {
        let fixture = Fixture()
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.makeReadsCancellationAware()
        fixture.mock.makeWritesCancellationAware()
        let writeSuspension = fixture.mock.suspendNextWrite(for: .awakeMode, matching: .awake(.system))
        let applyTask = Task { try await fixture.coordinator.apply(Self.awakeScene()) }
        #expect(await writeSuspension.waitUntilSuspended())
        let readSuspension = fixture.mock.suspendNextRead(for: .awakeMode)
        await writeSuspension.resume()
        #expect(await readSuspension.waitUntilSuspended())
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.system))
        let pending = try #require(fixture.journal.transaction)
        #expect(pending.entries.first?.phase == .inFlight)
        #expect(pending.entries.first?.appliedValue == nil)
        await #expect(throws: SceneRestoreError.operationInProgress) {
            try await fixture.coordinator.abandonPendingTransaction(expectedTransactionID: pending.id)
        }
        if rollbackFails {
            fixture.mock.failWrites(for: .awakeMode, matching: .awake(.off))
        }
        applyTask.cancel()
        await readSuspension.resume()

        do {
            _ = try await applyTask.value
            Issue.record("Expected cancellation to unwind the mutated control")
        } catch let error as SceneApplyError {
            guard case .actionFailed(let control, _, let cleanup) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(control == .awakeMode)
            #expect(cleanup == (rollbackFails ? .rollbackIncomplete(controls: [.awakeMode]) : .rolledBack))
        }
        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        if rollbackFails {
            #expect(fixture.journal.transaction?.id == pending.id)
            #expect(fixture.journal.transaction?.entries.first?.phase == .inFlight)
            fixture.mock.clearWriteFailures(for: .awakeMode)
            _ = try await fixture.coordinator.restore(expectedTransactionID: pending.id)
        }
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.off))
        #expect(fixture.journal.transaction == nil)
    }

    private static func awakeScene() -> SemperScene {
        SemperScene(name: "Awake preview", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
        ])
    }

    private static func settledTransaction() -> SceneTransaction {
        SceneTransaction(sceneID: UUID(), sceneName: "Settled", startedAt: SceneTestSupport.fixedDate, entries: [
            SceneTransactionEntry(
                control: .awakeMode,
                importance: .required,
                snapshotValue: .awake(.off),
                targetValue: .awake(.system),
                appliedValue: .awake(.system),
                phase: .restored
            ),
        ])
    }

    private struct Fixture {
        let mock = SceneControlAdapterMock()
        let journal: PreviewJournalSpy
        let coordinator: SceneCoordinator

        init(transaction: SceneTransaction? = nil) {
            journal = PreviewJournalSpy(transaction: transaction)
            coordinator = SceneCoordinator(
                adapters: SceneTestSupport.registry(mock),
                journalStore: journal,
                now: { SceneTestSupport.fixedDate }
            )
        }
    }
}

private nonisolated final class PreviewJournalSpy: SceneJournalStoring {
    private struct State {
        var transaction: SceneTransaction?
        var saved: [SceneTransaction] = []
        var loadCount = 0
        var clearCount = 0
    }

    private let state: Mutex<State>

    init(transaction: SceneTransaction?) {
        state = Mutex(State(transaction: transaction))
    }

    var transaction: SceneTransaction? { state.withLock { $0.transaction } }
    var saved: [SceneTransaction] { state.withLock { $0.saved } }
    var loadCount: Int { state.withLock { $0.loadCount } }
    var clearCount: Int { state.withLock { $0.clearCount } }

    func load() throws -> SceneTransaction? {
        state.withLock {
            $0.loadCount += 1
            return $0.transaction
        }
    }

    func save(_ transaction: SceneTransaction) throws {
        try transaction.validate()
        state.withLock {
            $0.transaction = transaction
            $0.saved.append(transaction)
        }
    }

    func clear() throws {
        state.withLock {
            $0.transaction = nil
            $0.clearCount += 1
        }
    }
}
