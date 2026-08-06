// Semper/SemperApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import AppKit
import os

private let logger = Logger(subsystem: "systems.semper.Semper", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var audioEngine: AudioEngine?
    var audioCommands: (any AudioCommandDispatching)?
    var updateManager: UpdateManager?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine, let audioCommands, let updateManager else {
            return
        }
        let urlHandler = URLHandler(
            audioEngine: audioEngine,
            audioCommands: audioCommands,
            checkForUpdates: updateManager.checkForUpdates
        )

        for url in urls {
            urlHandler.handleURL(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// LSUIElement agent — closing the Settings window must not terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SemperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @State private var audioCommands: AudioCommandDispatcher
    @State private var audioActivityStore: AudioActivityStore
    @State private var callMode: CallModeCoordinator
    @State private var bluetoothHDGuard: BluetoothHDGuardCoordinator
    @State private var accessibility: AccessibilityPermissionService
    @State private var mediaKeyStatus: MediaKeyStatus
    @State private var popupVisibility: PopupVisibilityService
    @State private var hudController: HUDWindowController
    @State private var mediaKeyMonitor: MediaKeyMonitor
    @State private var feedbackPlayer: VolumeFeedbackPlayer
    @State private var iconCoordinator: MenuBarIconCoordinator
    @State private var menuBarPopupController: MenuBarPopupController
    @State private var shortcutsRegistry: ShortcutsRegistry
    @State private var resolver: TargetAppResolver
    @State private var experimentManager: ExperimentManager
    @StateObject private var updateManager: UpdateManager
    @State private var showMenuBarExtra = true

    /// Snapshot icon computed at launch from the user's chosen style and the current
    /// default-device volume/mute. The coordinator keeps it in sync afterwards.
    private let launchIconImage: NSImage

    var body: some Scene {
        // Declared before FluidMenuBarExtra so this Settings scene wins over
        // FluidMenuBarExtra's `Settings {}` placeholder. Both ⌘, and the
        // gear button route here via openSettings().
        Settings {
            SettingsRootView(
                settings: audioEngine.settingsManager,
                audioEngine: audioEngine,
                audioCommands: audioCommands,
                callMode: callMode,
                bluetoothHDGuard: bluetoothHDGuard,
                deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry,
                updateManager: updateManager
            )
        }
        FluidMenuBarExtra("Semper", image: launchIconImage, isInserted: $showMenuBarExtra) {
            menuBarContent
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        // `deviceVolumeMonitor` is declared as `any DeviceVolumeProviding` on
        // AudioEngine so tests can inject mocks; in production it's always the
        // concrete `DeviceVolumeMonitor` that this view consumes directly.
        MenuBarPopupView(
            audioEngine: audioEngine,
            audioCommands: audioCommands,
            audioActivityStore: audioActivityStore,
            callMode: callMode,
            bluetoothHDGuard: bluetoothHDGuard,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
            updateManager: updateManager,
            permission: audioEngine.permission,
            accessibility: accessibility,
            mediaKeyStatus: mediaKeyStatus,
            popupVisibility: popupVisibility,
            hudController: hudController,
            mediaKeyMonitor: mediaKeyMonitor,
            experimentManager: experimentManager
        )
        .task {
            // Idempotent: subsequent task runs (popup re-open) are no-ops inside start().
            shortcutsRegistry.start()
        }
    }

    init() {
        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        let startupCleanup = OrphanedTapCleanup.destroyOrphanedDevices()

        let settings = SettingsManager(managesLaunchAtLogin: true)
        let updater = UpdateManager()
        _updateManager = StateObject(wrappedValue: updater)
        _experimentManager = State(initialValue: ExperimentManager())
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: profileManager,
            initialCleanupResult: startupCleanup
        )
        _audioEngine = State(initialValue: engine)
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
        _audioCommands = State(initialValue: commandDispatcher)
        _audioActivityStore = State(initialValue: activityStore)
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
        _callMode = State(initialValue: callMode)
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
        _bluetoothHDGuard = State(initialValue: bluetoothHDGuard)

        // Media keys / HUD services — instantiated at app scope so the tap
        // and HUD panel outlive popup open/close cycles.
        let accessibilityService = AccessibilityPermissionService()
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)
        let feedbackPlayer = VolumeFeedbackPlayer()

        // Wire the interactive Tahoe slider back to the device volume monitor.
        // Mirrors the mute semantics applied for media-key drags (auto-unmute
        // when ramping above 0 from muted; auto-mute when dragging down to 0)
        // so the HUD slider and F11/F12 behave identically.
        hud.volumeWriter = { [weak engine, commandDispatcher] sliderFraction in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            let deviceID = volumeMonitor.defaultDeviceID
            guard deviceID.isValid else { return }
            let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
            let currentMute = volumeMonitor.muteStates[deviceID] ?? false
            guard let deviceUID = volumeMonitor.defaultDeviceUID
                ?? engine.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else {
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
        _accessibility = State(initialValue: accessibilityService)
        _mediaKeyStatus = State(initialValue: statusService)
        _popupVisibility = State(initialValue: popupService)
        _hudController = State(initialValue: hud)
        _mediaKeyMonitor = State(initialValue: monitor)
        _feedbackPlayer = State(initialValue: feedbackPlayer)

        let coordinator = MenuBarIconCoordinator(
            deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor,
            deviceProvider: engine.deviceMonitor,
            settings: settings
        )
        monitor.iconCoordinator = coordinator
        // Defer start() so NSApplication.shared is fully bootstrapped before we walk NSApp.windows.
        DispatchQueue.main.async { [coordinator] in coordinator.start() }
        _iconCoordinator = State(initialValue: coordinator)

        // Render the scene's first frame with the user's chosen style instead of a generic
        // placeholder, so non-speaker styles don't briefly flash a speaker icon at launch.
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
        // The fallback must go through the shared canvas too, or the status
        // item launches at natural symbol width and jumps on the first apply().
        launchIconImage = launchState.image.nsImage()
            ?? MenuBarIconImage.systemSymbol("speaker.wave.2").nsImage()!

        // Start Accessibility polling immediately so `isTrustedCached` is live
        // before the user first opens Settings. The trust-flip callback wires
        // the monitor to reconcile its tap state whenever trust changes — this
        // is the single source of truth for retroactive start/stop (a `.onChange`
        // inside MenuBarPopupView would miss flips when the popup is closed).
        accessibilityService.onTrustChanged = { [weak monitor] _ in
            monitor?.reconcile()
        }
        accessibilityService.start()
        monitor.reconcile()

        // Global hotkeys (KeyboardShortcuts SPM, Carbon-backed; no Accessibility
        // permission required for the hotkey itself). Registry start() is deferred
        // to a SwiftUI `.task` on the popup content so the FluidMenuBarExtra
        // status item has been materialized before any hotkey can fire.
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
        _menuBarPopupController = State(initialValue: popupController)
        _shortcutsRegistry = State(initialValue: registry)
        _resolver = State(initialValue: resolver)

        // Pass URL action dependencies to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine
        _appDelegate.wrappedValue.audioCommands = commandDispatcher
        _appDelegate.wrappedValue.updateManager = updater

        if permission.status == .unknown,
           settings.audioProcessingMode != .bypassed {
            permission.request()
        }

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set delegate before requesting authorization so willPresent is called
        UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        // Flush debounced settings + tear down the CGEventTap before dealloc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings, engine, callMode, bluetoothHDGuard, monitor, accessibilityService, hud, coordinator] _ in
            MainActor.assumeIsolated {
                coordinator.stop()
                monitor.stop()
                accessibilityService.stop()
                hud.shutdown()
                callMode.shutdown()
                bluetoothHDGuard.shutdown()
                engine.shutdown()
                settings.flushSync()
            }
        }
    }
}
