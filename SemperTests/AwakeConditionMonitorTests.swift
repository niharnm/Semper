import AppKit
import Foundation
import IOKit.ps
import Testing
@testable import Semper

@MainActor
private final class NativeAwakeConditionFixture {
    let notifications = NotificationCenter()
    var applications: [AwakeNativeProcessSnapshot] = []
    var process: AwakeNativeProcessSnapshot?
    var descriptions: [[String: Any]]?
    var cannotObservePower = false
    var duringPowerSubscription: (@MainActor () -> Void)?
    private(set) var applicationReads = 0
    private(set) var processReads: [Int32] = []
    private(set) var powerReads = 0
    private(set) var powerCallbacks: [@MainActor @Sendable () -> Void] = []
    private(set) var activeSubscriptions: Set<Int> = []
    private(set) var cancellations: [Int] = []
    private(set) var wasSubscribedWhenPowerRead: [Bool] = []

    func makeMonitor() -> NativeAwakeConditionMonitor {
        NativeAwakeConditionMonitor(
            notificationCenter: notifications,
            ownProcessIdentifier: 100,
            readApplications: { [self] in
                applicationReads += 1
                return applications
            },
            readProcess: { [self] identifier in
                processReads.append(identifier)
                return process
            },
            readPowerSources: { [self] in
                powerReads += 1
                wasSubscribedWhenPowerRead.append(!activeSubscriptions.isEmpty)
                return descriptions
            },
            observePower: { [self] callback in
                let identifier = powerCallbacks.count
                powerCallbacks.append(callback)
                guard !cannotObservePower else { return nil }
                activeSubscriptions.insert(identifier)
                duringPowerSubscription?()
                return { [self] in
                    cancellations.append(identifier)
                    activeSubscriptions.remove(identifier)
                }
            }
        )
    }
}

@MainActor
@Suite("Awake native condition monitor")
struct AwakeConditionMonitorTests {
    private let launchDate = Date(timeIntervalSince1970: 1_700_000_000)

    private var selectedApplication: AwakeApplication {
        AwakeApplication(id: .init(processIdentifier: 200, launchDate: launchDate), name: "Selected app")
    }

    private func process(
        _ identifier: Int32 = 200,
        launchDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        name: String? = "Selected app",
        regular: Bool = true,
        terminated: Bool = false
    ) -> AwakeNativeProcessSnapshot {
        AwakeNativeProcessSnapshot(
            processIdentifier: identifier,
            launchDate: launchDate,
            name: name,
            isRegular: regular,
            isTerminated: terminated
        )
    }

    private func battery(
        current: Any = 40,
        maximum: Any = 100,
        state: String = kIOPSBatteryPowerValue,
        present: Bool = true
    ) -> [String: Any] {
        [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: present,
            kIOPSCurrentCapacityKey: current,
            kIOPSMaxCapacityKey: maximum,
            kIOPSPowerSourceStateKey: state,
        ]
    }

    @Test("Initialization and an empty condition snapshot do not read native state")
    func cheapInitialization() throws {
        let fixture = NativeAwakeConditionFixture()
        let monitor = fixture.makeMonitor()
        #expect(fixture.applicationReads == 0)
        #expect(fixture.processReads.isEmpty)
        #expect(fixture.powerReads == 0)
        #expect(fixture.powerCallbacks.isEmpty)
        #expect(monitor.snapshot(for: .init()) == .init(selectedApplicationRunning: nil, battery: .unknown))
        var snapshots: [AwakeConditionSnapshot] = []
        try monitor.start(conditions: .init()) { snapshots.append($0) }
        #expect(snapshots.count == 1)
        #expect(fixture.processReads.isEmpty)
        #expect(fixture.powerReads == 0)
        #expect(fixture.powerCallbacks.isEmpty)
        monitor.stop()
    }

    @Test("App choices exclude self, helpers, exited apps and unknown process identities")
    func availableApplicationFiltering() {
        let fixture = NativeAwakeConditionFixture()
        fixture.applications = [
            process(100, name: "Self"), process(200, name: "Zeta"), process(201, name: "Alpha"),
            process(202, name: "Helper", regular: false), process(203, terminated: true),
            process(204, launchDate: nil), process(-1), process(205, name: nil), process(206, name: ""),
        ]
        let applications = fixture.makeMonitor().availableApplications()
        #expect(applications.map(\.name) == ["Alpha", "Zeta"])
        #expect(applications.map(\.id.processIdentifier) == [201, 200])
        #expect(applications.allSatisfy { $0.id.launchDate == launchDate })
        #expect(fixture.powerReads == 0)
    }

    @Test("Each selected process snapshot verifies PID, launch date and termination")
    func stableProcessIdentity() {
        let fixture = NativeAwakeConditionFixture()
        let monitor = fixture.makeMonitor()
        let conditions = AwakeStopConditions(application: selectedApplication)
        fixture.process = process()
        #expect(monitor.snapshot(for: conditions).selectedApplicationRunning == true)
        fixture.process = process(201)
        #expect(monitor.snapshot(for: conditions).selectedApplicationRunning == false)
        fixture.process = process(launchDate: launchDate.addingTimeInterval(1))
        #expect(monitor.snapshot(for: conditions).selectedApplicationRunning == false)
        fixture.process = process(launchDate: nil)
        #expect(monitor.snapshot(for: conditions).selectedApplicationRunning == false)
        fixture.process = process(terminated: true)
        #expect(monitor.snapshot(for: conditions).selectedApplicationRunning == false)
        fixture.process = nil
        #expect(monitor.snapshot(for: conditions).selectedApplicationRunning == false)
        #expect(fixture.processReads == Array(repeating: 200, count: 6))
        #expect(fixture.applicationReads == 0)
        #expect(fixture.powerReads == 0)
    }

    @Test("Missing and malformed power descriptions are unknown, while no internal source means no battery")
    func missingPowerDescriptions() {
        #expect(NativeAwakeConditionMonitor.batteryState(from: nil) == .unknown)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [[:]]) == .unknown)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [[kIOPSTypeKey: 1]]) == .unknown)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [[kIOPSTypeKey: "Unknown source"]]) == .unknown)
        #expect(NativeAwakeConditionMonitor.batteryState(from: []) == .noBattery)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [[kIOPSTypeKey: kIOPSUPSType]]) == .noBattery)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(present: false)]) == .noBattery)
        var missingPresence = battery()
        missingPresence.removeValue(forKey: kIOPSIsPresentKey)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [missingPresence]) == .unknown)
        missingPresence[kIOPSIsPresentKey] = 1
        #expect(NativeAwakeConditionMonitor.batteryState(from: [missingPresence]) == .unknown)
    }

    @Test("Capacity uses current divided by maximum and does not read UPS percentage")
    func batteryCapacityAndUPSIgnored() {
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(current: 3000, maximum: 6000)]) == .battery(percentage: 50))
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(current: 0)]) == .battery(percentage: 0))
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(current: 29)]) == .battery(percentage: 29))
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(current: 1, maximum: 3)]) == .battery(percentage: 33))
        var ups = battery(current: 1)
        ups[kIOPSTypeKey] = kIOPSUPSType
        #expect(NativeAwakeConditionMonitor.batteryState(from: [ups, battery(current: 80)]) == .battery(percentage: 80))
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(), battery()]) == .unknown)
    }

    @Test("Invalid capacities remain unknown and do not fabricate a percentage")
    func malformedCapacity() {
        let invalid: [Any] = [-1, 101, true, "40", 0.5, Double.nan, Double.infinity, Double.greatestFiniteMagnitude]
        for current in invalid {
            #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(current: current)]) == .unknown)
        }
        let invalidMaximums: [Any] = [0, -1, true, "100", 0.5, Double.nan, Double.infinity]
        for maximum in invalidMaximums {
            #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(maximum: maximum)]) == .unknown)
        }
        var missingCapacity = battery()
        missingCapacity.removeValue(forKey: kIOPSCurrentCapacityKey)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [missingCapacity]) == .unknown)
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(state: "Offline")]) == .unknown)
    }

    @Test("AC power can be known even when capacity is unavailable")
    func externalPowerWithOptionalCapacity() {
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(current: 10, state: kIOPSACPowerValue)]) == .externalPower(percentage: 10))
        #expect(NativeAwakeConditionMonitor.batteryState(from: [battery(maximum: 0, state: kIOPSACPowerValue)]) == .externalPower(percentage: nil))
    }

    @Test("Power observation is installed before the first snapshot and reports AC transitions")
    func powerObservationStartupAndTransitions() throws {
        let fixture = NativeAwakeConditionFixture()
        fixture.descriptions = [battery(current: 10, state: kIOPSACPowerValue)]
        let monitor = fixture.makeMonitor()
        var snapshots: [AwakeConditionSnapshot] = []
        try monitor.start(conditions: .init(batteryThreshold: .twenty)) { snapshots.append($0) }
        #expect(snapshots.map(\.battery) == [.externalPower(percentage: 10)])
        #expect(fixture.wasSubscribedWhenPowerRead == [true])
        fixture.descriptions = [battery(current: 10)]
        fixture.powerCallbacks[0]()
        #expect(snapshots.map(\.battery) == [.externalPower(percentage: 10), .battery(percentage: 10)])
        #expect(fixture.processReads.isEmpty)
        fixture.notifications.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        #expect(snapshots.count == 2)
        monitor.stop()
        monitor.stop()
        #expect(fixture.cancellations == [0])
    }

    @Test("Process notifications detect exit and PID replacement and are removed on stop")
    func processNotifications() throws {
        let fixture = NativeAwakeConditionFixture()
        fixture.process = process()
        let monitor = fixture.makeMonitor()
        var snapshots: [AwakeConditionSnapshot] = []
        try monitor.start(conditions: .init(application: selectedApplication)) { snapshots.append($0) }
        fixture.process = nil
        fixture.notifications.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        fixture.process = process(launchDate: launchDate.addingTimeInterval(1))
        fixture.notifications.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        #expect(snapshots.map(\.selectedApplicationRunning) == [true, false, false])
        #expect(fixture.powerCallbacks.isEmpty)
        monitor.stop()
        fixture.notifications.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        #expect(snapshots.count == 3)
        #expect(fixture.processReads.count == 3)
    }

    @Test("Power callback generations reject events after stop and after changed conditions")
    func stalePowerCallbacks() throws {
        let fixture = NativeAwakeConditionFixture()
        fixture.descriptions = [battery()]
        let monitor = fixture.makeMonitor()
        var snapshots: [AwakeConditionSnapshot] = []
        try monitor.start(conditions: .init(batteryThreshold: .twenty)) { snapshots.append($0) }
        let staleCallback = fixture.powerCallbacks[0]
        try monitor.start(conditions: .init(batteryThreshold: .fifty)) { snapshots.append($0) }
        #expect(fixture.cancellations == [0])
        staleCallback()
        #expect(snapshots.count == 2)
        fixture.powerCallbacks[1]()
        #expect(snapshots.count == 3)
        monitor.stop()
        fixture.powerCallbacks[1]()
        #expect(snapshots.count == 3)
        #expect(fixture.powerReads == 3)
        #expect(fixture.cancellations == [0, 1])
        #expect(fixture.activeSubscriptions.isEmpty)
    }

    @Test("Failed power subscription tears down process observers and delivers no stale snapshot")
    func powerSubscriptionFailure() {
        let fixture = NativeAwakeConditionFixture()
        fixture.cannotObservePower = true
        fixture.process = process()
        let monitor = fixture.makeMonitor()
        var snapshots: [AwakeConditionSnapshot] = []
        #expect(throws: AwakeConditionMonitorError.batteryNotificationsUnavailable) {
            try monitor.start(conditions: .init(application: selectedApplication, batteryThreshold: .twenty)) {
                snapshots.append($0)
            }
        }
        fixture.notifications.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        fixture.powerCallbacks[0]()
        #expect(snapshots.isEmpty)
        #expect(fixture.processReads.isEmpty)
        #expect(fixture.powerReads == 0)
    }

    @Test("Stop during subscription cancels the returned observation instead of retaining it")
    func stopDuringSubscription() throws {
        let fixture = NativeAwakeConditionFixture()
        let monitor = fixture.makeMonitor()
        fixture.duringPowerSubscription = { [weak monitor] in monitor?.stop() }
        var snapshots: [AwakeConditionSnapshot] = []
        try monitor.start(conditions: .init(batteryThreshold: .twenty)) { snapshots.append($0) }
        #expect(snapshots.isEmpty)
        #expect(fixture.cancellations == [0])
        #expect(fixture.activeSubscriptions.isEmpty)
        fixture.powerCallbacks[0]()
        #expect(fixture.powerReads == 0)
    }

    @Test("Releasing the monitor cancels observations without a callback retain cycle")
    func monitorDeinitialization() throws {
        let fixture = NativeAwakeConditionFixture()
        fixture.descriptions = [battery()]
        var monitor: NativeAwakeConditionMonitor? = fixture.makeMonitor()
        weak let weakMonitor = monitor
        var snapshots: [AwakeConditionSnapshot] = []
        try monitor?.start(conditions: .init(batteryThreshold: .twenty)) { snapshots.append($0) }
        monitor = nil
        #expect(weakMonitor == nil)
        #expect(fixture.cancellations == [0])
        fixture.powerCallbacks[0]()
        #expect(snapshots.count == 1)
    }
}
