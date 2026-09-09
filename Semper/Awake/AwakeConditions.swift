import Foundation

struct AwakeProcessIdentity: Hashable, Sendable {
    let processIdentifier: Int32
    let launchDate: Date
}

struct AwakeApplication: Equatable, Identifiable, Sendable {
    let id: AwakeProcessIdentity
    let name: String
}

enum AwakeBatteryThreshold: Int, CaseIterable, Identifiable, Sendable {
    case ten = 10
    case twenty = 20
    case thirty = 30
    case fifty = 50

    var id: Int { rawValue }
}

enum AwakeBatteryState: Equatable, Sendable {
    case unknown
    case noBattery
    case externalPower(percentage: Int?)
    case battery(percentage: Int)
}

struct AwakeStopConditions: Equatable, Sendable {
    var application: AwakeApplication?
    var batteryThreshold: AwakeBatteryThreshold?

    init(application: AwakeApplication? = nil, batteryThreshold: AwakeBatteryThreshold? = nil) {
        self.application = application
        self.batteryThreshold = batteryThreshold
    }

    var needsObservation: Bool {
        application != nil || batteryThreshold != nil
    }
}

struct AwakeConditionSnapshot: Equatable, Sendable {
    let selectedApplicationRunning: Bool?
    let battery: AwakeBatteryState
}

enum AwakeConditionMonitorError: Error, Equatable, Sendable {
    case batteryNotificationsUnavailable
}

enum AwakeSessionEndReason: Equatable, Sendable {
    case selectedApplicationExited(String)
    case batteryThresholdReached(Int)
    case batteryStateUnavailable
    case conditionMonitoringUnavailable
    case expired
}

@MainActor
protocol AwakeConditionMonitoring: AnyObject {
    func availableApplications() -> [AwakeApplication]
    func snapshot(for conditions: AwakeStopConditions) -> AwakeConditionSnapshot
    func start(
        conditions: AwakeStopConditions,
        onChange: @escaping @MainActor @Sendable (AwakeConditionSnapshot) -> Void
    ) throws(AwakeConditionMonitorError)
    func stop()
}
