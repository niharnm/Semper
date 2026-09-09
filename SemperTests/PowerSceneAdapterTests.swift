import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Semper

@MainActor
private final class PowerSceneAssertionBackendMock: PowerAssertionCreating {
    enum Event: Equatable {
        case created(PowerAssertionID, PowerAssertionKind)
        case released(PowerAssertionID)
        case releaseFailed(PowerAssertionID)
    }

    var failingKinds: Set<PowerAssertionKind> = []
    var failingReleaseIDs: Set<PowerAssertionID> = []
    private(set) var events: [Event] = []
    private var nextID: PowerAssertionID = 1

    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        timeout: TimeInterval?
    ) throws(PowerAssertionError) -> PowerAssertionID {
        guard !failingKinds.contains(kind) else {
            throw PowerAssertionError.creationFailed(kIOReturnError)
        }
        let id = nextID
        nextID += 1
        events.append(.created(id, kind))
        return id
    }

    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        guard !failingReleaseIDs.contains(id) else {
            events.append(.releaseFailed(id))
            throw PowerAssertionError.releaseFailed(kIOReturnError)
        }
        events.append(.released(id))
    }

    var activeAssertionIDs: Set<PowerAssertionID> {
        var active: Set<PowerAssertionID> = []
        for event in events {
            switch event {
            case .created(let id, _):
                active.insert(id)
            case .released(let id):
                active.remove(id)
            case .releaseFailed:
                break
            }
        }
        return active
    }
}

@MainActor
private final class PowerSceneExpirySchedulerMock: AwakeExpiryScheduling {
    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {}
    func cancelScheduledExpiry() {}
}

@MainActor
@Suite("Power scene adapter")
struct PowerSceneAdapterTests {
    private func makeService(
        backend: PowerSceneAssertionBackendMock = PowerSceneAssertionBackendMock()
    ) -> AwakeService {
        AwakeService(
            backend: backend,
            scheduler: PowerSceneExpirySchedulerMock(),
            workspaceNotificationCenter: NotificationCenter()
        )
    }

    @Test("Only the Awake control is supported")
    func capabilityAndPreflight() async {
        let adapter = PowerSceneAdapter(awake: makeService())

        #expect(await adapter.capability(for: .awakeMode) == .readWrite)
        #expect(await adapter.capability(for: .audioOutputDevice) == .unsupported)
        #expect(
            await adapter.preflightTarget(.awake(.system), for: .awakeMode) == .ready
        )
        #expect(
            await adapter.preflightTarget(.boolean(true), for: .awakeMode)
                == .unavailable("The Awake target is invalid.")
        )
    }

    @Test("Scene lease reports and applies every Awake state")
    func appliesEveryState() async throws {
        let service = makeService()
        let adapter = PowerSceneAdapter(awake: service)

        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.off))

        try await adapter.writeValue(.awake(.system), for: .awakeMode)
        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.system))
        #expect(service.leaseState(for: .scene)?.keepsDisplayAwake == false)

        try await adapter.writeValue(.awake(.displayAndSystem), for: .awakeMode)
        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.displayAndSystem))
        #expect(service.leaseState(for: .scene)?.keepsDisplayAwake == true)

        try await adapter.writeValue(.awake(.system), for: .awakeMode)
        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.system))

        try await adapter.writeValue(.awake(.off), for: .awakeMode)
        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.off))
        #expect(service.leaseState(for: .scene) == nil)
    }

    @Test("Scene off leaves user and Away Awake requests active")
    func sceneOffPreservesOtherOwners() async throws {
        let backend = PowerSceneAssertionBackendMock()
        let service = makeService(backend: backend)
        service.start(.oneHour)
        let awayLease = try service.acquireLease(
            owner: .awayMode,
            keepsDisplayAwake: false
        )
        let adapter = PowerSceneAdapter(awake: service)

        try await adapter.writeValue(.awake(.system), for: .awakeMode)
        try await adapter.writeValue(.awake(.off), for: .awakeMode)

        #expect(service.isActive)
        #expect(service.leaseState(for: .awayMode)?.keepsDisplayAwake == false)
        #expect(service.leaseState(for: .scene) == nil)
        #expect(service.effectiveLeaseCount == 1)
        #expect(backend.activeAssertionIDs == [1, 2])

        service.releaseLease(awayLease)
        service.stop()
    }

    @Test("Acquire failure maps to a rejected scene write")
    func acquireFailure() async throws {
        let backend = PowerSceneAssertionBackendMock()
        backend.failingKinds = [.preventIdleSystemSleep]
        let service = makeService(backend: backend)
        let adapter = PowerSceneAdapter(awake: service)

        await #expect(throws: SceneAdapterError.writeRejected) {
            try await adapter.writeValue(.awake(.system), for: .awakeMode)
        }

        #expect(service.leaseState(for: .scene) == nil)
        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.off))
    }

    @Test("Failed update acquisition preserves the prior scene state")
    func updateAcquisitionFailure() async throws {
        let backend = PowerSceneAssertionBackendMock()
        let service = makeService(backend: backend)
        let adapter = PowerSceneAdapter(awake: service)
        try await adapter.writeValue(.awake(.system), for: .awakeMode)
        backend.failingKinds = [.preventIdleDisplaySleep]

        await #expect(throws: SceneAdapterError.writeRejected) {
            try await adapter.writeValue(.awake(.displayAndSystem), for: .awakeMode)
        }

        #expect(service.leaseState(for: .scene)?.keepsDisplayAwake == false)
        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.system))
        #expect(backend.activeAssertionIDs == [1])
    }

    @Test("Failed update cleanup makes scene state unreadable")
    func updateReleaseFailure() async throws {
        let backend = PowerSceneAssertionBackendMock()
        let service = makeService(backend: backend)
        let adapter = PowerSceneAdapter(awake: service)
        try await adapter.writeValue(.awake(.system), for: .awakeMode)
        backend.failingReleaseIDs = [1]

        await #expect(throws: SceneAdapterError.writeRejected) {
            try await adapter.writeValue(.awake(.displayAndSystem), for: .awakeMode)
        }

        #expect(service.leaseState(for: .scene) == nil)
        await #expect(throws: SceneAdapterError.readUnavailable) {
            try await adapter.readValue(for: .awakeMode)
        }
    }

    @Test("Failed off cleanup cannot confirm a false off state")
    func releaseFailure() async throws {
        let backend = PowerSceneAssertionBackendMock()
        let service = makeService(backend: backend)
        let adapter = PowerSceneAdapter(awake: service)
        try await adapter.writeValue(.awake(.system), for: .awakeMode)
        backend.failingReleaseIDs = [1]

        await #expect(throws: SceneAdapterError.writeRejected) {
            try await adapter.writeValue(.awake(.off), for: .awakeMode)
        }

        #expect(service.leaseState(for: .scene) == nil)
        #expect(backend.activeAssertionIDs == [1])
        await #expect(throws: SceneAdapterError.readUnavailable) {
            try await adapter.readValue(for: .awakeMode)
        }
    }
}
