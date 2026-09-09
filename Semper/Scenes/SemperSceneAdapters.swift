import Foundation

nonisolated enum SceneAdapterError: LocalizedError, Equatable, Sendable {
    case unsupportedControl
    case invalidValue
    case deviceUnavailable(String)
    case readUnavailable
    case writeRejected
    case writeTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedControl:
            "The scene control is not supported by this adapter."
        case .invalidValue:
            "The scene value is invalid for this control."
        case .deviceUnavailable(let identifier):
            "Device \(identifier) is unavailable."
        case .readUnavailable:
            "The current value could not be read."
        case .writeRejected:
            "The requested value was rejected."
        case .writeTimedOut:
            "The requested value was not confirmed in time."
        }
    }
}

@MainActor
final class AudioSceneAdapter: SceneControlAdapting {
    private let engine: AudioEngine
    private let commands: any AudioCommandDispatching

    init(engine: AudioEngine, commands: any AudioCommandDispatching) {
        self.engine = engine
        self.commands = commands
    }

    func capability(for control: SceneControl) async -> SceneControlCapability {
        switch control {
        case .audioOutputDevice:
            return engine.deviceVolumeMonitor.defaultDeviceUID == nil ? .unsupported : .readWrite
        case .audioOutputVolume(let deviceID):
            guard let device = engine.deviceMonitor.device(for: deviceID),
                  engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id) != nil else {
                return .unsupported
            }
            return .readWrite
        case .audioOutputMuted(let deviceID):
            guard let device = engine.deviceMonitor.device(for: deviceID),
                  engine.deviceVolumeMonitor.muteStates[device.id] != nil,
                  engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id) != .ddc else {
                return .unsupported
            }
            return .readWrite
        default:
            return .unsupported
        }
    }

    func preflightTarget(_ value: SceneValue, for control: SceneControl) async -> SceneTargetPreflight {
        switch (control, value) {
        case (.audioOutputDevice, .text(let deviceID)):
            guard let device = engine.deviceMonitor.device(for: deviceID) else {
                return .unavailable("Audio output \(deviceID) is disconnected.")
            }
            if let limit = engine.settingsManager.outputVolumeLimit(for: deviceID) {
                guard let observed = engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id) else {
                    return .unavailable("The destination output volume cannot be read safely.")
                }
                if observed > limit + SafeOutputSwitchState.volumeTolerance,
                   engine.settingsManager.getOutputMasterGain(for: deviceID) != nil {
                    return .unavailable("Remove the destination output boost before applying this scene.")
                }
            }
            return .ready
        case (.audioOutputVolume(let deviceID), .number(let volume)):
            guard let device = engine.deviceMonitor.device(for: deviceID) else {
                return .unavailable("Audio output \(deviceID) is disconnected.")
            }
            if let limit = engine.settingsManager.outputVolumeLimit(for: deviceID),
               volume > Double(limit + SafeOutputSwitchState.volumeTolerance) {
                return .unavailable("The scene volume is above this output's limit.")
            }
            if volume < 1,
               engine.settingsManager.getOutputMasterGain(for: deviceID) != nil,
               let current = engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id),
               !AudioControlValue.scalar(current).matches(.scalar(Float(volume))) {
                return .unavailable("Remove the output boost before changing this output's volume.")
            }
            return .ready
        case (.audioOutputMuted(let deviceID), .boolean):
            return engine.deviceMonitor.device(for: deviceID) == nil
                ? .unavailable("Audio output \(deviceID) is disconnected.")
                : .ready
        default:
            return .unavailable("The value does not match the audio control.")
        }
    }

    func prerequisites(
        of value: SceneValue,
        for control: SceneControl
    ) async -> [SceneControlPrerequisite] {
        guard case .audioOutputDevice = control,
              case .text(let deviceID) = value,
              let device = engine.deviceMonitor.device(for: deviceID),
              let limit = engine.settingsManager.outputVolumeLimit(for: deviceID),
              let observed = engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id),
              observed > limit + SafeOutputSwitchState.volumeTolerance else {
            return []
        }
        return [SceneControlPrerequisite(
            control: .audioOutputVolume(deviceID: deviceID)
        )]
    }

    func restorationValue(
        for snapshot: SceneValue,
        control: SceneControl
    ) async -> SceneValue {
        guard case .audioOutputVolume(let deviceID) = control,
              case .number(let volume) = snapshot,
              let limit = engine.settingsManager.outputVolumeLimit(for: deviceID) else {
            return snapshot
        }
        return .number(min(volume, Double(limit)))
    }

    func readValue(for control: SceneControl) async throws -> SceneValue {
        switch control {
        case .audioOutputDevice:
            guard let deviceID = engine.deviceVolumeMonitor.defaultDeviceUID,
                  engine.isDefaultOutputRouteSettled(on: deviceID) else {
                throw SceneAdapterError.readUnavailable
            }
            return .text(deviceID)
        case .audioOutputVolume(let deviceID):
            guard let device = engine.deviceMonitor.device(for: deviceID) else {
                throw SceneAdapterError.deviceUnavailable(deviceID)
            }
            guard let volume = engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id) else {
                throw SceneAdapterError.readUnavailable
            }
            return .number(Double(volume))
        case .audioOutputMuted(let deviceID):
            guard let device = engine.deviceMonitor.device(for: deviceID) else {
                throw SceneAdapterError.deviceUnavailable(deviceID)
            }
            guard let muted = engine.deviceVolumeMonitor.muteStates[device.id] else {
                throw SceneAdapterError.readUnavailable
            }
            return .boolean(muted)
        default:
            throw SceneAdapterError.unsupportedControl
        }
    }

    func writeValue(_ value: SceneValue, for control: SceneControl) async throws {
        let command: AudioCommand
        switch (control, value) {
        case (.audioOutputDevice, .text(let deviceID)):
            guard let device = engine.deviceMonitor.device(for: deviceID) else {
                throw SceneAdapterError.deviceUnavailable(deviceID)
            }
            if engine.deviceVolumeMonitor.defaultDeviceUID == deviceID {
                try await waitForDefaultOutputRoute(to: deviceID)
                return
            }
            switch engine.requestPreparedDefaultOutputDeviceSwitch(device.id) {
            case .applied:
                try await waitForDefaultOutputRoute(to: deviceID)
                return
            case .accepted:
                try await waitForValue(value, control: control)
                try await waitForDefaultOutputRoute(to: deviceID)
                return
            case .rejected:
                throw SceneAdapterError.writeRejected
            }
        case (.audioOutputVolume(let deviceID), .number(let volume)):
            guard engine.deviceMonitor.device(for: deviceID) != nil,
                  volume.isFinite,
                  (0...1).contains(volume) else {
                throw SceneAdapterError.invalidValue
            }
            command = .setOutputVolume(deviceUID: deviceID, volume: Float(volume))
        case (.audioOutputMuted(let deviceID), .boolean(let muted)):
            guard engine.deviceMonitor.device(for: deviceID) != nil else {
                throw SceneAdapterError.deviceUnavailable(deviceID)
            }
            command = .setOutputMute(deviceUID: deviceID, muted: muted)
        default:
            throw SceneAdapterError.invalidValue
        }

        let result = commands.dispatch(
            command,
            context: AudioCommandContext(source: .automation, reason: .scene)
        )
        switch result {
        case .applied, .unchanged:
            return
        case .accepted:
            try await waitForValue(value, control: control)
        case .rejected:
            throw SceneAdapterError.writeRejected
        }
    }

    private func waitForValue(_ expected: SceneValue, control: SceneControl) async throws {
        for _ in 0..<40 {
            if let observed = try? await readValue(for: control),
               observed.matches(expected) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SceneAdapterError.writeTimedOut
    }

    private func waitForDefaultOutputRoute(to deviceID: String) async throws {
        for _ in 0..<40 {
            if engine.isDefaultOutputRouteSettled(on: deviceID) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SceneAdapterError.writeTimedOut
    }
}

@MainActor
final class DisplaySceneAdapter: SceneControlAdapting {
    private let displays: DisplayControlService

    init(displays: DisplayControlService) {
        self.displays = displays
    }

    func capability(for control: SceneControl) async -> SceneControlCapability {
        guard let target = Self.target(for: control) else { return .unsupported }
        return displays.isSceneEligible(target.feature, for: target.identity) ? .readWrite : .unsupported
    }

    func preflightTarget(_ value: SceneValue, for control: SceneControl) async -> SceneTargetPreflight {
        guard Self.target(for: control) != nil, case .number(let normalized) = value,
              normalized.isFinite, (0...1).contains(normalized) else {
            return .unavailable("The display target is invalid.")
        }
        return .ready
    }

    func readValue(for control: SceneControl) async throws -> SceneValue {
        guard let target = Self.target(for: control) else {
            throw SceneAdapterError.unsupportedControl
        }
        guard let reading = await displays.read(target.feature, for: target.identity) else {
            throw SceneAdapterError.readUnavailable
        }
        return .number(reading.normalized)
    }

    func writeValue(_ value: SceneValue, for control: SceneControl) async throws {
        guard let target = Self.target(for: control),
              case .number(let normalized) = value else {
            throw SceneAdapterError.invalidValue
        }
        switch try await displays.set(normalized, feature: target.feature, for: target.identity) {
        case .applied:
            return
        case .unavailable:
            throw SceneAdapterError.deviceUnavailable(target.identity.rawValue)
        case .invalidTarget:
            throw SceneAdapterError.invalidValue
        case .failed:
            throw SceneAdapterError.writeRejected
        }
    }

    private static func target(
        for control: SceneControl
    ) -> (identity: DisplayIdentity, feature: DisplayFeature)? {
        let rawIdentity: String
        let feature: DisplayFeature
        switch control {
        case .displayBrightness(let displayID):
            rawIdentity = displayID
            feature = .brightness
        case .displayContrast(let displayID):
            rawIdentity = displayID
            feature = .contrast
        default:
            return nil
        }
        guard let identity = DisplayIdentity(rawValue: rawIdentity) else { return nil }
        return (identity, feature)
    }
}

@MainActor
final class PowerSceneAdapter: SceneControlAdapting {
    private let awake: AwakeService
    private var sceneLease: AwakeLeaseToken?
    private var readFailed = false

    init(awake: AwakeService) {
        self.awake = awake
    }

    func capability(for control: SceneControl) async -> SceneControlCapability {
        control == .awakeMode ? .readWrite : .unsupported
    }

    func preflightTarget(_ value: SceneValue, for control: SceneControl) async -> SceneTargetPreflight {
        guard control == .awakeMode, case .awake = value else {
            return .unavailable("The Awake target is invalid.")
        }
        return .ready
    }

    func readValue(for control: SceneControl) async throws -> SceneValue {
        guard control == .awakeMode else { throw SceneAdapterError.unsupportedControl }
        guard !readFailed else { throw SceneAdapterError.readUnavailable }
        guard let lease = awake.leaseState(for: .scene) else {
            return .awake(.off)
        }
        return .awake(lease.keepsDisplayAwake ? .displayAndSystem : .system)
    }

    func writeValue(_ value: SceneValue, for control: SceneControl) async throws {
        guard control == .awakeMode, case .awake(let state) = value else {
            throw SceneAdapterError.invalidValue
        }
        guard !readFailed else { throw SceneAdapterError.writeRejected }

        switch state {
        case .off:
            guard let sceneLease else { return }
            self.sceneLease = nil
            guard awake.releaseLease(sceneLease) else {
                readFailed = true
                throw SceneAdapterError.writeRejected
            }
        case .system:
            try setLease(keepsDisplayAwake: false)
        case .displayAndSystem:
            try setLease(keepsDisplayAwake: true)
        }
    }

    private func setLease(keepsDisplayAwake: Bool) throws {
        do {
            if let sceneLease {
                try awake.updateLease(sceneLease, keepsDisplayAwake: keepsDisplayAwake)
            } else {
                sceneLease = try awake.acquireLease(
                    owner: .scene,
                    keepsDisplayAwake: keepsDisplayAwake
                )
            }
        } catch let error {
            if awake.leaseState(for: .scene) == nil {
                sceneLease = nil
            }
            if awake.failure == .couldNotRelease {
                readFailed = true
            }
            throw map(error)
        }
    }

    private func map(_ error: AwakeLeaseError) -> SceneAdapterError {
        switch error {
        case .serviceUnavailable, .invalidToken, .couldNotAcquire, .couldNotReplace:
            .writeRejected
        }
    }
}
