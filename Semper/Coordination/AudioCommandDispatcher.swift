import AudioToolbox
import Foundation

enum AudioCommandSource: String, Equatable, Sendable {
    case popup
    case popupKeyboard
    case hud
    case mediaKey
    case globalShortcut
    case url
    case appIntent
    case automation
    case recovery
    case system
}

enum AudioChangeReason: String, Equatable, Sendable {
    case directUser
    case shortcut
    case safeCap
    case deviceFallback
    case deviceReconnect
    case callMode
    case bluetoothGuard
    case bypass
    case recovery
    case undo
}

enum AudioInputSelectionIntent: Equatable, Sendable {
    case userPreference
    case temporary
}

struct AudioAppCommandTarget: Hashable, Sendable {
    let identifier: String
    let processID: pid_t?

    static func active(_ app: AudioApp) -> AudioAppCommandTarget {
        AudioAppCommandTarget(identifier: app.persistenceIdentifier, processID: app.id)
    }

    static func persisted(_ identifier: String) -> AudioAppCommandTarget {
        AudioAppCommandTarget(identifier: identifier, processID: nil)
    }
}

enum AudioCommand: Equatable, Sendable {
    case setAppVolume(target: AudioAppCommandTarget, volume: Float)
    case setAppMute(target: AudioAppCommandTarget, muted: Bool)
    case setAppBoost(target: AudioAppCommandTarget, boost: BoostLevel)
    case setAppDevice(target: AudioAppCommandTarget, deviceUID: String?)
    case setAppDeviceMode(target: AudioAppCommandTarget, mode: DeviceSelectionMode)
    case setAppDevices(target: AudioAppCommandTarget, deviceUIDs: Set<String>)
    case setOutputVolume(deviceUID: String, volume: Float)
    case setOutputMasterGain(deviceUID: String, gain: Float)
    case setOutputMute(deviceUID: String, muted: Bool)
    case setOutputBalance(deviceUID: String, balance: Float)
    case setDefaultOutput(deviceUID: String)
    case setInputVolume(deviceUID: String, volume: Float)
    case setInputMute(deviceUID: String, muted: Bool)
    case setDefaultInput(deviceUID: String, intent: AudioInputSelectionIntent)
    case setAudioProcessingMode(AudioProcessingMode)

    var controlKey: AudioControlKey {
        switch self {
        case .setAppVolume(let target, _): .appVolume(target)
        case .setAppMute(let target, _): .appMute(target)
        case .setAppBoost(let target, _): .appBoost(target)
        case .setAppDevice(let target, _): .appDevice(target)
        case .setAppDeviceMode(let target, _): .appDeviceMode(target)
        case .setAppDevices(let target, _): .appDevices(target)
        case .setOutputVolume(let uid, _): .outputVolume(uid)
        case .setOutputMasterGain(let uid, _): .outputMasterGain(uid)
        case .setOutputMute(let uid, _): .outputMute(uid)
        case .setOutputBalance(let uid, _): .outputBalance(uid)
        case .setDefaultOutput: .defaultOutput
        case .setInputVolume(let uid, _): .inputVolume(uid)
        case .setInputMute(let uid, _): .inputMute(uid)
        case .setDefaultInput: .defaultInput
        case .setAudioProcessingMode: .audioProcessingMode
        }
    }

    var requestedValue: AudioControlValue {
        switch self {
        case .setAppVolume(_, let volume),
             .setOutputVolume(_, let volume),
             .setOutputMasterGain(_, let volume),
             .setOutputBalance(_, let volume),
             .setInputVolume(_, let volume):
            .scalar(volume)
        case .setAppMute(_, let muted),
             .setOutputMute(_, let muted),
             .setInputMute(_, let muted):
            .flag(muted)
        case .setAppBoost(_, let boost):
            .boost(boost)
        case .setAppDevice(_, let uid):
            .identifier(uid)
        case .setAppDeviceMode(_, let mode):
            .mode(mode.rawValue)
        case .setAppDevices(_, let uids):
            .identifiers(uids)
        case .setDefaultOutput(let uid), .setDefaultInput(let uid, _):
            .identifier(uid)
        case .setAudioProcessingMode(let mode):
            .mode(mode.rawValue)
        }
    }
}

struct AudioCommandContext: Equatable, Sendable {
    let source: AudioCommandSource
    let reason: AudioChangeReason
    let owner: AudioAutomationOwner?
    let transactionID: UUID
    let presentation: AudioActivityPresentation?

    init(
        source: AudioCommandSource,
        reason: AudioChangeReason = .directUser,
        owner: AudioAutomationOwner? = nil,
        transactionID: UUID = UUID(),
        presentation: AudioActivityPresentation? = nil
    ) {
        self.source = source
        self.reason = reason
        self.owner = owner
        self.transactionID = transactionID
        self.presentation = presentation
    }
}

enum AudioCommandRejection: Equatable, Sendable {
    case invalidValue
    case appUnavailable(String)
    case deviceUnavailable(String)
    case permissionDenied
    case unsupportedRoute(String)
    case writeFailed
}

struct AudioCommandReceipt: Equatable, Sendable {
    let command: AudioCommand
    let context: AudioCommandContext
    let previousValue: AudioControlValue?
    let observedValue: AudioControlValue?
    let recoveryToken: AudioRecoveryToken?
    let timestamp: Date
}

enum AudioCommandResult: Equatable, Sendable {
    case applied(AudioCommandReceipt)
    case accepted(AudioCommandReceipt)
    case unchanged(AudioCommandReceipt)
    case rejected(AudioCommandRejection)
}

@MainActor
protocol AudioCommandDispatching: AnyObject {
    @discardableResult
    func dispatch(_ command: AudioCommand, context: AudioCommandContext) -> AudioCommandResult
}

enum AudioBackendApplyResult: Equatable {
    case applied(AudioControlValue)
    case accepted
    case rejected(AudioCommandRejection)
}

@MainActor
protocol AudioCommandBackend: AnyObject {
    func read(_ key: AudioControlKey) -> AudioControlValue?
    func apply(_ command: AudioCommand) -> AudioBackendApplyResult
    func effectiveRequestedValue(for command: AudioCommand) -> AudioControlValue
    func recoveryAliasKeys(for command: AudioCommand) -> Set<AudioControlKey>
}

extension AudioCommandBackend {
    func effectiveRequestedValue(for command: AudioCommand) -> AudioControlValue {
        command.requestedValue
    }

    func recoveryAliasKeys(for command: AudioCommand) -> Set<AudioControlKey> {
        []
    }
}

@Observable
@MainActor
final class AudioCommandDispatcher: AudioCommandDispatching {
    let activityStore: AudioActivityStore
    let recoveryJournal: AudioAutomationRecoveryJournal

    private let backend: any AudioCommandBackend
    private struct AcceptanceClaim {
        let token: AudioRecoveryToken?
        let requested: AudioControlValue
        let relinquishOnSuccess: Bool
        let recoveryAliasKeys: Set<AudioControlKey>
    }
    private var pendingAcceptances: [AudioControlKey: [AcceptanceClaim]] = [:]

    init(
        backend: any AudioCommandBackend,
        activityStore: AudioActivityStore = AudioActivityStore(),
        recoveryJournal: AudioAutomationRecoveryJournal = AudioAutomationRecoveryJournal()
    ) {
        self.backend = backend
        self.activityStore = activityStore
        self.recoveryJournal = recoveryJournal
    }

    @discardableResult
    func dispatch(_ command: AudioCommand, context: AudioCommandContext) -> AudioCommandResult {
        guard Self.isValid(command) else { return .rejected(.invalidValue) }

        let key = command.controlKey
        let requested = backend.effectiveRequestedValue(for: command)
        let previous = backend.read(key)
        let recoveryAliasKeys = backend.recoveryAliasKeys(for: command)
        let timestamp = Date()

        if let previous, previous.matches(requested) {
            if context.owner == nil {
                discardPendingAcceptances(for: key)
                recoveryJournal.relinquish(key)
                relinquishRecoveryAliases(recoveryAliasKeys)
            }
            let receipt = AudioCommandReceipt(
                command: command,
                context: context,
                previousValue: previous,
                observedValue: previous,
                recoveryToken: nil,
                timestamp: timestamp
            )
            return .unchanged(receipt)
        }

        let suspendedAcceptances = pendingAcceptances.removeValue(forKey: key) ?? []
        let recoveryToken: AudioRecoveryToken?
        if let owner = context.owner, let previous {
            recoveryToken = recoveryJournal.begin(owner: owner, key: key, original: previous)
        } else {
            recoveryToken = nil
        }

        switch backend.apply(command) {
        case .applied(let observed):
            if let recoveryToken {
                recoveryJournal.confirm(recoveryToken, applied: observed)
            }
            if context.owner == nil {
                recoveryJournal.relinquish(key)
                relinquishRecoveryAliases(recoveryAliasKeys)
            }
            let receipt = AudioCommandReceipt(
                command: command,
                context: context,
                previousValue: previous,
                observedValue: observed,
                recoveryToken: recoveryToken,
                timestamp: timestamp
            )
            recordActivity(from: context)
            return .applied(receipt)

        case .accepted:
            pendingAcceptances[key] = suspendedAcceptances + [
                AcceptanceClaim(
                    token: recoveryToken,
                    requested: requested,
                    relinquishOnSuccess: context.owner == nil,
                    recoveryAliasKeys: recoveryAliasKeys
                )
            ]
            let receipt = AudioCommandReceipt(
                command: command,
                context: context,
                previousValue: previous,
                observedValue: nil,
                recoveryToken: recoveryToken,
                timestamp: timestamp
            )
            recordActivity(from: context)
            return .accepted(receipt)

        case .rejected(let reason):
            if let recoveryToken { recoveryJournal.cancel(recoveryToken) }
            if !suspendedAcceptances.isEmpty {
                pendingAcceptances[key] = suspendedAcceptances
            }
            return .rejected(reason)
        }
    }

    @discardableResult
    func completeAccepted(_ key: AudioControlKey, observed: AudioControlValue) -> Bool {
        guard let claims = pendingAcceptances[key],
              let current = claims.last,
              current.requested.matches(observed) else {
            return false
        }
        pendingAcceptances[key] = nil
        if let token = current.token {
            return recoveryJournal.confirm(token, applied: observed)
        }
        if current.relinquishOnSuccess {
            recoveryJournal.relinquish(key)
            relinquishRecoveryAliases(current.recoveryAliasKeys)
        }
        return true
    }

    func rejectAccepted(_ key: AudioControlKey) {
        guard let claims = pendingAcceptances.removeValue(forKey: key),
              !claims.isEmpty else {
            return
        }
        let observed = backend.read(key)
        for index in claims.indices.reversed() {
            let claim = claims[index]
            if index != claims.index(before: claims.endIndex),
               let observed,
               claim.requested.matches(observed) {
                if let token = claim.token {
                    _ = recoveryJournal.confirm(token, applied: observed)
                } else if claim.relinquishOnSuccess {
                    recoveryJournal.relinquish(key)
                    relinquishRecoveryAliases(claim.recoveryAliasKeys)
                }
                return
            }
            if let token = claim.token {
                recoveryJournal.cancel(token)
            }
        }
    }

    private func discardPendingAcceptances(for key: AudioControlKey) {
        guard let claims = pendingAcceptances.removeValue(forKey: key) else { return }
        for claim in claims.reversed() {
            if let token = claim.token {
                recoveryJournal.cancel(token)
            }
        }
    }

    private func relinquishRecoveryAliases(_ keys: Set<AudioControlKey>) {
        for key in keys {
            discardPendingAcceptances(for: key)
            recoveryJournal.relinquish(key)
        }
    }

    private func recordActivity(from context: AudioCommandContext) {
        guard let presentation = context.presentation ?? Self.defaultPresentation(for: context.reason) else {
            return
        }
        activityStore.record(
            presentation: presentation,
            source: context.source,
            reason: context.reason
        )
    }

    private static func defaultPresentation(for reason: AudioChangeReason) -> AudioActivityPresentation? {
        switch reason {
        case .directUser:
            nil
        case .shortcut:
            AudioActivityPresentation(message: "Changed by keyboard shortcut", systemImage: "keyboard")
        case .safeCap:
            AudioActivityPresentation(message: "Adjusted by the device volume limit", systemImage: "speaker.badge.exclamationmark")
        case .deviceFallback:
            AudioActivityPresentation(message: "Changed because an audio device disconnected", systemImage: "arrow.triangle.branch")
        case .deviceReconnect:
            AudioActivityPresentation(message: "Restored after the audio device reconnected", systemImage: "arrow.clockwise")
        case .callMode:
            AudioActivityPresentation(message: "Changed by Call Mode", systemImage: "phone")
        case .bluetoothGuard:
            AudioActivityPresentation(message: "Changed to protect Bluetooth audio quality", systemImage: "wave.3.right")
        case .bypass:
            AudioActivityPresentation(message: "Audio processing state changed", systemImage: "waveform")
        case .recovery:
            AudioActivityPresentation(message: "Restored after audio recovery", systemImage: "arrow.clockwise")
        case .undo:
            AudioActivityPresentation(message: "Restored by Undo", systemImage: "arrow.uturn.backward")
        }
    }

    private static func isValid(_ command: AudioCommand) -> Bool {
        switch command {
        case .setAppVolume(let target, let value):
            !target.identifier.isEmpty && value.isFinite && (0...1).contains(value)
        case .setAppMute(let target, _),
             .setAppBoost(let target, _),
             .setAppDevice(let target, _),
             .setAppDeviceMode(let target, _),
             .setAppDevices(let target, _):
            !target.identifier.isEmpty
        case .setOutputVolume(let uid, let value), .setInputVolume(let uid, let value):
            !uid.isEmpty && value.isFinite && (0...1).contains(value)
        case .setOutputMasterGain(let uid, let value):
            !uid.isEmpty && value.isFinite && (0...VolumeMapping.maximumMasterGain).contains(value)
        case .setOutputMute(let uid, _), .setInputMute(let uid, _):
            !uid.isEmpty
        case .setOutputBalance(let uid, let value):
            !uid.isEmpty && value.isFinite && (-1...1).contains(value)
        case .setDefaultOutput(let uid), .setDefaultInput(let uid, _):
            !uid.isEmpty
        case .setAudioProcessingMode:
            true
        }
    }
}

@MainActor
final class AudioEngineCommandBackend: AudioCommandBackend {
    private let engine: AudioEngine
    private let readDefaultInputDevice: () -> AudioDeviceID?

    init(
        engine: AudioEngine,
        readDefaultInputDevice: @escaping () -> AudioDeviceID? = {
            try? AudioDeviceID.readDefaultInputDevice()
        }
    ) {
        self.engine = engine
        self.readDefaultInputDevice = readDefaultInputDevice
    }

    func read(_ key: AudioControlKey) -> AudioControlValue? {
        switch key {
        case .appVolume(let target):
            guard let volume = readApp(target, active: { engine.getVolume(for: $0) }, inactive: {
                engine.getVolumeForInactive(identifier: target.identifier)
            }) else { return nil }
            return .scalar(volume)
        case .appMute(let target):
            guard let muted = readApp(target, active: { engine.getMute(for: $0) }, inactive: {
                engine.getMuteForInactive(identifier: target.identifier)
            }) else { return nil }
            return .flag(muted)
        case .appBoost(let target):
            guard let boost = readApp(target, active: { engine.getBoost(for: $0) }, inactive: {
                engine.getBoostForInactive(identifier: target.identifier)
            }) else { return nil }
            return .boost(boost)
        case .appDevice(let target):
            if let app = activeApp(target) {
                return .identifier(engine.isFollowingDefault(for: app) ? nil : engine.getDeviceUID(for: app))
            }
            guard target.processID == nil else { return nil }
            return .identifier(
                engine.isFollowingDefaultForInactive(identifier: target.identifier)
                    ? nil
                    : engine.getDeviceRoutingForInactive(identifier: target.identifier)
            )
        case .appDeviceMode(let target):
            guard let mode = readApp(target, active: engine.getDeviceSelectionMode(for:), inactive: {
                engine.getDeviceSelectionModeForInactive(identifier: target.identifier)
            }) else { return nil }
            return .mode(mode.rawValue)
        case .appDevices(let target):
            guard let uids = readApp(target, active: engine.getSelectedDeviceUIDs(for:), inactive: {
                engine.getSelectedDeviceUIDsForInactive(identifier: target.identifier)
            }) else { return nil }
            return .identifiers(uids)
        case .outputVolume(let uid):
            guard let device = engine.deviceMonitor.device(for: uid) else { return nil }
            guard let volume = engine.deviceVolumeMonitor.volumes[device.id] else { return nil }
            return .scalar(volume)
        case .outputMasterGain(let uid):
            guard let device = engine.deviceMonitor.device(for: uid) else { return nil }
            guard let volume = engine.knownMasterOutputVolume(for: device) else { return nil }
            return .scalar(volume)
        case .outputMute(let uid):
            guard let device = engine.deviceMonitor.device(for: uid) else { return nil }
            guard let muted = engine.deviceVolumeMonitor.muteStates[device.id] else { return nil }
            return .flag(muted)
        case .outputBalance(let uid):
            guard engine.deviceMonitor.device(for: uid) != nil else { return nil }
            return .scalar(engine.outputBalance(for: uid))
        case .defaultOutput:
            return .identifier(engine.deviceVolumeMonitor.defaultDeviceUID)
        case .inputVolume(let uid):
            guard let device = engine.deviceMonitor.inputDevice(for: uid) else { return nil }
            guard let volume = engine.deviceVolumeMonitor.inputVolumes[device.id] else { return nil }
            return .scalar(volume)
        case .inputMute(let uid):
            guard let device = engine.deviceMonitor.inputDevice(for: uid) else { return nil }
            guard let muted = engine.deviceVolumeMonitor.inputMuteStates[device.id] else { return nil }
            return .flag(muted)
        case .defaultInput:
            return .identifier(engine.deviceVolumeMonitor.defaultInputDeviceUID)
        case .audioProcessingMode:
            return .mode(engine.audioProcessingMode.rawValue)
        }
    }

    func recoveryAliasKeys(for command: AudioCommand) -> Set<AudioControlKey> {
        let deviceUID: String
        switch command {
        case .setOutputVolume(let uid, _),
             .setOutputMasterGain(let uid, _),
             .setOutputMute(let uid, _):
            deviceUID = uid
        default:
            return []
        }
        guard let device = engine.deviceMonitor.device(for: deviceUID),
              engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id) == .ddc else {
            return []
        }
        return Set<AudioControlKey>([
            .outputVolume(deviceUID),
            .outputMasterGain(deviceUID),
            .outputMute(deviceUID)
        ]).subtracting([command.controlKey])
    }

    func effectiveRequestedValue(for command: AudioCommand) -> AudioControlValue {
        switch command {
        case .setOutputVolume(let uid, let volume),
             .setOutputMasterGain(let uid, let volume):
            let limit = engine.settingsManager.outputVolumeLimit(for: uid) ?? volume
            return .scalar(min(volume, limit))
        case .setAudioProcessingMode(let mode)
            where mode != .bypassed && engine.permission.status != .authorized:
            return .mode(AudioProcessingMode.resumeRequested.rawValue)
        default:
            return command.requestedValue
        }
    }

    func apply(_ command: AudioCommand) -> AudioBackendApplyResult {
        switch command {
        case .setAppVolume(let target, let volume):
            if let app = activeApp(target) {
                engine.setVolume(for: app, to: volume)
            } else if target.processID == nil {
                engine.setVolumeForInactive(identifier: target.identifier, to: volume)
            } else {
                return .rejected(.appUnavailable(target.identifier))
            }
            return .applied(.scalar(volume))

        case .setAppMute(let target, let muted):
            if let app = activeApp(target) {
                engine.setMute(for: app, to: muted)
            } else if target.processID == nil {
                engine.setMuteForInactive(identifier: target.identifier, to: muted)
            } else {
                return .rejected(.appUnavailable(target.identifier))
            }
            return .applied(.flag(muted))

        case .setAppBoost(let target, let boost):
            if let app = activeApp(target) {
                engine.setBoost(for: app, to: boost)
            } else if target.processID == nil {
                engine.setBoostForInactive(identifier: target.identifier, to: boost)
            } else {
                return .rejected(.appUnavailable(target.identifier))
            }
            return .applied(.boost(boost))

        case .setAppDevice(let target, let uid):
            guard let app = activeApp(target) else {
                guard target.processID == nil else {
                    return .rejected(.appUnavailable(target.identifier))
                }
                engine.setDeviceRoutingForInactive(identifier: target.identifier, deviceUID: uid)
                return .applied(.identifier(uid))
            }
            guard engine.permission.status == .authorized else {
                return .rejected(.permissionDenied)
            }
            engine.setDevice(for: app, deviceUID: uid)
            switch engine.routeLifecycle(for: app) {
            case .preparing:
                return .accepted
            case .active:
                return .applied(.identifier(uid))
            case .failed(_, let message), .unavailable(let message):
                return .rejected(.unsupportedRoute(message))
            }

        case .setAppDeviceMode(let target, let mode):
            if let app = activeApp(target) {
                guard engine.permission.status == .authorized else {
                    return .rejected(.permissionDenied)
                }
                engine.setDeviceSelectionMode(for: app, to: mode)
                return .accepted
            }
            guard target.processID == nil else {
                return .rejected(.appUnavailable(target.identifier))
            }
            engine.setDeviceSelectionModeForInactive(identifier: target.identifier, to: mode)
            return .applied(.mode(mode.rawValue))

        case .setAppDevices(let target, let uids):
            if let app = activeApp(target) {
                guard engine.permission.status == .authorized else {
                    return .rejected(.permissionDenied)
                }
                let mode = engine.getDeviceSelectionMode(for: app)
                engine.setSelectedDeviceUIDs(for: app, to: uids)
                return mode == .multi ? .accepted : .applied(.identifiers(uids))
            }
            guard target.processID == nil else {
                return .rejected(.appUnavailable(target.identifier))
            }
            engine.setSelectedDeviceUIDsForInactive(identifier: target.identifier, to: uids)
            return .applied(.identifiers(uids))

        case .setOutputVolume(let uid, let volume):
            guard let device = engine.deviceMonitor.device(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            engine.supersedePendingMasterOutputWrite(for: uid)
            let safeVolume = min(volume, engine.settingsManager.outputVolumeLimit(for: uid) ?? volume)
            let tier = engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id)
            let expected = DeviceVolumeMonitor.storedVolume(safeVolume, tier: tier)
            engine.deviceVolumeMonitor.setVolume(for: device.id, to: safeVolume)
            guard engine.deviceVolumeMonitor.volumes[device.id] == expected else {
                return .rejected(.writeFailed)
            }
            if tier == .ddc {
                engine.beginPendingDDCOutputCommand(
                    .outputVolume(uid),
                    deviceID: device.id,
                    deviceUID: uid
                )
                return .accepted
            }
            return .applied(.scalar(expected))

        case .setOutputMasterGain(let uid, let gain):
            guard let device = engine.deviceMonitor.device(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            let safeGain = min(gain, engine.settingsManager.outputVolumeLimit(for: uid) ?? gain)
            switch engine.setMasterOutputVolume(for: device, to: safeGain) {
            case .applied(let observed):
                return .applied(.scalar(observed))
            case .accepted:
                return .accepted
            case .rejected:
                return .rejected(.writeFailed)
            }

        case .setOutputMute(let uid, let muted):
            guard let device = engine.deviceMonitor.device(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            engine.supersedePendingMasterOutputWrite(for: uid)
            let tier = engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id)
            engine.deviceVolumeMonitor.setMute(for: device.id, to: muted)
            guard engine.deviceVolumeMonitor.muteStates[device.id] == muted else {
                return .rejected(.writeFailed)
            }
            if tier == .ddc {
                engine.beginPendingDDCOutputCommand(
                    .outputMute(uid),
                    deviceID: device.id,
                    deviceUID: uid
                )
                return .accepted
            }
            return .applied(.flag(muted))

        case .setOutputBalance(let uid, let balance):
            guard let device = engine.deviceMonitor.device(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            guard engine.outputCapabilities(for: device).supportsBalance else {
                return .rejected(.unsupportedRoute("Balance is unavailable for this output"))
            }
            engine.setOutputBalance(for: uid, to: balance)
            return .applied(.scalar(engine.outputBalance(for: uid)))

        case .setDefaultOutput(let uid):
            guard let device = engine.deviceMonitor.device(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            switch engine.requestDefaultOutputDeviceSwitch(device.id) {
            case .applied:
                guard (try? AudioDeviceID.readDefaultOutputDevice()) == device.id else {
                    return .rejected(.writeFailed)
                }
                return .applied(.identifier(uid))
            case .accepted:
                return .accepted
            case .rejected:
                return .rejected(.writeFailed)
            }

        case .setInputVolume(let uid, let volume):
            guard let device = engine.deviceMonitor.inputDevice(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            engine.deviceVolumeMonitor.setInputVolume(for: device.id, to: volume)
            return engine.deviceVolumeMonitor.inputVolumes[device.id] == volume
                ? .applied(.scalar(volume))
                : .rejected(.writeFailed)

        case .setInputMute(let uid, let muted):
            guard let device = engine.deviceMonitor.inputDevice(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            engine.deviceVolumeMonitor.setInputMute(for: device.id, to: muted)
            return engine.deviceVolumeMonitor.inputMuteStates[device.id] == muted
                ? .applied(.flag(muted))
                : .rejected(.writeFailed)

        case .setDefaultInput(let uid, let intent):
            guard let device = engine.deviceMonitor.inputDevice(for: uid) else {
                return .rejected(.deviceUnavailable(uid))
            }
            switch intent {
            case .userPreference:
                let previousLockedUID = engine.settingsManager.lockedInputDeviceUID
                let previousPreferredUID = engine.settingsManager.preferredInputDeviceUID
                guard engine.setLockedInputDevice(device),
                      readDefaultInputDevice() == device.id else {
                    engine.settingsManager.setLockedInputDeviceUID(previousLockedUID)
                    engine.settingsManager.setPreferredInputDeviceUID(previousPreferredUID)
                    return .rejected(.writeFailed)
                }
            case .temporary:
                guard engine.setTemporaryInputDevice(device),
                      readDefaultInputDevice() == device.id else {
                    return .rejected(.writeFailed)
                }
            }
            return .applied(.identifier(uid))

        case .setAudioProcessingMode(let mode):
            switch engine.requestAudioProcessingMode(mode) {
            case .applied(let observed):
                return .applied(.mode(observed.rawValue))
            case .accepted:
                return .accepted
            case .rejected:
                return .rejected(.writeFailed)
            }
        }
    }

    private func activeApp(_ target: AudioAppCommandTarget) -> AudioApp? {
        if let processID = target.processID {
            return engine.apps.first {
                $0.id == processID && $0.persistenceIdentifier == target.identifier
            }
        }
        return engine.apps.first { $0.persistenceIdentifier == target.identifier }
    }

    private func readApp<Value>(
        _ target: AudioAppCommandTarget,
        active: (AudioApp) -> Value,
        inactive: () -> Value
    ) -> Value? {
        if let app = activeApp(target) {
            return active(app)
        }
        return target.processID == nil ? inactive() : nil
    }
}
