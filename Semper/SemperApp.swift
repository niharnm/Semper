import AppKit
import Darwin
import FluidMenuBarExtra
import SwiftUI
import UserNotifications
import os

private let logger = Logger(subsystem: "systems.semper.Semper", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var runtime: UtilityRuntime?
    private var terminationTask: Task<Void, Never>?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let runtime else { return }
        Task { @MainActor in
            for url in urls where url.scheme == "semper" {
                if url.host == "update" {
                    runtime.updateManager.checkForUpdates()
                    continue
                }
                guard
                    ["set-volumes", "step-volume", "set-mute", "toggle-mute", "set-device", "reset"].contains(
                        url.host ?? "")
                else { continue }
                do {
                    try await runtime.lifecycle.start(.sound)
                    guard !runtime.lifecycle.isShuttingDown,
                        runtime.registry.state(for: .sound)?.presence == .added,
                        !runtime.registry.pausedModuleIDs.contains(.sound), let sound = runtime.sound
                    else { continue }
                    let handler = URLHandler(
                        audioEngine: sound.audioEngine, audioCommands: sound.audioCommands,
                        checkForUpdates: runtime.updateManager.checkForUpdates)
                    handler.handleURL(url)
                } catch {
                    runtime.message = error.localizedDescription
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor in
            await runtime.shutdown()
            if runtime.lifecycle.failures.isEmpty {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                let alert = NSAlert()
                alert.messageText = "Some controls could not finish cleanup"
                alert.informativeText =
                    runtime.lifecycle.failures.values.sorted().joined(separator: "\n")
                    + "\nQuitting ends this process. Any saved recovery records remain available at the next launch."
                alert.addButton(withTitle: "Quit Semper")
                alert.addButton(withTitle: "Keep Open")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertFirstButtonReturn)
                self.terminationTask = nil
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

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
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
            {
                instanceLock = nil
                _runtime = State(initialValue: nil)
                _showMenuBarExtra = State(initialValue: false)
                return
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
            _runtime = State(initialValue: runtime)
            _appDelegate.wrappedValue.runtime = runtime
            UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue
        } catch {
            logger.fault("Semper could not start: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }
}
