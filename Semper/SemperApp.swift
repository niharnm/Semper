import AppKit
import CoreServices
import Darwin
import FluidMenuBarExtra
import SwiftUI
import UserNotifications
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
    weak var runtime: UtilityRuntime?
    weak var awayMode: (any AwayTerminationHandling)?
    private let terminateApplication: @MainActor () -> Void
    private let isSystemTerminationRequest: @MainActor () -> Bool
    private let replyToTerminationRequest: @MainActor (NSApplication, Bool) -> Void
    private let confirmIncompleteCleanup: @MainActor ([String]) -> Bool
    private var currentAwayOverride: (@MainActor () -> (any AwayTerminationHandling)?)?
    private var terminationDrainOverride: (@MainActor () async -> [String])?
    private weak var authenticatedAway: (any AwayTerminationHandling)?
    private var terminationTask: Task<Void, Never>?
    private var isTerminationDrainComplete = false
    #if DEBUG
        private var awayUITestFixture: AwayShellUITestFixture?
        private var shellUITestFixture: ShellUITestFixture?
    #endif

    override init() {
        terminateApplication = { NSApp.terminate(nil) }
        isSystemTerminationRequest = Self.currentAppleEventIsSystemTermination
        replyToTerminationRequest = { application, shouldTerminate in
            application.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        confirmIncompleteCleanup = Self.confirmQuitAfterIncompleteCleanup
        super.init()
    }

    init(
        terminateApplication: @escaping @MainActor () -> Void,
        isSystemTerminationRequest: @escaping @MainActor () -> Bool = {
            AppDelegate.currentAppleEventIsSystemTermination()
        },
        currentAway: (@MainActor () -> (any AwayTerminationHandling)?)? = nil,
        terminationDrain: (@MainActor () async -> [String])? = nil,
        confirmIncompleteCleanup: @escaping @MainActor ([String]) -> Bool = {
            AppDelegate.confirmQuitAfterIncompleteCleanup($0)
        },
        replyToTerminationRequest: @escaping @MainActor (NSApplication, Bool) -> Void = {
            application, shouldTerminate in
            application.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    ) {
        self.terminateApplication = terminateApplication
        self.isSystemTerminationRequest = isSystemTerminationRequest
        self.currentAwayOverride = currentAway
        self.terminationDrainOverride = terminationDrain
        self.confirmIncompleteCleanup = confirmIncompleteCleanup
        self.replyToTerminationRequest = replyToTerminationRequest
        super.init()
    }

    private var currentAway: (any AwayTerminationHandling)? {
        if let currentAwayOverride { return currentAwayOverride() }
        if let runtime { return runtime.away }
        return awayMode
    }

    #if DEBUG
        func installAwayUITestFixture(_ fixture: AwayShellUITestFixture) {
            awayUITestFixture = fixture
            currentAwayOverride = { fixture.coordinator }
            terminationDrainOverride = { await fixture.shutdownAndDrain() }
            fixture.coordinator.onAuthenticatedQuit = { [weak self, weak coordinator = fixture.coordinator] in
                guard let self, let coordinator, currentAway === coordinator else { return }
                permitTerminationAfterAwayAuthentication()
            }
        }

        func installShellUITestFixture(_ fixture: ShellUITestFixture) {
            shellUITestFixture = fixture
            currentAwayOverride = { fixture.runtime.away }
            terminationDrainOverride = { await fixture.shutdownAndDrain() }
            fixture.runtime.onAuthenticatedAwayQuit = { [weak self] in
                self?.permitTerminationAfterAwayAuthentication()
            }
        }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            awayUITestFixture?.showHostWindow()
            shellUITestFixture?.showHostWindow()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let runtime else { return }
        Task { @MainActor [runtime] in
            for url in urls where url.scheme == "semper" {
                if url.host == "update" {
                    runtime.updateManager.checkForUpdates()
                    continue
                }
                if url.host == "apply-scene" || url.host == "restore-scene" {
                    do {
                        let sceneID: UUID?
                        if url.host == "apply-scene" {
                            guard
                                let rawID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                                    .first(where: { $0.name.caseInsensitiveCompare("id") == .orderedSame })?.value,
                                let id = UUID(uuidString: rawID)
                            else { throw UtilityLifecycleError.unavailable("The scene URL needs a valid id.") }
                            sceneID = id
                        } else {
                            sceneID = nil
                        }
                        try await runtime.start(.scenes)
                        guard let scenes = runtime.scenes else { throw SceneCommandRuntimeError.unavailable }
                        let result =
                            if let sceneID {
                                try await scenes.applyScene(id: sceneID)
                            } else {
                                try await scenes.restoreScene()
                            }
                        runtime.message = result.message
                    } catch { runtime.message = error.localizedDescription }
                    continue
                }
                guard
                    ["set-volumes", "step-volume", "set-mute", "toggle-mute", "set-device", "reset"].contains(
                        url.host ?? "")
                else { continue }
                do {
                    try await runtime.start(.sound)
                    guard !runtime.lifecycle.isShuttingDown,
                        runtime.registry.state(for: .sound)?.presence == .added,
                        !runtime.registry.pausedModuleIDs.contains(.sound), let sound = runtime.sound
                    else { continue }
                    let handler = URLHandler(
                        audioEngine: sound.audioEngine, audioCommands: sound.audioCommands,
                        allowsMutations: { [weak runtime] in runtime?.away?.isGuarding != true },
                        checkForUpdates: runtime.updateManager.checkForUpdates)
                    handler.handleURL(url)
                } catch {
                    runtime.message = error.localizedDescription
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationDrainComplete else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        let away = currentAway
        let isAuthenticated = authenticatedAway != nil && authenticatedAway === away
        authenticatedAway = nil
        if !isAuthenticated, !isSystemTerminationRequest(), away?.isGuarding == true {
            away?.requestQuit()
            return .terminateCancel
        }

        guard terminationDrainOverride != nil || runtime != nil else { return .terminateNow }
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let failures: [String]
            if let terminationDrainOverride {
                failures = await terminationDrainOverride()
            } else if let runtime {
                await runtime.shutdown()
                failures = runtime.lifecycle.failures.values.sorted()
            } else {
                failures = []
            }
            let shouldTerminate = failures.isEmpty || confirmIncompleteCleanup(failures)
            authenticatedAway = nil
            isTerminationDrainComplete = shouldTerminate
            terminationTask = nil
            replyToTerminationRequest(sender, shouldTerminate)
        }
        return .terminateLater
    }

    func permitTerminationAfterAwayAuthentication() {
        guard terminationTask == nil, !isTerminationDrainComplete, let away = currentAway else { return }
        authenticatedAway = away
        terminateApplication()
    }

    func waitForTerminationDrain() async {
        await terminationTask?.value
    }

    private static func confirmQuitAfterIncompleteCleanup(_ failures: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Some controls could not finish cleanup"
        alert.informativeText =
            failures.sorted().joined(separator: "\n")
            + "\nQuitting ends this process. Any saved recovery records remain available at the next launch."
        alert.addButton(withTitle: "Quit Semper")
        alert.addButton(withTitle: "Keep Open")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func currentAppleEventIsSystemTermination() -> Bool {
        guard
            let reason = NSAppleEventManager.shared()
                .currentAppleEvent?
                .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
                .enumCodeValue
        else { return false }
        return isSystemTerminationReason(reason)
    }

    static func isSystemTerminationReason(_ reason: OSType?) -> Bool {
        guard let reason else { return false }
        return [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains(reason)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

#if DEBUG
    enum SemperDebugLaunchMode: Equatable {
        case awayUITest(AwayUITestLaunchOptions)
        case shellUITest
        case testHost
        case regular

        static func select(
            arguments: [String], hasXCTestConfiguration: Bool, hasXCTestClass: Bool
        ) -> Self {
            if let options = AwayUITestLaunchOptions.parse(arguments: arguments) { return .awayUITest(options) }
            if arguments.contains(ShellUITestFixture.enabledArgument) { return .shellUITest }
            return hasXCTestConfiguration || hasXCTestClass ? .testHost : .regular
        }
    }
#endif

@main
struct SemperApp: App {
    private let instanceLock: AppInstanceLock?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var runtime: UtilityRuntime?
    @State private var showMenuBarExtra = true
    private var launchIconImage: NSImage {
        MenuBarIconImage.systemSymbol(runtime?.settings.appSettings.menuBarIconStyle.iconName ?? "square.grid.2x2")
            .nsImage() ?? NSImage()
    }

    var body: some Scene {
        Settings {
            if let runtime { UtilitySettingsView(runtime: runtime) }
        }
        Window("Semper", id: "utilities") {
            if let runtime { UtilityShellView(runtime: runtime) }
        }
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentMinSize)
        FluidMenuBarExtra("Semper", image: launchIconImage, isInserted: $showMenuBarExtra) {
            if let runtime { UtilityShellView(runtime: runtime, compact: true) }
        }
    }

    init() {
        #if DEBUG
            switch SemperDebugLaunchMode.select(
                arguments: ProcessInfo.processInfo.arguments,
                hasXCTestConfiguration: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
                hasXCTestClass: NSClassFromString("XCTestCase") != nil)
            {
            case .awayUITest(let options):
                do {
                    let fixture = try AwayShellUITestFixture(options: options)
                    instanceLock = nil
                    _runtime = State(initialValue: nil)
                    _showMenuBarExtra = State(initialValue: false)
                    _appDelegate.wrappedValue.installAwayUITestFixture(fixture)
                    return
                } catch {
                    logger.fault("Semper could not start its isolated Away UI fixture: \(error.localizedDescription)")
                    exit(EXIT_FAILURE)
                }
            case .shellUITest:
                do {
                    let fixture = try ShellUITestFixture()
                    instanceLock = nil
                    _runtime = State(initialValue: nil)
                    _showMenuBarExtra = State(initialValue: false)
                    _appDelegate.wrappedValue.installShellUITestFixture(fixture)
                    return
                } catch {
                    logger.fault("Semper could not start its isolated shell UI fixture: \(error.localizedDescription)")
                    exit(EXIT_FAILURE)
                }
            case .testHost:
                instanceLock = nil
                _runtime = State(initialValue: nil)
                _showMenuBarExtra = State(initialValue: false)
                return
            case .regular:
                break
            }
        #endif
        do {
            switch try AppInstanceLock.acquire() {
            case .acquired(let lock): instanceLock = lock
            case .alreadyRunning:
                let bundleIdentifier = Bundle.main.bundleIdentifier ?? "systems.semper.Semper"
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                    .activate(options: [.activateAllWindows])
                exit(EXIT_SUCCESS)
            }
            let runtime = try UtilityRuntime()
            runtime.installIntentActivation()
            _runtime = State(initialValue: runtime)
            _appDelegate.wrappedValue.runtime = runtime
            runtime.onAuthenticatedAwayQuit = { [weak delegate = _appDelegate.wrappedValue] in
                delegate?.permitTerminationAfterAwayAuthentication()
            }
            UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue
        } catch {
            logger.fault("Semper could not start: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }
}
