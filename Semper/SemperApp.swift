// Semper/SemperApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import AppKit
import CoreServices
import Darwin
import os

private let logger = Logger(subsystem: "systems.semper.Semper", category: "App")

@MainActor
protocol AwayTerminationHandling: AnyObject {
    var isGuarding: Bool { get }
    func requestQuit()
}

extension AwayModeCoordinator: AwayTerminationHandling {}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var audioEngine: AudioEngine?
    var audioCommands: (any AudioCommandDispatching)?
    var sceneCommands: (any SceneCommandHandling)?
    var updateManager: UpdateManager?
    weak var awayMode: (any AwayTerminationHandling)?
    var displayService: DisplayControlService?

    private let terminateApplication: @MainActor () -> Void
    private let isSystemTerminationRequest: @MainActor () -> Bool
    private let terminationDrainOverride: (@MainActor () async -> Void)?
    private let replyToTerminationRequest: @MainActor (NSApplication, Bool) -> Void
    private var permitsAuthenticatedTermination = false
    private var terminationDrainTask: Task<Void, Never>?
    private var isTerminationDrainComplete = false

    override init() {
        terminateApplication = { NSApp.terminate(nil) }
        isSystemTerminationRequest = Self.currentAppleEventIsSystemTermination
        terminationDrainOverride = nil
        replyToTerminationRequest = { application, shouldTerminate in
            application.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        super.init()
    }

    init(
        terminateApplication: @escaping @MainActor () -> Void,
        isSystemTerminationRequest: @escaping @MainActor () -> Bool = {
            AppDelegate.currentAppleEventIsSystemTermination()
        },
        terminationDrain: (@MainActor () async -> Void)? = nil,
        replyToTerminationRequest: @escaping @MainActor (NSApplication, Bool) -> Void = {
            application,
            shouldTerminate in
            application.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    ) {
        self.terminateApplication = terminateApplication
        self.isSystemTerminationRequest = isSystemTerminationRequest
        self.terminationDrainOverride = terminationDrain
        self.replyToTerminationRequest = replyToTerminationRequest
        super.init()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine, let audioCommands, let updateManager else {
            return
        }
        let urlHandler = URLHandler(
            audioEngine: audioEngine,
            audioCommands: audioCommands,
            sceneCommands: sceneCommands,
            allowsMutations: { [weak self] in self?.awayMode?.isGuarding != true },
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationDrainComplete else { return .terminateNow }
        guard terminationDrainTask == nil else { return .terminateLater }

        if permitsAuthenticatedTermination {
            permitsAuthenticatedTermination = false
        } else if !isSystemTerminationRequest(), awayMode?.isGuarding == true {
            awayMode?.requestQuit()
            return .terminateCancel
        }

        guard terminationDrainOverride != nil || displayService != nil else {
            return .terminateNow
        }
        terminationDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let terminationDrainOverride {
                await terminationDrainOverride()
            } else if let displayService {
                await displayService.stopAndDrain()
                #if !APP_STORE
                await audioEngine?.ddcController.stopAndDrain()
                #endif
            }
            isTerminationDrainComplete = true
            terminationDrainTask = nil
            replyToTerminationRequest(sender, true)
        }
        return .terminateLater
    }

    func permitTerminationAfterAwayAuthentication() {
        permitsAuthenticatedTermination = true
        terminateApplication()
    }

    private static func currentAppleEventIsSystemTermination() -> Bool {
        guard let reason = NSAppleEventManager.shared()
            .currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
            .enumCodeValue else {
            return false
        }
        return isSystemTerminationReason(reason)
    }

    static func isSystemTerminationReason(_ reason: OSType?) -> Bool {
        guard let reason else { return false }
        return [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains(reason)
    }
}

@main
struct SemperApp: App {
    private let instanceLock: AppInstanceLock
    #if DEBUG
    private let awayUITestSupport: AwayUITestSupport?
    #endif
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
    @State private var awakeService: AwakeService
    @State private var displayService: DisplayControlService
    @State private var sceneManager: SceneManager
    @State private var sceneShortcutRegistry: SceneShortcutRegistry
    @State private var awayMode: AwayModeCoordinator
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
                sceneManager: sceneManager,
                sceneShortcutRegistry: sceneShortcutRegistry,
                awayMode: awayMode,
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
            experimentManager: experimentManager,
            sceneManager: sceneManager,
            displayService: displayService,
            awakeService: awakeService,
            awayMode: awayMode
        )
        .task {
            // Idempotent: subsequent task runs (popup re-open) are no-ops inside start().
            shortcutsRegistry.start()
            sceneShortcutRegistry.start()
            await sceneManager.prepare()
        }
    }

    init() {
        #if DEBUG
        let uiTestSupport = AwayUITestSupport.current()
        awayUITestSupport = uiTestSupport
        let isXCTestHost = uiTestSupport == nil
            && (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil)
        let testHostDirectory = isXCTestHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent(
                "Semper-XCTestHost-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            : nil
        #endif

        do {
            #if DEBUG
            let lockAcquisition = try uiTestSupport.map {
                try AppInstanceLock.acquire(in: $0.settingsDirectory)
            } ?? testHostDirectory.map {
                try AppInstanceLock.acquire(in: $0)
            } ?? AppInstanceLock.acquire()
            #else
            let lockAcquisition = try AppInstanceLock.acquire()
            #endif
            switch lockAcquisition {
            case .acquired(let instanceLock):
                self.instanceLock = instanceLock
            case .alreadyRunning:
                let bundleIdentifier = Bundle.main.bundleIdentifier ?? "systems.semper.Semper"
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                    .activate(options: [.activateAllWindows])
                exit(EXIT_SUCCESS)
            }
        } catch {
            logger.fault("Semper could not acquire its process lock: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }

        // Install crash handler to clean up aggregate devices on abnormal exit
        #if DEBUG
        if !isXCTestHost {
            CrashGuard.install()
        }
        #else
        CrashGuard.install()
        #endif
        // Destroy any orphaned aggregate devices from previous crashes
        #if DEBUG
        let startupCleanup = uiTestSupport == nil && !isXCTestHost
            ? OrphanedTapCleanup.destroyOrphanedDevices()
            : OrphanedTapCleanupResult.empty
        let settings = uiTestSupport.map {
            SettingsManager(directory: $0.settingsDirectory)
        } ?? testHostDirectory.map {
            SettingsManager(directory: $0)
        } ?? SettingsManager(managesLaunchAtLogin: true)
        uiTestSupport?.prepare(settings)
        #else
        let startupCleanup = OrphanedTapCleanup.destroyOrphanedDevices()
        let settings = SettingsManager(managesLaunchAtLogin: true)
        #endif
        let updater = UpdateManager()
        _updateManager = StateObject(wrappedValue: updater)
        _experimentManager = State(initialValue: ExperimentManager())
        #if DEBUG
        let awake = uiTestSupport?.awakeService
            ?? AwakeService(backend: IOPMPowerAssertionBackend())
        #else
        let awake = AwakeService(backend: IOPMPowerAssertionBackend())
        #endif
        _awakeService = State(initialValue: awake)
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: profileManager,
            initialCleanupResult: startupCleanup,
            startMonitorsAutomatically: {
                #if DEBUG
                uiTestSupport == nil && !isXCTestHost
                #else
                true
                #endif
            }()
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
        let mutationAdmission = MutationAdmissionGate()
        #if !APP_STORE
        precondition(engine.ddcController.installMutationAdmission(mutationAdmission))
        let displayService = DisplayControlService(
            ddcController: engine.ddcController,
            mutationAdmission: mutationAdmission
        )
        #else
        let displayService = DisplayControlService()
        #endif
        displayService.start()
        #if DEBUG
        let away = uiTestSupport?.makeCoordinator(
            settings: settings,
            mutationAdmission: mutationAdmission
        ) ?? AwayModeCoordinator(
            settings: settings,
            awakeServiceProvider: { awake },
            mutationAdmission: mutationAdmission
        )
        #else
        let away = AwayModeCoordinator(
            settings: settings,
            awakeServiceProvider: { awake },
            mutationAdmission: mutationAdmission
        )
        #endif
        _awayMode = State(initialValue: away)
        let sceneManager = SceneManager(
            engine: engine,
            commands: commandDispatcher,
            awake: awake,
            displays: displayService,
            mutationAdmission: mutationAdmission
        )
        let sceneShortcutRegistry = SceneShortcutRegistry(
            settings: settings,
            sceneManager: sceneManager,
            allowsShortcuts: { [weak away] in away?.blocksOrdinaryShortcuts != true }
        )
        sceneManager.onScenesChanged = { [weak sceneShortcutRegistry] in
            sceneShortcutRegistry?.sync()
        }
        _displayService = State(initialValue: displayService)
        _sceneManager = State(initialValue: sceneManager)
        _sceneShortcutRegistry = State(initialValue: sceneShortcutRegistry)
        SemperSceneAppIntentRuntime.install(sceneManager)
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
        SemperAppIntentRuntime.install(
            AppShortcutController(
                engine: engine,
                commands: commandDispatcher,
                callMode: callMode,
                allowsMutations: { [weak away] in away?.isGuarding != true }
            )
        )
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
        #if DEBUG
        if uiTestSupport == nil {
            DispatchQueue.main.async { [coordinator] in coordinator.start() }
        }
        #else
        DispatchQueue.main.async { [coordinator] in coordinator.start() }
        #endif
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
        #if DEBUG
        if uiTestSupport == nil {
            accessibilityService.start()
            monitor.reconcile()
        }
        #else
        accessibilityService.start()
        monitor.reconcile()
        #endif

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
        #if DEBUG
        if uiTestSupport == nil {
            resolver.start()
        }
        #else
        resolver.start()
        #endif
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: popupController,
            resolver: resolver,
            audioEngine: engine,
            audioCommands: commandDispatcher,
            hud: hud,
            awayHandler: away
        )
        registry.onShortcutsChanged = { [weak sceneShortcutRegistry] in
            sceneShortcutRegistry?.sync()
        }

        popupController.isPresentationAllowed = { [weak away] in
            away?.isGuarding != true
        }
        hud.isSuppressed = { [weak away] in
            away?.isGuarding == true
        }
        monitor.isInputSuppressed = { [weak away] in
            away?.isGuarding == true
        }
        updater.shouldDeferRelaunch = { [weak away] in
            away?.isGuarding == true
        }
        away.onWillGuard = { [weak popupController, weak hud] in
            popupController?.dismiss()
            hud?.hide()
        }
        away.onDidDisarm = { [weak updater] in
            updater?.resumeDeferredInstallation()
        }
        away.makeCurtainContent = { [weak away] screen, isPrimary in
            guard let away else {
                throw AwayWindowFailure.contentCreationFailed
            }
            return NSHostingView(
                rootView: AwayCurtainView(
                    coordinator: away,
                    screen: screen,
                    isPrimary: isPrimary
                )
            )
        }
        #if DEBUG
        if let uiTestSupport {
            DispatchQueue.main.async { [uiTestSupport, away] in
                uiTestSupport.showHostWindow(coordinator: away)
            }
        }
        #endif
        _menuBarPopupController = State(initialValue: popupController)
        _shortcutsRegistry = State(initialValue: registry)
        _resolver = State(initialValue: resolver)

        // Pass URL action dependencies to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine
        _appDelegate.wrappedValue.audioCommands = commandDispatcher
        _appDelegate.wrappedValue.sceneCommands = sceneManager
        _appDelegate.wrappedValue.updateManager = updater
        _appDelegate.wrappedValue.awayMode = away
        _appDelegate.wrappedValue.displayService = displayService
        away.onAuthenticatedQuit = { [weak delegate = _appDelegate.wrappedValue] in
            delegate?.permitTerminationAfterAwayAuthentication()
        }

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set delegate before requesting authorization so willPresent is called
        UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue

        // Request notification authorization (for device disconnect alerts)
        #if DEBUG
        if uiTestSupport == nil && !isXCTestHost {
            requestNotificationAuthorization()
        }
        #else
        requestNotificationAuthorization()
        #endif

        func requestNotificationAuthorization() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
                if let error {
                    logger.error("Notification authorization error: \(error.localizedDescription)")
                }
            }
        }

        // Flush debounced settings + tear down the CGEventTap before dealloc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings, engine, callMode, bluetoothHDGuard, monitor, accessibilityService, hud, coordinator, awake, away] _ in
            MainActor.assumeIsolated {
                away.shutdown()
                coordinator.stop()
                monitor.stop()
                accessibilityService.stop()
                hud.shutdown()
                callMode.shutdown()
                bluetoothHDGuard.shutdown()
                awake.shutdown()
                engine.shutdown()
                settings.flushSync()
                #if DEBUG
                uiTestSupport?.cleanUp()
                #endif
            }
        }
    }
}
