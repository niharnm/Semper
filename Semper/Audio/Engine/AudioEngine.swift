// Semper/Audio/Engine/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

enum MasterOutputVolumeWriteResult: Equatable {
    case applied(Float)
    case accepted
    case rejected
}

enum DefaultOutputSwitchResult: Equatable {
    case applied
    case accepted
    case rejected
}

enum AudioProcessingModeRequestResult: Equatable {
    case applied(AudioProcessingMode)
    case accepted
    case rejected
}

@Observable
@MainActor
final class AudioEngine {
    let processMonitor: any AudioProcessMonitoring
    let deviceMonitor: any AudioDeviceProviding
    let bluetoothDeviceMonitor: BluetoothDeviceMonitor
    let deviceVolumeMonitor: any DeviceVolumeProviding
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    let autoEQProfileManager: AutoEQProfileManager
    let permission: AudioRecordingPermission
    let appListCoordinator: AppListCoordinator
    let modeOverlayStore: AudioModeOverlayStore
    var onCommandValueObserved: ((AudioControlKey, AudioControlValue) -> Void)?
    var onCommandWriteRejected: ((AudioControlKey) -> Void)?
    private(set) var audioProcessingState: AudioProcessingState = .active
    private(set) var audioRecoveryDiagnostics = AudioRecoveryDiagnostics()

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    private var taps: [pid_t: any ProcessTapControlling] = [:]
    private var outputMasterGains: [String: Float] = [:]
    private struct PendingMasterOutputWrite {
        let previousGain: Float?
        var requestedGain: Float
    }
    private struct PendingOutputVolumeLimitChange {
        let previousLimit: Float?
    }
    private struct PendingDDCOutputCommand {
        let deviceUID: String
        let key: AudioControlKey
    }
    private var pendingMasterOutputWrites: [String: PendingMasterOutputWrite] = [:]
    private var pendingOutputVolumeLimitChanges: [String: PendingOutputVolumeLimitChange] = [:]
    private var pendingDDCOutputCommands: [AudioDeviceID: PendingDDCOutputCommand] = [:]
    private var outputBalances: [String: Float] = [:]
    private var appRouteLifecycles: [pid_t: AppRouteLifecycle] = [:]
    private struct PendingAppRouteOperation {
        let generation: UInt64
        let key: AudioControlKey
        let task: Task<Void, Never>
    }
    private var nextAppRouteOperationGeneration: UInt64 = 0
    private var appRouteOperationGenerations: [pid_t: UInt64] = [:]
    private var pendingAppRouteOperations: [pid_t: PendingAppRouteOperation] = [:]
    private struct PendingSafeOutputSwitch {
        let generation: UInt64
        let deviceID: AudioDeviceID
        let reportsCommandResult: Bool
        let requiresDDCConfirmation: Bool
        let ownsOutputVolumeLimitChange: Bool
        var state: SafeOutputSwitchState
    }
    private var nextSafeOutputSwitchGeneration: UInt64 = 0
    private var pendingSafeOutputSwitch: PendingSafeOutputSwitch?
    private var safeOutputSwitchTimeoutTask: Task<Void, Never>?
    private struct PendingDefaultOutputConfirmation {
        let generation: UInt64
        let deviceID: AudioDeviceID
        let deviceUID: String
        let echoToken: Int
        let reportsCommandResult: Bool
    }
    private var nextDefaultOutputConfirmationGeneration: UInt64 = 0
    private var pendingDefaultOutputConfirmation: PendingDefaultOutputConfirmation?
    private var defaultOutputConfirmationTimeoutTask: Task<Void, Never>?

    /// Factory for creating tap controllers. Overridable for testing.
    private let tapFactory: @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

    /// Closure to check if a device is alive. Overridable for testing.
    private let isAliveCheck: (AudioDeviceID) -> Bool

    /// One-shot HAL listeners for devices that were present but not alive during priority resolution.
    /// Keyed by AudioDeviceID. Each entry holds the device UID, listener block, and a timeout task.
    private var aliveWatchers: [AudioDeviceID: (uid: String, block: AudioObjectPropertyListenerBlock, timeout: Task<Void, Never>)] = [:]

    /// Number of pending alive watchers (exposed for testing).
    var pendingAliveWatcherCount: Int { aliveWatchers.count }

    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
    /// The last output default confirmed by Semper (user change or programmatic switch).
    /// Used to restore after macOS auto-switches to a lower-priority device.
    private var lastConfirmedDefaultUID: String?
    /// Timestamp of the last auto-switch override. Used to distinguish rapid BT auto-switches
    /// (< 1s apart) from deliberate user changes (> 1s after last override).
    private var lastAutoSwitchOverrideTime: Date?
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var tapMembershipRefreshTasks: [pid_t: Task<Void, Never>] = [:]
    private var tapMaintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private var staleCleanupTask: Task<Void, Never>?  // Debounced cleanup scheduling
    private var healthMonitorTask: Task<Void, Never>?  // Periodic tap health monitor
    private var tapRecoveryCooldownUntil: [pid_t: Date] = [:]  // Prevents tap recreation thrashing
    private var audioProcessingTransitionTask: Task<Void, Never>?
    private var audioProcessingTransitionGeneration: UInt64 = 0
    private var permissionPersistenceFailurePending = false
    private var isEngineStopped = false
    private let orphanedTapCleanup: @MainActor () -> OrphanedTapCleanupResult
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Semper", category: "AudioEngine")

    // MARK: - Priority State Machine

    /// Tracks whether we're waiting for macOS to potentially auto-switch after a device connect.
    private enum PriorityState {
        case stable
        case pendingAutoSwitch(connectedDeviceUID: String, timeoutTask: Task<Void, Never>)
    }

    private var outputPriorityState: PriorityState = .stable
    private var inputPriorityState: PriorityState = .stable

    /// Grace period for auto-switch detection (wired devices)
    private let autoSwitchGracePeriod: TimeInterval = 2.0

    /// Extended grace period for Bluetooth devices (firmware handshake takes longer)
    private let btAutoSwitchGracePeriod: TimeInterval = 5.0

    // MARK: - Echo Suppression

    private let outputEchoTracker = EchoTracker(label: "Output")
    private let inputEchoTracker = EchoTracker(label: "Input")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        deviceVolumeMonitor.outputVolumeBackend(for: deviceID)
    }

    func outputCapabilities(for device: AudioDevice) -> OutputDeviceCapabilities {
        guard permission.status == .authorized else {
            return .unavailable(
                channelCount: device.outputTopology.channelCount,
                reason: "Allow System Audio Recording to enable boost"
            )
        }
        guard device.outputTopology.supportsProcessedAudio else {
            return .unavailable(
                channelCount: device.outputTopology.channelCount,
                reason: "This output has no usable audio channels"
            )
        }

        let isVerified = taps.values.contains { $0.currentDeviceUIDs == [device.uid] }
        guard isVerified else {
            return .unavailable(
                channelCount: device.outputTopology.channelCount,
                reason: "Route an app here to verify boost"
            )
        }

        return OutputDeviceCapabilities(
            maximumGain: VolumeMapping.maximumMasterGain,
            supportsBalance: device.outputTopology.supportsIndependentBalance,
            channelCount: device.outputTopology.channelCount,
            isRouteVerified: true,
            unavailableReason: nil
        )
    }

    func routeLifecycle(for app: AudioApp) -> AppRouteLifecycle {
        if let lifecycle = appRouteLifecycles[app.id] {
            switch lifecycle {
            case .preparing, .failed, .unavailable:
                return lifecycle
            case .active:
                break
            }
        }
        if let tap = taps[app.id] {
            return .active(deviceUIDs: tap.currentDeviceUIDs)
        }
        return .unavailable(message: "Routing is not active for this audio")
    }

    private func beginAppRouteOperation(
        for app: AudioApp,
        key: AudioControlKey
    ) -> (generation: UInt64, predecessor: Task<Void, Never>?) {
        let predecessor = pendingAppRouteOperations.removeValue(forKey: app.id)
        if let pending = predecessor {
            pending.task.cancel()
            onCommandWriteRejected?(pending.key)
        }
        nextAppRouteOperationGeneration &+= 1
        appRouteOperationGenerations[app.id] = nextAppRouteOperationGeneration
        return (nextAppRouteOperationGeneration, predecessor?.task)
    }

    private func isCurrentAppRouteOperation(for appID: pid_t, generation: UInt64) -> Bool {
        appRouteOperationGenerations[appID] == generation
    }

    private func finishAppRouteOperation(for appID: pid_t, generation: UInt64) {
        guard pendingAppRouteOperations[appID]?.generation == generation else { return }
        pendingAppRouteOperations.removeValue(forKey: appID)
    }

    func masterOutputVolume(for device: AudioDevice) -> Float {
        knownMasterOutputVolume(for: device) ?? 1
    }

    func knownMasterOutputVolume(for device: AudioDevice) -> Float? {
        let maximumGain = outputCapabilities(for: device).maximumGain
        if let boostedGain = outputMasterGains[device.uid]
            ?? settingsManager.getOutputMasterGain(for: device.uid) {
            return min(maximumGain, boostedGain)
        }
        guard let deviceVolume = deviceVolumeMonitor.volumes[device.id] else { return nil }
        return min(maximumGain, deviceVolume)
    }

    func beginOutputVolumeLimitChange(for deviceUID: String, to limit: Float) {
        rollbackPendingOutputVolumeLimitChange(for: deviceUID)
        pendingOutputVolumeLimitChanges[deviceUID] = PendingOutputVolumeLimitChange(
            previousLimit: settingsManager.outputVolumeLimit(for: deviceUID)
        )
        settingsManager.setOutputVolumeLimit(for: deviceUID, to: limit)
    }

    func hasPendingOutputVolumeLimitChange(for deviceUID: String) -> Bool {
        pendingOutputVolumeLimitChanges[deviceUID] != nil
    }

    func commitOutputVolumeLimitChange(for deviceUID: String, to limit: Float?) {
        pendingOutputVolumeLimitChanges.removeValue(forKey: deviceUID)
        settingsManager.setOutputVolumeLimit(for: deviceUID, to: limit)
    }

    func resolveOutputVolumeLimitChange(
        for deviceUID: String,
        commandResult: AudioCommandResult
    ) {
        switch commandResult {
        case .applied:
            pendingOutputVolumeLimitChanges.removeValue(forKey: deviceUID)
        case .unchanged:
            if pendingMasterOutputWrites[deviceUID] == nil {
                pendingOutputVolumeLimitChanges.removeValue(forKey: deviceUID)
            }
        case .accepted:
            break
        case .rejected:
            rollbackPendingOutputVolumeLimitChange(for: deviceUID)
        }
    }

    private func rollbackPendingOutputVolumeLimitChange(for deviceUID: String) {
        guard let pending = pendingOutputVolumeLimitChanges.removeValue(forKey: deviceUID) else {
            return
        }
        settingsManager.setOutputVolumeLimit(for: deviceUID, to: pending.previousLimit)
        refreshTapOutputStates(forDeviceUID: deviceUID)
    }

    @discardableResult
    func setMasterOutputVolume(
        for device: AudioDevice,
        to gain: Float
    ) -> MasterOutputVolumeWriteResult {
        let maximumGain = min(
            outputCapabilities(for: device).maximumGain,
            settingsManager.outputVolumeLimit(for: device.uid) ?? .greatestFiniteMagnitude
        )
        let clampedGain = max(0, min(maximumGain, gain))
        let previousGain = outputMasterGains[device.uid]
            ?? settingsManager.getOutputMasterGain(for: device.uid)
        let physicalTarget = min(1, clampedGain)
        let tier = deviceVolumeMonitor.outputVolumeBackend(for: device.id)

        setStoredMasterOutputGain(clampedGain > 1 ? clampedGain : nil, deviceUID: device.uid)
        refreshTapOutputStates(forDeviceUID: device.uid)

        if tier == .ddc, var pending = pendingMasterOutputWrites[device.uid] {
            pending.requestedGain = clampedGain
            pendingMasterOutputWrites[device.uid] = pending
        }

        if let currentVolume = deviceVolumeMonitor.volumes[device.id],
           AudioControlValue.scalar(currentVolume).matches(.scalar(physicalTarget)) {
            if tier == .ddc, pendingMasterOutputWrites[device.uid] != nil {
                beginPendingDDCOutputCommand(
                    .outputMasterGain(device.uid),
                    deviceID: device.id,
                    deviceUID: device.uid
                )
                return .accepted
            }
            return .applied(clampedGain)
        }

        if tier == .ddc, pendingMasterOutputWrites[device.uid] == nil {
            pendingMasterOutputWrites[device.uid] = PendingMasterOutputWrite(
                previousGain: previousGain,
                requestedGain: clampedGain
            )
        }
        deviceVolumeMonitor.setVolume(for: device.id, to: physicalTarget)
        guard let observedVolume = deviceVolumeMonitor.volumes[device.id],
              AudioControlValue.scalar(physicalTarget).matches(.scalar(observedVolume)) else {
            pendingMasterOutputWrites.removeValue(forKey: device.uid)
            setStoredMasterOutputGain(previousGain, deviceUID: device.uid)
            refreshTapOutputStates(forDeviceUID: device.uid)
            return .rejected
        }

        if tier == .ddc {
            beginPendingDDCOutputCommand(
                .outputMasterGain(device.uid),
                deviceID: device.id,
                deviceUID: device.uid
            )
            return .accepted
        }

        return .applied(clampedGain)
    }

    private func setStoredMasterOutputGain(_ gain: Float?, deviceUID: String) {
        if let gain {
            outputMasterGains[deviceUID] = gain
            settingsManager.setOutputMasterGain(for: deviceUID, to: gain)
        } else {
            outputMasterGains.removeValue(forKey: deviceUID)
            settingsManager.setOutputMasterGain(for: deviceUID, to: nil)
        }
    }

    func supersedePendingMasterOutputWrite(
        for deviceUID: String,
        preservingVolumeLimitChange: Bool = false
    ) {
        guard let pending = pendingMasterOutputWrites.removeValue(forKey: deviceUID) else {
            return
        }
        pendingDDCOutputCommands = pendingDDCOutputCommands.filter { _, command in
            command.key != .outputMasterGain(deviceUID)
        }
        if !preservingVolumeLimitChange {
            rollbackPendingOutputVolumeLimitChange(for: deviceUID)
        }
        setStoredMasterOutputGain(pending.previousGain, deviceUID: deviceUID)
        refreshTapOutputStates(forDeviceUID: deviceUID)
        onCommandWriteRejected?(.outputMasterGain(deviceUID))
    }

    func beginPendingDDCOutputCommand(
        _ key: AudioControlKey,
        deviceID: AudioDeviceID,
        deviceUID: String
    ) {
        if let previous = pendingDDCOutputCommands[deviceID], previous.key != key {
            onCommandWriteRejected?(previous.key)
        }
        pendingDDCOutputCommands[deviceID] = PendingDDCOutputCommand(
            deviceUID: deviceUID,
            key: key
        )
    }

    func outputBalance(for deviceUID: String) -> Float {
        outputBalances[deviceUID]
            ?? settingsManager.getOutputBalance(for: deviceUID)
            ?? 0
    }

    func setOutputBalance(for deviceUID: String, to balance: Float) {
        guard let device = deviceMonitor.device(for: deviceUID),
              outputCapabilities(for: device).supportsBalance else {
            return
        }
        let clampedBalance = max(-1, min(1, balance))
        if abs(clampedBalance) < 0.0001 {
            outputBalances.removeValue(forKey: deviceUID)
            settingsManager.setOutputBalance(for: deviceUID, to: nil)
        } else {
            outputBalances[deviceUID] = clampedBalance
            settingsManager.setOutputBalance(for: deviceUID, to: clampedBalance)
        }
        refreshTapOutputStates(forDeviceUID: deviceUID)
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    /// Output devices sorted by user-defined priority order.
    /// Devices in the priority list appear in that order; new/unknown devices are appended alphabetically.
    var prioritySortedOutputDevices: [AudioDevice] {
        let devices = outputDevices
        let priorityOrder = settingsManager.devicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Collect devices in priority order (skip stale UIDs)
        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        // Append new devices alphabetically
        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Input devices sorted by user-defined priority order.
    var prioritySortedInputDevices: [AudioDevice] {
        let devices = inputDevices
        let priorityOrder = settingsManager.inputDevicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Registers any output devices not yet in the priority list.
    /// Call this when devices change (not from computed properties).
    func registerNewDevicesInPriority() {
        for device in outputDevices {
            settingsManager.ensureDeviceInPriority(device.uid)
        }
        for device in inputDevices {
            settingsManager.ensureInputDeviceInPriority(device.uid)
        }
    }

    /// Returns the highest-priority device that is both connected and alive.
    /// `isDeviceAlive()` is checked internally — callers never need to check separately.
    static func resolveHighestPriority(
        priorityOrder: [String],
        connectedDevices: [AudioDevice],
        excluding: String? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil
    ) -> AudioDevice? {
        let aliveCheck = isAlive ?? { $0.isDeviceAlive() }
        let connected = Dictionary(
            connectedDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for uid in priorityOrder {
            guard uid != excluding,
                  let device = connected[uid],
                  aliveCheck(device.id) else { continue }
            return device
        }
        // Fallback: any alive connected device not excluded
        return connectedDevices.first {
            $0.uid != excluding && aliveCheck($0.id)
        }
    }

    enum ConnectedOutputDefaultAction: Equatable {
        case ensureHighestPriorityDefault
        case restorePrevious
        case none
    }

    static func connectedOutputDefaultAction(
        connectedDeviceUID: String,
        highestPriorityConnectedUID: String?,
        currentDefaultUID: String?
    ) -> ConnectedOutputDefaultAction {
        if connectedDeviceUID == highestPriorityConnectedUID {
            return .ensureHighestPriorityDefault
        }
        if connectedDeviceUID == currentDefaultUID {
            return .restorePrevious
        }
        return .none
    }


    init(
        permission: AudioRecordingPermission,
        settingsManager: SettingsManager,
        autoEQProfileManager: AutoEQProfileManager,
        deviceProvider: (any AudioDeviceProviding)? = nil,
        processMonitor: (any AudioProcessMonitoring)? = nil,
        deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
        modeOverlayStore: AudioModeOverlayStore? = nil,
        tapFactory: (@MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        initialCleanupResult: OrphanedTapCleanupResult = .empty,
        orphanedTapCleanup: @escaping @MainActor () -> OrphanedTapCleanupResult = {
            OrphanedTapCleanup.destroyOrphanedDevices()
        },
        startMonitorsAutomatically: Bool = true
    ) {
        self.permission = permission
        let manager = settingsManager
        self.settingsManager = manager
        self.appListCoordinator = AppListCoordinator(settingsManager: manager)
        self.autoEQProfileManager = autoEQProfileManager
        self.volumeState = VolumeState(settingsManager: manager)
        self.modeOverlayStore = modeOverlayStore ?? AudioModeOverlayStore()
        self.isAliveCheck = isAlive ?? { $0.isDeviceAlive() }
        self.orphanedTapCleanup = orphanedTapCleanup
        self.audioRecoveryDiagnostics = AudioRecoveryDiagnostics(
            startupCleanup: initialCleanupResult
        )
        self.audioProcessingState = Self.initialAudioProcessingState(
            mode: manager.audioProcessingMode,
            permission: permission.status,
            startupCleanupFailed: initialCleanupResult.failedCount > 0
        )

        // If a custom deviceProvider is given, use it directly.
        // Otherwise create a real AudioDeviceMonitor (needed by DeviceVolumeMonitor and default tap factory).
        let realDeviceMonitor: AudioDeviceMonitor?
        if let provider = deviceProvider {
            realDeviceMonitor = provider as? AudioDeviceMonitor
            self.deviceMonitor = provider
        } else {
            let monitor = AudioDeviceMonitor()
            realDeviceMonitor = monitor
            self.deviceMonitor = monitor
        }
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.bluetoothDeviceMonitor = BluetoothDeviceMonitor()

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager, ddcController: ddc)
        }
        #else
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager)
        }
        #endif

        // Tap factory: use provided factory or default to ProcessTapController
        if let factory = tapFactory {
            self.tapFactory = factory
        } else {
            self.tapFactory = { app, deviceUIDs, preferredSource in
                if deviceUIDs.count == 1 {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUID: deviceUIDs[0],
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                } else {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUIDs: deviceUIDs,
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                }
            }
        }

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.restoreConfirmedDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.restoreLockedInputDevice()
        }

        // Wire callbacks — needed for both test and production mode
        wireCallbacks()
        self.modeOverlayStore.onChange = { [weak self] identifiers in
            self?.refreshTapOutputStates(forAppIdentifiers: identifiers)
        }

        if startMonitorsAutomatically {
            Task { @MainActor [self] in
                if self.permission.status == .authorized,
                   manager.audioProcessingMode == .active,
                   self.audioProcessingState == .active {
                    self.processMonitor.start()
                }
                self.deviceMonitor.start()
                self.bluetoothDeviceMonitor.start()

                #if !APP_STORE
                ddc.onProbeCompleted = { [weak self] in
                    self?.deviceVolumeMonitor.refreshAfterDDCProbe()
                    self?.refreshAllTapOutputStates()
                }
                ddc.start()
                #endif

                // Start device volume monitor AFTER deviceMonitor.start() populates devices
                self.deviceVolumeMonitor.start()

                if manager.audioProcessingMode == .active,
                   self.audioProcessingState == .active {
                    self.applyPersistedSettings()
                    self.startHealthMonitor()
                } else if manager.audioProcessingMode == .resumeRequested {
                    self.startAudioProcessingTransitionIfNeeded()
                }
                self.registerNewDevicesInPriority()
                // Seed the confirmed default from whatever macOS has at startup
                self.lastConfirmedDefaultUID = self.deviceVolumeMonitor.defaultDeviceUID
                if manager.appSettings.lockInputDevice {
                    self.restoreLockedInputDevice()
                }
            }
        }

        if startMonitorsAutomatically {
            observePermissionChanges()
        }
    }

    private func observePermissionChanges() {
        withObservationTracking {
            _ = self.permission.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAudioPermissionChange()
                self.observePermissionChanges()
            }
        }
    }

    func handleAudioPermissionChange() {
        if permission.status == .authorized {
            if settingsManager.audioProcessingMode == .resumeRequested {
                startAudioProcessingTransitionIfNeeded()
            } else if settingsManager.audioProcessingMode == .active,
                      audioProcessingState != .active {
                startAudioProcessingTransitionIfNeeded()
            }
            return
        }

        if settingsManager.audioProcessingMode == .active {
            if !persistAudioProcessingMode(.resumeRequested) {
                permissionPersistenceFailurePending = true
                startAudioProcessingTransitionIfNeeded()
                return
            }
        }
        if settingsManager.audioProcessingMode == .resumeRequested {
            startAudioProcessingTransitionIfNeeded()
        }
    }

    /// Wire all event callbacks from monitors to AudioEngine handlers.
    private func wireCallbacks() {
        // Sync device volume changes to taps for VU meter accuracy
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            let tier = self.deviceVolumeMonitor.outputVolumeBackend(for: deviceID)
            if tier != .ddc {
                self.onCommandValueObserved?(.outputVolume(deviceUID), .scalar(newVolume))
                let masterGain = self.deviceMonitor.device(for: deviceUID)
                    .flatMap { self.knownMasterOutputVolume(for: $0) }
                    ?? newVolume
                self.onCommandValueObserved?(.outputMasterGain(deviceUID), .scalar(masterGain))
            }
            if newVolume < 1, self.pendingMasterOutputWrites[deviceUID] == nil {
                self.outputMasterGains.removeValue(forKey: deviceUID)
                self.settingsManager.setOutputMasterGain(for: deviceUID, to: nil)
            }
            let loudnessEnabled = self.settingsManager.appSettings.loudnessCompensationEnabled
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                    tap.updateLoudnessCompensation(
                        volume: self.effectiveLoudnessVolume(for: tap),
                        enabled: loudnessEnabled
                    )
                }
            }
        }

        deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            if self.deviceVolumeMonitor.outputVolumeBackend(for: deviceID) != .ddc {
                self.onCommandValueObserved?(.outputMute(deviceUID), .flag(isMuted))
            }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.isDeviceMuted = isMuted
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                }
            }
        }

        deviceVolumeMonitor.onOutputWriteCompleted = { [weak self] deviceID, succeeded in
            guard let self else { return }
            self.handleSafeOutputPreflightWriteCompleted(
                deviceID: deviceID,
                succeeded: succeeded
            )
            let pendingCommand = self.pendingDDCOutputCommands.removeValue(forKey: deviceID)
            let deviceUID = pendingCommand?.deviceUID
                ?? self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid
            guard let deviceUID else { return }
            let pendingMasterWrite = self.pendingMasterOutputWrites.removeValue(forKey: deviceUID)
            if !succeeded {
                if pendingCommand?.key == .outputMasterGain(deviceUID) {
                    self.rollbackPendingOutputVolumeLimitChange(for: deviceUID)
                }
                if let pendingMasterWrite {
                    self.setStoredMasterOutputGain(
                        pendingMasterWrite.previousGain,
                        deviceUID: deviceUID
                    )
                    self.refreshTapOutputStates(forDeviceUID: deviceUID)
                }
                if let key = pendingCommand?.key {
                    self.onCommandWriteRejected?(key)
                }
                return
            }

            if pendingCommand?.key == .outputMasterGain(deviceUID) {
                self.pendingOutputVolumeLimitChanges.removeValue(forKey: deviceUID)
            }

            guard let key = pendingCommand?.key else { return }
            switch key {
            case .outputVolume:
                if let volume = self.deviceVolumeMonitor.volumes[deviceID] {
                    self.onCommandValueObserved?(key, .scalar(volume))
                }
            case .outputMasterGain:
                if let masterGain = pendingMasterWrite?.requestedGain {
                    self.onCommandValueObserved?(key, .scalar(masterGain))
                }
            case .outputMute:
                if let muted = self.deviceVolumeMonitor.muteStates[deviceID] {
                    self.onCommandValueObserved?(key, .flag(muted))
                }
            default:
                break
            }
        }

        deviceVolumeMonitor.onInputVolumeChanged = { [weak self] deviceID, volume in
            guard let self,
                  let uid = self.deviceMonitor.inputDevices.first(where: { $0.id == deviceID })?.uid else {
                return
            }
            self.onCommandValueObserved?(.inputVolume(uid), .scalar(volume))
        }

        deviceVolumeMonitor.onInputMuteChanged = { [weak self] deviceID, muted in
            guard let self,
                  let uid = self.deviceMonitor.inputDevices.first(where: { $0.id == deviceID })?.uid else {
                return
            }
            self.onCommandValueObserved?(.inputMute(uid), .flag(muted))
        }

        processMonitor.onAppsChanged = { [weak self] apps in
            self?.handleAppsChanged(apps)
        }

        // Priority order closures — only for concrete AudioDeviceMonitor
        if let realMonitor = deviceMonitor as? AudioDeviceMonitor {
            realMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            realMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
            }
            realMonitor.onBTDeviceSampleRateChanged = { [weak self] uid, newRate in
                Task { @MainActor [weak self] in
                    await self?.handleBTDeviceSampleRateChanged(uid: uid, newRate: newRate)
                }
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.refresh()
        }

        deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceConnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.notifyDeviceAppearedInCoreAudio()
        }

        deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
            self?.handleInputDeviceDisconnected(deviceUID)
        }

        deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
            self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
            self?.handleInputDeviceConnected(deviceUID, name: deviceName)
        }

        deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
            self?.handleDefaultOutputConfirmation(newDefaultUID)
            self?.onCommandValueObserved?(.defaultOutput, .identifier(newDefaultUID))
            self?.handleDefaultDeviceChanged(newDefaultUID)
        }

        deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
            Task { @MainActor [weak self] in
                self?.onCommandValueObserved?(.defaultInput, .identifier(newDefaultInputUID))
                self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
            }
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    private func handleAppsChanged(_ updatedApps: [AudioApp]) {
        guard canCreateProcessTaps else { return }
        applyPersistedSettings()
        scheduleStaleCleanup()

        for app in updatedApps {
            guard let tap = taps[app.id],
                  Self.shouldRefreshTapMembership(
                    currentObjectIDs: tap.app.processObjectIDs,
                    latestObjectIDs: app.processObjectIDs
                  ) else {
                continue
            }
            tapMembershipRefreshTasks[app.id]?.cancel()
            tapMembershipRefreshTasks[app.id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                guard let self else { return }
                defer {
                    self.tapMembershipRefreshTasks.removeValue(forKey: app.id)
                }
                guard !Task.isCancelled,
                      let latestApp = self.apps.first(where: { $0.id == app.id }),
                      let currentTap = self.taps[app.id],
                      Self.shouldRefreshTapMembership(
                        currentObjectIDs: currentTap.app.processObjectIDs,
                        latestObjectIDs: latestApp.processObjectIDs
                      ) else {
                    return
                }
                let currentIDs = Set(currentTap.app.processObjectIDs)
                let latestIDs = Set(latestApp.processObjectIDs)
                if !currentIDs.isDisjoint(with: latestIDs),
                   currentTap.hasRecentAudioCallback(within: 1.0) {
                    return
                }
                self.logger.info("Refreshing process membership for \(latestApp.name)")
                await self.recreateTap(for: latestApp.id)
            }
        }
    }

    static func shouldRefreshTapMembership(
        currentObjectIDs: [AudioObjectID],
        latestObjectIDs: [AudioObjectID],
        isRunning: (AudioObjectID) -> Bool = { $0.readProcessIsRunning() }
    ) -> Bool {
        let currentIDs = Set(currentObjectIDs)
        let latestIDs = Set(latestObjectIDs)
        guard currentIDs != latestIDs else { return false }
        if currentIDs.isEmpty {
            return !latestIDs.isEmpty
        }
        return latestIDs.subtracting(currentIDs).contains(where: isRunning)
    }

    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Pinned apps appear first (sorted alphabetically), then unpinned active apps (sorted alphabetically).
    var displayableApps: [DisplayableApp] {
        let activeApps = apps
            .filter { !appListCoordinator.isIgnored(identifier: $0.persistenceIdentifier) }
            .filter { $0.processObjectIDs.contains { $0.readProcessIsRunning() } }
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = appListCoordinator.pinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }

        // Pinned active apps (sorted alphabetically)
        let pinnedActive = activeApps
            .filter { appListCoordinator.isPinned(identifier: $0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        // Pinned inactive apps (sorted alphabetically)
        let pinnedInactive = pinnedInactiveInfos
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { DisplayableApp.pinnedInactive($0) }

        // Unpinned active apps (sorted alphabetically)
        let unpinnedActive = activeApps
            .filter { !appListCoordinator.isPinned(identifier: $0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        return pinnedActive + pinnedInactive + unpinnedActive
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        appListCoordinator.pinApp(app)
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        appListCoordinator.unpinApp(identifier)
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        appListCoordinator.isPinned(app)
    }

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        appListCoordinator.isPinned(identifier: identifier)
    }

    // MARK: - Ignored Apps

    /// Hide an active app so Semper ignores it entirely. Persists the ignore,
    /// then tears down the live tap so audio returns to natural volume.
    func ignoreApp(_ app: AudioApp) {
        appListCoordinator.recordIgnore(app)

        if let tap = taps.removeValue(forKey: app.id) {
            tap.invalidate()
        }
        appDeviceRouting.removeValue(forKey: app.id)
        followsDefault.remove(app.id)
        appliedPIDs.remove(app.id)
    }

    /// Unhide an app by its persistence identifier.
    /// Immediately creates a tap if the app is currently running.
    func unignoreApp(_ identifier: String) {
        appListCoordinator.clearIgnore(identifier)
        applyPersistedSettings()
    }

    /// Check if an identifier is hidden.
    func isIgnored(identifier: String) -> Bool {
        appListCoordinator.isIgnored(identifier: identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    func getVolumeForInactive(identifier: String) -> Float {
        appListCoordinator.getVolumeForInactive(identifier: identifier)
    }

    func setVolumeForInactive(identifier: String, to volume: Float) {
        appListCoordinator.setVolumeForInactive(identifier: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        appListCoordinator.getBoostForInactive(identifier: identifier)
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        appListCoordinator.setBoostForInactive(identifier: identifier, to: boost)
    }

    func getMuteForInactive(identifier: String) -> Bool {
        appListCoordinator.getMuteForInactive(identifier: identifier)
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        appListCoordinator.setMuteForInactive(identifier: identifier, to: muted)
    }

    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        appListCoordinator.getEQSettingsForInactive(identifier: identifier)
    }

    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        appListCoordinator.setEQSettingsForInactive(settings, identifier: identifier)
    }

    func getDeviceRoutingForInactive(identifier: String) -> String? {
        appListCoordinator.getDeviceRoutingForInactive(identifier: identifier)
    }

    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        appListCoordinator.setDeviceRoutingForInactive(identifier: identifier, deviceUID: deviceUID)
    }

    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        appListCoordinator.isFollowingDefaultForInactive(identifier: identifier)
    }

    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        appListCoordinator.getDeviceSelectionModeForInactive(identifier: identifier)
    }

    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        appListCoordinator.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
    }

    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        appListCoordinator.getSelectedDeviceUIDsForInactive(identifier: identifier)
    }

    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        appListCoordinator.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    func outputStereoAudioLevel(for deviceUID: String) -> StereoAudioLevel {
        var left: Float = 0
        var right: Float = 0
        for tap in taps.values where tap.currentDeviceUIDs.contains(deviceUID) {
            let level = tap.stereoAudioLevel
            left = max(left, level.left)
            right = max(right, level.right)
        }
        return StereoAudioLevel(left: left, right: right)
    }

    func outputAttenuationNotice(for deviceUID: String) -> String? {
        let producingPIDs = Set(apps.compactMap { app in
            app.processObjectIDs.isEmpty
                || app.processObjectIDs.contains { $0.readProcessIsRunning() }
                ? app.id
                : nil
        })
        var quietestApp: (name: String, percent: Int)?
        for tap in taps.values
            where tap.currentDeviceUIDs.contains(deviceUID)
                && producingPIDs.contains(tap.app.id) {
            let percent = Int(round(VolumeMapping.gainToSlider(
                volumeState.getVolume(for: tap.app.id)
            ) * 100))
            if percent < 100,
               quietestApp.map({ percent < $0.percent }) ?? true {
                quietestApp = (tap.app.name, percent)
            }
        }

        let loudnessEnabled = settingsManager.appSettings.loudnessCompensationEnabled
            || settingsManager.appSettings.loudnessEqualizationEnabled

        if let quietestApp, loudnessEnabled {
            return "\(quietestApp.name) \(quietestApp.percent)% · Loudness processing on"
        }
        if let quietestApp {
            return "\(quietestApp.name) \(quietestApp.percent)% app volume"
        }
        if loudnessEnabled {
            return "Loudness processing on"
        }
        return nil
    }

    func start() {
        isEngineStopped = false
        // Monitors have internal guards against double-starting
        if permission.status == .authorized,
           settingsManager.audioProcessingMode == .active,
           audioProcessingState == .active {
            processMonitor.start()
        }
        deviceMonitor.start()
        if settingsManager.audioProcessingMode == .active,
           audioProcessingState == .active {
            applyPersistedSettings()
            startHealthMonitor()
        } else if settingsManager.audioProcessingMode == .resumeRequested {
            startAudioProcessingTransitionIfNeeded()
        }

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.info("AudioEngine started")
    }

    func stop() {
        isEngineStopped = true
        audioProcessingTransitionGeneration &+= 1
        audioProcessingTransitionTask?.cancel()
        audioProcessingTransitionTask = nil
        stopHealthMonitor()
        cancelPendingSafeOutputSwitch(reportFailure: true)
        cancelPendingDefaultOutputConfirmation(reportFailure: true)
        for deviceUID in Array(pendingOutputVolumeLimitChanges.keys) {
            rollbackPendingOutputVolumeLimitChange(for: deviceUID)
        }
        for pending in pendingAppRouteOperations.values {
            pending.task.cancel()
            onCommandWriteRejected?(pending.key)
        }
        pendingAppRouteOperations.removeAll()
        appRouteOperationGenerations.removeAll()
        processMonitor.stop()
        deviceMonitor.stop()
        #if !APP_STORE
        ddcController.stop()
        #endif
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        appliedPIDs.removeAll()
        logger.info("AudioEngine stopped")
    }

    /// Explicit shutdown for app termination. Ensures all listeners are cleaned up.
    /// Call from applicationWillTerminate or equivalent lifecycle hook.
    /// Note: For menu bar apps, process exit cleans up resources anyway, so this is optional.
    func shutdown() {
        stop()
        deviceVolumeMonitor.stop()
        logger.info("AudioEngine shutdown complete")
    }

    // MARK: - Audio Processing Recovery

    var audioProcessingMode: AudioProcessingMode {
        settingsManager.audioProcessingMode
    }

    var activeProcessingTapCount: Int {
        taps.count
    }

    var audioRecoveryReport: String {
        audioRecoveryDiagnostics.report(
            state: audioProcessingState,
            permission: permission.status,
            activeTapCount: taps.count
        )
    }

    @discardableResult
    func requestAudioProcessingMode(
        _ requestedMode: AudioProcessingMode
    ) -> AudioProcessingModeRequestResult {
        switch requestedMode {
        case .bypassed:
            guard audioProcessingState != .bypassed || !taps.isEmpty else {
                return .applied(.bypassed)
            }
            guard persistAudioProcessingMode(.bypassed) else { return .rejected }
            startAudioProcessingTransitionIfNeeded()
            return .accepted

        case .active, .resumeRequested:
            if audioProcessingState == .active,
               settingsManager.audioProcessingMode == .active {
                return .applied(.active)
            }

            guard permission.status == .authorized else {
                guard persistAudioProcessingMode(.resumeRequested) else { return .rejected }
                if permission.status == .unknown {
                    permission.request()
                }
                if taps.isEmpty {
                    audioProcessingState = .waitingForPermission
                    return .applied(.resumeRequested)
                }
                startAudioProcessingTransitionIfNeeded()
                return .accepted
            }

            guard persistAudioProcessingMode(.resumeRequested) else { return .rejected }
            startAudioProcessingTransitionIfNeeded()
            return .accepted
        }
    }

    private func persistAudioProcessingMode(_ mode: AudioProcessingMode) -> Bool {
        let previousMode = settingsManager.audioProcessingMode
        settingsManager.setAudioProcessingMode(mode)
        guard settingsManager.flushSync() else {
            settingsManager.setAudioProcessingMode(previousMode)
            audioRecoveryDiagnostics.recordFailure(.settingsPersistence)
            onCommandWriteRejected?(.audioProcessingMode)
            return false
        }
        permissionPersistenceFailurePending = false
        return true
    }

    func retryAudioProcessingRecovery() {
        startAudioProcessingTransitionIfNeeded()
    }

    func waitForAudioProcessingTransition() async {
        await audioProcessingTransitionTask?.value
    }

    private static func initialAudioProcessingState(
        mode: AudioProcessingMode,
        permission: AudioCapturePermissionStatus,
        startupCleanupFailed: Bool
    ) -> AudioProcessingState {
        if startupCleanupFailed { return .failed(.aggregateCleanup) }
        switch mode {
        case .active:
            return permission == .authorized ? .active : .waitingForPermission
        case .bypassed:
            return .bypassed
        case .resumeRequested:
            return permission == .authorized ? .resuming : .waitingForPermission
        }
    }

    private var canCreateProcessTaps: Bool {
        guard !isEngineStopped, permission.status == .authorized else { return false }
        switch audioProcessingState {
        case .active:
            return settingsManager.audioProcessingMode == .active
        case .resuming:
            return settingsManager.audioProcessingMode == .resumeRequested
        default:
            return false
        }
    }

    private func startAudioProcessingTransitionIfNeeded() {
        guard !isEngineStopped, audioProcessingTransitionTask == nil else { return }
        audioProcessingTransitionGeneration &+= 1
        let generation = audioProcessingTransitionGeneration
        audioProcessingTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileAudioProcessing(generation: generation)
            if self.audioProcessingTransitionGeneration == generation {
                self.audioProcessingTransitionTask = nil
            }
        }
    }

    private func reconcileAudioProcessing(generation: UInt64) async {
        while !isEngineStopped,
              audioProcessingTransitionGeneration == generation {
            switch settingsManager.audioProcessingMode {
            case .bypassed:
                if audioProcessingState != .bypassed || !taps.isEmpty {
                    guard await tearDownAudioProcessing(explicitBypass: true) else { return }
                }
                guard settingsManager.audioProcessingMode == .bypassed else { continue }
                audioProcessingState = .bypassed
                onCommandValueObserved?(
                    .audioProcessingMode,
                    .mode(AudioProcessingMode.bypassed.rawValue)
                )
                return

            case .active, .resumeRequested:
                guard permission.status == .authorized else {
                    if !taps.isEmpty || audioProcessingState == .active {
                        guard await tearDownAudioProcessing(explicitBypass: false) else { return }
                    }
                    if permissionPersistenceFailurePending {
                        audioProcessingState = .failed(.settingsPersistence)
                        onCommandWriteRejected?(.audioProcessingMode)
                        return
                    }
                    audioProcessingState = .waitingForPermission
                    onCommandValueObserved?(
                        .audioProcessingMode,
                        .mode(AudioProcessingMode.resumeRequested.rawValue)
                    )
                    return
                }

                if audioProcessingState == .active,
                   settingsManager.audioProcessingMode == .active {
                    return
                }
                guard await resumeAudioProcessing() else { return }
                if settingsManager.audioProcessingMode == .bypassed {
                    continue
                }
                return
            }
        }
    }

    private func tearDownAudioProcessing(explicitBypass: Bool) async -> Bool {
        audioProcessingState = .bypassing
        let healthTask = healthMonitorTask
        stopHealthMonitor()
        processMonitor.stop()

        let staleTask = staleCleanupTask
        staleCleanupTask?.cancel()
        staleCleanupTask = nil
        let cleanupTasks = Array(pendingCleanup.values)
        for task in cleanupTasks { task.cancel() }
        pendingCleanup.removeAll()
        let membershipTasks = Array(tapMembershipRefreshTasks.values)
        for task in membershipTasks { task.cancel() }
        tapMembershipRefreshTasks.removeAll()

        let maintenanceTasks = Array(tapMaintenanceTasks.values)
        for task in maintenanceTasks { task.cancel() }
        tapMaintenanceTasks.removeAll()

        let routeTasks = pendingAppRouteOperations.values.map(\.task)
        for pending in pendingAppRouteOperations.values {
            pending.task.cancel()
            onCommandWriteRejected?(pending.key)
        }
        pendingAppRouteOperations.removeAll()
        appRouteOperationGenerations.removeAll()
        for task in routeTasks {
            await task.value
        }
        for task in maintenanceTasks {
            await task.value
        }
        await staleTask?.value
        for task in cleanupTasks {
            await task.value
        }
        for task in membershipTasks {
            await task.value
        }
        await healthTask?.value

        let ownedTaps = Array(taps.values)
        taps.removeAll()
        appliedPIDs.removeAll()
        tapRecoveryCooldownUntil.removeAll()
        appRouteLifecycles.removeAll()

        var resourceCleanup = TapResourceCleanupResult.empty
        for tap in ownedTaps {
            resourceCleanup.merge(await tap.invalidateAsync())
        }

        let cleanup = orphanedTapCleanup()
        if explicitBypass {
            audioRecoveryDiagnostics.recordBypass(
                cleanup: cleanup,
                resources: resourceCleanup
            )
        }
        if resourceCleanup.failureCount > 0 {
            audioRecoveryDiagnostics.recordFailure(.resourceCleanup)
            audioProcessingState = .failed(.resourceCleanup)
            onCommandWriteRejected?(.audioProcessingMode)
            return false
        }
        if cleanup.failedCount > 0 {
            audioRecoveryDiagnostics.recordFailure(.aggregateCleanup)
            audioProcessingState = .failed(.aggregateCleanup)
            onCommandWriteRejected?(.audioProcessingMode)
            return false
        }
        return true
    }

    private func startTapMaintenanceTask(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        guard canCreateProcessTaps else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tapMaintenanceTasks.removeValue(forKey: id) }
            guard !Task.isCancelled, self.canCreateProcessTaps else { return }
            await operation()
        }
        tapMaintenanceTasks[id] = task
    }

    private func resumeAudioProcessing() async -> Bool {
        audioProcessingState = .resuming
        let cleanup = orphanedTapCleanup()
        audioRecoveryDiagnostics.recordResume(cleanup: cleanup)
        guard cleanup.failedCount == 0 else {
            audioProcessingState = .failed(.aggregateCleanup)
            onCommandWriteRejected?(.audioProcessingMode)
            return false
        }
        guard settingsManager.audioProcessingMode != .bypassed,
              permission.status == .authorized,
              !isEngineStopped else {
            return true
        }

        processMonitor.start()
        applyPersistedSettings()
        startHealthMonitor()
        guard persistAudioProcessingMode(.active) else {
            _ = await tearDownAudioProcessing(explicitBypass: false)
            audioProcessingState = .failed(.settingsPersistence)
            return false
        }
        audioProcessingState = .active
        onCommandValueObserved?(
            .audioProcessingMode,
            .mode(AudioProcessingMode.active.rawValue)
        )
        return true
    }

    // MARK: - Settings Reset

    /// Resets all persisted settings and synchronizes in-memory engine state.
    /// Active taps are kept alive but reverted to defaults (unity volume, unmuted, flat EQ).
    func handleSettingsReset() {
        // 1. Clear persisted state
        settingsManager.resetAllSettings()
        outputMasterGains.removeAll()
        outputBalances.removeAll()

        // 2. Clear in-memory routing and tracking state
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        // 3. Clear cached per-app audio state
        volumeState.resetAll()

        // 4. Refresh output state caches so software-backed devices reset to defaults.
        deviceVolumeMonitor.refreshOutputDeviceStates()

        // 5. Push defaults to all active taps
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
            tap.updateEQSettings(.flat)
            tap.updateAutoEQProfile(nil)
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: false)
        }

        // 6. Re-apply from clean settings (re-establishes routing to system default)
        applyPersistedSettings()

        logger.info("Settings reset: engine state synchronized")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
            if settingsManager.appSettings.loudnessCompensationEnabled {
                tap.updateLoudnessCompensation(
                    volume: effectiveLoudnessVolume(for: tap),
                    enabled: true
                )
            }
        }
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    // MARK: - Boost

    func setBoost(for app: AudioApp, to boost: BoostLevel) {
        volumeState.setBoost(for: app.id, to: boost, identifier: app.persistenceIdentifier)
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func getBoost(for app: AudioApp) -> BoostLevel {
        volumeState.getBoost(for: app.id)
    }

    /// Effective gain for ProcessTapController: app volume × app boost × master gain,
    /// plus the device's volume when it uses Semper's software backend.
    /// Per-device software gain, master boost, and balance apply only to single-device
    /// routing because they have no unambiguous meaning across fan-out.
    private func effectiveVolume(for pid: pid_t, deviceUIDs: [String]? = nil) -> Float {
        let identifier = taps[pid]?.app.persistenceIdentifier
            ?? apps.first(where: { $0.id == pid })?.persistenceIdentifier
        let overlayGain = identifier.map(modeOverlayStore.effectiveGain(for:)) ?? 1
        let appGain = volumeState.getVolume(for: pid)
            * volumeState.getBoost(for: pid).rawValue
            * overlayGain

        guard let resolvedUIDs = deviceUIDs, resolvedUIDs.count == 1,
              let primaryUID = resolvedUIDs.first,
              let device = deviceMonitor.device(for: primaryUID) else {
            return appGain
        }

        let deviceGain = outputVolumeBackend(for: device.id) == .software
            ? deviceVolumeMonitor.outputProcessingGain(for: device.id)
            : 1.0
        let storedMasterGain = outputMasterGains[primaryUID]
            ?? settingsManager.getOutputMasterGain(for: primaryUID)
        let masterGain = storedMasterGain.map {
            min($0, settingsManager.outputVolumeLimit(for: primaryUID) ?? $0)
        } ?? 1
        return appGain * deviceGain * masterGain
    }

    /// Estimated listening level for loudness compensation: device volume × per-app slider.
    /// Does not include boost (intentional amplification beyond reference).
    /// The compensator's phon estimation clamps to [0,1] so values > 1 are treated as reference.
    private func effectiveLoudnessVolume(for tap: any ProcessTapControlling) -> Float {
        tap.currentDeviceVolume
            * volumeState.getVolume(for: tap.app.id)
            * modeOverlayStore.effectiveGain(for: tap.app.persistenceIdentifier)
    }

    private func applyTapOutputState(to tap: any ProcessTapControlling, for pid: pid_t, deviceUIDs: [String]? = nil) {
        let resolvedUIDs = deviceUIDs ?? tap.currentDeviceUIDs
        tap.volume = effectiveVolume(for: pid, deviceUIDs: resolvedUIDs)
        tap.isMuted = volumeState.getMute(for: pid)
        tap.updateBalance(
            resolvedUIDs.count == 1
                ? outputBalance(for: resolvedUIDs[0])
                : 0
        )

        if let primaryUID = resolvedUIDs.first,
           let device = deviceMonitor.device(for: primaryUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        } else {
            tap.currentDeviceVolume = 1.0
            tap.isDeviceMuted = false
        }
    }

    private func refreshAllTapOutputStates() {
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    private func refreshTapOutputStates(forDeviceUID deviceUID: String) {
        for tap in taps.values where tap.currentDeviceUIDs == [deviceUID] {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    private func refreshTapOutputStates(forAppIdentifiers identifiers: Set<String>) {
        for tap in taps.values where identifiers.contains(tap.app.persistenceIdentifier) {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
            tap.updateLoudnessCompensation(
                volume: effectiveLoudnessVolume(for: tap),
                enabled: settingsManager.appSettings.loudnessCompensationEnabled
            )
        }
    }

    func toggleMute(for app: AudioApp) {
        let current = volumeState.getMute(for: app.id)
        setMute(for: app, to: !current)
    }

    func currentVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func isMuted(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    func isAudibleNow(bundleID: String) -> Bool {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return app.processObjectIDs.contains { $0.readProcessIsRunning() }
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    func setAutoEQProfile(for deviceUID: String, profileID: String?) {
        if let profileID {
            settingsManager.setAutoEQSelection(for: deviceUID, to: AutoEQSelection(profileID: profileID, isEnabled: true))
        } else {
            settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        }
        applyAutoEQToTaps(for: deviceUID)
    }

    func setAutoEQEnabled(for deviceUID: String, enabled: Bool) {
        guard var selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return }
        selection.isEnabled = enabled
        settingsManager.setAutoEQSelection(for: deviceUID, to: selection)
        applyAutoEQToTaps(for: deviceUID)
    }

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settingsManager.getAutoEQSelection(for: deviceUID)
    }

    var autoEQPreampEnabled: Bool {
        settingsManager.autoEQPreampEnabled
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsManager.autoEQPreampEnabled = enabled
        for tap in taps.values {
            tap.setAutoEQPreampEnabled(enabled)
        }
    }

    func setLoudnessCompensationEnabled(_ enabled: Bool) {
        for tap in taps.values {
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: enabled)
        }
    }

    func setLoudnessEqualizationEnabled(_ enabled: Bool) {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = enabled
        for tap in taps.values {
            tap.updateLoudnessEqualization(settings)
        }
    }

    /// Apply AutoEQ profile to all taps currently routed to the given device.
    private func applyAutoEQToTaps(for deviceUID: String) {
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            applyAutoEQToTap(tap)
        }
    }

    /// Synchronous in-memory AutoEQ profile lookup. nil = not yet cached.
    private func autoEQProfileForActivation(deviceUID: String) -> AutoEQProfile? {
        guard let device = deviceMonitor.device(for: deviceUID), device.supportsAutoEQ else { return nil }
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID), selection.isEnabled else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    private func tapInitialState(forApp app: AudioApp, primaryDeviceUID: String, deviceVolume: Float) -> TapInitialState {
        var loudnessEqSettings = LoudnessEqualizerSettings()
        loudnessEqSettings.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
        return TapInitialState(
            eqSettings: settingsManager.getEQSettings(for: app.persistenceIdentifier),
            autoEQProfile: autoEQProfileForActivation(deviceUID: primaryDeviceUID),
            autoEQPreampEnabled: settingsManager.autoEQPreampEnabled,
            loudnessVolume: deviceVolume * volumeState.getVolume(for: app.id),
            loudnessCompensationEnabled: settingsManager.appSettings.loudnessCompensationEnabled,
            loudnessEqualizerSettings: loudnessEqSettings
        )
    }

    /// Skips AutoEQ entirely for devices that don't support it (speakers, HDMI, etc.).
    /// If the profile isn't loaded yet, triggers an async fetch and applies when ready.
    private func applyAutoEQToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }

        // Skip AutoEQ for non-headphone devices (or if device not found in monitor)
        guard let device = deviceMonitor.device(for: deviceUID) else {
            logger.debug("AutoEQ skip for \(tap.app.name): device \(deviceUID) not found in monitor")
            return
        }
        guard device.supportsAutoEQ else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): \(device.name) doesn't support AutoEQ")
            return
        }

        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID),
              selection.isEnabled else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): no selection or disabled for \(device.name)")
            return
        }

        // Try in-memory first (instant)
        if let profile = autoEQProfileManager.profile(for: selection.profileID) {
            tap.updateAutoEQProfile(profile)
            return
        }

        // Profile not loaded yet — fetch asynchronously
        tap.updateAutoEQProfile(nil)
        Task { @MainActor in
            guard let profile = await autoEQProfileManager.resolveProfile(for: selection.profileID) else { return }
            // Verify tap still exists and is still routed to the same device
            guard tap.currentDeviceUID == deviceUID else { return }
            guard let latestSelection = settingsManager.getAutoEQSelection(for: deviceUID),
                  latestSelection.profileID == selection.profileID,
                  latestSelection.isEnabled else { return }
            tap.updateAutoEQProfile(profile)
        }
    }

    @discardableResult
    func requestDefaultOutputDeviceSwitch(_ deviceID: AudioDeviceID) -> DefaultOutputSwitchResult {
        beginDefaultOutputSwitch(deviceID, reportsCommandResult: true)
    }

    private func beginDefaultOutputSwitch(
        _ deviceID: AudioDeviceID,
        reportsCommandResult: Bool
    ) -> DefaultOutputSwitchResult {
        guard let device = deviceMonitor.outputDevices.first(where: { $0.id == deviceID }),
              isAliveCheck(deviceID) else {
            return .rejected
        }

        cancelPendingSafeOutputSwitch(
            reportFailure: true,
            transferringVolumeLimitTo: device.uid
        )
        cancelPendingDefaultOutputConfirmation(reportFailure: true)
        let state = SafeOutputSwitchState(
            targetDeviceUID: device.uid,
            volumeLimit: settingsManager.outputVolumeLimit(for: device.uid),
            observedTargetVolume: deviceVolumeMonitor.confirmedOutputVolume(for: deviceID)
        )

        switch state.action {
        case .switchOutput:
            pendingOutputVolumeLimitChanges.removeValue(forKey: device.uid)
            return performDefaultOutputSwitch(
                to: device,
                reportsCommandResult: reportsCommandResult
            )

        case .lowerTargetVolume(_, let limit):
            let ownsOutputVolumeLimitChange = pendingOutputVolumeLimitChanges[device.uid] != nil
            supersedePendingMasterOutputWrite(
                for: device.uid,
                preservingVolumeLimitChange: ownsOutputVolumeLimitChange
            )
            if let pendingCommand = pendingDDCOutputCommands.removeValue(forKey: deviceID) {
                onCommandWriteRejected?(pendingCommand.key)
            }

            nextSafeOutputSwitchGeneration &+= 1
            let generation = nextSafeOutputSwitchGeneration
            let requiresDDCConfirmation = deviceVolumeMonitor.outputVolumeBackend(for: deviceID) == .ddc
            pendingSafeOutputSwitch = PendingSafeOutputSwitch(
                generation: generation,
                deviceID: deviceID,
                reportsCommandResult: reportsCommandResult,
                requiresDDCConfirmation: requiresDDCConfirmation,
                ownsOutputVolumeLimitChange: ownsOutputVolumeLimitChange,
                state: state
            )
            deviceVolumeMonitor.setVolume(for: deviceID, to: limit)
            safeOutputSwitchTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: SafeOutputSwitchState.preflightTimeout)
                guard let self, !Task.isCancelled else { return }
                self.finishSafeOutputPreflight(generation: generation, writeSucceeded: nil)
            }
            return .accepted

        case .keepCurrentOutput:
            return .rejected
        }
    }

    private func finishSafeOutputPreflight(
        generation: UInt64,
        writeSucceeded: Bool?
    ) {
        guard var pending = pendingSafeOutputSwitch,
              pending.generation == generation else {
            return
        }

        let observedVolume = deviceVolumeMonitor.confirmedOutputVolume(for: pending.deviceID)
        let action: SafeOutputSwitchState.Action
        if let writeSucceeded {
            action = pending.state.handle(.writeCompleted(
                succeeded: writeSucceeded,
                observedTargetVolume: observedVolume
            ))
        } else if pending.requiresDDCConfirmation {
            action = pending.state.handle(.writeCompleted(
                succeeded: false,
                observedTargetVolume: observedVolume
            ))
        } else {
            action = pending.state.handle(.timeout(observedTargetVolume: observedVolume))
        }

        if pending.ownsOutputVolumeLimitChange {
            if case .switchOutput = action {
                pendingOutputVolumeLimitChanges.removeValue(forKey: pending.state.targetDeviceUID)
            } else {
                rollbackPendingOutputVolumeLimitChange(for: pending.state.targetDeviceUID)
            }
        }

        pendingSafeOutputSwitch = nil
        safeOutputSwitchTimeoutTask?.cancel()
        safeOutputSwitchTimeoutTask = nil

        guard case .switchOutput(let deviceUID) = action,
              let device = deviceMonitor.device(for: deviceUID),
              device.id == pending.deviceID,
              isAliveCheck(device.id) else {
            if pending.reportsCommandResult {
                onCommandWriteRejected?(.defaultOutput)
            }
            return
        }

        let result = performDefaultOutputSwitch(
            to: device,
            reportsCommandResult: pending.reportsCommandResult
        )
        switch result {
        case .applied:
            if pending.reportsCommandResult {
                onCommandValueObserved?(.defaultOutput, .identifier(device.uid))
            }
        case .accepted:
            break
        case .rejected:
            if pending.reportsCommandResult {
                onCommandWriteRejected?(.defaultOutput)
            }
        }
    }

    private func handleSafeOutputPreflightWriteCompleted(
        deviceID: AudioDeviceID,
        succeeded: Bool
    ) {
        guard let pending = pendingSafeOutputSwitch,
              pending.deviceID == deviceID,
              pending.requiresDDCConfirmation else {
            return
        }
        finishSafeOutputPreflight(
            generation: pending.generation,
            writeSucceeded: succeeded
        )
    }

    private func cancelPendingSafeOutputSwitch(
        reportFailure: Bool,
        transferringVolumeLimitTo deviceUID: String? = nil
    ) {
        safeOutputSwitchTimeoutTask?.cancel()
        safeOutputSwitchTimeoutTask = nil
        guard let pending = pendingSafeOutputSwitch else { return }
        pendingSafeOutputSwitch = nil
        if pending.ownsOutputVolumeLimitChange,
           pending.state.targetDeviceUID != deviceUID {
            rollbackPendingOutputVolumeLimitChange(for: pending.state.targetDeviceUID)
        }
        if reportFailure, pending.reportsCommandResult {
            onCommandWriteRejected?(.defaultOutput)
        }
    }

    private func performDefaultOutputSwitch(
        to device: AudioDevice,
        reportsCommandResult: Bool
    ) -> DefaultOutputSwitchResult {
        guard deviceVolumeMonitor.setDefaultDevice(device.id) else { return .rejected }
        let echoToken = outputEchoTracker.increment(device.uid)
        if deviceVolumeMonitor.defaultDeviceUID == device.uid {
            lastConfirmedDefaultUID = device.uid
            routeFollowsDefaultApps(to: device.uid)
            return .applied
        }

        nextDefaultOutputConfirmationGeneration &+= 1
        let generation = nextDefaultOutputConfirmationGeneration
        pendingDefaultOutputConfirmation = PendingDefaultOutputConfirmation(
            generation: generation,
            deviceID: device.id,
            deviceUID: device.uid,
            echoToken: echoToken,
            reportsCommandResult: reportsCommandResult
        )
        defaultOutputConfirmationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.finishDefaultOutputConfirmation(generation: generation)
        }
        return .accepted
    }

    private func handleDefaultOutputConfirmation(_ observedDeviceUID: String) {
        guard let pending = pendingDefaultOutputConfirmation else { return }
        guard observedDeviceUID == pending.deviceUID else { return }
        pendingDefaultOutputConfirmation = nil
        defaultOutputConfirmationTimeoutTask?.cancel()
        defaultOutputConfirmationTimeoutTask = nil
        lastConfirmedDefaultUID = pending.deviceUID
        routeFollowsDefaultApps(to: pending.deviceUID)
    }

    private func finishDefaultOutputConfirmation(generation: UInt64) {
        guard let pending = pendingDefaultOutputConfirmation,
              pending.generation == generation else {
            return
        }
        pendingDefaultOutputConfirmation = nil
        defaultOutputConfirmationTimeoutTask = nil
        outputEchoTracker.cancel(pending.deviceUID, token: pending.echoToken)
        guard deviceVolumeMonitor.defaultDeviceUID == pending.deviceUID else {
            if pending.reportsCommandResult {
                onCommandWriteRejected?(.defaultOutput)
            }
            return
        }
        lastConfirmedDefaultUID = pending.deviceUID
        routeFollowsDefaultApps(to: pending.deviceUID)
        if pending.reportsCommandResult {
            onCommandValueObserved?(.defaultOutput, .identifier(pending.deviceUID))
        }
    }

    private func cancelPendingDefaultOutputConfirmation(reportFailure: Bool) {
        defaultOutputConfirmationTimeoutTask?.cancel()
        defaultOutputConfirmationTimeoutTask = nil
        guard let pending = pendingDefaultOutputConfirmation else { return }
        pendingDefaultOutputConfirmation = nil
        outputEchoTracker.cancel(pending.deviceUID, token: pending.echoToken)
        if reportFailure, pending.reportsCommandResult {
            onCommandWriteRejected?(.defaultOutput)
        }
    }

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        let shouldFollowDefault = deviceUID == nil
        guard let targetUID = deviceUID ?? deviceVolumeMonitor.defaultDeviceUID else {
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)
            followsDefault.insert(app.id)
            appRouteLifecycles[app.id] = .unavailable(message: "No system output is available")
            logger.warning("No default device available for \(app.name), will route when available")
            return
        }

        let previousUID = appDeviceRouting[app.id]
        let previouslyFollowedDefault = followsDefault.contains(app.id)
        let previousUIDs = taps[app.id]?.currentDeviceUIDs ?? previousUID.map { [$0] } ?? []

        guard let targetDevice = deviceMonitor.device(for: targetUID),
              targetDevice.outputTopology.supportsProcessedAudio else {
            appRouteLifecycles[app.id] = .failed(
                previousDeviceUIDs: previousUIDs,
                message: "The selected output is unavailable"
            )
            return
        }
        guard permission.status == .authorized else {
            appRouteLifecycles[app.id] = .unavailable(
                message: "Allow System Audio Recording to route this app"
            )
            return
        }

        let target = AudioAppCommandTarget.active(app)
        let commandKey = AudioControlKey.appDevice(target)
        let operation = beginAppRouteOperation(for: app, key: commandKey)
        let generation = operation.generation
        appRouteLifecycles[app.id] = .preparing(deviceUIDs: [targetUID])
        let preferredTapSourceUID = preferredTapSourceDeviceUID(
            forOutputUIDs: [targetUID],
            isFollowsDefault: shouldFollowDefault
        )

        if let tap = taps[app.id] {
            let task = Task { @MainActor [weak self] in
                if let predecessor = operation.predecessor {
                    await predecessor.value
                }
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentAppRouteOperation(for: app.id, generation: generation) else {
                    return
                }
                defer { self.finishAppRouteOperation(for: app.id, generation: generation) }
                do {
                    if tap.currentDeviceUIDs != [targetUID] {
                        try await tap.switchDevice(
                            to: targetUID,
                            preferredTapSourceDeviceUID: preferredTapSourceUID
                        )
                    } else if previouslyFollowedDefault != shouldFollowDefault {
                        try await tap.refreshTapSource(preferredTapSourceUID)
                    }
                    guard !Task.isCancelled,
                          self.isCurrentAppRouteOperation(for: app.id, generation: generation) else {
                        return
                    }
                    self.commitSingleDeviceRoute(
                        for: app,
                        deviceUID: targetUID,
                        followsDefault: shouldFollowDefault
                    )
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                    self.appRouteLifecycles[app.id] = .active(deviceUIDs: tap.currentDeviceUIDs)
                    self.onCommandValueObserved?(
                        commandKey,
                        .identifier(shouldFollowDefault ? nil : targetUID)
                    )
                    self.logger.debug("Switched \(app.name) to device: \(targetUID)")
                } catch {
                    guard !Task.isCancelled,
                          self.isCurrentAppRouteOperation(for: app.id, generation: generation) else {
                        return
                    }
                    self.appRouteLifecycles[app.id] = .failed(
                        previousDeviceUIDs: tap.currentDeviceUIDs,
                        message: error.localizedDescription
                    )
                    self.onCommandWriteRejected?(commandKey)
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
            pendingAppRouteOperations[app.id] = PendingAppRouteOperation(
                generation: generation,
                key: commandKey,
                task: task
            )
        } else {
            commitSingleDeviceRoute(
                for: app,
                deviceUID: targetUID,
                followsDefault: shouldFollowDefault
            )
            if !ensureTapExists(for: app, deviceUID: targetUID) {
                restoreSingleDeviceRoute(
                    for: app,
                    deviceUID: previousUID,
                    followsDefault: previouslyFollowedDefault
                )
            }
        }
    }

    private func commitSingleDeviceRoute(
        for app: AudioApp,
        deviceUID: String,
        followsDefault shouldFollowDefault: Bool
    ) {
        appDeviceRouting[app.id] = deviceUID
        if shouldFollowDefault {
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)
        } else {
            followsDefault.remove(app.id)
            settingsManager.setDeviceRouting(
                for: app.persistenceIdentifier,
                deviceUID: deviceUID
            )
        }
    }

    private func restoreSingleDeviceRoute(
        for app: AudioApp,
        deviceUID: String?,
        followsDefault shouldFollowDefault: Bool
    ) {
        if let deviceUID {
            appDeviceRouting[app.id] = deviceUID
        } else {
            appDeviceRouting.removeValue(forKey: app.id)
        }
        if shouldFollowDefault || deviceUID == nil {
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)
        } else if let deviceUID {
            followsDefault.remove(app.id)
            settingsManager.setDeviceRouting(
                for: app.persistenceIdentifier,
                deviceUID: deviceUID
            )
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Returns true if the app follows system default device
    func isFollowingDefault(for app: AudioApp) -> Bool {
        followsDefault.contains(app.id)
    }

    // MARK: - Multi-Device Selection

    /// Gets the device selection mode for an app
    func getDeviceSelectionMode(for app: AudioApp) -> DeviceSelectionMode {
        volumeState.getDeviceSelectionMode(for: app.id)
    }

    /// Sets the device selection mode for an app.
    /// Triggers tap reconfiguration when mode changes.
    func setDeviceSelectionMode(for app: AudioApp, to mode: DeviceSelectionMode) {
        let previousMode = volumeState.getDeviceSelectionMode(for: app.id)
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        if mode == .multi,
           volumeState.getSelectedDeviceUIDs(for: app.id).isEmpty,
           let currentUID = appDeviceRouting[app.id] {
            volumeState.setSelectedDeviceUIDs(
                for: app.id,
                to: [currentUID],
                identifier: app.persistenceIdentifier
            )
        }
        volumeState.setDeviceSelectionMode(for: app.id, to: mode, identifier: app.persistenceIdentifier)

        guard previousMode != mode else { return }

        let key = AudioControlKey.appDeviceMode(.active(app))
        let operation = beginAppRouteOperation(for: app, key: key)
        let generation = operation.generation
        let task = Task { @MainActor [weak self] in
            if let predecessor = operation.predecessor {
                await predecessor.value
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentAppRouteOperation(for: app.id, generation: generation) else {
                return
            }
            defer { self.finishAppRouteOperation(for: app.id, generation: generation) }
            switch await self.updateTapForCurrentMode(for: app, generation: generation) {
            case .applied:
                self.onCommandValueObserved?(
                    key,
                    .mode(mode.rawValue)
                )
            case .failed:
                self.volumeState.setDeviceSelectionMode(
                    for: app.id,
                    to: previousMode,
                    identifier: app.persistenceIdentifier
                )
                self.volumeState.setSelectedDeviceUIDs(
                    for: app.id,
                    to: previousUIDs,
                    identifier: app.persistenceIdentifier
                )
                self.onCommandWriteRejected?(key)
            case .superseded:
                break
            }
        }
        pendingAppRouteOperations[app.id] = PendingAppRouteOperation(
            generation: generation,
            key: key,
            task: task
        )
    }

    /// Gets the selected device UIDs for multi-mode
    func getSelectedDeviceUIDs(for app: AudioApp) -> Set<String> {
        volumeState.getSelectedDeviceUIDs(for: app.id)
    }

    /// Sets the selected device UIDs for multi-mode.
    /// Triggers tap reconfiguration when in multi mode.
    func setSelectedDeviceUIDs(for app: AudioApp, to uids: Set<String>) {
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        guard previousUIDs != uids else { return }
        volumeState.setSelectedDeviceUIDs(for: app.id, to: uids, identifier: app.persistenceIdentifier)
        guard getDeviceSelectionMode(for: app) == .multi else { return }

        let key = AudioControlKey.appDevices(.active(app))
        let operation = beginAppRouteOperation(for: app, key: key)
        let generation = operation.generation
        let task = Task { @MainActor [weak self] in
            if let predecessor = operation.predecessor {
                await predecessor.value
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentAppRouteOperation(for: app.id, generation: generation) else {
                return
            }
            defer { self.finishAppRouteOperation(for: app.id, generation: generation) }
            switch await self.updateTapForCurrentMode(for: app, generation: generation) {
            case .applied:
                self.onCommandValueObserved?(
                    key,
                    .identifiers(uids)
                )
            case .failed:
                self.volumeState.setSelectedDeviceUIDs(
                    for: app.id,
                    to: previousUIDs,
                    identifier: app.persistenceIdentifier
                )
                self.onCommandWriteRejected?(key)
            case .superseded:
                break
            }
        }
        pendingAppRouteOperations[app.id] = PendingAppRouteOperation(
            generation: generation,
            key: key,
            task: task
        )
    }

    private enum AppRouteUpdateResult {
        case applied
        case failed
        case superseded
    }

    /// Updates tap configuration based on current mode and selected devices
    @discardableResult
    private func updateTapForCurrentMode(
        for app: AudioApp,
        generation: UInt64? = nil
    ) async -> AppRouteUpdateResult {
        guard !Task.isCancelled,
              generation.map({ isCurrentAppRouteOperation(for: app.id, generation: $0) }) ?? true else {
            return .superseded
        }
        let mode = getDeviceSelectionMode(for: app)

        let deviceUIDs: [String]
        switch mode {
        case .single:
            if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else if let deviceUID = appDeviceRouting[app.id] {
                deviceUIDs = [deviceUID]
            } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else {
                logger.warning("No device available for \(app.name) in single mode")
                appRouteLifecycles[app.id] = .unavailable(message: "No output is available")
                return .failed
            }

        case .multi:
            let selectedUIDs = getSelectedDeviceUIDs(for: app).sorted()
            if selectedUIDs.isEmpty {
                appRouteLifecycles[app.id] = .unavailable(
                    message: "Select at least one output"
                )
                return .failed
            }
            deviceUIDs = selectedUIDs
        }

        let unavailableUID = deviceUIDs.first {
            guard let device = deviceMonitor.device(for: $0) else { return true }
            return !device.outputTopology.supportsProcessedAudio
        }
        if unavailableUID != nil {
            appRouteLifecycles[app.id] = .failed(
                previousDeviceUIDs: taps[app.id]?.currentDeviceUIDs ?? [],
                message: "One of the selected outputs is unavailable"
            )
            return .failed
        }

        appRouteLifecycles[app.id] = .preparing(deviceUIDs: deviceUIDs)

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    guard !Task.isCancelled,
                          generation.map({ isCurrentAppRouteOperation(for: app.id, generation: $0) }) ?? true else {
                        return .superseded
                    }
                    applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
                    appRouteLifecycles[app.id] = .active(deviceUIDs: tap.currentDeviceUIDs)
                    logger.debug("Updated \(app.name) to \(deviceUIDs.count) device(s)")
                } catch {
                    guard !Task.isCancelled,
                          generation.map({ isCurrentAppRouteOperation(for: app.id, generation: $0) }) ?? true else {
                        return .superseded
                    }
                    appRouteLifecycles[app.id] = .failed(
                        previousDeviceUIDs: tap.currentDeviceUIDs,
                        message: error.localizedDescription
                    )
                    logger.error("Failed to update devices for \(app.name): \(error.localizedDescription)")
                    return .failed
                }
            } else {
                appRouteLifecycles[app.id] = .active(deviceUIDs: tap.currentDeviceUIDs)
            }
            return .applied
        } else {
            // No tap exists - create one
            return ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs) ? .applied : .failed
        }
    }

    /// Creates a tap with the specified device UIDs
    @discardableResult
    private func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String]) -> Bool {
        guard !deviceUIDs.isEmpty else { return false }
        if let tap = taps[app.id] {
            appRouteLifecycles[app.id] = .active(deviceUIDs: tap.currentDeviceUIDs)
            return true
        }
        guard canCreateProcessTaps else {
            appRouteLifecycles[app.id] = .unavailable(
                message: audioProcessingState == .waitingForPermission
                    ? "Allow System Audio Recording to route this app"
                    : "Resume audio processing to route this app"
            )
            return false
        }

        appRouteLifecycles[app.id] = .preparing(deviceUIDs: deviceUIDs)
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUIDs[0],
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            appRouteLifecycles[app.id] = .active(deviceUIDs: tap.currentDeviceUIDs)
            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
            return true
        } catch {
            appRouteLifecycles[app.id] = .failed(
                previousDeviceUIDs: [],
                message: error.localizedDescription
            )
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
            return false
        }
    }

    func applyPersistedSettings() {
        guard canCreateProcessTaps else { return }

        // Warm the AutoEQ cache for every (app, device) selection so that subsequent
        // tap activations can apply correction synchronously inside activate(initial:)
        // instead of falling back to the async resolve path. Imported profiles are
        // already loaded by AutoEQProfileManager.init.
        let selectedProfileIDs: Set<String> = Set(apps.compactMap { app -> String? in
            let deviceUID = appDeviceRouting[app.id] ?? deviceVolumeMonitor.defaultDeviceUID
            guard let deviceUID, let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
            return selection.isEnabled ? selection.profileID : nil
        })
        let manager = autoEQProfileManager
        Task { @MainActor in
            for id in selectedProfileIDs where manager.profile(for: id) == nil {
                _ = await manager.resolveProfile(for: id)
            }
        }

        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }
            guard !settingsManager.isIgnored(app.persistenceIdentifier) else { continue }
            guard shouldKeepTap(for: app) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume, mute, and boost state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)
            _ = volumeState.loadSavedBoost(for: app.id, identifier: app.persistenceIdentifier)

            // Handle multi-device mode
            if mode == .multi {
                if let savedUIDs = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
                   !savedUIDs.isEmpty {
                    // Filter to currently available devices, maintaining deterministic order
                    let availableUIDs = savedUIDs.filter { deviceMonitor.device(for: $0) != nil }
                        .sorted()  // Deterministic ordering
                    if !availableUIDs.isEmpty {
                        logger.debug("Restoring multi-device mode for \(app.name) with \(availableUIDs.count) device(s)")
                        ensureTapWithDevices(for: app, deviceUIDs: availableUIDs)

                        // Mark as applied if tap created successfully
                        guard taps[app.id] != nil else { continue }
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
                        appliedPIDs.insert(app.id)

                        // Apply volume (with boost) and mute
                        if savedVolume != nil {
                            if let tap = taps[app.id] {
                                applyTapOutputState(to: tap, for: app.id, deviceUIDs: availableUIDs)
                            }
                        }
                        if let muted = savedMute, muted {
                            taps[app.id]?.isMuted = true
                        }
                        continue  // Skip single-device path
                    }
                    // All saved devices unavailable - fall through to single-device mode
                    logger.debug("All multi-mode devices unavailable for \(app.name), falling back to single mode")
                }
            }

            // Single-device mode (or multi-mode fallback)
            let deviceUID: String
            if settingsManager.isFollowingDefault(for: app.persistenceIdentifier) {
                // App follows system default (new app or explicitly set to follow)
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device available for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) follows system default: \(deviceUID)")
            } else if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
                      deviceMonitor.device(for: savedDeviceUID) != nil {
                // Explicit device routing exists and device is available
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // Saved device temporarily unavailable: fall back to system default for now
                // Don't persist - keep original device preference for when it reconnects
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) device temporarily unavailable, using default: \(deviceUID)")
            }
            appDeviceRouting[app.id] = deviceUID

            // If a tap already exists but is on the wrong device (e.g., app reappeared
            // after the default changed while it was absent), switch it.
            if let existingTap = taps[app.id], existingTap.currentDeviceUIDs != [deviceUID] {
                let preferredSource = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
                startTapMaintenanceTask { [weak self] in
                    guard let self else { return }
                    do {
                        try await existingTap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredSource)
                        guard self.canCreateProcessTaps else { return }
                        self.applyTapOutputState(to: existingTap, for: app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(existingTap)
                    } catch {
                        self.logger.error("Failed to re-route \(app.name) to \(deviceUID): \(error.localizedDescription)")
                    }
                }
                appliedPIDs.insert(app.id)
                continue
            }

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if savedVolume != nil {
                let effective = effectiveVolume(for: app.id, deviceUIDs: [deviceUID])
                let displayPercent = Int(effective * 100)
                logger.debug("Applying saved volume \(displayPercent)% (with boost) to \(app.name)")
                taps[app.id]?.volume = effective
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    @discardableResult
    private func ensureTapExists(for app: AudioApp, deviceUID: String) -> Bool {
        if let tap = taps[app.id] {
            appRouteLifecycles[app.id] = .active(deviceUIDs: tap.currentDeviceUIDs)
            return true
        }
        guard canCreateProcessTaps else {
            appRouteLifecycles[app.id] = .unavailable(
                message: audioProcessingState == .waitingForPermission
                    ? "Allow System Audio Recording to route this app"
                    : "Resume audio processing to route this app"
            )
            return false
        }

        appRouteLifecycles[app.id] = .preparing(deviceUIDs: [deviceUID])
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, [deviceUID], preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: [deviceUID])

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUID,
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            // Imported profiles always hit the synchronous path above.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            appRouteLifecycles[app.id] = .active(deviceUIDs: tap.currentDeviceUIDs)
            logger.debug("Created tap for \(app.name)")
            return true
        } catch {
            appRouteLifecycles[app.id] = .failed(
                previousDeviceUIDs: [],
                message: error.localizedDescription
            )
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
            return false
        }
    }

    /// Restores the default to `lastConfirmedDefaultUID` (what the user/Semper intended).
    /// Falls back to highest-priority device if the confirmed device is gone.
    private func restoreConfirmedDefault() {
        if let restoreUID = lastConfirmedDefaultUID,
           let device = deviceMonitor.device(for: restoreUID),
           isAliveCheck(device.id) {
            if deviceVolumeMonitor.defaultDeviceUID != restoreUID {
                let result = beginDefaultOutputSwitch(
                    device.id,
                    reportsCommandResult: false
                )
                if result != .rejected {
                    logger.info("Restored default → \(device.name)")
                }
            } else {
                routeFollowsDefaultApps(to: restoreUID)
            }
        } else {
            reEvaluateOutputDefault()
        }
    }

    /// Ensures system default matches highest-priority alive connected device.
    /// Routes followsDefault apps and switches their taps if default changes.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateOutputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if target.uid != currentDefault {
            let result = beginDefaultOutputSwitch(
                target.id,
                reportsCommandResult: false
            )
            if result != .rejected {
                logger.info("System default → \(target.name)")
            }
        } else {
            lastConfirmedDefaultUID = target.uid
            routeFollowsDefaultApps(to: target.uid)
        }
        return target.uid
    }

    /// Ensures system default input matches highest-priority alive connected input device.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateInputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        if target.uid != deviceVolumeMonitor.defaultInputDeviceUID {
            if deviceVolumeMonitor.setDefaultInputDevice(target.id) {
                inputEchoTracker.increment(target.uid)
                logger.info("Default input → \(target.name)")
            }
        }
        return target.uid
    }

    /// Routes all followsDefault apps to the given device UID and switches their taps.
    /// Early-exits if all apps are already routed to the target (avoids unnecessary tap switches).
    private func routeFollowsDefaultApps(to targetUID: String) {
        guard !followsDefault.allSatisfy({ appDeviceRouting[$0] == targetUID }) else { return }

        for pid in followsDefault {
            appDeviceRouting[pid] = targetUID
        }

        var tapsToSwitch: [(app: AudioApp, tap: any ProcessTapControlling)] = []
        for app in apps {
            guard followsDefault.contains(app.id), let tap = taps[app.id] else { continue }
            tapsToSwitch.append((app, tap))
        }
        guard !tapsToSwitch.isEmpty else { return }

        startTapMaintenanceTask { [weak self] in
            guard let self else { return }
            for (app, tap) in tapsToSwitch {
                guard self.canCreateProcessTaps else { return }
                do {
                    let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: true)
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    guard self.canCreateProcessTaps else { return }
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                } catch {
                    self.logger.error("Failed to switch \(app.name) to \(targetUID): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Clean up alive watcher — use UID lookup since device is already removed from monitor
        removeAliveWatcher(forUID: deviceUID)

        if pendingSafeOutputSwitch?.state.targetDeviceUID == deviceUID {
            cancelPendingSafeOutputSwitch(reportFailure: true)
        }
        if pendingDefaultOutputConfirmation?.deviceUID == deviceUID {
            cancelPendingDefaultOutputConfirmation(reportFailure: true)
        }

        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = outputPriorityState, uid == deviceUID {
            task.cancel()
            outputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultOutput = deviceUID == deviceVolumeMonitor.defaultDeviceUID

        // Use priority-based fallback (resolve checks isDeviceAlive internally)
        let fallbackDevice = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        var affectedApps: [AudioApp] = []
        var singleModeTapsToSwitch: [(tap: any ProcessTapControlling, fallbackUID: String)] = []
        var multiModeTapsToUpdate: [(tap: any ProcessTapControlling, remainingUIDs: [String])] = []

        // Iterate over taps instead of apps - apps list may be empty if disconnected device
        // was the system default (CoreAudio removes app from process list when output disappears)
        for tap in taps.values {
            let app = tap.app
            let mode = getDeviceSelectionMode(for: app)

            // Check if this tap uses the disconnected device
            guard tap.currentDeviceUIDs.contains(deviceUID) else { continue }

            affectedApps.append(app)

            if mode == .multi && tap.currentDeviceUIDs.count > 1 {
                // Multi-device mode: remove disconnected device, keep others
                let remainingUIDs = tap.currentDeviceUIDs.filter { $0 != deviceUID }.sorted()
                if !remainingUIDs.isEmpty {
                    multiModeTapsToUpdate.append((tap: tap, remainingUIDs: remainingUIDs))
                    // Update in-memory selection to remove disconnected device (don't persist)
                    var currentSelection = volumeState.getSelectedDeviceUIDs(for: app.id)
                    currentSelection.remove(deviceUID)
                    volumeState.setSelectedDeviceUIDs(for: app.id, to: currentSelection, identifier: nil)
                    continue
                }
                // All devices gone in multi-mode, fall through to single-device fallback
            }

            // Single-device mode (or multi-mode with no remaining devices): switch to fallback
            if let fallback = fallbackDevice {
                appDeviceRouting[app.id] = fallback.uid
                // Set to follow default in-memory (UI shows "System Audio")
                // Don't persist - original device preference stays in settings for reconnection
                followsDefault.insert(app.id)
                singleModeTapsToSwitch.append((tap: tap, fallbackUID: fallback.uid))
            } else {
                logger.error("No fallback device available for \(app.name)")
            }
        }

        // Execute device switches
        if !singleModeTapsToSwitch.isEmpty || !multiModeTapsToUpdate.isEmpty {
            startTapMaintenanceTask { [weak self] in
                guard let self else { return }
                // Handle single-mode switches — source device is dead, skip crossfade
                for (tap, fallbackUID) in singleModeTapsToSwitch {
                    guard self.canCreateProcessTaps else { return }
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [fallbackUID], isFollowsDefault: true)
                        try await tap.switchDevice(to: fallbackUID, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        guard self.canCreateProcessTaps else { return }
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [fallbackUID])
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                // Source device is dead, skip crossfade
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    guard self.canCreateProcessTaps else { return }
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs, isFollowsDefault: self.followsDefault.contains(tap.app.id))
                        try await tap.updateDevices(to: remainingUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        guard self.canCreateProcessTaps else { return }
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: remainingUIDs)
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            let fallbackName = fallbackDevice?.name ?? "none"
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) affected")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackName, affectedApps: affectedApps)
            }
        }

        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID)
        }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        // Register newly connected device in priority list
        settingsManager.ensureDeviceInPriority(deviceUID)

        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [any ProcessTapControlling] = []

        // Iterate over taps for consistency with handleDeviceDisconnected
        for tap in taps.values {
            let app = tap.app

            // Skip apps that are PERSISTED as following default - they don't have explicit device preferences
            // Note: in-memory followsDefault may include temporarily displaced apps, so check persisted state
            guard !settingsManager.isFollowingDefault(for: app.persistenceIdentifier) else { continue }

            // Check if this app was pinned to the reconnected device (from persisted settings)
            let persistedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier)
            guard persistedUID == deviceUID else { continue }

            // App was pinned to this device - switch it back
            guard appDeviceRouting[app.id] != deviceUID else { continue }

            affectedApps.append(app)
            appDeviceRouting[app.id] = deviceUID
            // Remove from followsDefault since we're restoring explicit routing
            followsDefault.remove(app.id)
            tapsToSwitch.append(tap)
        }

        if !tapsToSwitch.isEmpty {
            startTapMaintenanceTask { [weak self] in
                guard let self else { return }
                for tap in tapsToSwitch {
                    guard self.canCreateProcessTaps else { return }
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: false)
                        try await tap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        guard self.canCreateProcessTaps else { return }
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Second pass: restore multi-device apps that had this device in their selection
        var multiModeTapsToUpdate: [any ProcessTapControlling] = []
        for tap in taps.values {
            let app = tap.app
            guard settingsManager.getDeviceSelectionMode(for: app.persistenceIdentifier) == .multi else { continue }
            guard let persistedUIDs = settingsManager.getSelectedDeviceUIDs(for: app.persistenceIdentifier),
                  persistedUIDs.contains(deviceUID) else { continue }
            let currentUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
            guard !currentUIDs.contains(deviceUID) else { continue }

            // Add the reconnected device back to in-memory selection
            var updatedUIDs = currentUIDs
            updatedUIDs.insert(deviceUID)
            volumeState.setSelectedDeviceUIDs(for: app.id, to: updatedUIDs, identifier: app.persistenceIdentifier)
            multiModeTapsToUpdate.append(tap)
        }

        if !multiModeTapsToUpdate.isEmpty {
            startTapMaintenanceTask { [weak self] in
                guard let self else { return }
                for tap in multiModeTapsToUpdate {
                    guard self.canCreateProcessTaps else { return }
                    await self.updateTapForCurrentMode(for: tap.app)
                }
            }
            logger.info("\(deviceName) reconnected, restored to \(multiModeTapsToUpdate.count) multi-device app(s)")
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }

        // Only override the default if the newly connected device IS the highest-priority
        // device (i.e., a higher-priority device just came back). If a lower-priority device
        // connects while the user is on a higher-priority device, respect the current default —
        // the user chose it. We still enter PENDING_AUTOSWITCH to guard against macOS
        // auto-switching to the new device.
        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        let highestPriorityUID = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            isAlive: isAliveCheck
        )?.uid

        // If this device is present but not alive, watch for it to become alive
        if let device = deviceMonitor.device(for: deviceUID),
           !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }

        switch Self.connectedOutputDefaultAction(
            connectedDeviceUID: deviceUID,
            highestPriorityConnectedUID: highestPriorityUID,
            currentDefaultUID: currentDefault
        ) {
        case .ensureHighestPriorityDefault:
            reEvaluateOutputDefault()
        case .restorePrevious:
            restoreConfirmedDefault()
        case .none:
            break
        }

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one.
        if case .pendingAutoSwitch(_, let oldTask) = outputPriorityState {
            oldTask.cancel()
            outputPriorityState = .stable
        }

        // Always enter PENDING_AUTOSWITCH for the newly connected device.
        // macOS may auto-switch to it multiple times during BT firmware handshake.
        // Without this grace period, auto-switches would be treated as "genuine user change".
        let transport = deviceMonitor.device(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.outputPriorityState = .stable
            self.logger.debug("Auto-switch grace period expired, no macOS switch detected")
        }

        lastAutoSwitchOverrideTime = nil
        outputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
        logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")
    }

    // MARK: - Alive Watchers

    /// Installs a one-shot HAL listener for kAudioDevicePropertyDeviceIsAlive on a device
    /// that is present but not yet alive. When the device becomes alive, re-runs
    /// handleDeviceConnected so priority is re-evaluated. Self-removes after firing or timeout.
    private func installAliveWatcher(deviceID: AudioDeviceID, uid: String, name: String) {
        guard aliveWatchers[deviceID] == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAliveCheck(deviceID) else { return }
                self.logger.info("Device became alive: \(name) (\(uid)), re-evaluating priority")
                self.removeAliveWatcher(deviceID)
                self.handleDeviceConnected(uid, name: name)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            logger.warning("Failed to install alive watcher for \(name) (\(deviceID)): \(status)")
            return
        }

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.logger.debug("Alive watcher timed out for \(name) (\(uid))")
            self.removeAliveWatcher(deviceID)
        }

        aliveWatchers[deviceID] = (uid: uid, block: block, timeout: timeoutTask)
        logger.debug("Installed alive watcher for \(name) (\(uid))")
    }

    /// Removes a one-shot alive watcher by device ID, cleaning up the HAL listener and timeout.
    private func removeAliveWatcher(_ deviceID: AudioDeviceID) {
        guard let watcher = aliveWatchers.removeValue(forKey: deviceID) else { return }
        watcher.timeout.cancel()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, watcher.block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove alive watcher for device \(deviceID): \(status)")
        }
    }

    /// Removes a one-shot alive watcher by device UID. Used during disconnect when the
    /// device is already removed from the monitor's list and device(for:) returns nil.
    private func removeAliveWatcher(forUID uid: String) {
        guard let (deviceID, _) = aliveWatchers.first(where: { $0.value.uid == uid }) else { return }
        removeAliveWatcher(deviceID)
    }

    private func showReconnectNotification(deviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Reconnected"
        content.body = "\"\(deviceName)\" is back. \(affectedApps.count) app(s) switched back."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-reconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    private func showDisconnectNotification(deviceName: String, fallbackName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Disconnected"
        content.body = "\"\(deviceName)\" disconnected. \(affectedApps.count) app(s) switched to \(fallbackName)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-disconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Called when system default output device changes - switches apps that follow default
    private func handleDefaultDeviceChanged(_ newDefaultUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after a device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = outputPriorityState {
            // Check echoes FIRST — Semper's own changes (UI, restoreConfirmedDefault)
            // create echoes. Consuming before Case 1 ensures Semper UI changes aren't
            // mistaken for macOS auto-switches.
            if outputEchoTracker.consume(newDefaultUID) {
                return
            }

            if newDefaultUID == pendingUID {
                // Settling heuristic: if >1s since last override, BT auto-switches have
                // settled. This is likely the user changing via System Settings — accept it.
                // BT auto-switches happen within ms; user actions take >1s.
                if let lastOverride = lastAutoSwitchOverrideTime,
                   Date().timeIntervalSince(lastOverride) > 1.0 {
                    timeoutTask.cancel()
                    outputPriorityState = .stable
                    lastConfirmedDefaultUID = newDefaultUID
                    lastAutoSwitchOverrideTime = nil
                    routeFollowsDefaultApps(to: newDefaultUID)
                    let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? newDefaultUID
                    logger.info("Accepted user change to \(deviceName) (settled >1s)")
                    return
                }

                // Case 1: macOS auto-switched to the newly connected device — restore what
                // the user was on. Re-enter PENDING_AUTOSWITCH for further auto-switches.
                timeoutTask.cancel()
                restoreConfirmedDefault()
                lastAutoSwitchOverrideTime = Date()
                let transport = deviceMonitor.device(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.outputPriorityState = .stable
                    self.lastAutoSwitchOverrideTime = nil
                    self.logger.debug("Auto-switch grace period expired after override")
                }
                outputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }

            // Case 3: Genuine user intent (different device, not our echo) — respect it.
            timeoutTask.cancel()
            outputPriorityState = .stable
            lastAutoSwitchOverrideTime = nil
        }

        // Suppress echo from our own priority-based override (when not in pendingAutoSwitch)
        if outputEchoTracker.consume(newDefaultUID) {
            return
        }

        // If any echo counter is pending, another override is in flight — skip interim routing
        if outputEchoTracker.hasPending {
            logger.debug("Skipping followsDefault routing — echo pending")
            return
        }

        // Check if the new default device is known and alive.
        guard let newDevice = deviceMonitor.device(for: newDefaultUID) else {
            // Device not yet in monitor's list (e.g., BT device default-changed before device-list
            // notification). Defer — the upcoming handleDeviceConnected will enforce priority.
            logger.debug("Default changed to unknown device \(newDefaultUID), deferring to device list refresh")
            return
        }

        let newDeviceIsAlive = isAliveCheck(newDevice.id)

        if !newDeviceIsAlive {
            // Dead device became default (race with disconnect) — override to priority fallback
            reEvaluateOutputDefault()
        } else {
            // Genuine change to a live device — route followsDefault apps
            lastConfirmedDefaultUID = newDefaultUID
            routeFollowsDefaultApps(to: newDefaultUID)

            let affectedApps = apps.filter { followsDefault.contains($0.id) }
            if !affectedApps.isEmpty {
                let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? "Default Output"
                logger.info("Default changed to \(deviceName), \(affectedApps.count) app(s) following")
                if settingsManager.appSettings.showDeviceDisconnectAlerts {
                    showDefaultChangedNotification(newDeviceName: deviceName, affectedApps: affectedApps)
                }
            }
        }
    }

    private func showDefaultChangedNotification(newDeviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Default Audio Device Changed"
        content.body = "\(affectedApps.count) app(s) switched to \"\(newDeviceName)\""
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "default-device-changed",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the preferred tap source device UID for stream-specific capture.
    /// Only follows-default apps use stream-specific taps (multichannel preserved, tap always
    /// valid because the app switches device when default changes). Explicitly-routed apps
    /// always use stereo mixdown (nil) — their tap never goes stale when the default changes.
    private func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String], isFollowsDefault: Bool) -> String? {
        guard isFollowsDefault else { return nil }
        guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else { return nil }
        return outputUIDs.contains(defaultUID) ? defaultUID : nil
    }

    private func cleanupStaleTaps() {
        let activePIDs = Set(apps.filter(shouldKeepTap(for:)).map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel cleanup for PIDs that reappeared — but only if bundleID matches.
        // PID reuse by a different app should not rescue the old tap.

        for pid in activePIDs {
            guard let task = pendingCleanup[pid] else { continue }

            let reappearedApp = apps.first { $0.id == pid }
            let existingTap = taps[pid]

            if let reappearedApp, let existingTap,
               reappearedApp.bundleID != existingTap.app.bundleID {
                // PID was reused by a different app — let the old tap be destroyed
                logger.debug("PID \(pid) reused by different app (\(reappearedApp.bundleID ?? "nil") vs \(existingTap.app.bundleID ?? "nil")), not cancelling cleanup")
                continue
            }

            pendingCleanup.removeValue(forKey: pid)
            task.cancel()
            // Don't remove from appliedPIDs — the tap is still alive and the aggregate
            // device is still running. The process just transiently stopped audio I/O
            // during a device change (kAudioProcessPropertyIsRunning flicker).
            // Device routing is already handled by routeFollowsDefaultApps (follows-default)
            // or stays put (explicit routing). Re-processing would cause an unnecessary
            // crossfade that interrupts audio.
            logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }

                // Double-check still stale
                let currentPIDs = Set(
                    self.apps.filter(self.shouldKeepTap(for:)).map { $0.id }
                )
                guard !currentPIDs.contains(pid) else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.debug("Cleaned up stale tap for PID \(pid)")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.followsDefault.remove(pid)
                self.appRouteLifecycles.removeValue(forKey: pid)
                self.tapMembershipRefreshTasks.removeValue(forKey: pid)?.cancel()
                self.appliedPIDs.remove(pid)  // Allow re-initialization if app resumes
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    private func shouldKeepTap(for app: AudioApp) -> Bool {
        app.processObjectIDs.contains { $0.readProcessIsRunning() }
            || settingsManager.hasSavedAudioConfiguration(
                for: app.persistenceIdentifier
            )
    }

    /// Debounced stale tap cleanup — coalesces rapid app-list changes into a single cleanup pass.
    private func scheduleStaleCleanup() {
        staleCleanupTask?.cancel()
        staleCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.cleanupStaleTaps()
        }
    }

    // MARK: - Tap Health Monitor

    /// Starts a periodic health check that recreates unresponsive taps.
    /// Checks every 2 seconds; after 3 consecutive misses (~6s), the tap is presumed dead.
    private func startHealthMonitor() {
        guard canCreateProcessTaps, healthMonitorTask == nil else { return }
        healthMonitorTask = Task { @MainActor [weak self] in
            var consecutiveMisses: [pid_t: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }

                // Skip entirely when no taps exist — avoids unnecessary work at idle (#176)
                guard !self.taps.isEmpty else { continue }

                let now = Date()

                for (pid, tap) in self.taps {
                    // Skip muted apps — no callbacks while muted isn't a health signal
                    guard !tap.isMuted else { continue }

                    // Skip PIDs in recovery cooldown to prevent recreation thrashing
                    if let cooldownEnd = self.tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                        continue
                    }

                    guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

                    // Only health-check apps that are actively streaming.
                    let isActivelyStreaming = self.apps.first { $0.id == pid }?
                        .processObjectIDs.contains { $0.readProcessIsRunning() } ?? false
                    guard isActivelyStreaming else {
                        consecutiveMisses[pid] = 0
                        continue
                    }

                    if tap.hasRecentAudioCallback(within: 3.0) {
                        consecutiveMisses[pid] = 0
                    } else {
                        let misses = (consecutiveMisses[pid] ?? 0) + 1
                        consecutiveMisses[pid] = misses

                        if misses >= 3 {
                            self.logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                            consecutiveMisses[pid] = 0
                            await self.recreateTap(for: pid)
                        }
                    }
                }

                // Prune entries for PIDs no longer tracked
                consecutiveMisses = consecutiveMisses.filter { self.taps[$0.key] != nil }
                self.tapRecoveryCooldownUntil = self.tapRecoveryCooldownUntil.filter { self.taps[$0.key] != nil }
            }
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    private func recreateTap(for pid: pid_t) async {
        guard canCreateProcessTaps else { return }
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        let deviceUIDs = oldTap.currentDeviceUIDs
        _ = await oldTap.invalidateAsync()

        // Set cooldown to prevent thrashing
        tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(20)

        // Find the current AudioApp entry for this PID
        guard canCreateProcessTaps,
              let app = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Re-route to the same device(s), preserving multi-device routing
        if deviceUIDs.count > 1 {
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
            if taps[app.id] != nil {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else if let deviceUID = deviceUIDs.first {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Mark as applied to avoid redundant re-processing in applyPersistedSettings
        if taps[pid] != nil {
            appliedPIDs.insert(pid)
        }

        // Restore mute state
        if let muted = volumeState.loadSavedMute(for: pid, identifier: app.persistenceIdentifier), muted {
            taps[pid]?.isMuted = true
        }
    }

    /// Recreates the aggregate at the device's new rate for every tap on a BT output that changed
    /// sample rate (A2DP↔SCO), so each tap's IOProc re-rates to match. Falls back to a full tap
    /// recreate if the in-controller recreation throws.
    private func handleBTDeviceSampleRateChanged(uid: String, newRate: Double) async {
        guard canCreateProcessTaps else { return }
        logger.info("[RATE] BT output \(uid, privacy: .public) → \(newRate, format: .fixed(precision: 0)) Hz — recreating affected taps (clean dip)")
        let affected = taps.filter { $0.value.currentDeviceUIDs.contains(uid) }
        for (pid, tap) in affected {
            do {
                logger.info("[RATE] Recreating tap for PID \(pid)")
                try await tap.recreateForOutputRateChange()
            } catch {
                logger.error("[RATE] Recreate failed for PID \(pid): \(error.localizedDescription) — falling back to full recreate")
                await recreateTap(for: pid)
            }
        }
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses state machine to distinguish auto-switch (from device connection) vs user action.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after input device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = inputPriorityState {
            if newDefaultInputUID == pendingUID, settingsManager.appSettings.lockInputDevice {
                // Case 1: macOS auto-switched to the newly connected device — restore locked device.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times.
                timeoutTask.cancel()
                restoreLockedInputDevice()
                let transport = deviceMonitor.inputDevice(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.inputPriorityState = .stable
                    self.logger.debug("Input auto-switch grace period expired after override")
                }
                inputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }
            // Case 2: Our own echo from the override. Consume without disrupting state machine.
            if inputEchoTracker.consume(newDefaultInputUID) {
                return
            }
            // Case 3: Genuine user intent — respect it.
            timeoutTask.cancel()
            inputPriorityState = .stable
        }

        // Suppress echo from our own input device override (when not in pendingAutoSwitch)
        if inputEchoTracker.consume(newDefaultInputUID) {
            return
        }

        // If any input echo counter is pending, skip routing
        if inputEchoTracker.hasPending {
            logger.debug("Skipping input routing — echo pending")
            return
        }

        // If lock is disabled, let system control input freely
        guard settingsManager.appSettings.lockInputDevice else { return }

        // Restore the locked device — any change outside Semper's UI is either
        // macOS auto-switch or System Settings, and the lock should hold either way.
        // Users change the lock via Semper's UI (setLockedInputDevice).
        guard let lockedUID = settingsManager.lockedInputDeviceUID else { return }
        if newDefaultInputUID != lockedUID {
            restoreLockedInputDevice()
        }
    }

    /// Restores the locked input device, or falls back to built-in mic if unavailable.
    private func restoreLockedInputDevice() {
        guard let lockedUID = settingsManager.lockedInputDeviceUID,
              let lockedDevice = deviceMonitor.inputDevice(for: lockedUID) else {
            // No locked device or it's unavailable - fall back to built-in
            lockToBuiltInMicrophone()
            return
        }

        // Don't restore if already on the locked device
        guard deviceVolumeMonitor.defaultInputDeviceUID != lockedUID else { return }

        logger.info("Restoring locked input device: \(lockedDevice.name)")
        if deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id) {
            inputEchoTracker.increment(lockedDevice.uid)
        }
    }

    /// Locks the input device to the built-in microphone.
    /// This is a fallback — does NOT update preferredInputDeviceUID.
    private func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        applyInputDeviceLock(builtInMic)
    }

    /// Applies input device lock without changing the user's preferred device.
    /// Used for fallback scenarios (disconnect, built-in mic recovery).
    private func applyInputDeviceLock(_ device: AudioDevice) {
        logger.info("Locking input device to: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when the user toggles lockInputDevice ON in settings.
    /// Captures the current default input device as the locked and preferred device.
    func handleInputLockEnabled() {
        guard let currentUID = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = deviceMonitor.inputDevice(for: currentUID) else {
            return
        }
        logger.info("Input lock enabled, locking to current default: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)
    }

    /// Called when user explicitly selects an input device (via Semper UI).
    /// Persists the choice and applies the change.
    @discardableResult
    func setLockedInputDevice(_ device: AudioDevice) -> Bool {
        logger.info("User locked input device to: \(device.name)")

        guard deviceVolumeMonitor.setDefaultInputDevice(device.id) else { return false }
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)
        inputEchoTracker.increment(device.uid)
        return true
    }

    @discardableResult
    func setTemporaryInputDevice(_ device: AudioDevice) -> Bool {
        let success = deviceVolumeMonitor.setDefaultInputDevice(device.id)
        if success {
            inputEchoTracker.increment(device.uid)
        }
        return success
    }

    /// Called when an input device connects — restores locked/preferred device and guards against auto-switch.
    private func handleInputDeviceConnected(_ deviceUID: String, name deviceName: String) {
        guard settingsManager.appSettings.lockInputDevice else { return }

        // If the reconnected device is the user's preferred device, restore the lock to it
        if let preferredUID = settingsManager.preferredInputDeviceUID,
           deviceUID == preferredUID,
           settingsManager.lockedInputDeviceUID != preferredUID,
           let device = deviceMonitor.inputDevice(for: deviceUID) {
            logger.info("Preferred input device reconnected: \(deviceName), restoring lock")
            settingsManager.setLockedInputDeviceUID(device.uid)
        }

        // Restore the user's locked device (not priority-based — lock overrides priority)
        restoreLockedInputDevice()

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one
        if case .pendingAutoSwitch(_, let oldTask) = inputPriorityState {
            oldTask.cancel()
        }

        // Always enter PENDING_AUTOSWITCH — macOS may auto-switch to the newly connected
        // device multiple times during BT handshake, even if we just restored the lock.
        let transport = deviceMonitor.inputDevice(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.inputPriorityState = .stable
            self.logger.debug("Input auto-switch grace period expired, no macOS switch detected")
        }

        inputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
    }

    /// Handles input device disconnect — uses priority fallback, then built-in mic.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = inputPriorityState, uid == deviceUID {
            task.cancel()
            inputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultInput = deviceUID == deviceVolumeMonitor.defaultInputDeviceUID

        let priorityFallback = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }

        // If the locked device disconnected, update the lock to the fallback (or built-in mic)
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        if let fallbackDevice = priorityFallback {
            logger.info("Locked input device disconnected, falling back to priority: \(fallbackDevice.name)")
            if wasDefaultInput {
                // Default already switched above, just update the lock setting
                settingsManager.setLockedInputDeviceUID(fallbackDevice.uid)
            } else {
                applyInputDeviceLock(fallbackDevice)
            }
        } else {
            logger.info("Locked input device disconnected, falling back to built-in mic")
            lockToBuiltInMicrophone()
        }
    }
}

// MARK: - URLHandlerEngine Conformance

extension AudioEngine: URLHandlerEngine {}
