import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
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
    var onCreate: (() -> Void)?
    private(set) var events: [Event] = []
    private(set) var requestedReasons: [String] = []
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
        requestedReasons.append(reason)
        requestedTimeouts.append(timeout)
        onCreate?()
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
private final class AwakeConditionsMock: AwakeConditionMonitoring {
    static let editor = AwakeApplication(
        id: AwakeProcessIdentity(processIdentifier: 41, launchDate: Date(timeIntervalSince1970: 100)),
        name: "Editor"
    )
    var applications: [AwakeApplication] = [editor]
    var battery: AwakeBatteryState = .battery(percentage: 80)
    var onStart: (() -> Void)?
    var startError: AwakeConditionMonitorError?
    private(set) var conditions: AwakeStopConditions?
    private(set) var callbacks: [@MainActor @Sendable (AwakeConditionSnapshot) -> Void] = []
    private(set) var snapshotCount = 0
    private(set) var subscriptionCount = 0

    func availableApplications() -> [AwakeApplication] { applications }

    func snapshot(for conditions: AwakeStopConditions) -> AwakeConditionSnapshot {
        snapshotCount += 1
        return AwakeConditionSnapshot(
            selectedApplicationRunning: conditions.application.map { selected in
                applications.contains { $0.id == selected.id }
            },
            battery: conditions.batteryThreshold == nil ? .unknown : battery
        )
    }

    func start(
        conditions: AwakeStopConditions,
        onChange: @escaping @MainActor @Sendable (AwakeConditionSnapshot) -> Void
    ) throws(AwakeConditionMonitorError) {
        if let startError { throw startError }
        self.conditions = conditions
        callbacks.append(onChange)
        subscriptionCount += 1
        onStart?()
        onChange(snapshot(for: conditions))
    }

    func stop() { conditions = nil }

    func emit() {
        guard let conditions, let callback = callbacks.last else { return }
        callback(snapshot(for: conditions))
    }
}

@MainActor
@Suite("AwakeService")
struct AwakeServiceTests {

    @MainActor
    private final class ManualAdmission {
        var allowed = true
        private(set) var checkCount = 0

        func check() -> Bool {
            checkCount += 1
            return allowed
        }
    }

    private func makeService(
        backend: PowerAssertionBackendMock = PowerAssertionBackendMock(),
        workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
        conditionMonitor: any AwakeConditionMonitoring = AwakeConditionsMock(),
        manualMutationAllowed: @escaping @MainActor () -> Bool = { true }
    ) -> (AwakeService, PowerAssertionBackendMock, ExpirySchedulerMock, TestClock) {
        let scheduler = ExpirySchedulerMock()
        let clock = TestClock()
        let service = AwakeService(
            backend: backend,
            scheduler: scheduler,
            now: { clock.current },
            workspaceNotificationCenter: workspaceNotificationCenter,
            conditionMonitor: conditionMonitor,
            manualMutationAllowed: manualMutationAllowed
        )
        return (service, backend, scheduler, clock)
    }

    @Test("Exclusive control rejects every manual mutation before touching assertions or conditions")
    func manualAdmissionBeforeStart() {
        let admission = ManualAdmission()
        admission.allowed = false
        let monitor = AwakeConditionsMock()
        let (service, backend, _, _) = makeService(conditionMonitor: monitor) {
            admission.check()
        }
        defer { service.shutdown() }

        service.setConditions(.init(application: AwakeConditionsMock.editor, batteryThreshold: .twenty))
        service.setSessionReason("Blocked edit")
        service.setKeepDisplayAwake(true)
        service.start(.oneHour)
        service.stop()

        #expect(admission.checkCount == 5)
        #expect(service.manualMutationRejected)
        #expect(service.conditions == AwakeStopConditions())
        #expect(service.sessionReason.isEmpty)
        #expect(!service.keepDisplayAwake)
        #expect(service.session == nil)
        #expect(backend.events.isEmpty)
        #expect(monitor.snapshotCount == 0)
        #expect(monitor.subscriptionCount == 0)

        admission.allowed = true
        service.start(.oneHour)
        #expect(!service.manualMutationRejected)
        #expect(service.session != nil)
    }

    @Test("Exclusive control preserves an existing session but cannot block a condition stop")
    func manualAdmissionDuringSession() throws {
        let admission = ManualAdmission()
        let monitor = AwakeConditionsMock()
        let (service, backend, scheduler, _) = makeService(
            conditionMonitor: monitor, manualMutationAllowed: { admission.check() }
        )
        defer { service.shutdown() }
        service.setConditions(.init(batteryThreshold: .twenty))
        service.setSessionReason("Export")
        service.start(.oneHour)
        let original = service.session
        let deadline = scheduler.scheduledDate
        let originalEvents = backend.events
        let originalSnapshots = monitor.snapshotCount

        admission.allowed = false
        service.stop()
        service.start(.twoHours)
        service.setConditions(.init())
        service.setSessionReason("Replacement")
        service.setKeepDisplayAwake(true)
        #expect(service.manualMutationRejected)
        #expect(service.session == original)
        #expect(service.sessionReason == "Export")
        #expect(service.conditions.batteryThreshold == .twenty)
        #expect(!service.keepDisplayAwake)
        #expect(scheduler.scheduledDate == deadline)
        #expect(backend.events == originalEvents)
        #expect(monitor.snapshotCount == originalSnapshots)

        let away = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        monitor.battery = .battery(percentage: 19)
        monitor.emit()
        #expect(service.session == nil)
        #expect(service.lastSessionEndReason == .batteryThresholdReached(20))
        #expect(!service.manualMutationRejected)
        #expect(service.hasLease(for: .awayMode))
        #expect(service.releaseLease(away))
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("Expiry, shutdown, and explicit owner cleanup bypass manual admission")
    func automaticCleanupBypassesAdmission() throws {
        let admission = ManualAdmission()
        let (service, backend, scheduler, clock) = makeService {
            admission.check()
        }
        service.start(.thirtyMinutes)
        admission.allowed = false
        let scene = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        clock.advance(by: 1_800)
        scheduler.fire()
        #expect(service.lastSessionEndReason == .expired)
        #expect(service.session == nil)
        #expect(service.hasLease(for: .scene))

        backend.failingReleaseIDs = [2]
        #expect(!service.releaseLease(scene))
        backend.failingReleaseIDs = []
        #expect(service.retryPendingLeaseCleanup(owner: .scene))
        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: true)
        service.shutdown()
        #expect(admission.checkCount == 1)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(service.failure == nil)
    }

    @Test("Conditions do not subscribe or inspect power while stopped or with only leases")
    func conditionsAreSessionOwned() throws {
        let monitor = AwakeConditionsMock()
        let (service, _, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(application: AwakeConditionsMock.editor, batteryThreshold: .twenty))
        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        service.reconcile()
        #expect(monitor.snapshotCount == 0)
        #expect(monitor.subscriptionCount == 0)

        service.start(.oneHour)
        #expect(monitor.subscriptionCount == 1)
        service.stop()
        #expect(monitor.conditions == nil)
        #expect(service.conditionSnapshot == nil)
        #expect(service.hasLease(for: .awayMode))
    }

    @Test("Selected process exit stops only the manual session")
    func selectedProcessExit() throws {
        let monitor = AwakeConditionsMock()
        let (service, backend, _, clock) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        _ = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false,
                                     deadline: clock.current.addingTimeInterval(7200))
        service.setConditions(AwakeStopConditions(application: AwakeConditionsMock.editor))
        service.start(.oneHour)
        monitor.applications = []
        monitor.emit()
        #expect(service.session == nil)
        #expect(service.lastSessionEndReason == .selectedApplicationExited("Editor"))
        #expect(service.effectiveLeaseCount == 3)
        #expect(backend.activeAssertionIDs == [1, 2, 3])
        #expect(backend.releaseCount(for: 4) == 1)
        #expect(monitor.conditions == nil)
    }

    @Test("A replacement process with the same PID does not extend the selected session")
    func selectedProcessPIDReuse() {
        let monitor = AwakeConditionsMock()
        let (service, backend, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(application: AwakeConditionsMock.editor))
        service.start(.untilTurnedOff)
        monitor.applications = [AwakeApplication(
            id: AwakeProcessIdentity(processIdentifier: 41, launchDate: Date(timeIntervalSince1970: 200)),
            name: "Editor"
        )]
        monitor.emit()
        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(service.lastSessionEndReason == .selectedApplicationExited("Editor"))
    }

    @Test("Battery cutoff distinguishes battery, AC, absent battery and unknown readings", arguments: [
        (AwakeBatteryState.battery(percentage: 21), true),
        (AwakeBatteryState.battery(percentage: 20), false),
        (AwakeBatteryState.battery(percentage: 19), false),
        (AwakeBatteryState.externalPower(percentage: 5), true),
        (AwakeBatteryState.externalPower(percentage: nil), true),
        (AwakeBatteryState.noBattery, true),
        (AwakeBatteryState.unknown, false),
    ])
    func batteryCutoffPolicy(battery: AwakeBatteryState, allowed: Bool) {
        let monitor = AwakeConditionsMock()
        monitor.battery = battery
        let (service, backend, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(batteryThreshold: .twenty))
        service.start(.oneHour)
        #expect(service.isActive == allowed)
        #expect(backend.events.isEmpty == !allowed)
        if battery == .unknown {
            #expect(service.lastSessionEndReason == .batteryStateUnavailable)
        } else if !allowed {
            #expect(service.lastSessionEndReason == .batteryThresholdReached(20))
        }
    }

    @Test("Unplugging below the threshold stops the manual session without ending a lease")
    func batteryUnplug() throws {
        let monitor = AwakeConditionsMock()
        monitor.battery = .externalPower(percentage: 10)
        let (service, backend, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        service.setConditions(AwakeStopConditions(batteryThreshold: .twenty))
        service.start(.oneHour)
        monitor.battery = .battery(percentage: 10)
        monitor.emit()
        #expect(service.session == nil)
        #expect(service.hasLease(for: .awayMode))
        #expect(backend.activeAssertionIDs == [1])
        #expect(service.lastSessionEndReason == .batteryThresholdReached(20))
    }

    @Test("Wake reevaluates a missed power change and cancels condition observation")
    func conditionWakeReconciliation() {
        let monitor = AwakeConditionsMock()
        let center = NotificationCenter()
        let (service, backend, _, _) = makeService(workspaceNotificationCenter: center, conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(batteryThreshold: .twenty))
        service.start(.oneHour)
        monitor.battery = .unknown
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(service.lastSessionEndReason == .batteryStateUnavailable)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(monitor.conditions == nil)
    }

    @Test("Condition and reason changes preserve the session deadline and ignore obsolete callbacks")
    func conditionChangesAndStaleCallbacks() {
        let monitor = AwakeConditionsMock()
        let (service, backend, scheduler, clock) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(application: AwakeConditionsMock.editor))
        service.start(.oneHour)
        let originalEnd = service.session?.endsAt
        let originalStart = service.session?.startedAt
        let obsoleteCallback = monitor.callbacks[0]
        clock.advance(by: 60)
        service.setConditions(AwakeStopConditions(batteryThreshold: .twenty))
        service.setSessionReason("  Exporting video  ")
        obsoleteCallback(AwakeConditionSnapshot(selectedApplicationRunning: false, battery: .unknown))
        #expect(service.isActive)
        #expect(service.session?.reason == "Exporting video")
        #expect(service.session?.conditions == AwakeStopConditions(batteryThreshold: .twenty))
        #expect(service.session?.startedAt == originalStart)
        #expect(service.session?.endsAt == originalEnd)
        #expect(scheduler.scheduledDate == originalEnd)
        #expect(backend.events.count == 1)
        service.setConditions(AwakeStopConditions())
        #expect(monitor.conditions == nil)
        monitor.callbacks.last?(AwakeConditionSnapshot(selectedApplicationRunning: nil, battery: .battery(percentage: 0)))
        #expect(service.isActive)
    }

    @Test("A raised cutoff ends the current session immediately")
    func changedThresholdStopsSession() {
        let monitor = AwakeConditionsMock()
        monitor.battery = .battery(percentage: 25)
        let (service, backend, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(batteryThreshold: .twenty))
        service.start(.oneHour)
        service.setConditions(AwakeStopConditions(batteryThreshold: .thirty))
        #expect(service.lastSessionEndReason == .batteryThresholdReached(30))
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("Reason edits trim whitespace, limit characters, and retain the default without extending time")
    func reasonLimits() {
        let (service, backend, _, _) = makeService()
        defer { service.shutdown() }
        service.setSessionReason(" \n ")
        service.start(.oneHour)
        #expect(service.session?.reason == "Manual Awake session")
        let deadline = service.session?.endsAt
        let reason = String(repeating: "🙂", count: 121)
        service.setSessionReason(reason)
        #expect(service.sessionReason == String(reason.prefix(120)))
        #expect(service.session?.reason.count == 120)
        #expect(service.session?.endsAt == deadline)
        #expect(backend.events.count == 1)
    }

    @Test("Editing conditions after expiry cannot extend or resubscribe the session")
    func changedConditionsAfterExpiry() {
        let monitor = AwakeConditionsMock()
        let (service, backend, _, clock) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.start(.thirtyMinutes)
        clock.advance(by: 1_801)
        service.setConditions(.init(application: AwakeConditionsMock.editor))
        #expect(service.session == nil)
        #expect(service.lastSessionEndReason == .expired)
        #expect(monitor.subscriptionCount == 0)
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("A process quitting between preflight and subscription releases the newly acquired assertion")
    func conditionStartupRace() {
        let monitor = AwakeConditionsMock()
        monitor.onStart = { [weak monitor] in monitor?.applications = [] }
        let (service, backend, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(application: AwakeConditionsMock.editor))
        service.start(.untilTurnedOff)
        #expect(service.lastSessionEndReason == .selectedApplicationExited("Editor"))
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(monitor.conditions == nil)
    }

    @Test("Unavailable condition observation stops only the manual session")
    func conditionSubscriptionFailure() throws {
        let monitor = AwakeConditionsMock()
        monitor.startError = .batteryNotificationsUnavailable
        let (service, backend, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        _ = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        service.setConditions(AwakeStopConditions(batteryThreshold: .twenty))
        service.start(.oneHour)
        #expect(service.lastSessionEndReason == .conditionMonitoringUnavailable)
        #expect(backend.activeAssertionIDs == [1])
        #expect(monitor.conditions == nil)
    }

    @Test("Condition cleanup failure stays visible and stopped callbacks cannot retry it")
    func conditionCleanupFailure() {
        let monitor = AwakeConditionsMock()
        let (service, backend, _, _) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(batteryThreshold: .twenty))
        service.start(.oneHour)
        let callback = monitor.callbacks[0]
        backend.failingReleaseIDs = [1]
        callback(AwakeConditionSnapshot(selectedApplicationRunning: nil, battery: .battery(percentage: 10)))
        service.stop()
        let stoppedEvents = backend.events
        callback(AwakeConditionSnapshot(selectedApplicationRunning: nil, battery: .battery(percentage: 10)))
        service.start(.oneHour)
        #expect(service.failure == .couldNotRelease)
        #expect(backend.events == stoppedEvents)
        #expect(backend.releaseCount(for: 1) == 1)
    }

    @Test("Expiry and shutdown cancel condition subscriptions and invalidate callbacks", arguments: [false, true])
    func conditionTeardown(shutdown: Bool) {
        let monitor = AwakeConditionsMock()
        let (service, backend, scheduler, clock) = makeService(conditionMonitor: monitor)
        defer { service.shutdown() }
        service.setConditions(AwakeStopConditions(application: AwakeConditionsMock.editor))
        service.start(.oneHour)
        let callback = monitor.callbacks[0]
        if shutdown {
            service.shutdown()
        } else {
            clock.advance(by: 3600)
            scheduler.fire()
            #expect(service.lastSessionEndReason == .expired)
        }
        let finalEvents = backend.events
        callback(AwakeConditionSnapshot(selectedApplicationRunning: false, battery: .unknown))
        #expect(backend.events == finalEvents)
        #expect(monitor.conditions == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("Explicit lease retry releases only the failed owner's pending identifiers")
    func explicitLeaseCleanupRetry() throws {
        let (service, backend, _, clock) = makeService()
        defer { service.shutdown() }
        service.start(.oneHour)
        let away = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: true)
        let scene = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        let presentation = try service.acquireLease(owner: .presentation, keepsDisplayAwake: true,
                                                    deadline: clock.current.addingTimeInterval(300))
        backend.failingReleaseIDs = [3, 6]
        #expect(!service.releaseLease(away))
        #expect(!service.releaseLease(presentation))
        #expect(!service.retryReleaseLease(presentation))
        #expect(backend.releaseCount(for: 3) == 1)
        backend.failingReleaseIDs = [3]
        #expect(service.retryReleaseLease(presentation))
        #expect(service.failure == .couldNotRelease)
        #expect(service.isActive)
        #expect(service.hasLease(for: .scene))
        #expect(backend.activeAssertionIDs == [1, 3, 4])
        backend.failingReleaseIDs = []
        #expect(service.retryReleaseLease(away))
        #expect(service.failure == nil)
        let events = backend.events
        #expect(service.retryReleaseLease(presentation))
        #expect(backend.events == events)
        #expect(service.releaseLease(scene))
    }

    @Test("Failed acquisition cleanup can be retried by owner without a returned token")
    func ownerCleanupAfterFailedAcquisition() throws {
        let (service, backend, _, clock) = makeService()
        defer { service.shutdown() }
        service.start(.oneHour)
        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        backend.failingKinds = [.preventIdleDisplaySleep]
        backend.failingReleaseIDs = [3]
        #expect(throws: AwakeLeaseError.couldNotAcquire) {
            _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: true,
                                         deadline: clock.current.addingTimeInterval(300))
        }
        #expect(service.hasPendingLeaseCleanup(owner: .presentation))
        #expect(!service.hasPendingLeaseCleanup(owner: .awayMode))
        let events = backend.events
        #expect(service.retryPendingLeaseCleanup(owner: .scene))
        #expect(backend.events == events)
        #expect(!service.retryPendingLeaseCleanup(owner: .presentation))
        backend.failingReleaseIDs = []
        #expect(service.retryPendingLeaseCleanup(owner: .presentation))
        #expect(!service.hasPendingLeaseCleanup(owner: .presentation))
        #expect(service.failure == nil)
        #expect(backend.activeAssertionIDs == [1, 2])
        #expect(service.isActive)
        #expect(service.hasLease(for: .awayMode))
    }

    @Test("Lease retry cannot clear an unresolved manual cleanup failure")
    func leaseRetryPreservesManualFault() throws {
        let (service, backend, _, _) = makeService()
        defer { service.shutdown() }
        service.start(.oneHour)
        let token = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        backend.failingReleaseIDs = [1, 2]
        service.stop()
        #expect(!service.releaseLease(token))
        backend.failingReleaseIDs = [1]
        #expect(service.retryReleaseLease(token))
        #expect(service.failure == .couldNotRelease)
        let events = backend.events
        service.start(.oneHour)
        #expect(backend.events == events)
    }

    @Test("Deliberate lifecycle cleanup recovers a terminal manual release failure without reopening Awake")
    func terminalManualCleanupRetry() {
        let (service, backend, _, _) = makeService()
        service.start(.oneHour)
        backend.failingReleaseIDs = [1]
        service.stop()
        service.shutdown()
        #expect(service.failure == .couldNotRelease)
        #expect(backend.releaseCount(for: 1) == 2)

        backend.failingReleaseIDs = []
        #expect(service.hasPendingAssertionCleanup)
        #expect(service.retryPendingAssertionCleanup())
        #expect(!service.hasPendingAssertionCleanup)
        #expect(service.failure == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.releaseCount(for: 1) == 3)
        let cleanedEvents = backend.events
        service.start(.oneHour)
        service.shutdown()
        #expect(service.session == nil)
        #expect(throws: AwakeLeaseError.serviceUnavailable) {
            _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        }
        #expect(backend.events == cleanedEvents)
    }

    @Test("Lifecycle retry drains mixed pending IDs but preserves a live owner and partial failure")
    func mixedPendingLifecycleCleanup() throws {
        let admission = ManualAdmission()
        let (service, backend, _, _) = makeService { admission.check() }
        defer { service.shutdown() }
        service.start(.oneHour)
        let away = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: true)
        let scene = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        backend.failingReleaseIDs = [1, 4]
        service.stop()
        #expect(!service.releaseLease(scene))
        #expect(service.hasPendingAssertionCleanup)
        #expect(service.hasPendingLeaseCleanup(owner: .scene))
        admission.allowed = false
        let admissionChecks = admission.checkCount

        backend.failingReleaseIDs = [1]
        #expect(!service.retryPendingAssertionCleanup())
        #expect(service.failure == .couldNotRelease)
        #expect(service.hasPendingAssertionCleanup)
        #expect(!service.hasPendingLeaseCleanup(owner: .scene))
        #expect(backend.activeAssertionIDs == [1, 2, 3])
        #expect(service.hasLease(for: .awayMode))
        #expect(admission.checkCount == admissionChecks)

        backend.failingReleaseIDs = []
        #expect(service.retryPendingAssertionCleanup())
        #expect(!service.hasPendingAssertionCleanup)
        #expect(service.failure == nil)
        #expect(backend.activeAssertionIDs == [2, 3])
        #expect(backend.releaseCount(for: 1) == 3)
        #expect(backend.releaseCount(for: 4) == 2)
        #expect(service.session == nil)
        let cleanedEvents = backend.events
        #expect(service.retryPendingAssertionCleanup())
        #expect(service.retryReleaseLease(scene))
        #expect(backend.events == cleanedEvents)
        #expect(service.releaseLease(away))
    }

    @Test("Manual acquisition rollback without a session can be retried before shutdown")
    func rollbackOnlyLifecycleCleanup() {
        let (service, backend, scheduler, _) = makeService()
        defer { service.shutdown() }
        service.setKeepDisplayAwake(true)
        backend.failingKinds = [.preventIdleDisplaySleep]
        backend.failingReleaseIDs = [1]
        service.start(.oneHour)
        #expect(service.session == nil)
        #expect(service.hasPendingAssertionCleanup)
        #expect(scheduler.scheduledDate == nil)
        #expect(!service.retryPendingAssertionCleanup())
        #expect(backend.releaseCount(for: 1) == 2)
        backend.failingReleaseIDs = []
        #expect(service.retryPendingAssertionCleanup())
        #expect(service.failure == nil)
        #expect(!service.hasPendingAssertionCleanup)
        #expect(service.session == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        let cleanedEvents = backend.events
        service.shutdown()
        #expect(backend.events == cleanedEvents)
    }

    @Test("Terminal cleanup retries only failed IDs and never recreates assertions")
    func terminalPartialLifecycleCleanup() throws {
        let (service, backend, scheduler, _) = makeService()
        service.start(.oneHour)
        _ = try service.acquireLease(owner: .scene, keepsDisplayAwake: true)
        backend.failingReleaseIDs = [1, 3]
        service.shutdown()
        #expect(service.hasPendingAssertionCleanup)
        #expect(backend.releaseCount(for: 2) == 1)
        #expect(backend.activeAssertionIDs == [1, 3])

        backend.failingReleaseIDs = [3]
        #expect(!service.retryPendingAssertionCleanup())
        #expect(service.failure == .couldNotRelease)
        #expect(backend.activeAssertionIDs == [3])
        #expect(service.hasPendingLeaseCleanup(owner: .scene))
        backend.failingReleaseIDs = []
        #expect(service.retryPendingAssertionCleanup())
        #expect(!service.hasPendingLeaseCleanup(owner: .scene))
        #expect(!service.hasPendingAssertionCleanup)
        #expect(backend.releaseCount(for: 1) == 3)
        #expect(backend.releaseCount(for: 2) == 1)
        #expect(backend.releaseCount(for: 3) == 4)
        let cleanedEvents = backend.events
        #expect(service.retryPendingAssertionCleanup())
        service.start(.oneHour)
        service.shutdown()
        #expect(service.session == nil)
        #expect(service.leaseStates.isEmpty)
        #expect(scheduler.scheduledDate == nil)
        #expect(backend.events == cleanedEvents)
    }

    @Test("Pending lifecycle cleanup invalidates observation on failure and recovery")
    func pendingCleanupObservation() async {
        let (service, backend, _, _) = makeService()
        defer { service.shutdown() }
        service.start(.oneHour)
        await confirmation("Pending cleanup changed", expectedCount: 2) { changed in
            withObservationTracking {
                _ = service.hasPendingAssertionCleanup
            } onChange: {
                changed()
            }
            backend.failingReleaseIDs = [1]
            service.stop()
            #expect(service.hasPendingAssertionCleanup)
            withObservationTracking {
                _ = service.hasPendingAssertionCleanup
            } onChange: {
                changed()
            }
            backend.failingReleaseIDs = []
            #expect(service.retryPendingAssertionCleanup())
            #expect(!service.hasPendingAssertionCleanup)
        }
    }

    @Test("Initial state is inactive with no assertions")
    func initialState() {
        let (service, backend, scheduler, _) = makeService()

        #expect(service.session == nil)
        #expect(!service.isActive)
        #expect(!service.keepDisplayAwake)
        #expect(!service.lastActionFailed)
        #expect(service.leaseStates.isEmpty)
        #expect(service.effectiveLeaseCount == 0)
        #expect(!service.hasEffectiveAwakeRequest)
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

    @Test(
        "Replacement cleanup failure survives manual stop and timed expiry",
        arguments: [false, true]
    )
    func replacementCleanupFailureSurvivesStop(expires: Bool) {
        let (service, backend, scheduler, clock) = makeService()
        defer { service.shutdown() }

        service.start(.oneHour)
        let originalSession = service.session
        backend.failingKinds = [.preventIdleDisplaySleep]
        backend.failingReleaseIDs = [2]
        service.setKeepDisplayAwake(true)

        #expect(service.session == originalSession)
        #expect(service.failure == .couldNotRelease)
        #expect(backend.activeAssertionIDs == [1, 2])

        if expires {
            clock.advance(by: 60 * 60)
            scheduler.fire()
        } else {
            service.stop()
        }

        #expect(service.session == nil)
        #expect(service.failure == .couldNotRelease)
        #expect(scheduler.scheduledDate == nil)
        #expect(backend.activeAssertionIDs == [2])
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.releaseCount(for: 2) == 1)

        backend.failingKinds = []
        let eventsAfterStop = backend.events
        service.start(.twoHours)
        service.setKeepDisplayAwake(true)
        service.stop()

        #expect(service.session == nil)
        #expect(service.failure == .couldNotRelease)
        #expect(!service.keepDisplayAwake)
        #expect(backend.events == eventsAfterStop)
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

    @Test("User, Away, and Scene requests own independent assertions")
    func leaseOwnerIsolation() throws {
        let (service, backend, _, _) = makeService()

        service.start(.oneHour)
        let away = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        let scene = try service.acquireLease(owner: .scene, keepsDisplayAwake: true)

        #expect(service.isActive)
        #expect(service.effectiveLeaseCount == 2)
        #expect(service.hasEffectiveAwakeRequest)
        #expect(service.leaseState(for: .awayMode) == AwakeLeaseState(
            owner: .awayMode,
            keepsDisplayAwake: false
        ))
        #expect(service.leaseState(for: .scene) == AwakeLeaseState(
            owner: .scene,
            keepsDisplayAwake: true
        ))
        #expect(backend.activeAssertionIDs == [1, 2, 3, 4])

        #expect(service.releaseLease(scene))
        #expect(service.leaseState(for: .scene) == nil)
        #expect(service.hasLease(for: .awayMode))
        #expect(service.isActive)
        #expect(backend.activeAssertionIDs == [1, 2])

        service.stop()
        #expect(!service.isActive)
        #expect(service.hasLease(for: .awayMode))
        #expect(service.hasEffectiveAwakeRequest)
        #expect(backend.activeAssertionIDs == [2])

        #expect(service.releaseLease(away))
        #expect(!service.hasEffectiveAwakeRequest)
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("Lease assertions use owner-specific reasons")
    func ownerSpecificReasons() throws {
        let (service, backend, _, _) = makeService()

        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: true)
        _ = try service.acquireLease(owner: .scene, keepsDisplayAwake: true)

        #expect(backend.requestedReasons == [
            "Semper Away Mode requested idle sleep prevention",
            "Semper Away Mode requested idle display sleep prevention",
            "Semper Scene requested idle sleep prevention",
            "Semper Scene requested idle display sleep prevention",
        ])
    }

    @Test(
        "Presentation refuses missing, expired, and nonfinite deadlines",
        arguments: [TimeInterval?.none, -1, 0, .infinity, -.infinity, .nan]
    )
    func presentationRequiresFiniteDeadline(_ interval: TimeInterval?) {
        let (service, backend, scheduler, clock) = makeService()
        let deadline = interval.map { clock.current.addingTimeInterval($0) }

        #expect(throws: AwakeLeaseError.invalidDeadline) {
            try service.acquireLease(owner: .presentation, keepsDisplayAwake: true, deadline: deadline)
        }

        #expect(backend.events.isEmpty)
        #expect(!service.hasLease(for: .presentation))
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("Presentation assertions use their remaining deadline and owner reasons")
    func presentationAssertionTimeouts() throws {
        let (service, backend, scheduler, clock) = makeService()
        let deadline = clock.current.addingTimeInterval(600)
        backend.onCreate = { clock.advance(by: 10) }

        _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: true, deadline: deadline)

        #expect(backend.requestedTimeouts == [600, 590])
        #expect(backend.requestedReasons == [
            "Semper Presentation requested idle sleep prevention",
            "Semper Presentation requested idle display sleep prevention",
        ])
        #expect(service.leaseState(for: .presentation) == AwakeLeaseState(
            owner: .presentation, keepsDisplayAwake: true, deadline: deadline
        ))
        #expect(scheduler.scheduledDate == deadline)
    }

    @Test("An elapsed deadline during acquisition rolls back the partial assertion")
    func presentationDeadlineElapsedDuringAcquisition() {
        let (service, backend, scheduler, clock) = makeService()
        let deadline = clock.current.addingTimeInterval(60)
        backend.onCreate = { clock.advance(by: 60) }

        #expect(throws: AwakeLeaseError.couldNotAcquire) {
            try service.acquireLease(owner: .presentation, keepsDisplayAwake: true, deadline: deadline)
        }

        #expect(backend.requestedTimeouts == [60])
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(service.leaseState(for: .presentation) == nil)
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("Presentation remains independent of manual, Away, and Scene requests")
    func presentationOwnerIsolation() throws {
        let (service, backend, scheduler, clock) = makeService()
        let deadline = clock.current.addingTimeInterval(600)
        service.start(.oneHour)
        let away = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        let scene = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        let presentation = try service.acquireLease(
            owner: .presentation, keepsDisplayAwake: true, deadline: deadline
        )

        service.stop()
        service.start(.twoHours)
        service.stop()
        #expect(backend.activeAssertionIDs == [2, 3, 4, 5])
        #expect(service.effectiveLeaseCount == 3)
        #expect(scheduler.scheduledDate == deadline)

        #expect(service.releaseLease(scene))
        #expect(service.releaseLease(away))
        #expect(backend.activeAssertionIDs == [4, 5])
        #expect(scheduler.scheduledDate == deadline)
        #expect(service.releaseLease(presentation))
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("Presentation acquisition only reuses an exactly matching active request")
    func presentationAcquisitionCannotReplaceSession() throws {
        let (service, backend, scheduler, clock) = makeService()
        let deadline = clock.current.addingTimeInterval(600)
        let token = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false, deadline: deadline)
        let events = backend.events

        #expect(try service.acquireLease(owner: .presentation, keepsDisplayAwake: false, deadline: deadline) == token)
        #expect(throws: AwakeLeaseError.conflictingLease) {
            try service.acquireLease(owner: .presentation, keepsDisplayAwake: true, deadline: deadline)
        }
        for changedDeadline in [deadline.addingTimeInterval(-60), deadline.addingTimeInterval(60)] {
            #expect(throws: AwakeLeaseError.conflictingLease) {
                try service.acquireLease(owner: .presentation, keepsDisplayAwake: false, deadline: changedDeadline)
            }
        }

        #expect(backend.events == events)
        #expect(scheduler.scheduledDate == deadline)
        #expect(service.leaseState(for: .presentation)?.deadline == deadline)
    }

    @Test("Presentation display changes preserve the original deadline")
    func presentationDisplayUpdatePreservesDeadline() throws {
        let (service, backend, scheduler, clock) = makeService()
        let deadline = clock.current.addingTimeInterval(600)
        let token = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false, deadline: deadline)
        clock.advance(by: 120)

        try service.updateLease(token, keepsDisplayAwake: true)

        #expect(backend.requestedTimeouts == [600, 480, 480])
        #expect(service.leaseState(for: .presentation)?.deadline == deadline)
        #expect(service.leaseState(for: .presentation)?.keepsDisplayAwake == true)
        #expect(scheduler.scheduledDate == deadline)
        clock.advance(by: 480)
        scheduler.fire()
        #expect(!service.hasLease(for: .presentation))
        #expect(backend.activeAssertionIDs.isEmpty)
    }

    @Test("Presentation expiry releases only its assertions without a manual session")
    func presentationExpiryWithoutManualSession() throws {
        let (service, backend, scheduler, clock) = makeService()
        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: true,
                                     deadline: clock.current.addingTimeInterval(600))

        clock.advance(by: 300)
        scheduler.fire()
        #expect(service.hasLease(for: .presentation))
        #expect(scheduler.scheduledDate == clock.current.addingTimeInterval(300))
        clock.advance(by: 300)
        scheduler.fire()

        #expect(!service.hasLease(for: .presentation))
        #expect(service.hasLease(for: .awayMode))
        #expect(backend.activeAssertionIDs == [1])
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("Wake expires a Presentation lease even when manual Awake is inactive")
    func presentationWakeExpiry() throws {
        let notifications = NotificationCenter()
        let (service, backend, scheduler, clock) = makeService(workspaceNotificationCenter: notifications)
        _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false,
                                     deadline: clock.current.addingTimeInterval(60))
        clock.advance(by: 120)

        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(service.leaseStates.isEmpty)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("The timer always tracks the earliest manual or Presentation deadline", arguments: [true, false])
    func earliestOwnedDeadline(presentationFirst: Bool) throws {
        let (service, backend, scheduler, clock) = makeService()
        let startedAt = clock.current
        let presentationDuration: TimeInterval = presentationFirst ? 900 : 3600
        service.start(.thirtyMinutes)
        _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false,
                                     deadline: startedAt.addingTimeInterval(presentationDuration))

        let firstInterval = min(1800, presentationDuration)
        let lastInterval = max(1800, presentationDuration)
        #expect(scheduler.scheduledDate == startedAt.addingTimeInterval(firstInterval))
        clock.advance(by: firstInterval)
        scheduler.fire()
        #expect(service.isActive == presentationFirst)
        #expect(service.hasLease(for: .presentation) == !presentationFirst)
        #expect(scheduler.scheduledDate == startedAt.addingTimeInterval(lastInterval))
        clock.advance(by: lastInterval - firstInterval)
        scheduler.fire()
        #expect(!service.hasEffectiveAwakeRequest)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("An expired Presentation token cannot update or release its replacement")
    func stalePresentationToken() throws {
        let (service, backend, scheduler, clock) = makeService()
        let first = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false,
                                             deadline: clock.current.addingTimeInterval(60))
        clock.advance(by: 60)
        #expect(throws: AwakeLeaseError.invalidToken) {
            try service.updateLease(first, keepsDisplayAwake: true)
        }
        let deadline = clock.current.addingTimeInterval(120)
        let replacement = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false, deadline: deadline)

        #expect(first != replacement)
        #expect(service.releaseLease(first))
        #expect(throws: AwakeLeaseError.invalidToken) {
            try service.updateLease(first, keepsDisplayAwake: true)
        }
        #expect(backend.activeAssertionIDs == [2])
        #expect(service.hasLease(for: .presentation))
        #expect(scheduler.scheduledDate == deadline)
    }

    @Test("Presentation expiry retains failed-release tracking for shutdown")
    func presentationExpiryReleaseFailure() throws {
        let (service, backend, scheduler, clock) = makeService()
        let token = try service.acquireLease(owner: .presentation, keepsDisplayAwake: true,
                                             deadline: clock.current.addingTimeInterval(60))
        backend.failingReleaseIDs = [2]
        clock.advance(by: 60)
        scheduler.fire()

        #expect(service.failure == .couldNotRelease)
        #expect(service.leaseState(for: .presentation) == nil)
        #expect(backend.activeAssertionIDs == [2])
        #expect(!service.releaseLease(token))
        #expect(backend.releaseCount(for: 2) == 1)
        #expect(throws: AwakeLeaseError.serviceUnavailable) {
            try service.acquireLease(owner: .presentation, keepsDisplayAwake: false,
                                     deadline: clock.current.addingTimeInterval(60))
        }

        backend.failingReleaseIDs = []
        service.shutdown()
        #expect(service.failure == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.releaseCount(for: 2) == 2)
        #expect(service.releaseLease(token))
        #expect(scheduler.scheduledDate == nil)
    }

    @Test("A failed manual replacement cannot cancel Presentation expiry")
    func manualReplacementFailurePreservesPresentationExpiry() throws {
        let (service, backend, scheduler, clock) = makeService()
        service.start(.oneHour)
        let deadline = clock.current.addingTimeInterval(60)
        _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: false, deadline: deadline)
        backend.failingReleaseIDs = [1]

        service.start(.twoHours)

        #expect(service.session == nil)
        #expect(service.failure == .couldNotRelease)
        #expect(scheduler.scheduledDate == deadline)
        #expect(backend.activeAssertionIDs == [1, 2])
        clock.advance(by: 60)
        scheduler.fire()
        #expect(!service.hasLease(for: .presentation))
        #expect(backend.activeAssertionIDs == [1])
        #expect(service.failure == .couldNotRelease)
    }

    @Test("A lease update acquires its replacement before releasing prior assertions")
    func leaseUpdateOrder() throws {
        let (service, backend, _, _) = makeService()
        let lease = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)

        try service.updateLease(lease, keepsDisplayAwake: true)

        #expect(backend.events == [
            .created(1, .preventIdleSystemSleep),
            .created(2, .preventIdleSystemSleep),
            .created(3, .preventIdleDisplaySleep),
            .released(1),
        ])
        #expect(service.leaseState(for: .scene)?.keepsDisplayAwake == true)
        #expect(backend.activeAssertionIDs == [2, 3])
    }

    @Test("Repeated acquire returns one owner token and updates it in place")
    func idempotentLeaseAcquire() throws {
        let (service, backend, _, _) = makeService()
        let first = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        let eventsAfterFirstAcquire = backend.events

        let unchanged = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        #expect(unchanged == first)
        #expect(backend.events == eventsAfterFirstAcquire)

        let updated = try service.acquireLease(owner: .scene, keepsDisplayAwake: true)
        #expect(updated == first)
        #expect(service.effectiveLeaseCount == 1)
        #expect(service.leaseState(for: .scene)?.keepsDisplayAwake == true)
        #expect(backend.events == [
            .created(1, .preventIdleSystemSleep),
            .created(2, .preventIdleSystemSleep),
            .created(3, .preventIdleDisplaySleep),
            .released(1),
        ])
    }

    @Test("A failed lease acquisition preserves that owner's prior state")
    func failedLeaseUpdateAcquisition() throws {
        let (service, backend, _, _) = makeService()
        let lease = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        backend.failingKinds = [.preventIdleDisplaySleep]

        #expect(throws: AwakeLeaseError.couldNotAcquire) {
            try service.updateLease(lease, keepsDisplayAwake: true)
        }

        #expect(service.leaseState(for: .scene)?.keepsDisplayAwake == false)
        #expect(service.failure == .couldNotStart)
        #expect(backend.activeAssertionIDs == [1])
        #expect(backend.releaseCount(for: 2) == 1)
    }

    @Test("Lease release reports a backend failure and retains cleanup state")
    func leaseReleaseFailure() throws {
        let (service, backend, _, _) = makeService()
        let lease = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        backend.failingReleaseIDs = [1]

        #expect(!service.releaseLease(lease))
        #expect(service.failure == .couldNotRelease)
        #expect(service.leaseState(for: .awayMode) == nil)
        #expect(service.effectiveLeaseCount == 0)
        #expect(backend.activeAssertionIDs == [1])

        #expect(!service.releaseLease(lease))
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(throws: AwakeLeaseError.serviceUnavailable) {
            try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        }
    }

    @Test("Shutdown retries only the unresolved IDs from a partial lease release")
    func shutdownRetriesPartialLeaseRelease() throws {
        let (service, backend, _, _) = makeService()
        let lease = try service.acquireLease(owner: .scene, keepsDisplayAwake: true)
        backend.failingReleaseIDs = [2]

        #expect(!service.releaseLease(lease))
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.releaseCount(for: 2) == 1)
        let eventsAfterRelease = backend.events
        #expect(!service.releaseLease(lease))
        #expect(backend.events == eventsAfterRelease)

        backend.failingReleaseIDs = []
        service.shutdown()
        #expect(backend.releaseCount(for: 1) == 1)
        #expect(backend.releaseCount(for: 2) == 2)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(service.releaseLease(lease))

        let eventsAfterShutdown = backend.events
        service.shutdown()
        #expect(backend.events == eventsAfterShutdown)
    }

    @Test("Shutdown retries a failed user-session release once")
    func shutdownRetriesUserSessionRelease() {
        let (service, backend, _, _) = makeService()
        service.start(.untilTurnedOff)
        backend.failingReleaseIDs = [1]

        service.stop()
        #expect(service.failure == .couldNotRelease)
        #expect(backend.releaseCount(for: 1) == 1)

        backend.failingReleaseIDs = []
        service.shutdown()
        #expect(service.failure == nil)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(backend.releaseCount(for: 1) == 2)

        let eventsAfterShutdown = backend.events
        service.shutdown()
        #expect(backend.events == eventsAfterShutdown)
    }

    @Test("Repeated shutdown does not retry a failed cleanup again")
    func failedShutdownLeaseRetry() throws {
        let (service, backend, _, _) = makeService()
        service.start(.untilTurnedOff)
        let lease = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        backend.failingReleaseIDs = [1, 2]

        service.stop()
        #expect(!service.releaseLease(lease))
        backend.failingReleaseIDs = [2]
        service.shutdown()

        #expect(service.failure == .couldNotRelease)
        #expect(backend.activeAssertionIDs == [2])
        #expect(backend.releaseCount(for: 1) == 2)
        #expect(backend.releaseCount(for: 2) == 2)
        #expect(!service.releaseLease(lease))

        let eventsAfterShutdown = backend.events
        service.shutdown()
        #expect(backend.events == eventsAfterShutdown)
    }

    @Test("Duplicate and stale lease releases are idempotent")
    func duplicateLeaseRelease() throws {
        let (service, backend, _, _) = makeService()
        let first = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
        #expect(service.releaseLease(first))
        let second = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)

        #expect(service.releaseLease(first))
        #expect(service.hasLease(for: .scene))
        #expect(backend.activeAssertionIDs == [2])

        #expect(service.releaseLease(second))
        #expect(service.releaseLease(second))
        #expect(backend.releaseCount(for: 2) == 1)
    }

    @Test("Shutdown releases user, Away, Scene, and Presentation assertions exactly once")
    func shutdownReleasesEveryOwner() throws {
        let (service, backend, scheduler, clock) = makeService()
        service.setKeepDisplayAwake(true)
        service.start(.untilTurnedOff)
        _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
        _ = try service.acquireLease(owner: .scene, keepsDisplayAwake: true)
        _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: true,
                                     deadline: clock.current.addingTimeInterval(60))

        service.shutdown()
        service.shutdown()

        #expect(service.session == nil)
        #expect(service.leaseStates.isEmpty)
        #expect(!service.hasEffectiveAwakeRequest)
        #expect(backend.activeAssertionIDs.isEmpty)
        #expect(scheduler.scheduledDate == nil)
        for id in PowerAssertionID(1)...PowerAssertionID(7) {
            #expect(backend.releaseCount(for: id) == 1)
        }
    }

    @Test("Per-owner lease state invalidates observation")
    func leaseStateObservation() async throws {
        let (service, _, _, _) = makeService()

        try await confirmation("Scene lease state changed", expectedCount: 3) { changed in
            withObservationTracking {
                _ = service.leaseState(for: .scene)
            } onChange: {
                changed()
            }

            let lease = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)

            withObservationTracking {
                _ = service.leaseState(for: .scene)
            } onChange: {
                changed()
            }

            try service.updateLease(lease, keepsDisplayAwake: true)

            withObservationTracking {
                _ = service.leaseState(for: .scene)
            } onChange: {
                changed()
            }

            #expect(service.releaseLease(lease))
        }
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
