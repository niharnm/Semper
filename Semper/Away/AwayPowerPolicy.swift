import Foundation
import IOKit.ps
import Observation

enum AwayThermalPressure: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

enum AwayPowerSupply: Equatable, Sendable {
    case ac(percentage: Int?, isCharging: Bool?)
    case battery(percentage: Int?)
    case unknown
}

struct AwayPowerReading: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let thermalPressure: AwayThermalPressure
    let powerSupply: AwayPowerSupply
    let isPowerSourceMonitoringAvailable: Bool

    init(
        isLowPowerModeEnabled: Bool,
        thermalPressure: AwayThermalPressure,
        powerSupply: AwayPowerSupply,
        isPowerSourceMonitoringAvailable: Bool = true
    ) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalPressure = thermalPressure
        self.powerSupply = powerSupply
        self.isPowerSourceMonitoringAvailable = isPowerSourceMonitoringAvailable
    }

    var batteryPercentage: Int? {
        switch powerSupply {
        case .ac(let percentage, _), .battery(let percentage):
            percentage
        case .unknown:
            nil
        }
    }

    var isOnACPower: Bool? {
        switch powerSupply {
        case .ac:
            true
        case .battery:
            false
        case .unknown:
            nil
        }
    }

    var isCharging: Bool? {
        switch powerSupply {
        case .ac(_, let isCharging):
            isCharging
        case .battery:
            false
        case .unknown:
            nil
        }
    }
}

enum AwayAwakeRestriction: Equatable, Sendable {
    case criticalThermalPressure
    case lowBattery
    case powerStatusUnavailable
    case awaitingSafePower
}

struct AwayPowerPolicySnapshot: Equatable, Sendable {
    let reading: AwayPowerReading
    let allowsMotion: Bool
    let allowsAwakeAssertions: Bool
    let awakeRestriction: AwayAwakeRestriction?

    var allowsDisplayAssertion: Bool {
        allowsAwakeAssertions
    }

    var macOSMaySleep: Bool {
        !allowsAwakeAssertions
    }
}

struct AwayPowerPolicyReduction: Equatable, Sendable {
    let snapshot: AwayPowerPolicySnapshot
    let hasAwakeAssertionDenial: Bool
}

enum AwayPowerPolicyReducer {
    static let releaseBatteryPercentage = 10
    static let recoveryBatteryPercentage = 15

    static func reduce(
        reading: AwayPowerReading,
        hadAwakeAssertionDenial: Bool
    ) -> AwayPowerPolicyReduction {
        let isCritical = reading.thermalPressure == .critical
        let isPowerStatusUnavailable = !reading.isPowerSourceMonitoringAvailable
        let isLowBattery: Bool
        if case .battery(let percentage) = reading.powerSupply,
           let percentage {
            isLowBattery = percentage <= releaseBatteryPercentage
        } else {
            isLowBattery = false
        }

        var hasAwakeAssertionDenial =
            hadAwakeAssertionDenial || isCritical || isLowBattery || isPowerStatusUnavailable
        let thermalAllowsRecovery = reading.thermalPressure == .nominal
            || reading.thermalPressure == .fair
        if hasAwakeAssertionDenial,
           thermalAllowsRecovery,
           !isPowerStatusUnavailable {
            switch reading.powerSupply {
            case .ac:
                hasAwakeAssertionDenial = false
            case .battery(let percentage):
                if let percentage,
                   percentage >= recoveryBatteryPercentage {
                    hasAwakeAssertionDenial = false
                }
            case .unknown:
                break
            }
        }

        let thermalPausesMotion = reading.thermalPressure == .serious || isCritical
        let allowsMotion = !reading.isLowPowerModeEnabled && !thermalPausesMotion

        let restriction: AwayAwakeRestriction?
        if isCritical {
            restriction = .criticalThermalPressure
        } else if isLowBattery {
            restriction = .lowBattery
        } else if isPowerStatusUnavailable {
            restriction = .powerStatusUnavailable
        } else if hasAwakeAssertionDenial {
            restriction = .awaitingSafePower
        } else {
            restriction = nil
        }

        return AwayPowerPolicyReduction(
            snapshot: AwayPowerPolicySnapshot(
                reading: reading,
                allowsMotion: allowsMotion,
                allowsAwakeAssertions: !hasAwakeAssertionDenial,
                awakeRestriction: restriction
            ),
            hasAwakeAssertionDenial: hasAwakeAssertionDenial
        )
    }
}

@MainActor
protocol AwayPowerReadingSource: AnyObject {
    func currentReading() -> AwayPowerReading
    func startMonitoring(_ handler: @escaping @MainActor @Sendable () -> Void)
    func stopMonitoring()
}

@MainActor
final class SystemAwayPowerReadingSource: AwayPowerReadingSource {
    typealias RunLoopSourceFactory = @MainActor (SystemAwayPowerReadingSource) -> CFRunLoopSource?

    private let processInfo: ProcessInfo
    private let notificationCenter: NotificationCenter
    private let runLoopSourceFactory: RunLoopSourceFactory

    private var notificationObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var changeHandler: (@MainActor @Sendable () -> Void)?
    private(set) var isPowerSourceMonitoringAvailable = true

    init(
        processInfo: ProcessInfo = .processInfo,
        notificationCenter: NotificationCenter = .default,
        runLoopSourceFactory: @escaping RunLoopSourceFactory = { source in
            let context = Unmanaged.passUnretained(source).toOpaque()
            return IOPSNotificationCreateRunLoopSource(
                awayPowerSourceDidChange,
                context
            )?.takeRetainedValue()
        }
    ) {
        self.processInfo = processInfo
        self.notificationCenter = notificationCenter
        self.runLoopSourceFactory = runLoopSourceFactory
    }

    func currentReading() -> AwayPowerReading {
        AwayPowerReading(
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalPressure: Self.thermalPressure(for: processInfo.thermalState),
            powerSupply: Self.powerSupply(),
            isPowerSourceMonitoringAvailable: isPowerSourceMonitoringAvailable
        )
    }

    func startMonitoring(_ handler: @escaping @MainActor @Sendable () -> Void) {
        guard changeHandler == nil else { return }
        changeHandler = handler

        _ = processInfo.thermalState
        let notificationNames: [Notification.Name] = [
            .NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ]
        for name in notificationNames {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.notifyChange()
                }
            }
            notificationObservers.append(observer)
        }

        if let source = runLoopSourceFactory(self) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = source
        } else {
            isPowerSourceMonitoringAvailable = false
            notifyChange()
        }
    }

    func stopMonitoring() {
        for observer in notificationObservers {
            notificationCenter.removeObserver(observer)
        }
        notificationObservers.removeAll()

        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
        changeHandler = nil
    }

    isolated deinit {
        stopMonitoring()
    }

    fileprivate func notifyChange() {
        changeHandler?()
    }

    private static func thermalPressure(
        for state: ProcessInfo.ThermalState
    ) -> AwayThermalPressure {
        switch state {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .critical
        }
    }

    private static func powerSupply() -> AwayPowerSupply {
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else {
            return .unknown
        }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedSources = IOPSCopyPowerSourcesList(info) else {
            return .unknown
        }
        let sources = unmanagedSources.takeRetainedValue() as [CFTypeRef]
        guard !sources.isEmpty else {
            return .ac(percentage: nil, isCharging: nil)
        }

        var fallbackSupply: AwayPowerSupply?
        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(
                info,
                source
            ) else {
                continue
            }
            let description = unmanagedDescription.takeUnretainedValue() as NSDictionary
            if let isPresent = description[kIOPSIsPresentKey] as? Bool,
               !isPresent {
                continue
            }

            let type = description[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType || type == kIOPSUPSType else {
                continue
            }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let supply: AwayPowerSupply
            if state == kIOPSACPowerValue {
                supply = .ac(
                    percentage: batteryPercentage(from: description),
                    isCharging: description[kIOPSIsChargingKey] as? Bool
                )
            } else if state == kIOPSBatteryPowerValue {
                supply = .battery(percentage: batteryPercentage(from: description))
            } else {
                supply = .unknown
            }

            if type == kIOPSInternalBatteryType {
                return supply
            }
            fallbackSupply = supply
        }

        return fallbackSupply ?? .ac(percentage: nil, isCharging: nil)
    }

    private static func batteryPercentage(from description: NSDictionary) -> Int? {
        guard let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
              let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
              maximum.doubleValue > 0 else {
            return nil
        }
        let percentage = Int(
            (current.doubleValue / maximum.doubleValue * 100).rounded(.down)
        )
        return min(100, max(0, percentage))
    }
}

private let awayPowerSourceDidChange: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let source = Unmanaged<SystemAwayPowerReadingSource>
        .fromOpaque(context)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        source.notifyChange()
    }
}

@Observable
@MainActor
final class AwayPowerPolicy {
    private(set) var snapshot: AwayPowerPolicySnapshot
    @ObservationIgnored var onChange: (@MainActor @Sendable (AwayPowerPolicySnapshot) -> Void)?

    @ObservationIgnored private let source: any AwayPowerReadingSource
    @ObservationIgnored private var hasAwakeAssertionDenial: Bool
    @ObservationIgnored private var didShutDown = false

    init(source: any AwayPowerReadingSource = SystemAwayPowerReadingSource()) {
        self.source = source
        let initial = AwayPowerPolicyReducer.reduce(
            reading: source.currentReading(),
            hadAwakeAssertionDenial: false
        )
        snapshot = initial.snapshot
        hasAwakeAssertionDenial = initial.hasAwakeAssertionDenial
        source.startMonitoring { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        guard !didShutDown else { return }
        let reduction = AwayPowerPolicyReducer.reduce(
            reading: source.currentReading(),
            hadAwakeAssertionDenial: hasAwakeAssertionDenial
        )
        hasAwakeAssertionDenial = reduction.hasAwakeAssertionDenial
        guard reduction.snapshot != snapshot else { return }
        snapshot = reduction.snapshot
        onChange?(snapshot)
    }

    func shutdown() {
        guard !didShutDown else { return }
        didShutDown = true
        source.stopMonitoring()
    }

    isolated deinit {
        if !didShutDown {
            source.stopMonitoring()
        }
    }
}
