import AppKit
import Foundation
import IOKit.pwr_mgt
import SwiftUI
import Testing
@testable import Semper

@MainActor
private final class PowerAssertionBackendMock: PowerAssertionCreating {
    enum Event: Equatable {
        case created(PowerAssertionID, PowerAssertionKind)
        case released(PowerAssertionID)
        case releaseFailed(PowerAssertionID)
    }

    var failingKinds: Set<PowerAssertionKind> = []
    var failingReleaseIDs: Set<PowerAssertionID> = []
    private(set) var events: [Event] = []
    private(set) var requestedTimeouts: [TimeInterval?] = []
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
        requestedTimeouts.append(timeout)
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
            case .created(let id, _): active.insert(id)
            case .released(let id): active.remove(id)
            case .releaseFailed: break
            }
        }
        return active
    }

    var activeKinds: [PowerAssertionKind] {
        var kindByID: [PowerAssertionID: PowerAssertionKind] = [:]
        for event in events {
            if case .created(let id, let kind) = event {
                kindByID[id] = kind
            }
        }
        return activeAssertionIDs.sorted().compactMap { kindByID[$0] }
    }

    func releaseCount(for id: PowerAssertionID) -> Int {
        events.filter { $0 == .released(id) || $0 == .releaseFailed(id) }.count
    }
}

@MainActor
private final class ExpirySchedulerMock: AwakeExpiryScheduling {
    private(set) var scheduledDate: Date?
    private var handler: (@MainActor @Sendable () -> Void)?

    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {
        scheduledDate = date
        self.handler = handler
    }

    func cancelScheduledExpiry() {
        scheduledDate = nil
        handler = nil
    }

    func fire() {
        handler?()
    }
}

@MainActor
private final class TestClock {
    var current = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }
}

@MainActor
@Suite("AwakeService")
struct AwakeServiceTests {

    private func makeService(
        backend: PowerAssertionBackendMock = PowerAssertionBackendMock(),
        workspaceNotificationCenter: NotificationCenter = NotificationCenter()
    ) -> (AwakeService, PowerAssertionBackendMock, ExpirySchedulerMock, TestClock) {
        let scheduler = ExpirySchedulerMock()
        let clock = TestClock()
        let service = AwakeService(
            backend: backend,
            scheduler: scheduler,
            now: { clock.current },
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        return (service, backend, scheduler, clock)
    }

    @Test("Initial state is inactive with no assertions")
    func initialState() {
        let (service, backend, scheduler, _) = makeService()

        #expect(service.session == nil)
        #expect(!service.isActive)
        #expect(!service.keepDisplayAwake)
        #expect(!service.lastActionFailed)
        #expect(backend.events.isEmpty)
        #expect(scheduler.scheduledDate == nil)
    }

    @Test(
        "Timed durations set an absolute end date and schedule expiry",
        arguments: [
            (AwakeDuration.thirtyMinutes, TimeInterval(30 * 60)),
            (AwakeDuration.oneHour, TimeInterval(60 * 60)),
            (AwakeDuration.twoHours, TimeInterval(2 * 60 * 60)),
        ]
    )
    func timedDurations(duration: AwakeDuration, interval: TimeInterval) {
        let (service, backend, scheduler, clock) = makeService()

        service.start(duration)

        let expectedEnd = clock.current.addingTimeInterval(interval)
        #expect(service.session?.duration == duration)
        #expect(service.session?.startedAt == clock.current)
        #expect(service.session?.endsAt == expectedEnd)
        #expect(scheduler.scheduledDate == expectedEnd)
        #expect(backend.activeKinds == [.preventIdleSystemSleep])
        let expectedTimeouts: [TimeInterval?] = [interval]
        #expect(backend.requestedTimeouts == expectedTimeouts)
    }

    @Test("Until turned off has no end date and no scheduled expiry")
    func untilTurnedOff() {
        let (service, backend, scheduler, _) = makeService()

        service.start(.untilTurnedOff)

        #expect(service.isActive)
        #expect(service.session?.endsAt == nil)
        #expect(scheduler.scheduledDate == nil)
        #expect(backend.activeKinds == [.preventIdleSystemSleep])
        let expectedTimeouts: [TimeInterval?] = [nil]
        #expect(backend.requestedTimeouts == expectedTimeouts)
    }

    @Test("Display scope acquires a second assertion")
    func displayScope() {
        let (service, backend, _, _) = makeService()

        service.setKeepDisplayAwake(true)
        #expect(backend.events.isEmpty, "Scope preference alone must not create assertions")

        service.start(.oneHour)

        #expect(service.session?.keepsDisplayAwake == true)
        #expect(backend.activeKinds == [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        let expectedTimeouts: [TimeInterval?] = [60 * 60, 60 * 60]
        #expect(backend.requestedTimeouts == expectedTimeouts)
    }

    @Test("Creation failure leaves no session and no leaked assertions")
    func creationFailure() {
        let backend = PowerAssertionBackendMock()
        backend.failingKinds = [.preventIdleSystemSleep]
        let (service, _, scheduler, _) = makeService(backend: backend)

        service.start(.oneHour)

        #expect(service.session == nil)
        #expect(service.lastActionFailed)
        #expect(service.failure == .couldNotStart)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("Partial failure releases only the newly created assertion")
    func partialFailure() {
        let backend = PowerAssertionBackendMock()
        backend.failingKinds = [.preventIdleDisplaySleep]
        let (service, _, _, _) = makeService(backend: backend)

        service.setKeepDisplayAwake(true)
        service.start(.oneHour)

        #expect(service.session == nil)
        #expect(service.lastActionFailed)
        #expect(service.failure == .couldNotStart)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.events == [
            .created(1, .preventIdleSystemSleep),
            .released(1),
        ])
    }

    @Test("Replacement acquires the new assertion before releasing the old one")
    func replacementOrder() {
        let (service, backend, scheduler, clock) = makeService()

        service.start(.oneHour)
        clock.advance(by: 60)
        service.start(.twoHours)

        #expect(backend.events == [
            .created(1, .preventIdleSystemSleep),
            .created(2, .preventIdleSystemSleep),
            .released(1),
        ])
        #expect(service.session?.duration == .twoHours)
        #expect(service.session?.endsAt == clock.current.addingTimeInterval(2 * 60 * 60))
        #expect(scheduler.scheduledDate == service.session?.endsAt)
        #expect(backend.activeAssertionIDs == [2])
    }

    @Test("Failed replacement preserves the running session untouched")
    func replacementPartialFailure() {
        let (service, backend, scheduler, clock) = makeService()

        service.start(.oneHour)
        let original = service.session
        let originalSchedule = scheduler.scheduledDate

        clock.advance(by: 60)
        backend.failingKinds = [.preventIdleDisplaySleep]
        service.setKeepDisplayAwake(true)

        #expect(service.session == original)
        #expect(!service.keepDisplayAwake)
        #expect(service.lastActionFailed)
        #expect(scheduler.scheduledDate == originalSchedule)
        #expect(backend.activeAssertionIDs == [1])
        #expect(backend.releaseCount(for: 2) == 1, "The replacement system assertion must be released")
    }

    @Test("Display scope change while active preserves the absolute end date")
    func displayScopeChangePreservesEndDate() {
        let (service, backend, _, clock) = makeService()

        service.start(.oneHour)
        let originalEnd = service.session?.endsAt

        clock.advance(by: 10 * 60)
        service.setKeepDisplayAwake(true)

        #expect(service.keepDisplayAwake)
        #expect(service.session?.keepsDisplayAwake == true)
        #expect(service.session?.endsAt == originalEnd)
        #expect(backend.activeKinds == [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        #expect(backend.releaseCount(for: 1) == 1)
        let expectedTimeouts: [TimeInterval?] = [60 * 60, 50 * 60, 50 * 60]
        #expect(backend.requestedTimeouts == expectedTimeouts)
    }

    @Test("Stop releases each assertion exactly once and is idempotent")
    func stopTwice() {
        let (service, backend, scheduler, _) = makeService()

        service.setKeepDisplayAwake(true)
        service.start(.thirtyMinutes)
        service.stop()
        service.stop()

        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.releaseCount(for: 2) == 1)
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("A failed release is attempted once and reported")
    func releaseFailure() {
        let (service, backend, _, _) = makeService()

        service.start(.untilTurnedOff)
        backend.failingReleaseIDs = [1]
        service.stop()
        service.stop()
        let eventsAfterFailure = backend.events
        service.start(.oneHour)
        service.setKeepDisplayAwake(true)

        #expect(service.session == nil)
        #expect(service.failure == .couldNotRelease)
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.activeAssertionIDs == [1])
        #expect(backend.events == eventsAfterFailure)
        #expect(!service.keepDisplayAwake)
    }

    @Test("Replacement release failure cleans up the new assertion without retrying")
    func replacementReleaseFailure() {
        let (service, backend, _, _) = makeService()

        service.start(.oneHour)
        backend.failingReleaseIDs = [1]
        service.start(.twoHours)
        service.stop()
        let eventsAfterFailure = backend.events
        service.start(.thirtyMinutes)

        #expect(service.session == nil)
        #expect(service.failure == .couldNotRelease)
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.releaseCount(for: 2) == 1)
        #expect(backend.activeAssertionIDs == [1])
        #expect(backend.events == eventsAfterFailure)
    }

    @Test("Partial creation rollback failure is reported without a second release")
    func partialCreationRollbackFailure() {
        let backend = PowerAssertionBackendMock()
        backend.failingKinds = [.preventIdleDisplaySleep]
        backend.failingReleaseIDs = [1]
        let (service, _, _, _) = makeService(backend: backend)

        service.setKeepDisplayAwake(true)
        service.start(.oneHour)
        service.stop()
        let eventsAfterFailure = backend.events
        service.start(.twoHours)

        #expect(service.session == nil)
        #expect(service.failure == .couldNotRelease)
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.activeAssertionIDs == [1])
        #expect(backend.events == eventsAfterFailure)
    }

    @Test("Expiry at the end date stops the session")
    func expiry() {
        let (service, backend, scheduler, clock) = makeService()

        service.start(.thirtyMinutes)
        clock.advance(by: 30 * 60)
        scheduler.fire()

        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.releaseCount(for: 1) == 1)
    }

    @Test("An early timer fire re-arms at the absolute end date")
    func earlyFire() {
        let (service, backend, scheduler, clock) = makeService()

        service.start(.thirtyMinutes)
        let endsAt = service.session?.endsAt
        clock.advance(by: 15 * 60)
        scheduler.fire()

        #expect(service.isActive)
        #expect(backend.activeAssertionIDs == [1])
        #expect(scheduler.scheduledDate == endsAt)
    }

    @Test("Wake reconciliation stops a session that lapsed during sleep")
    func wakeReconciliationExpired() {
        let (service, backend, _, clock) = makeService()

        service.start(.thirtyMinutes)
        clock.advance(by: 2 * 60 * 60)
        service.reconcile()

        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("Wake reconciliation keeps a still valid session running")
    func wakeReconciliationStillValid() {
        let (service, backend, scheduler, clock) = makeService()

        service.start(.twoHours)
        let endsAt = service.session?.endsAt
        clock.advance(by: 60)
        service.reconcile()

        #expect(service.isActive)
        #expect(backend.activeAssertionIDs == [1])
        #expect(scheduler.scheduledDate == endsAt)
    }

    @Test("Workspace wake notification reconciles an expired session")
    func wakeNotificationReconcilesExpiry() {
        let notificationCenter = NotificationCenter()
        let (service, backend, _, clock) = makeService(
            workspaceNotificationCenter: notificationCenter
        )

        service.start(.thirtyMinutes)
        clock.advance(by: 60 * 60)
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("Shutdown releases everything once and refuses later starts")
    func shutdown() {
        let (service, backend, _, _) = makeService()

        service.setKeepDisplayAwake(true)
        service.start(.untilTurnedOff)
        service.shutdown()
        service.shutdown()

        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.releaseCount(for: 2) == 1)

        service.start(.oneHour)
        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("A fresh service never restores a previous session")
    func freshServiceDoesNotRestore() {
        let backend = PowerAssertionBackendMock()
        let (first, _, _, clock) = makeService(backend: backend)
        first.start(.untilTurnedOff)
        let eventsBefore = backend.events

        let fresh = AwakeService(
            backend: backend,
            scheduler: ExpirySchedulerMock(),
            now: { clock.current },
            workspaceNotificationCenter: NotificationCenter()
        )

        #expect(fresh.session == nil)
        #expect(!fresh.isActive)
        #expect(backend.events == eventsBefore, "Creating a service must not touch assertions")
    }

    @Test("Assertion kinds map to the public idle sleep constants")
    func assertionTypes() {
        #expect(
            PowerAssertionKind.preventIdleSystemSleep.ioKitType
                == kIOPMAssertPreventUserIdleSystemSleep
        )
        #expect(
            PowerAssertionKind.preventIdleDisplaySleep.ioKitType
                == kIOPMAssertPreventUserIdleDisplaySleep
        )
    }

    @Test("Awake view renders at the compact popup width")
    func compactViewRender() {
        let (service, _, _, _) = makeService()
        service.setKeepDisplayAwake(true)
        service.start(.oneHour)

        let renderer = ImageRenderer(
            content: AwakeModuleView(awake: service)
                .frame(width: 260)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Awake view did not render")
            return
        }
        #expect(image.size.width == 260)
    }
}
