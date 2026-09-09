import AppKit
import Foundation
import IOKit.ps

struct AwakeNativeProcessSnapshot: Sendable {
    let processIdentifier: Int32
    let launchDate: Date?
    let name: String?
    let isRegular: Bool
    let isTerminated: Bool

    var identity: AwakeProcessIdentity? {
        guard processIdentifier > 0, let launchDate, !isTerminated else { return nil }
        return AwakeProcessIdentity(processIdentifier: processIdentifier, launchDate: launchDate)
    }

    init(
        processIdentifier: Int32,
        launchDate: Date?,
        name: String?,
        isRegular: Bool,
        isTerminated: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.launchDate = launchDate
        self.name = name
        self.isRegular = isRegular
        self.isTerminated = isTerminated
    }

    init(_ application: NSRunningApplication) {
        processIdentifier = application.processIdentifier
        launchDate = application.launchDate
        name = application.localizedName
        isRegular = application.activationPolicy == .regular
        isTerminated = application.isTerminated
    }
}

@MainActor
final class NativeAwakeConditionMonitor: AwakeConditionMonitoring {
    typealias PowerObservation = @MainActor (@escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)?

    private let notificationCenter: NotificationCenter
    private let ownProcessIdentifier: Int32
    private let readApplications: @MainActor () -> [AwakeNativeProcessSnapshot]
    private let readProcess: @MainActor (Int32) -> AwakeNativeProcessSnapshot?
    private let readPowerSources: @MainActor () -> [[String: Any]]?
    private let observePower: PowerObservation
    private var observers: [NSObjectProtocol] = []
    private var cancelPowerObservation: (@MainActor () -> Void)?
    private var generation: UUID?
    private var conditions: AwakeStopConditions?
    private var onChange: (@MainActor @Sendable (AwakeConditionSnapshot) -> Void)?

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        ownProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        readApplications: @escaping @MainActor () -> [AwakeNativeProcessSnapshot] = {
            NSWorkspace.shared.runningApplications.map(AwakeNativeProcessSnapshot.init)
        },
        readProcess: @escaping @MainActor (Int32) -> AwakeNativeProcessSnapshot? = { identifier in
            NSRunningApplication(processIdentifier: identifier).map(AwakeNativeProcessSnapshot.init)
        },
        readPowerSources: @escaping @MainActor () -> [[String: Any]]? = NativeAwakeConditionMonitor.powerSourceDescriptions,
        observePower: @escaping PowerObservation = NativeAwakeConditionMonitor.observePowerChanges
    ) {
        self.notificationCenter = notificationCenter
        self.ownProcessIdentifier = ownProcessIdentifier
        self.readApplications = readApplications
        self.readProcess = readProcess
        self.readPowerSources = readPowerSources
        self.observePower = observePower
    }

    isolated deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
        cancelPowerObservation?()
    }

    func availableApplications() -> [AwakeApplication] {
        readApplications().compactMap { process in
            guard process.isRegular,
                  process.processIdentifier != ownProcessIdentifier,
                  let identity = process.identity,
                  let name = process.name,
                  !name.isEmpty else { return nil }
            return AwakeApplication(id: identity, name: name)
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame
                ? $0.id.processIdentifier < $1.id.processIdentifier
                : order == .orderedAscending
        }
    }

    func snapshot(for conditions: AwakeStopConditions) -> AwakeConditionSnapshot {
        let running = conditions.application.map { application in
            readProcess(application.id.processIdentifier)?.identity == application.id
        }
        let battery = conditions.batteryThreshold == nil
            ? AwakeBatteryState.unknown
            : Self.batteryState(from: readPowerSources())
        return AwakeConditionSnapshot(selectedApplicationRunning: running, battery: battery)
    }

    func start(
        conditions: AwakeStopConditions,
        onChange: @escaping @MainActor @Sendable (AwakeConditionSnapshot) -> Void
    ) throws(AwakeConditionMonitorError) {
        stop()
        let generation = UUID()
        self.generation = generation
        self.conditions = conditions
        self.onChange = onChange
        let handler: @MainActor @Sendable () -> Void = { [weak self] in
            self?.emitSnapshot(generation: generation)
        }

        if conditions.application != nil {
            for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
                observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { handler() }
                })
            }
        }
        if conditions.batteryThreshold != nil {
            guard let cancel = observePower(handler) else {
                stop()
                throw .batteryNotificationsUnavailable
            }
            guard self.generation == generation else {
                cancel()
                return
            }
            cancelPowerObservation = cancel
        }
        emitSnapshot(generation: generation)
    }

    func stop() {
        generation = nil
        conditions = nil
        onChange = nil
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        let cancel = cancelPowerObservation
        cancelPowerObservation = nil
        cancel?()
    }

    private func emitSnapshot(generation: UUID) {
        guard self.generation == generation, let conditions, let onChange else { return }
        onChange(snapshot(for: conditions))
    }

    static func batteryState(from descriptions: [[String: Any]]?) -> AwakeBatteryState {
        guard let descriptions,
              descriptions.allSatisfy({
                  let type = $0[kIOPSTypeKey] as? String
                  return type == kIOPSInternalBatteryType || type == kIOPSUPSType
              }) else { return .unknown }
        let batteries = descriptions.filter { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard !batteries.isEmpty else { return .noBattery }
        guard batteries.count == 1, let battery = batteries.first else { return .unknown }
        guard let present = battery[kIOPSIsPresentKey] as? NSNumber,
              CFGetTypeID(present) == CFBooleanGetTypeID() else { return .unknown }
        guard present.boolValue else { return .noBattery }

        let percentage: Int?
        if let current = capacity(battery[kIOPSCurrentCapacityKey]),
           let maximum = capacity(battery[kIOPSMaxCapacityKey]),
           maximum > 0, current >= 0, current <= maximum {
            percentage = Int((current * 100 / maximum).rounded(.down))
        } else {
            percentage = nil
        }
        switch battery[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue:
            return .externalPower(percentage: percentage)
        case kIOPSBatteryPowerValue:
            return percentage.map { .battery(percentage: $0) } ?? .unknown
        default:
            return .unknown
        }
    }

    private static func capacity(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value <= Double(Int.max), value.rounded(.towardZero) == value else { return nil }
        return value
    }

    private static func powerSourceDescriptions() -> [[String: Any]]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var descriptions: [[String: Any]] = []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                return nil
            }
            descriptions.append(description)
        }
        return descriptions
    }

    private static func observePowerChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)? {
        guard let observation = AwakePowerSourceObservation(onChange: onChange) else { return nil }
        return { observation.cancel() }
    }
}

@MainActor
private final class AwakePowerSourceObservation {
    @MainActor
    private final class CallbackContext {
        var onChange: (@MainActor @Sendable () -> Void)?

        init(onChange: @escaping @MainActor @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    private let context: CallbackContext
    private var source: CFRunLoopSource?

    init?(onChange: @escaping @MainActor @Sendable () -> Void) {
        let context = CallbackContext(onChange: onChange)
        self.context = context
        let callback: IOPowerSourceCallbackType = { pointer in
            guard let pointer else { return }
            let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
            // This source is installed only on the main run loop.
            MainActor.assumeIsolated { context.onChange?() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(context).toOpaque())?.takeRetainedValue() else {
            return nil
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    isolated deinit {
        context.onChange = nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }

    func cancel() {
        context.onChange = nil
        guard let source else { return }
        // Invalidate before releasing the context that IOKit holds without retaining.
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }
}
