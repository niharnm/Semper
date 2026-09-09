import Foundation
import Testing
@testable import Semper

@MainActor
private final class AwayPowerReadingSourceStub: AwayPowerReadingSource {
    var reading: AwayPowerReading
    private(set) var startMonitoringCallCount = 0
    private(set) var stopMonitoringCallCount = 0
    private var handler: (@MainActor @Sendable () -> Void)?

    init(reading: AwayPowerReading) {
        self.reading = reading
    }

    func currentReading() -> AwayPowerReading {
        reading
    }

    func startMonitoring(_ handler: @escaping @MainActor @Sendable () -> Void) {
        startMonitoringCallCount += 1
        self.handler = handler
    }

    func stopMonitoring() {
        stopMonitoringCallCount += 1
        handler = nil
    }

    func sendChange() {
        handler?()
    }
}

@MainActor
private final class AwayPowerChangeRecorder {
    var snapshots: [AwayPowerPolicySnapshot] = []
    var notificationCount = 0
}

@MainActor
@Suite("AwayPowerPolicy")
struct AwayPowerPolicyTests {
    @Test("Nominal power permits motion and awake requests")
    func nominalPower() {
        let reading = makeReading(powerSupply: .battery(percentage: 80))
        let source = AwayPowerReadingSourceStub(reading: reading)
        let policy = AwayPowerPolicy(source: source)

        #expect(policy.snapshot.reading == reading)
        #expect(policy.snapshot.allowsMotion)
        #expect(policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.allowsDisplayAssertion)
        #expect(!policy.snapshot.macOSMaySleep)
        #expect(policy.snapshot.awakeRestriction == nil)
    }

    @Test("Low Power Mode pauses motion only")
    func lowPowerMode() {
        let source = AwayPowerReadingSourceStub(
            reading: makeReading(isLowPowerModeEnabled: true)
        )
        let policy = AwayPowerPolicy(source: source)

        #expect(!policy.snapshot.allowsMotion)
        #expect(policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.allowsDisplayAssertion)
        #expect(!policy.snapshot.macOSMaySleep)
    }

    @Test("Serious thermal pressure pauses motion only")
    func seriousThermalPressure() {
        let source = AwayPowerReadingSourceStub(
            reading: makeReading(thermalPressure: .serious)
        )
        let policy = AwayPowerPolicy(source: source)

        #expect(!policy.snapshot.allowsMotion)
        #expect(policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == nil)
    }

    @Test("Critical thermal pressure denies awake requests until recovery")
    func criticalThermalPressure() {
        let source = AwayPowerReadingSourceStub(
            reading: makeReading(
                thermalPressure: .critical,
                powerSupply: .battery(percentage: 12)
            )
        )
        let policy = AwayPowerPolicy(source: source)

        #expect(!policy.snapshot.allowsMotion)
        #expect(!policy.snapshot.allowsAwakeAssertions)
        #expect(!policy.snapshot.allowsDisplayAssertion)
        #expect(policy.snapshot.macOSMaySleep)
        #expect(policy.snapshot.awakeRestriction == .criticalThermalPressure)

        source.reading = makeReading(
            thermalPressure: .serious,
            powerSupply: .ac(percentage: 12, isCharging: true)
        )
        source.sendChange()
        #expect(!policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == .awaitingSafePower)

        source.reading = makeReading(powerSupply: .battery(percentage: 12))
        source.sendChange()
        #expect(!policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == .awaitingSafePower)

        source.reading = makeReading(
            thermalPressure: .fair,
            powerSupply: .battery(percentage: 15)
        )
        source.sendChange()
        #expect(policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == nil)
    }

    @Test("Battery recovery uses separate release and recovery thresholds")
    func batteryHysteresis() {
        let source = AwayPowerReadingSourceStub(
            reading: makeReading(powerSupply: .battery(percentage: 10))
        )
        let policy = AwayPowerPolicy(source: source)

        #expect(!policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == .lowBattery)

        for percentage in 11...14 {
            source.reading = makeReading(
                powerSupply: .battery(percentage: percentage)
            )
            source.sendChange()
            #expect(!policy.snapshot.allowsAwakeAssertions)
            #expect(policy.snapshot.awakeRestriction == .awaitingSafePower)
        }

        source.reading = makeReading(powerSupply: .battery(percentage: 15))
        source.sendChange()
        #expect(policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == nil)
    }

    @Test("AC power clears a held battery denial")
    func acPowerRecovery() {
        let source = AwayPowerReadingSourceStub(
            reading: makeReading(powerSupply: .battery(percentage: 4))
        )
        let policy = AwayPowerPolicy(source: source)

        source.reading = makeReading(
            powerSupply: .ac(percentage: 4, isCharging: true)
        )
        source.sendChange()

        #expect(policy.snapshot.reading.batteryPercentage == 4)
        #expect(policy.snapshot.reading.isOnACPower == true)
        #expect(policy.snapshot.reading.isCharging == true)
        #expect(policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.allowsDisplayAssertion)
        #expect(policy.snapshot.awakeRestriction == nil)
    }

    @Test("Missing battery data stays denied only after a prior release")
    func missingBatteryData() {
        let source = AwayPowerReadingSourceStub(
            reading: makeReading(powerSupply: .battery(percentage: nil))
        )
        let policy = AwayPowerPolicy(source: source)

        #expect(policy.snapshot.allowsAwakeAssertions)

        source.reading = makeReading(powerSupply: .battery(percentage: 10))
        source.sendChange()
        source.reading = makeReading(powerSupply: .battery(percentage: nil))
        source.sendChange()
        #expect(!policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == .awaitingSafePower)

        source.reading = makeReading(powerSupply: .unknown)
        source.sendChange()
        #expect(!policy.snapshot.allowsAwakeAssertions)
        #expect(policy.snapshot.awakeRestriction == .awaitingSafePower)
    }

    @Test("Unavailable power monitoring denies awake requests")
    func unavailablePowerMonitoring() {
        let reading = AwayPowerReading(
            isLowPowerModeEnabled: false,
            thermalPressure: .nominal,
            powerSupply: .ac(percentage: 80, isCharging: false),
            isPowerSourceMonitoringAvailable: false
        )
        let reduction = AwayPowerPolicyReducer.reduce(
            reading: reading,
            hadAwakeAssertionDenial: false
        )

        #expect(!reduction.snapshot.allowsAwakeAssertions)
        #expect(reduction.snapshot.awakeRestriction == .powerStatusUnavailable)
    }

    @Test("Changed readings notify once and shutdown stops monitoring")
    func changeCallbackAndShutdown() {
        let source = AwayPowerReadingSourceStub(reading: makeReading())
        let policy = AwayPowerPolicy(source: source)
        let recorder = AwayPowerChangeRecorder()
        policy.onChange = { snapshot in
            recorder.snapshots.append(snapshot)
        }

        source.sendChange()
        #expect(recorder.snapshots.isEmpty)

        let changedReading = makeReading(isLowPowerModeEnabled: true)
        source.reading = changedReading
        source.sendChange()
        #expect(recorder.snapshots.count == 1)
        #expect(recorder.snapshots.first?.reading == changedReading)
        #expect(policy.snapshot == recorder.snapshots.first)

        policy.shutdown()
        policy.shutdown()
        #expect(source.startMonitoringCallCount == 1)
        #expect(source.stopMonitoringCallCount == 1)

        source.reading = makeReading()
        source.sendChange()
        #expect(recorder.snapshots.count == 1)
        #expect(policy.snapshot.reading == changedReading)
    }

    @Test("System source forwards power and thermal notifications")
    func systemSourceNotifications() {
        let notificationCenter = NotificationCenter()
        let source = SystemAwayPowerReadingSource(
            notificationCenter: notificationCenter
        )
        let recorder = AwayPowerChangeRecorder()
        source.startMonitoring {
            recorder.notificationCount += 1
        }

        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(recorder.notificationCount == 1)

        notificationCenter.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        #expect(recorder.notificationCount == 2)

        source.stopMonitoring()
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(recorder.notificationCount == 2)
    }

    @Test("System source exposes notification setup failure")
    func systemSourceNotificationSetupFailure() {
        let source = SystemAwayPowerReadingSource(
            notificationCenter: NotificationCenter(),
            runLoopSourceFactory: { _ in nil }
        )
        let recorder = AwayPowerChangeRecorder()

        source.startMonitoring {
            recorder.notificationCount += 1
        }

        #expect(!source.isPowerSourceMonitoringAvailable)
        #expect(!source.currentReading().isPowerSourceMonitoringAvailable)
        #expect(recorder.notificationCount == 1)
        source.stopMonitoring()
    }

    private func makeReading(
        isLowPowerModeEnabled: Bool = false,
        thermalPressure: AwayThermalPressure = .nominal,
        powerSupply: AwayPowerSupply = .battery(percentage: 80)
    ) -> AwayPowerReading {
        AwayPowerReading(
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            thermalPressure: thermalPressure,
            powerSupply: powerSupply
        )
    }
}
