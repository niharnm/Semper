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

    @Test("A synthesized APFS whole node cannot establish physical-device identity")
    func synthesizedWholeTopology() async {
        let topology = SafeEjectMediaTopology(
            bsdName: "disk30", registryID: 300, isWhole: true,
            providerIsBlockStorageDriver: false, deviceIsBlockStorageDevice: false,
            physicalInterconnect: "Virtual Interface"
        )
        #expect(topology.physicalDeviceID == nil)
        let original = volume()
        let synthesized = SafeEjectVolume(
            id: original.id, name: original.name, deviceID: topology.physicalDeviceID,
            isInternal: false, isRemovable: false, isEjectable: true, isRoot: false
        )
        let backend = SafeEjectTestBackend(mounted: [synthesized, volume(index: 2)])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(synthesized) == .refused(.unknownDevice))
        #expect(backend.unmountCalls == 0)
        #expect(backend.ejectCalls == 0)
    }

    @Test("Physical partitions share the verified media identity and cannot eject a sibling")
    func verifiedPhysicalSiblingTopology() async {
        let topology = SafeEjectMediaTopology(
            bsdName: "disk10", registryID: 100, isWhole: true,
            providerIsBlockStorageDriver: true, deviceIsBlockStorageDevice: true,
            physicalInterconnect: "USB", physicalLocation: "External"
        )
        let identity = topology.physicalDeviceID
        #expect(identity == SafeEjectDeviceID(bsdName: "disk10", registryID: 100))
        let selected = volume(device: identity)
        let sibling = volume(index: 2, device: identity)
        let backend = SafeEjectTestBackend(mounted: [selected, sibling])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .refused(.otherMountedVolumes))
        #expect(backend.unmountCalls == 0)
        #expect(backend.ejectCalls == 0)
    }

    @Test("Missing, virtual or unsupported backing evidence cannot authorize unmount")
    func incompletePhysicalTopology() async {
        let cases: [(Bool, Bool, String?)] = [
            (false, true, "USB"),
            (true, false, "USB"),
            (true, true, nil),
            (true, true, "Virtual Interface"),
            (true, true, "Unknown transport"),
        ]
        for (hasDriver, hasDevice, interconnect) in cases {
            let topology = SafeEjectMediaTopology(
                bsdName: "disk10", registryID: 100, isWhole: true,
                providerIsBlockStorageDriver: hasDriver, deviceIsBlockStorageDevice: hasDevice,
                physicalInterconnect: interconnect, physicalLocation: "External"
            )
            #expect(topology.physicalDeviceID == nil)
            let original = volume()
            let selected = SafeEjectVolume(
                id: original.id, name: original.name, deviceID: topology.physicalDeviceID,
                isInternal: false, isRemovable: true, isEjectable: true, isRoot: false
            )
            let backend = SafeEjectTestBackend(mounted: [selected])
            let service = SafeEjectService(backend: backend)
            service.start()
            #expect(await service.eject(selected) == .refused(.unknownDevice))
            #expect(backend.unmountCalls == 0)
            #expect(backend.ejectCalls == 0)
        }
    }

    @Test("Single-store APFS resolves beyond synthesized whole media to hardware")
    func apfsPhysicalGraph() {
        let (graph, apfs) = apfsGraph()
        let resolved = graph.resolve(apfs: apfs)
        #expect(resolved?.deviceID == SafeEjectDeviceID(bsdName: "disk10", registryID: 100))
        #expect(resolved?.isInternal == false)
        #expect(graph.resolve(apfs: nil) == nil)
        let snapshot = SafeEjectRegistryGraph(
            rootID: 302,
            nodes: graph.nodes + [
                SafeEjectRegistryNode(
                    id: 302, parents: [301], bsdName: "disk30s1s1", mediaUUID: UUID(), isMedia: true, isWhole: false
                )
            ],
            isComplete: true
        )
        #expect(snapshot.resolve(apfs: apfs)?.deviceID == resolved?.deviceID)
    }

    @Test("APFS and ordinary partitions on the same physical device block each other")
    func apfsSiblingGrouping() async {
        let (graph, apfs) = apfsGraph()
        let selected = volume(device: graph.resolve(apfs: apfs)?.deviceID)
        let sibling = volume(index: 2, device: selected.deviceID)
        let backend = SafeEjectTestBackend(mounted: [selected, sibling])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .refused(.otherMountedVolumes))
        #expect(backend.unmountCalls == 0)
        #expect(backend.ejectCalls == 0)
    }

    @Test("Proven internal APFS backing does not block a different physical external drive")
    func internalAPFSIsDisjoint() async {
        let (graph, apfs) = apfsGraph(location: "Internal")
        let internalTopology = graph.resolve(apfs: apfs)
        #expect(internalTopology?.isInternal == true)
        let selected = volume(index: 20)
        let internalVolume = volume(device: internalTopology?.deviceID, isInternal: true, isRoot: true)
        let backend = SafeEjectTestBackend(mounted: [selected, internalVolume])
        let service = SafeEjectService(backend: backend)
        service.start()
        #expect(await service.eject(selected) == .ejected)
        #expect(backend.unmountCalls == 1)
        #expect(backend.ejectCalls == 1)
    }

    @Test("APFS stores on disk images and ambiguous hardware locations stay unresolved")
    func virtualAndAmbiguousBacking() {
        for (transport, location) in [
            ("Virtual Interface", "File"), ("USB", "Internal/External"), ("USB", "RAM"), ("USB", "File"),
        ] {
            let (graph, apfs) = apfsGraph(location: location, transport: transport)
            #expect(graph.resolve(apfs: apfs) == nil)
        }
    }

    @Test("Multiple stores, missing stores and changed UUID associations cannot authorize eject")
    func malformedAPFSRelationships() {
        let (graph, apfs) = apfsGraph()
        let container = apfs.containers[0]
        let wrongUUID = SafeEjectAPFSTopology.Store(bsdName: container.stores[0].bsdName, uuid: UUID())
        let extraStore = SafeEjectAPFSTopology.Store(bsdName: "disk11s2", uuid: UUID())
        for stores in [[], [wrongUUID], container.stores + [extraStore]] {
            let altered = SafeEjectAPFSTopology(containers: [
                .init(
                    bsdName: container.bsdName, uuid: container.uuid, volumes: container.volumes, stores: stores
                )
            ])
            #expect(graph.resolve(apfs: altered) == nil)
        }
        let changedVolume = SafeEjectAPFSTopology(containers: [
            .init(
                bsdName: container.bsdName, uuid: container.uuid,
                volumes: [.init(bsdName: container.volumes[0].bsdName, uuid: UUID())], stores: container.stores
            )
        ])
        #expect(graph.resolve(apfs: changedVolume) == nil)
    }

    @Test("All parent paths must resolve and incomplete or cyclic graphs refuse")
    func incompleteGraph() {
        let (graph, apfs) = apfsGraph()
        var nodes = graph.nodes
        nodes[0].parents.append(999)
        for altered in [
            SafeEjectRegistryGraph(rootID: graph.rootID, nodes: graph.nodes, isComplete: false),
            SafeEjectRegistryGraph(rootID: graph.rootID, nodes: nodes, isComplete: true),
            SafeEjectRegistryGraph(rootID: graph.rootID, nodes: nodes + [.init(id: 999)], isComplete: true),
            SafeEjectRegistryGraph(
                rootID: graph.rootID, nodes: nodes + [.init(id: 999, parents: [301])], isComplete: true),
        ] {
            #expect(altered.resolve(apfs: apfs) == nil)
        }
    }

    @Test("An unlisted APFS store on the same hardware cannot hide behind a single-store query")
    func newStoreDuringQuery() {
        let (graph, apfs) = apfsGraph()
        var nodes = graph.nodes
        nodes[nodes.firstIndex(where: { $0.id == 250 })!].parents.append(202)
        nodes.append(
            .init(
                id: 202, parents: [150], bsdName: "disk10s3", mediaUUID: UUID(), isMedia: true, isWhole: false
            ))
        let changed = SafeEjectRegistryGraph(rootID: graph.rootID, nodes: nodes, isComplete: true)
        #expect(changed.resolve(apfs: apfs) == nil)
    }

    @Test("Reappearing physical stores change the complete selection evidence")
    func changedStoreRegistryIdentity() {
        let (graph, apfs) = apfsGraph()
        var nodes = graph.nodes.filter { $0.id != 201 }
        nodes.append(
            .init(
                id: 202, parents: [150], bsdName: "disk10s2", mediaUUID: apfs.containers[0].stores[0].uuid,
                isMedia: true, isWhole: false
            ))
        nodes[nodes.firstIndex(where: { $0.id == 250 })!].parents = [202]
        let replacement = SafeEjectRegistryGraph(rootID: graph.rootID, nodes: nodes, isComplete: true)
        #expect(replacement.resolve(apfs: apfs)?.deviceID == graph.resolve(apfs: apfs)?.deviceID)
        #expect(replacement.resolve(apfs: apfs) != graph.resolve(apfs: apfs))
    }

    @Test("Stopping topology work cancels fresh checks and ignores a late reader result")
    func stoppedTopologyCache() async {
        let reader = SafeEjectSuspendedTopologyReader()
        let cache = SafeEjectTopologyCache { await reader.read() }
        var publications = 0
        cache.start { publications += 1 }
        await reader.waitForCall(1)
        let fresh = Task { try await cache.fresh() }
        await reader.waitForCancellation(1)
        await reader.resolve(1)
        await reader.waitForCall(2)
        cache.stop()
        await reader.resolveAll()
        do {
            _ = try await fresh.value
            Issue.record("A stopped fresh query must fail")
        } catch {
            #expect(error as? SafeEjectFailure == .interrupted)
        }
        #expect(cache.value == nil)
        #expect(publications == 0)
    }

    @Test("Caller cancellation and concurrent fresh topology queries cannot publish stale results")
    func cancelledTopologyPreflight() async {
        let reader = SafeEjectSuspendedTopologyReader()
        let cache = SafeEjectTopologyCache { await reader.read() }
        cache.start {}
        await reader.waitForCall(1)
        let first = Task { try await cache.fresh() }
        await reader.waitForCancellation(1)
        await reader.resolve(1)
        await reader.waitForCall(2)
        do {
            _ = try await cache.fresh()
            Issue.record("A second preflight must fail")
        } catch {
            #expect(error as? SafeEjectFailure == .operationInProgress)
        }
        first.cancel()
        await reader.resolveAll()
        do {
            _ = try await first.value
            Issue.record("A cancelled query must fail")
        } catch {
            #expect(error as? SafeEjectFailure == .interrupted)
        }
        #expect(cache.value == nil)
        cache.stop()
    }

    @Test("Topology invalidation prevents old preflight results from replacing the new inventory")
    func invalidatedTopologyCache() async {
        let reader = SafeEjectSuspendedTopologyReader()
        let cache = SafeEjectTopologyCache { await reader.read() }
        let (events, continuation) = AsyncStream<Void>.makeStream()
        var iterator = events.makeAsyncIterator()
        cache.start { continuation.yield(()) }
        await reader.waitForCall(1)
        let old = Task { try await cache.fresh() }
        await reader.waitForCancellation(1)
        await reader.resolve(1)
        await reader.waitForCall(2)
        cache.invalidate()
        await reader.waitForCancellation(2)
        await reader.resolve(2)
        do {
            _ = try await old.value
            Issue.record("An invalidated preflight must fail")
        } catch {
            #expect(error as? SafeEjectFailure == .interrupted)
        }
        await reader.waitForCall(3)
        await reader.resolve(3)
        _ = await iterator.next()
        #expect(cache.value == SafeEjectAPFSTopology(containers: []))
        cache.stop()
        await cache.drain()
        continuation.finish()
    }

    @Test("Rapid invalidation and restart retain cancelled readers until cleanup has drained")
    func serializedTopologyCleanup() async {
        let reader = SafeEjectSuspendedTopologyReader()
        let cache = SafeEjectTopologyCache { await reader.read() }
        cache.start {}
        await reader.waitForCall(1)
        for _ in 0..<20 { cache.invalidate() }
        await reader.waitForCancellation(1)
        cache.stop()
        cache.start {}
        for _ in 0..<20 { cache.invalidate() }
        #expect(await reader.count == 1)
        #expect(await reader.maximumPending == 1)
        await reader.resolve(1)
        await reader.waitForCall(2)
        #expect(await reader.maximumPending == 1)
        cache.stop()
        await reader.waitForCancellation(2)
        await reader.resolve(2)
        await cache.drain()
        #expect(await reader.count == 2)
        #expect(cache.value == nil)
    }

    @Test("A fresh query and stop await cancelled background cleanup without starting another reader")
    func freshWaitsForCleanup() async {
        let reader = SafeEjectSuspendedTopologyReader()
        let cache = SafeEjectTopologyCache { await reader.read() }
        cache.start {}
        await reader.waitForCall(1)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        var iterator = started.makeAsyncIterator()
        let fresh = Task {
            continuation.yield(())
            return try await cache.fresh()
        }
        _ = await iterator.next()
        await reader.waitForCancellation(1)
        #expect(await reader.count == 1)
        cache.stop()
        var drained = false
        let drain = Task {
            await cache.drain()
            drained = true
        }
        #expect(!drained)
        #expect(await reader.count == 1)
        await reader.resolve(1)
        do {
            _ = try await fresh.value
            Issue.record("The stopped preflight must not launch after cleanup")
        } catch {
            #expect(error as? SafeEjectFailure == .interrupted)
        }
        await drain.value
        #expect(drained)
        #expect(await reader.count == 1)
        #expect(await reader.maximumPending == 1)
        continuation.finish()
    }

    @Test("Service cleanup waits for the backend after synchronous pause or shutdown")
    func serviceWaitsForCleanup() async {
        let backend = SafeEjectTestBackend()
        backend.suspendCleanup = true
        let service = SafeEjectService(backend: backend)
        service.start()
        service.shutdown()
        var drained = false
        let wait = Task {
            await service.waitForCleanup()
            drained = true
        }
        await backend.waitUntilCleanupSuspended()
        #expect(!drained)
        #expect(!backend.isMonitoring)
        backend.finishCleanup()
        await wait.value
        #expect(drained)
        #expect(service.state == .shutDown)
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

    private func apfsGraph(
        location: String = "External", transport: String = "USB"
    ) -> (SafeEjectRegistryGraph, SafeEjectAPFSTopology) {
        let volumeUUID = UUID()
        let storeUUID = UUID()
        let containerUUID = UUID()
        let nodes = [
            SafeEjectRegistryNode(
                id: 301, parents: [300], bsdName: "disk30s1", mediaUUID: volumeUUID, isMedia: true, isWhole: false),
            SafeEjectRegistryNode(
                id: 300, parents: [250], bsdName: "disk30", mediaUUID: containerUUID, isMedia: true, isWhole: true),
            SafeEjectRegistryNode(id: 250, parents: [201]),
            SafeEjectRegistryNode(
                id: 201, parents: [150], bsdName: "disk10s2", mediaUUID: storeUUID, isMedia: true, isWhole: false),
            SafeEjectRegistryNode(id: 150, parents: [100]),
            SafeEjectRegistryNode(id: 100, parents: [101], bsdName: "disk10", isMedia: true, isWhole: true),
            SafeEjectRegistryNode(id: 101, parents: [102], isBlockStorageDriver: true),
            SafeEjectRegistryNode(
                id: 102, parents: [103], isBlockStorageDevice: true,
                physicalInterconnect: transport, physicalLocation: location),
            SafeEjectRegistryNode(id: 103),
        ]
        let apfs = SafeEjectAPFSTopology(containers: [
            .init(
                bsdName: "disk30", uuid: containerUUID,
                volumes: [.init(bsdName: "disk30s1", uuid: volumeUUID)],
                stores: [.init(bsdName: "disk10s2", uuid: storeUUID)]
            )
        ])
        return (SafeEjectRegistryGraph(rootID: 301, nodes: nodes, isComplete: true), apfs)
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
    var suspendCleanup = false
    var unmountFailure: SafeEjectFailure?
    var ejectFailure: SafeEjectFailure?
    var onUnmount: (() -> Void)?
    var onEject: (() -> Void)?
    private var handler: (@MainActor (SafeEjectSystemEvent) -> Void)?
    private var pendingUnmount: CheckedContinuation<Result<Void, SafeEjectFailure>, Never>?
    private var cleanupWaiter: CheckedContinuation<Void, Never>?
    private var cleanupStarted: CheckedContinuation<Void, Never>?
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

    func drain() async {
        guard suspendCleanup else { return }
        await withCheckedContinuation { continuation in
            cleanupWaiter = continuation
            cleanupStarted?.resume()
            cleanupStarted = nil
        }
    }

    func waitUntilCleanupSuspended() async {
        if cleanupWaiter != nil { return }
        await withCheckedContinuation { cleanupStarted = $0 }
    }

    func finishCleanup() {
        cleanupWaiter?.resume()
        cleanupWaiter = nil
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

private actor SafeEjectSuspendedTopologyReader {
    private(set) var count = 0
    private(set) var maximumPending = 0
    private var cancelled: Set<Int> = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var pending: [Int: CheckedContinuation<SafeEjectAPFSTopology, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func read() async -> SafeEjectAPFSTopology {
        count += 1
        let index = count
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[index] = continuation
                maximumPending = max(maximumPending, pending.count)
                let ready = waiters.filter { $0.0 <= count }
                waiters.removeAll { $0.0 <= count }
                for waiter in ready { waiter.1.resume() }
            }
        } onCancel: {
            Task { await self.didCancel(index) }
        }
    }

    private func didCancel(_ index: Int) {
        cancelled.insert(index)
        let ready = cancellationWaiters.filter { $0.0 == index }
        cancellationWaiters.removeAll { $0.0 == index }
        for waiter in ready { waiter.1.resume() }
    }

    func waitForCancellation(_ index: Int) async {
        if cancelled.contains(index) { return }
        await withCheckedContinuation { cancellationWaiters.append((index, $0)) }
    }

    func waitForCall(_ index: Int) async {
        if count >= index { return }
        await withCheckedContinuation { waiters.append((index, $0)) }
    }

    func resolve(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(returning: SafeEjectAPFSTopology(containers: []))
    }

    func resolveAll() {
        let continuations = pending.values
        pending = [:]
        for continuation in continuations { continuation.resume(returning: SafeEjectAPFSTopology(containers: [])) }
    }
}
