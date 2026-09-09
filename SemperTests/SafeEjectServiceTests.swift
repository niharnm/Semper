import DiskArbitration
import Foundation
import Testing

@testable import Semper

@Suite("Safe Eject lifecycle and observed results")
@MainActor
struct SafeEjectServiceTests {
    @Test("Construction is idle; start, pause and shutdown own monitoring")
    func lifecycle() {
        let backend = SafeEjectTestBackend()
        let service = SafeEjectService(backend: backend)
        #expect(backend.startCalls == 0)
        #expect(backend.inventoryCalls == 0)
        service.start()
        service.start()
        #expect(backend.startCalls == 1)
        #expect(backend.inventoryCalls == 1)
        service.pause()
        let reads = backend.inventoryCalls
        service.refresh()
        backend.emit(.volumesChanged)
        #expect(backend.inventoryCalls == reads)
        #expect(!backend.isMonitoring)
        service.start()
        #expect(backend.startCalls == 2)
        service.shutdown()
        service.start()
        #expect(service.state == .shutDown)
        #expect(!backend.isMonitoring)
        #expect(backend.startCalls == 2)
    }

    @Test("Releasing the service removes owned monitoring")
    func releaseStopsMonitoring() {
        let backend = SafeEjectTestBackend()
        var service: SafeEjectService? = SafeEjectService(backend: backend)
        service?.start()
        #expect(backend.isMonitoring)
        service = nil
        #expect(!backend.isMonitoring)
    }

    @Test("A failed start cleans up and exposes a failure")
    func failedStart() {
        let backend = SafeEjectTestBackend()
        backend.startFails = true
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(service.state == .paused)
        #expect(service.inventoryFailure == .unavailable)
        #expect(!backend.isMonitoring)
        #expect(backend.inventoryCalls == 0)
    }

    @Test("Only candidate external or removable volumes are listed")
    func eligibility() {
        let backend = SafeEjectTestBackend()
        let external = volume()
        let internalVolume = volume(index: 2, isInternal: true)
        let unknown = volume(index: 3, isInternal: nil)
        let removable = volume(index: 4, isInternal: true, isRemovable: true)
        let root = volume(index: 5, isInternal: false, isRoot: true)
        backend.mounted = [external, internalVolume, unknown, removable, root]
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(Set(service.volumes.map(\.id)) == [external.id, removable.id])
        #expect(service.refusal(for: internalVolume) == .ineligible)
        #expect(service.refusal(for: root) == .ineligible)
    }

    @Test("Other mounted partitions block physical eject before any mutation")
    func siblingProtection() async {
        let selected = volume()
        let sibling = volume(index: 2, device: selected.deviceID, isInternal: true)
        let backend = SafeEjectTestBackend(mounted: [selected, sibling])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .refused(.otherMountedVolumes))
        #expect(backend.unmountCalls == 0)
        #expect(backend.ejectCalls == 0)
    }

    @Test("Unknown local-volume mapping blocks eject rather than hiding a sibling")
    func incompleteInventory() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.hasUnidentified = true
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .refused(.incompleteInventory))
        #expect(backend.unmountCalls == 0)
    }

    @Test("An identified volume with unknown whole-device mapping cannot hide a sibling")
    func unknownSiblingDevice() async {
        let selected = volume()
        let sibling = SafeEjectVolume(
            id: volume(index: 2).id, name: "Unmapped fixture", deviceID: nil,
            isInternal: false, isRemovable: true, isEjectable: true, isRoot: false
        )
        let backend = SafeEjectTestBackend(mounted: [selected, sibling])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .refused(.incompleteInventory))
        #expect(backend.unmountCalls == 0)
    }

    @Test("Reconnected volume with a reused BSD name cannot reuse old selection")
    func staleConnection() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        let service = SafeEjectService(backend: backend)
        service.start()
        backend.mounted = [volume(registryID: 999)]
        #expect(await service.eject(selected) == .refused(.changedVolume))
        #expect(backend.unmountCalls == 0)
    }

    @Test("An unchanged volume ID cannot retain a changed device association or eligibility")
    func staleMetadata() async {
        let selected = volume()
        for replacement in [
            volume(device: SafeEjectDeviceID(bsdName: "disk9", registryID: 999)),
            volume(isInternal: true),
        ] {
            let backend = SafeEjectTestBackend(mounted: [selected])
            let service = SafeEjectService(backend: backend)
            service.start()
            backend.mounted = [replacement]
            #expect(await service.eject(selected) == .refused(.changedVolume))
            #expect(backend.unmountCalls == 0)
        }
    }

    @Test("A successful callback alone is insufficient while volume remains mounted")
    func unmountReadback() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.removeOnUnmount = false
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .unverified(.stillMounted))
        #expect(backend.ejectCalls == 0)
    }

    @Test("A sibling mounting between unmount and eject stops physical eject")
    func siblingMountRace() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.onUnmount = { backend.mounted = [volume(index: 2, device: selected.deviceID)] }
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .unmountedOnly(.otherMountedVolumes))
        #expect(backend.ejectCalls == 0)
    }

    @Test("Sudden device disappearance after unmount is not credited as eject success")
    func disconnectRace() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.onUnmount = { backend.presentDevices = [] }
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .unmountedOnly(.changedVolume))
        #expect(backend.ejectCalls == 0)
    }

    @Test("Busy and denied API results remain failures and are never retried")
    func systemDenial() async {
        for failure: SafeEjectFailure in [.busy, .denied, .unsupported, .system(17)] {
            let selected = volume()
            let backend = SafeEjectTestBackend(mounted: [selected])
            backend.unmountFailure = failure
            let service = SafeEjectService(backend: backend)
            service.start()
            #expect(await service.eject(selected) == .unverified(failure))
            backend.emit(.volumesChanged)
            #expect(backend.unmountCalls == 1)
            #expect(backend.ejectCalls == 0)
        }
    }

    @Test("Unmount success plus eject failure reports a partial result")
    func partialFailure() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.ejectFailure = .denied
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .unmountedOnly(.denied))
        #expect(backend.unmountCalls == 1)
        #expect(backend.ejectCalls == 1)
    }

    @Test("Eject callback without observed device removal is reported as unverified")
    func ejectReadback() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.removeDeviceOnEject = false
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .unmountedOnly(.deviceStillPresent))
    }

    @Test("A remounted replacement at the same path invalidates completion")
    func remountDuringEject() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.onEject = { backend.mounted = [volume(registryID: 999)] }
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .unverified(.stillMounted))
    }

    @Test("Verified success requires unmount, eject acknowledgment, and absent device")
    func verifiedSuccess() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .ejected)
        #expect(backend.unmountCalls == 1)
        #expect(backend.ejectCalls == 1)
        #expect(service.activeVolumeID == nil)
        #expect(service.volumes.isEmpty)
        #expect(service.receipts.first?.outcome == .ejected)
        service.shutdown()
        #expect(service.receipts.isEmpty)
    }

    @Test("Pause during the unmount callback prevents a follow-on eject")
    func pauseDuringOperation() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        let service = SafeEjectService(backend: backend)
        service.start()
        backend.onUnmount = { service.pause() }
        #expect(await service.eject(selected) == .unverified(.interrupted))
        #expect(backend.ejectCalls == 0)
        #expect(!backend.isMonitoring)
        #expect(service.volumes.isEmpty)
    }

    @Test("Sleep invalidates an in-flight request, and wake only refreshes")
    func sleepAndWake() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        let service = SafeEjectService(backend: backend)
        service.start()
        backend.onUnmount = { backend.emit(.willSleep) }
        #expect(await service.eject(selected) == .unverified(.interrupted))
        #expect(service.state == .sleeping)
        let reads = backend.inventoryCalls
        backend.emit(.volumesChanged)
        #expect(backend.inventoryCalls == reads)
        backend.emit(.didWake)
        #expect(service.state == .running)
        #expect(backend.inventoryCalls == reads + 1)
        #expect(backend.unmountCalls == 1)
        #expect(backend.ejectCalls == 0)
    }

    @Test("Inventory failure cannot be treated as an empty device")
    func failedVerificationInventory() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        let service = SafeEjectService(backend: backend)
        service.start()
        backend.onUnmount = { backend.inventoryFails = true }
        #expect(await service.eject(selected) == .unverified(.unavailable))
        #expect(backend.ejectCalls == 0)
    }

    @Test("Unavailable device evidence cannot establish eject success")
    func failedPresenceProbe() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        let service = SafeEjectService(backend: backend)
        service.start()
        backend.onEject = { backend.presenceUnavailable = true }
        #expect(await service.eject(selected) == .unverified(.unavailable))
    }

    @Test("Cancelling a suspended unmount prevents physical eject")
    func taskCancellation() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.suspendUnmount = true
        let service = SafeEjectService(backend: backend)
        service.start()
        let task = Task { await service.eject(selected) }
        await backend.waitUntilSuspended()
        task.cancel()
        #expect(await task.value == .unverified(.interrupted))
        #expect(backend.ejectCalls == 0)
        #expect(backend.unmountCalls == 1)
        #expect(service.activeVolumeID == nil)
    }

    @Test("A concurrent request cannot start a second unmount")
    func simultaneousRequests() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.suspendUnmount = true
        let service = SafeEjectService(backend: backend)
        service.start()
        let first = Task { await service.eject(selected) }
        await backend.waitUntilSuspended()
        #expect(await service.eject(selected) == .refused(.operationInProgress))
        #expect(backend.unmountCalls == 1)
        service.pause()
        #expect(await first.value == .unverified(.interrupted))
        #expect(backend.ejectCalls == 0)
    }

    @Test("Shutdown during a suspended request leaves no late result or observation")
    func shutdownDuringRequest() async {
        let selected = volume()
        let backend = SafeEjectTestBackend(mounted: [selected])
        backend.suspendUnmount = true
        let service = SafeEjectService(backend: backend)
        service.start()
        let task = Task { await service.eject(selected) }
        await backend.waitUntilSuspended()
        service.shutdown()
        #expect(await task.value == .unverified(.interrupted))
        #expect(service.receipts.isEmpty)
        #expect(service.volumes.isEmpty)
        #expect(!backend.isMonitoring)
        #expect(backend.ejectCalls == 0)
    }

    @Test("Native error mapping makes no claims for unknown status codes")
    func statusMapping() {
        #expect(DiskArbitrationSafeEjectBackend.failure(for: Int32(truncatingIfNeeded: kDAReturnBusy)) == .busy)
        #expect(
            DiskArbitrationSafeEjectBackend.failure(for: Int32(truncatingIfNeeded: kDAReturnNotPrivileged)) == .denied)
        #expect(DiskArbitrationSafeEjectBackend.failure(for: 12345) == .system(12345))
    }

    @Test("Global storage action only opens the detail surface")
    func commandContract() {
        var didOpen = false
        SafeEjectModule.handle(.open) { didOpen = true }
        #expect(didOpen)
        #expect(SafeEjectModule.descriptor.commands == [.open])
        #expect(SafeEjectModule.descriptor.permissions.isEmpty)
    }

    private func volume(
        index: Int = 1,
        registryID: UInt64? = nil,
        device: SafeEjectDeviceID? = nil,
        isInternal: Bool? = false,
        isRemovable: Bool? = false,
        isRoot: Bool = false
    ) -> SafeEjectVolume {
        SafeEjectVolume(
            id: SafeEjectVolumeID(
                bsdName: "disk\(index)s1", registryID: registryID ?? UInt64(index),
                volumeUUID: "fixture-\(index)", mountURL: URL(fileURLWithPath: "/Volumes/Fixture\(index)")
            ),
            name: "Fixture \(index)",
            deviceID: device ?? SafeEjectDeviceID(bsdName: "disk\(index)", registryID: UInt64(index + 100)),
            isInternal: isInternal, isRemovable: isRemovable, isEjectable: false, isRoot: isRoot
        )
    }
}

@MainActor
private final class SafeEjectTestBackend: SafeEjectBackend {
    var mounted: [SafeEjectVolume]
    var presentDevices: Set<SafeEjectDeviceID>
    var hasUnidentified = false
    var inventoryFails = false
    var isMonitoring = false
    var startCalls = 0
    var startFails = false
    var inventoryCalls = 0
    var unmountCalls = 0
    var ejectCalls = 0
    var removeOnUnmount = true
    var removeDeviceOnEject = true
    var presenceUnavailable = false
    var suspendUnmount = false
    var unmountFailure: SafeEjectFailure?
    var ejectFailure: SafeEjectFailure?
    var onUnmount: (() -> Void)?
    var onEject: (() -> Void)?
    private var handler: (@MainActor (SafeEjectSystemEvent) -> Void)?
    private var pendingUnmount: CheckedContinuation<Result<Void, SafeEjectFailure>, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?

    init(mounted: [SafeEjectVolume] = []) {
        self.mounted = mounted
        self.presentDevices = Set(mounted.compactMap(\.deviceID))
    }

    func start(onEvent: @escaping @MainActor (SafeEjectSystemEvent) -> Void) throws {
        startCalls += 1
        isMonitoring = true
        handler = onEvent
        if startFails { throw SafeEjectFailure.unavailable }
    }

    func stop() {
        cancelPendingOperation()
        isMonitoring = false
        handler = nil
    }

    func cancelPendingOperation() {
        pendingUnmount?.resume(returning: .failure(.interrupted))
        pendingUnmount = nil
    }

    func waitUntilSuspended() async {
        if pendingUnmount != nil { return }
        await withCheckedContinuation { suspensionWaiter = $0 }
    }

    func inventory() throws -> SafeEjectInventory {
        inventoryCalls += 1
        if inventoryFails { throw SafeEjectFailure.unavailable }
        return SafeEjectInventory(volumes: mounted, hasUnidentifiedLocalVolumes: hasUnidentified)
    }

    func unmount(_ volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        unmountCalls += 1
        if suspendUnmount {
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    pendingUnmount = continuation
                    suspensionWaiter?.resume()
                    suspensionWaiter = nil
                }
            } onCancel: {
                Task { @MainActor in self.cancelPendingOperation() }
            }
            if case .failure = result { return result }
        }
        if let unmountFailure { return .failure(unmountFailure) }
        if removeOnUnmount { mounted.removeAll { $0.id == volume.id } }
        onUnmount?()
        return .success(())
    }

    func ejectDevice(containing volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        ejectCalls += 1
        if let ejectFailure { return .failure(ejectFailure) }
        if removeDeviceOnEject, let deviceID = volume.deviceID { presentDevices.remove(deviceID) }
        onEject?()
        return .success(())
    }

    func devicePresence(_ id: SafeEjectDeviceID) -> SafeEjectDevicePresence {
        if presenceUnavailable { return .unavailable }
        return presentDevices.contains(id) ? .present : .absent
    }

    func emit(_ event: SafeEjectSystemEvent) { handler?(event) }
}
