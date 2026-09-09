import AppKit
import Foundation

enum SoundRuntimeShutdownError: LocalizedError {
    case audioResourceCleanup
    case alertVolumeRestoration

    var errorDescription: String? {
        switch self {
        case .audioResourceCleanup:
            "Sound could not release every audio resource. Quit Semper before starting Sound again."
        case .alertVolumeRestoration:
            "Sound could not apply the last alert-volume setting. Retry Stop to try it again."
        }
    }
}

@MainActor
final class SoundRuntime {
    let audioEngine: AudioEngine
    let deviceVolumeMonitor: DeviceVolumeMonitor
    let audioCommands: AudioCommandDispatcher
    let audioActivityStore: AudioActivityStore
    let callMode: CallModeCoordinator
    let bluetoothHDGuard: BluetoothHDGuardCoordinator
    let accessibility: AccessibilityPermissionService
    let mediaKeyStatus: MediaKeyStatus
    let popupVisibility: PopupVisibilityService
    let hudController: HUDWindowController
    let mediaKeyMonitor: MediaKeyMonitor
    let feedbackPlayer: VolumeFeedbackPlayer
    let iconCoordinator: MenuBarIconCoordinator
    let menuBarPopupController: MenuBarPopupController
    let shortcutsRegistry: ShortcutsRegistry
    let resolver: TargetAppResolver
    let launchIconImage: NSImage
    private let appShortcutController: AppShortcutController
    private var startupTask: Task<Void, Never>?
    private var alertVolumeRestorationTask: Task<Bool, Never>?
    private var shutdownDrainFailed = false
    private var userEntryPointsStopped = false
    private(set) var isShutDown = false

    init(
        settings: SettingsManager,
        sharedDDCController: AudioEngine.SharedDDCController? = nil
    ) {
        CrashGuard.install()
        let startupCleanup = OrphanedTapCleanup.destroyOrphanedDevices()
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: profileManager,
            initialCleanupResult: startupCleanup,
            sharedDDCController: sharedDDCController
        )
        guard let deviceVolumeMonitor = engine.deviceVolumeMonitor as? DeviceVolumeMonitor else {
            preconditionFailure("SoundRuntime requires the production device volume monitor")
        }
        let activityStore = AudioActivityStore()
        let commandDispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: engine),
            activityStore: activityStore
        )
        engine.onCommandValueObserved = { [weak commandDispatcher] key, value in
            commandDispatcher?.completeAccepted(key, observed: value)
        }
        engine.onCommandWriteRejected = { [weak commandDispatcher] key in
            commandDispatcher?.rejectAccepted(key)
        }
        let callMode = CallModeCoordinator(
            settings: settings,
            overlayStore: engine.modeOverlayStore,
            activityStore: activityStore,
            currentInputDeviceUID: { [weak engine] in
                engine?.deviceVolumeMonitor.defaultInputDeviceUID
            },
            claimInputDevice: { [weak engine] deviceUID in
                engine?.setInputPolicyRequest(deviceUID: deviceUID, owner: .callMode) ?? false
            },
            releaseInputDevice: { [weak engine] in
                engine?.removeInputPolicyRequest(owner: .callMode)
            },
            readAlertVolume: { [weak engine] in
                engine?.deviceVolumeMonitor.alertVolume ?? 1
            },
            writeAlertVolume: { [weak engine] volume in
                engine?.deviceVolumeMonitor.setAlertVolume(volume)
            }
        )
        engine.onCallModeActivitiesChanged = { [weak callMode] activities in
            callMode?.handleActivities(activities)
        }
        let appShortcutController = AppShortcutController(
            engine: engine,
            commands: commandDispatcher,
            callMode: callMode
        )
        SemperAppIntentRuntime.install(appShortcutController)
        let bluetoothHDGuard = BluetoothHDGuardCoordinator(
            settings: settings,
            activityStore: activityStore,
            claimInputDevice: { [weak engine] deviceUID in
                engine?.setInputPolicyRequest(deviceUID: deviceUID, owner: .bluetoothGuard) ?? false
            },
            releaseInputDevice: { [weak engine] originalUID, protectedUID, restoreOriginal in
                engine?.releaseBluetoothHDGuard(
                    originalUID: originalUID,
                    protectedUID: protectedUID,
                    restoreOriginal: restoreOriginal
                )
            }
        )
        engine.onBluetoothHDGuardSnapshotChanged = { [weak bluetoothHDGuard] snapshot in
            bluetoothHDGuard?.handleSnapshot(snapshot)
        }
        engine.onExplicitInputDeviceSelected = { [weak bluetoothHDGuard] deviceUID in
            bluetoothHDGuard?.handleExplicitInputSelection(deviceUID)
        }
        engine.onAudioProcessingWillStop = { [weak callMode, weak bluetoothHDGuard] in
            callMode?.shutdown()
            bluetoothHDGuard?.shutdown()
        }

        let accessibilityService = AccessibilityPermissionService()
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(
            settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)
        let feedbackPlayer = VolumeFeedbackPlayer()

        hud.volumeWriter = { [weak engine, commandDispatcher] sliderFraction in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            let deviceID = volumeMonitor.defaultDeviceID
            guard deviceID.isValid else { return }
            let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
            let currentMute = volumeMonitor.muteStates[deviceID] ?? false
            guard
                let deviceUID = volumeMonitor.defaultDeviceUID
                    ?? engine.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid
            else {
                return
            }
            let willBeSilent = sliderFraction <= 0.001
            let transactionID = UUID()
            let context = AudioCommandContext(
                source: .hud,
                transactionID: transactionID
            )
            if currentMute && !willBeSilent {
                commandDispatcher.dispatch(
                    .setOutputMute(deviceUID: deviceUID, muted: false),
                    context: context
                )
            } else if !currentMute && willBeSilent {
                commandDispatcher.dispatch(
                    .setOutputMute(deviceUID: deviceUID, muted: true),
                    context: context
                )
            }
            let gain = VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: tier)
            commandDispatcher.dispatch(
                .setOutputVolume(deviceUID: deviceUID, volume: gain),
                context: context
            )
            feedbackPlayer.requestFeedback(
                gain: VolumeFeedback.gain(tier: tier, sliderFraction: sliderFraction)
            )
        }

        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            audioCommands: commandDispatcher,
            settingsManager: settings,
            accessibility: accessibilityService,
            hudController: hud,
            popupVisibility: popupService,
            mediaKeyStatus: statusService
        )
        monitor.feedbackPlayer = feedbackPlayer

        let coordinator = MenuBarIconCoordinator(
            deviceVolumeMonitor: deviceVolumeMonitor,
            deviceProvider: engine.deviceMonitor,
            settings: settings
        )
        monitor.iconCoordinator = coordinator

        let launchVolumeMonitor = engine.deviceVolumeMonitor
        let launchID = launchVolumeMonitor.defaultDeviceID
        let launchState = MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false,
            deviceSymbol: MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: settings.devicePriorityOrder,
                outputDevices: engine.deviceMonitor.outputDevices,
                defaultDeviceID: launchID,
                overrideForUID: { settings.getDeviceIconOverride(for: $0) }
            )
        )
        launchIconImage =
            launchState.image.nsImage()
            ?? MenuBarIconImage.systemSymbol("speaker.wave.2").nsImage()!

        accessibilityService.onTrustChanged = { [weak monitor] _ in
            monitor?.reconcile()
        }
        accessibilityService.start()
        monitor.reconcile()

        let popupController = MenuBarPopupController()
        let resolver = TargetAppResolver(
            ownBundleID: Bundle.main.bundleIdentifier ?? "systems.semper.Semper",
            preferenceProvider: { [settings] in
                ShortcutTargetPreference(
                    mode: settings.appSettings.shortcutTargetMode,
                    selectedBundleID: settings.appSettings.selectedShortcutTargetBundleID
                )
            }
        )
        resolver.start()
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: popupController,
            resolver: resolver,
            audioEngine: engine,
            audioCommands: commandDispatcher,
            hud: hud
        )

        self.audioEngine = engine
        self.deviceVolumeMonitor = deviceVolumeMonitor
        self.audioCommands = commandDispatcher
        self.audioActivityStore = activityStore
        self.callMode = callMode
        self.bluetoothHDGuard = bluetoothHDGuard
        self.accessibility = accessibilityService
        self.mediaKeyStatus = statusService
        self.popupVisibility = popupService
        self.hudController = hud
        self.mediaKeyMonitor = monitor
        self.feedbackPlayer = feedbackPlayer
        self.iconCoordinator = coordinator
        self.menuBarPopupController = popupController
        self.shortcutsRegistry = registry
        self.resolver = resolver
        self.appShortcutController = appShortcutController
        startupTask = Task { @MainActor [weak self] in
            guard let self, !self.isShutDown, !self.userEntryPointsStopped else { return }
            self.iconCoordinator.start()
            self.shortcutsRegistry.start()
        }
    }

    func stopUserEntryPoints() {
        guard !userEntryPointsStopped else { return }
        userEntryPointsStopped = true
        startupTask?.cancel()
        startupTask = nil
        SemperAppIntentRuntime.uninstall(appShortcutController)
        shortcutsRegistry.stop()
        resolver.stop()
        iconCoordinator.stop()
        accessibility.onTrustChanged = nil
        accessibility.stop()
        mediaKeyMonitor.shutdown()
        hudController.volumeWriter = nil
        hudController.shutdown()
        feedbackPlayer.shutdown()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        stopUserEntryPoints()
        audioEngine.onCallModeActivitiesChanged = nil
        callMode.handleActivities([])
        // An accepted alert edit remains an obligation after its Call Mode session ends.
        alertVolumeRestorationTask = deviceVolumeMonitor.flushAlertVolumeWrite(
            preservingPendingWrite: true,
            producedBy: callMode.shutdown
        )
        bluetoothHDGuard.shutdown()
        audioEngine.shutdown()
        audioCommands.shutdown()
        audioEngine.permission.shutdown()
    }

    func shutdownAndDrain() async throws {
        let retryAlertWrite = shutdownDrainFailed
        shutdown()
        await audioEngine.shutdownAndDrain()
        let alertWritesDrained = await deviceVolumeMonitor.drainAlertVolumeWrites()
        guard audioEngine.shutdownCleanupResult.failureCount == 0, alertWritesDrained else {
            shutdownDrainFailed = true
            throw SoundRuntimeShutdownError.audioResourceCleanup
        }
        if retryAlertWrite, let retry = deviceVolumeMonitor.retryFailedAlertVolumeWrite() {
            alertVolumeRestorationTask = retry
            _ = await retry.value
            guard await deviceVolumeMonitor.drainAlertVolumeWrites() else {
                shutdownDrainFailed = true
                throw SoundRuntimeShutdownError.audioResourceCleanup
            }
        }
        if await alertVolumeRestorationTask?.value == false {
            shutdownDrainFailed = true
            throw SoundRuntimeShutdownError.alertVolumeRestoration
        }
        shutdownDrainFailed = false
    }
}
