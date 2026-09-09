import Foundation
import Testing

@testable import Semper

@Suite("Safe Eject confirmed batches", .timeLimit(.minutes(1)))
@MainActor
struct SafeEjectBatchTests {
    @Test("Review has no device effects or shared permit and excludes mounted siblings")
    func reviewOnly() throws {
        let first = batchVolume(1)
        let sibling = batchVolume(2, device: first.deviceID)
        let independent = batchVolume(3)
        let internalVolume = batchVolume(4, internalVolume: true)
        let backend = SafeEjectBatchBackend([first, sibling, independent, internalVolume])
        let gate = MutationAdmissionGate()
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)
        let service = SafeEjectService(backend: backend, mutationAdmission: gate)
        service.start()
        let preview = try service.prepareBatch().get()
        #expect(preview.eligible == [independent])
        #expect(preview.excluded.map(\.volume) == [first, sibling])
        #expect(preview.excluded.allSatisfy { $0.reason == .otherMountedVolumes })
        #expect(service.pendingBatchConfirmation == preview)
        #expect(backend.unmounted.isEmpty && backend.ejected.isEmpty)
        #expect(gate.activeSharedPermitCount == 0)
        #expect(gate.activeExclusiveOwner == .awayMode)
        gate.release(exclusive)
    }

    @Test("Unknown backing remains an explicit exclusion and cannot execute an empty batch")
    func unknownBacking() async throws {
        let selected = batchVolume(1)
        let unknown = SafeEjectVolume(
            id: batchVolume(2).id, name: "Fixture 2", deviceID: nil,
            isInternal: false, isRemovable: true, isEjectable: true, isRoot: false)
        let backend = SafeEjectBatchBackend([selected, unknown])
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        #expect(preview.eligible.isEmpty)
        #expect(preview.excluded.map(\.reason) == [.incompleteInventory, .unknownDevice])
        #expect(await failure(service.ejectBatch(confirmationID: preview.id)) == .noEligibleVolumes)
        #expect(service.pendingBatchConfirmation == nil)
        #expect(backend.unmounted.isEmpty)
    }

    @Test("More than 128 candidates fails before retaining a preview or touching a device")
    func reviewLimit() {
        let backend = SafeEjectBatchBackend((1...129).map { batchVolume($0) })
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(failure(service.prepareBatch()) == .batchLimitExceeded)
        #expect(service.pendingBatchConfirmation == nil)
        #expect(backend.unmounted.isEmpty && backend.ejected.isEmpty)
    }

    @Test("A duplicate identity cannot produce an ambiguous confirmation")
    func duplicateIdentity() {
        let volume = batchVolume(1)
        let backend = SafeEjectBatchBackend([volume, volume])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(failure(service.prepareBatch()) == .incompleteInventory)
    }

    @Test("Review replaces the prior approval; discard and execution prevent approval replay")
    func singleUseConfirmation() async throws {
        let backend = SafeEjectBatchBackend([batchVolume(1)])
        let service = SafeEjectService(backend: backend)
        service.start()
        let first = try service.prepareBatch().get()
        let second = try service.prepareBatch().get()
        #expect(first.id != second.id)
        #expect(await failure(service.ejectBatch(confirmationID: first.id)) == .invalidConfirmation)
        service.discardBatchConfirmation()
        #expect(await failure(service.ejectBatch(confirmationID: second.id)) == .invalidConfirmation)
        let third = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: third.id).get()
        #expect(report.ejectedCount == 1)
        #expect(await failure(service.ejectBatch(confirmationID: third.id)) == .invalidConfirmation)
        #expect(backend.unmounted.count == 1 && backend.ejected.count == 1)
    }

    @Test("Only approved records execute; a newly attached volume is never added")
    func fixedMembership() async throws {
        let first = batchVolume(1)
        let added = batchVolume(2)
        let backend = SafeEjectBatchBackend([first])
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        backend.attach(added)
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(report.items.map(\.volume) == [first])
        #expect(report.ejectedCount == 1)
        #expect(backend.mounted == [added])
        #expect(backend.unmounted == [first.id])
    }

    @Test("Full approved records are revalidated before each item")
    func changedRecord() async throws {
        let first = batchVolume(1)
        let second = batchVolume(2)
        let changed = batchVolume(2, device: batchVolume(8).deviceID, internalVolume: true)
        let backend = SafeEjectBatchBackend([first, second])
        backend.afterEject = { volume in
            if volume.id == first.id { backend.mounted = [changed] }
        }
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(report.items.map(\.outcome) == [.completed(.ejected), .completed(.refused(.changedVolume))])
        #expect(backend.unmounted == [first.id])
        #expect(report.failedCount == 1)
    }

    @Test("A reappeared volume with a different registry identity is refused")
    func reappearedVolume() async throws {
        let original = batchVolume(1)
        let replacement = SafeEjectVolume(
            id: .init(
                bsdName: original.id.bsdName, registryID: 999, volumeUUID: original.id.volumeUUID,
                mountURL: original.id.mountURL),
            name: original.name, deviceID: original.deviceID,
            isInternal: false, isRemovable: true, isEjectable: true, isRoot: false)
        let backend = SafeEjectBatchBackend([original])
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        backend.mounted = [replacement]
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(report.items[0].outcome == .completed(.refused(.changedVolume)))
        #expect(backend.unmounted.isEmpty)
    }

    @Test("A newly mounted sibling refuses its approved volume without broadening scope")
    func newSibling() async throws {
        let first = batchVolume(1)
        let second = batchVolume(2)
        let backend = SafeEjectBatchBackend([first, second])
        backend.afterEject = { volume in
            if volume.id == first.id { backend.attach(batchVolume(3, device: second.deviceID)) }
        }
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(report.items[1].outcome == .completed(.refused(.otherMountedVolumes)))
        #expect(backend.unmounted == [first.id])
    }

    @Test(
        "A local denial yields a partial report and does not retry",
        arguments: [
            SafeEjectFailure.busy, .denied, .unsupported, .system(123),
        ])
    func localDenial(failure: SafeEjectFailure) async throws {
        let first = batchVolume(1)
        let second = batchVolume(2)
        let backend = SafeEjectBatchBackend([first, second])
        backend.unmountFailures[first.id] = failure
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(report.items.map(\.outcome) == [.completed(.unverified(failure)), .completed(.ejected)])
        #expect(report.ejectedCount == 1 && report.failedCount == 1 && report.notAttemptedCount == 0)
        #expect(backend.unmounted == [first.id, second.id])
        #expect(backend.ejected == [second.id])
    }

    @Test("Unavailable verification stops remaining work with a distinct not-attempted result")
    func verificationUnavailable() async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2), batchVolume(3)])
        backend.afterEject = { _ in backend.inventoryFailure = .unavailable }
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(
            report.items.map(\.outcome) == [
                .completed(.unverified(.unavailable)), .notAttempted(.failure(.unavailable)),
                .notAttempted(.failure(.unavailable)),
            ])
        #expect(backend.unmounted == [first.id])
        #expect(service.receipts.count == 1)
        #expect(report.notAttemptedCount == 2)
    }

    @Test("Timeout stops the remaining batch without an automatic retry")
    func timeoutStops() async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2)])
        backend.unmountFailures[first.id] = .timedOut
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(
            report.items.map(\.outcome) == [
                .completed(.unverified(.timedOut)), .notAttempted(.failure(.timedOut)),
            ])
        #expect(backend.unmounted == [first.id] && backend.ejected.isEmpty)
    }

    @Test("One outer admission and one shared permit span every item and suspended cancellation cleanup")
    func batchAdmissionAndCancellation() async throws {
        let first = batchVolume(1)
        let second = batchVolume(2)
        let third = batchVolume(3)
        let backend = SafeEjectBatchBackend([first, second, third])
        let firstGate = SafeEjectBatchSuspension()
        let secondGate = SafeEjectBatchSuspension()
        let cleanupGate = SafeEjectBatchSuspension()
        backend.unmountGates = [first.id: firstGate, second.id: secondGate]
        backend.cleanupGate = cleanupGate
        let gate = MutationAdmissionGate()
        let service = SafeEjectService(backend: backend, mutationAdmission: gate)
        service.start()
        let preview = try service.prepareBatch().get()
        let task = Task { await service.ejectBatch(confirmationID: preview.id) }
        await firstGate.waitForEntry()
        #expect(service.pendingBatchConfirmation == nil)
        #expect(gate.activeSharedPermitCount == 1)
        #expect(await service.eject(second) == .refused(.operationInProgress))
        #expect(await failure(service.ejectBatch(confirmationID: preview.id)) == .operationInProgress)
        #expect(failure(service.prepareBatch()) == .operationInProgress)
        #expect(backend.unmounted == [first.id])
        firstGate.release()
        await secondGate.waitForEntry()
        #expect(service.batchProgress?.completedCount == 1)
        #expect(service.batchProgress?.currentVolume == second)
        #expect(gate.activeSharedPermitCount == 1)
        service.cancelBatch()
        #expect(service.batchProgress?.isCancelling == true)
        secondGate.release()
        await cleanupGate.waitForEntry()
        #expect(service.isEjecting)
        #expect(gate.activeSharedPermitCount == 1)
        #expect(await service.eject(third) == .refused(.operationInProgress))
        cleanupGate.release()
        let report = try await task.value.get()
        #expect(
            report.items.map(\.outcome) == [
                .completed(.ejected), .completed(.unverified(.interrupted)), .notAttempted(.cancelled),
            ])
        #expect(backend.ejected == [first.id])
        #expect(!service.isEjecting && service.batchProgress == nil)
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("A standalone request owns admission against batch execution")
    func singleBlocksBatch() async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2)])
        let suspension = SafeEjectBatchSuspension()
        backend.unmountGates[first.id] = suspension
        let gate = MutationAdmissionGate()
        let service = SafeEjectService(backend: backend, mutationAdmission: gate)
        service.start()
        let preview = try service.prepareBatch().get()
        let task = Task { await service.eject(first) }
        await suspension.waitForEntry()
        #expect(gate.activeSharedPermitCount == 1)
        #expect(await failure(service.ejectBatch(confirmationID: preview.id)) == .operationInProgress)
        suspension.release()
        #expect(await task.value == .ejected)
        #expect(gate.activeSharedPermitCount == 0)
        #expect(await failure(service.ejectBatch(confirmationID: preview.id)) == .invalidConfirmation)
    }

    @Test("Caller cancellation cancels submitted work and never submits the remaining items")
    func callerCancellation() async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2)])
        let suspension = SafeEjectBatchSuspension()
        backend.unmountGates[first.id] = suspension
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let task = Task { await service.ejectBatch(confirmationID: preview.id) }
        await suspension.waitForEntry()
        task.cancel()
        await backend.cancelled.wait()
        suspension.release()
        let report = try await task.value.get()
        #expect(report.items.map(\.outcome) == [.completed(.unverified(.interrupted)), .notAttempted(.cancelled)])
        #expect(backend.unmounted == [first.id] && backend.ejected.isEmpty)
        #expect(backend.drainCalls == 1)
    }

    @Test("Cancellation before execution marks every item not attempted")
    func alreadyCancelled() async throws {
        let backend = SafeEjectBatchBackend([batchVolume(1), batchVolume(2)])
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let start = SafeEjectBatchSuspension()
        let task = Task {
            await start.suspend()
            return await service.ejectBatch(confirmationID: preview.id)
        }
        await start.waitForEntry()
        task.cancel()
        start.release()
        let report = try await task.value.get()
        #expect(report.items.allSatisfy { $0.outcome == .notAttempted(.cancelled) })
        #expect(backend.unmounted.isEmpty && backend.ejected.isEmpty)
    }

    @Test(
        "Pause, sleep and shutdown stop the queue and cannot restart an in-flight batch",
        arguments: [
            SafeEjectBatchStopReason.paused, .sleeping, .shutDown,
        ])
    func lifecycleStops(reason: SafeEjectBatchStopReason) async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2)])
        let suspension = SafeEjectBatchSuspension()
        backend.unmountGates[first.id] = suspension
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let task = Task { await service.ejectBatch(confirmationID: preview.id) }
        await suspension.waitForEntry()
        switch reason {
        case .paused:
            service.pause()
            service.start()
        case .sleeping:
            backend.emit(.willSleep)
            backend.emit(.didWake)
        case .shutDown:
            service.shutdown()
            service.start()
        default: Issue.record("Unexpected lifecycle test input")
        }
        #expect(backend.startCalls == 1)
        suspension.release()
        let report = try await task.value.get()
        #expect(report.items.map(\.outcome) == [.completed(.unverified(.interrupted)), .notAttempted(reason)])
        #expect(backend.ejected.isEmpty)
        if reason == .shutDown {
            #expect(service.lastBatchResult == nil && service.receipts.isEmpty)
        } else {
            #expect(service.lastBatchResult == report)
        }
    }

    @Test("An exclusive owner refuses single and confirmed batch before device work")
    func exclusiveOwnerBlocks() async throws {
        let volume = batchVolume(1)
        let backend = SafeEjectBatchBackend([volume])
        let gate = MutationAdmissionGate()
        let service = SafeEjectService(backend: backend, mutationAdmission: gate)
        service.start()
        let preview = try service.prepareBatch().get()
        let permit = try gate.acquire(owner: .awayMode, mode: .exclusive)
        #expect(await service.eject(volume) == .refused(.operationInProgress))
        #expect(await failure(service.ejectBatch(confirmationID: preview.id)) == .operationInProgress)
        #expect(backend.unmounted.isEmpty && backend.ejected.isEmpty)
        #expect(gate.activeSharedPermitCount == 0)
        #expect(service.pendingBatchConfirmation == nil)
        gate.release(permit)
        #expect(await failure(service.ejectBatch(confirmationID: preview.id)) == .invalidConfirmation)
    }

    @Test("Cleanup failure retains the shared permit through stop and releases only on deliberate successful retry")
    func cleanupFailureRetainsPermit() async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2)])
        backend.unmountFailures[first.id] = .cleanupPending
        backend.cleanupResult = .failure(.cleanupPending)
        let gate = MutationAdmissionGate()
        let service = SafeEjectService(backend: backend, mutationAdmission: gate)
        service.start()
        let preview = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(
            report.items.map(\.outcome) == [
                .completed(.unverified(.cleanupPending)), .notAttempted(.failure(.cleanupPending)),
            ])
        #expect(service.cleanupFailure == .cleanupPending)
        #expect(gate.activeSharedPermitCount == 1)
        #expect(backend.drainCalls == 0)
        #expect(throws: MutationAdmissionError.self) { try gate.acquire(owner: .awayMode, mode: .exclusive) }
        service.pause()
        service.start()
        #expect(service.state == .paused)
        #expect(await failure(service.waitForCleanup()) == .cleanupPending)
        #expect(gate.activeSharedPermitCount == 1)
        #expect(failure(service.prepareBatch()) == .cleanupPending)
        backend.cleanupResult = .success(())
        try await service.waitForCleanup().get()
        #expect(service.cleanupFailure == nil)
        #expect(gate.activeSharedPermitCount == 0)
        #expect(backend.drainCalls == 2)
        #expect(backend.unmounted == [first.id])
    }

    @Test("A cancelled batch holds admission while failed cleanup is retained")
    func cancellationCleanupFailure() async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2)])
        let suspension = SafeEjectBatchSuspension()
        backend.unmountGates[first.id] = suspension
        backend.cleanupResult = .failure(.cleanupPending)
        let gate = MutationAdmissionGate()
        let service = SafeEjectService(backend: backend, mutationAdmission: gate)
        service.start()
        let preview = try service.prepareBatch().get()
        let task = Task { await service.ejectBatch(confirmationID: preview.id) }
        await suspension.waitForEntry()
        service.cancelBatch()
        suspension.release()
        _ = try await task.value.get()
        #expect(service.cleanupFailure == .cleanupPending)
        #expect(gate.activeSharedPermitCount == 1)
        #expect(backend.drainCalls == 1)
        service.shutdown()
        backend.cleanupResult = .success(())
        try await service.waitForCleanup().get()
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("A successful explicit drain cannot release the permit before the cancelled request returns")
    func cleanupSuccessBeforeCallback() async throws {
        let first = batchVolume(1)
        let backend = SafeEjectBatchBackend([first, batchVolume(2)])
        let suspension = SafeEjectBatchSuspension()
        backend.unmountGates[first.id] = suspension
        let gate = MutationAdmissionGate()
        let service = SafeEjectService(backend: backend, mutationAdmission: gate)
        service.start()
        let preview = try service.prepareBatch().get()
        let task = Task { await service.ejectBatch(confirmationID: preview.id) }
        await suspension.waitForEntry()
        service.pause()
        try await service.waitForCleanup().get()
        #expect(service.isEjecting)
        #expect(gate.activeSharedPermitCount == 1)
        #expect(throws: MutationAdmissionError.self) { try gate.acquire(owner: .awayMode, mode: .exclusive) }
        suspension.release()
        let report = try await task.value.get()
        #expect(report.items.last?.outcome == .notAttempted(.paused))
        #expect(backend.drainCalls == 1)
        #expect(!service.isEjecting && gate.activeSharedPermitCount == 0)
    }

    @Test("Pause invalidates an approval even after restarting")
    func pauseInvalidatesReview() async throws {
        let backend = SafeEjectBatchBackend([batchVolume(1)])
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        service.pause()
        service.start()
        #expect(await failure(service.ejectBatch(confirmationID: preview.id)) == .invalidConfirmation)
        #expect(backend.unmounted.isEmpty && backend.ejected.isEmpty)
    }

    @Test("Mutation admission installation is idle and cannot replace an active gate")
    func gateInstallation() throws {
        let backend = SafeEjectBatchBackend([batchVolume(1)])
        let gate = MutationAdmissionGate()
        let service = SafeEjectService(backend: backend)
        try service.installMutationAdmission(gate)
        try service.installMutationAdmission(gate)
        #expect(backend.startCalls == 0 && backend.inventoryCalls == 0)
        #expect(gate.activeSharedPermitCount == 0)
        #expect(throws: SafeEjectFailure.operationInProgress) {
            try service.installMutationAdmission(MutationAdmissionGate())
        }
        service.start()
        #expect(throws: SafeEjectFailure.operationInProgress) { try service.installMutationAdmission(gate) }
    }

    @Test("The retained report is bounded and recent receipts remain capped at twenty")
    func boundedResults() async throws {
        let backend = SafeEjectBatchBackend((1...128).map { batchVolume($0) })
        let service = SafeEjectService(backend: backend)
        service.start()
        let preview = try service.prepareBatch().get()
        let report = try await service.ejectBatch(confirmationID: preview.id).get()
        #expect(report.items.count == 128 && report.ejectedCount == 128)
        #expect(service.receipts.count == 20)
        #expect(service.lastBatchResult == report)
        let added = batchVolume(129)
        backend.attach(added)
        service.refresh()
        #expect(await service.eject(added) == .ejected)
        #expect(service.lastBatchResult == report)
        #expect(service.receipts.count == 20 && service.receipts.first?.volumeID == added.id)
        service.clearResults()
        #expect(service.receipts.isEmpty && service.lastBatchResult == nil)
    }

    @Test("Batch commands create confirmation and navigate without executing storage actions")
    func commandReview() throws {
        let backend = SafeEjectBatchBackend([batchVolume(1)])
        let service = SafeEjectService(backend: backend)
        service.start()
        var opened = 0
        try SafeEjectModule.handle(.ejectAllEligible, service: service) { opened += 1 }
        let first = try #require(service.pendingBatchConfirmation)
        try SafeEjectModule.handle(.ejectAllEligible, service: service) { opened += 1 }
        #expect(service.pendingBatchConfirmation?.id != first.id)
        #expect(opened == 2)
        #expect(backend.unmounted.isEmpty && backend.ejected.isEmpty)
    }

    @Test("A failed batch review still navigates to details and never ejects")
    func commandErrorNavigates() {
        let backend = SafeEjectBatchBackend([batchVolume(1)])
        let service = SafeEjectService(backend: backend)
        var opened = false
        #expect(throws: SafeEjectFailure.paused) {
            try SafeEjectModule.handle(.ejectAllEligible, service: service) { opened = true }
        }
        #expect(opened)
        #expect(service.pendingBatchConfirmation == nil)
        #expect(backend.unmounted.isEmpty && backend.ejected.isEmpty)
    }
}

@MainActor
private func batchVolume(
    _ index: Int, device: SafeEjectDeviceID? = nil, internalVolume: Bool = false
) -> SafeEjectVolume {
    SafeEjectVolume(
        id: .init(
            bsdName: "disk\(index)s1", registryID: UInt64(index * 10), volumeUUID: "fixture-\(index)",
            mountURL: URL(fileURLWithPath: "/Volumes/Fixture-\(index)")),
        name: "Fixture \(index)",
        deviceID: device ?? .init(bsdName: "disk\(index)", registryID: UInt64(index)),
        isInternal: internalVolume, isRemovable: false, isEjectable: !internalVolume, isRoot: false)
}

private func failure<Value>(_ result: Result<Value, SafeEjectFailure>) -> SafeEjectFailure? {
    if case .failure(let failure) = result { return failure }
    return nil
}

@MainActor
private final class SafeEjectBatchSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let current = waiters
        waiters = []
        for waiter in current { waiter.resume() }
    }
}

@MainActor
private final class SafeEjectBatchSuspension {
    private let entered = SafeEjectBatchSignal()
    private let released = SafeEjectBatchSignal()
    func suspend() async {
        entered.signal()
        await released.wait()
    }
    func waitForEntry() async { await entered.wait() }
    func release() { released.signal() }
}

@MainActor
private final class SafeEjectBatchBackend: SafeEjectBackend {
    var mounted: [SafeEjectVolume]
    var presentDevices: Set<SafeEjectDeviceID>
    var inventoryFailure: SafeEjectFailure?
    var unmountFailures: [SafeEjectVolumeID: SafeEjectFailure] = [:]
    var unmountGates: [SafeEjectVolumeID: SafeEjectBatchSuspension] = [:]
    var cleanupGate: SafeEjectBatchSuspension?
    var cleanupResult: Result<Void, SafeEjectFailure> = .success(())
    var afterEject: ((SafeEjectVolume) -> Void)?
    var unmounted: [SafeEjectVolumeID] = []
    var ejected: [SafeEjectVolumeID] = []
    var startCalls = 0
    var inventoryCalls = 0
    var drainCalls = 0
    let cancelled = SafeEjectBatchSignal()
    private var handler: (@MainActor (SafeEjectSystemEvent) -> Void)?
    init(_ volumes: [SafeEjectVolume]) {
        mounted = volumes
        presentDevices = Set(volumes.compactMap(\.deviceID))
    }
    func attach(_ volume: SafeEjectVolume) {
        mounted.append(volume)
        if let deviceID = volume.deviceID { presentDevices.insert(deviceID) }
    }
    func start(onEvent: @escaping @MainActor (SafeEjectSystemEvent) -> Void) throws {
        startCalls += 1
        handler = onEvent
    }
    func stop() { handler = nil }
    func emit(_ event: SafeEjectSystemEvent) { handler?(event) }
    func cancelPendingOperation() { cancelled.signal() }
    func drain() async -> Result<Void, SafeEjectFailure> {
        drainCalls += 1
        if let cleanupGate { await cleanupGate.suspend() }
        if case .success = cleanupResult, inventoryFailure == .cleanupPending { inventoryFailure = nil }
        return cleanupResult
    }
    func inventory() throws -> SafeEjectInventory {
        inventoryCalls += 1
        if let inventoryFailure { throw inventoryFailure }
        return .init(volumes: mounted, hasUnidentifiedLocalVolumes: false)
    }
    func unmount(_ volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        unmounted.append(volume.id)
        if let gate = unmountGates[volume.id] { await gate.suspend() }
        if let failure = unmountFailures[volume.id] {
            if failure == .cleanupPending { inventoryFailure = .cleanupPending }
            return .failure(failure)
        }
        mounted.removeAll { $0.id == volume.id }
        return .success(())
    }
    func ejectDevice(containing volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        ejected.append(volume.id)
        if let deviceID = volume.deviceID { presentDevices.remove(deviceID) }
        afterEject?(volume)
        return .success(())
    }
    func devicePresence(_ id: SafeEjectDeviceID) -> SafeEjectDevicePresence {
        presentDevices.contains(id) ? .present : .absent
    }
}
