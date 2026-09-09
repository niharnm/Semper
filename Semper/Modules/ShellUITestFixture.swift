#if DEBUG
    import AppKit
    import Foundation
    import SwiftUI

    @MainActor
    final class ShellUITestFixture {
        static let enabledArgument = "--shell-ui-testing"

        let runtime: UtilityRuntime
        let directory: URL
        let settingsDirectory: URL
        let sceneDirectory: URL
        let defaultsSuiteName: String
        var factoryAttempts: [UtilityModuleID: Int] { factoryProbe.attempts }
        var hasHostWindow: Bool { hostWindow != nil }

        private let defaults: UserDefaults
        private let settings: SettingsManager
        private let factoryProbe: ShellUITestFactoryProbe
        private let drainRuntime: @MainActor (UtilityRuntime) async -> [String]
        private var hostWindow: NSWindow?
        private var cleanupTask: Task<[String], Never>?
        private var shutdownStarted = false
        private var cleanupCompleted = false

        convenience init() throws {
            try self.init(temporaryDirectory: FileManager.default.temporaryDirectory)
        }

        init(
            temporaryDirectory: URL,
            persistenceWriter: SettingsPersistenceWriter = SettingsPersistenceWriter(),
            drainRuntime: @escaping @MainActor (UtilityRuntime) async -> [String] = {
                await $0.shutdown()
                return $0.lifecycle.failures.values.sorted()
            }
        ) throws {
            let identifier = UUID().uuidString
            let suite = "Semper-Shell-UITests-\(identifier)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw UtilityLifecycleError.unavailable("Shell UI test preferences could not be created.")
            }
            let directory = temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let settingsDirectory = directory.appendingPathComponent("Settings", isDirectory: true)
            let sceneDirectory = directory.appendingPathComponent("Scenes", isDirectory: true)
            defaults.set([UtilityModuleID.sound.rawValue], forKey: ModuleRegistry.PersistenceKey.addedModules)
            defaults.set([String](), forKey: ModuleRegistry.PersistenceKey.pausedModules)
            defaults.set([String](), forKey: ModuleRegistry.PersistenceKey.favoriteActions)
            let settings = SettingsManager(
                directory: settingsDirectory, managesLaunchAtLogin: false, persistenceWriter: persistenceWriter)
            let probe = ShellUITestFactoryProbe()
            do {
                runtime = try UtilityRuntime(
                    settings: settings, defaults: defaults,
                    updateManager: UpdateManager.dormantForTesting(userDefaults: defaults),
                    soundFactory: { _, _ in try probe.refuse(.sound) },
                    awakeFactory: { try probe.refuse(.awake) },
                    workspaceFactory: { try probe.refuse(.workspace) },
                    shelfFactory: { try probe.refuse(.shelf) },
                    storageFactory: { try probe.refuse(.storage) },
                    sceneLibraryStore: FileSceneLibraryStore(directory: sceneDirectory),
                    sceneJournalStore: FileSceneJournalStore(directory: sceneDirectory),
                    displayFactory: { _, _ in try probe.refuse(.displays) },
                    awayFactory: { _, _, _ in try probe.refuse(.away) })
                runtime.lifecycle.startupDisabledForTesting = true
            } catch {
                guard settings.flushSync() else {
                    throw UtilityLifecycleError.unavailable(
                        "\(error.localizedDescription) Temporary shell UI test settings were retained because saving failed."
                    )
                }
                do { try Self.removeOwnedDirectory(directory) } catch let cleanupError {
                    throw UtilityLifecycleError.unavailable(
                        "\(error.localizedDescription) Temporary shell UI test cleanup failed: \(cleanupError.localizedDescription)"
                    )
                }
                defaults.removePersistentDomain(forName: suite)
                throw error
            }
            self.directory = directory
            self.settingsDirectory = settingsDirectory
            self.sceneDirectory = sceneDirectory
            defaultsSuiteName = suite
            self.defaults = defaults
            self.settings = settings
            factoryProbe = probe
            self.drainRuntime = drainRuntime
        }

        func showHostWindow() {
            guard !shutdownStarted, hostWindow == nil else { return }
            let rootView = UtilityShellView(runtime: runtime, connectsShellActions: false)
                .accessibilityIdentifier("shell-ui-test-host")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1060, height: 880),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Semper Shell UI Tests"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: rootView)
            hostWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func shutdownAndDrain() async -> [String] {
            shutdownStarted = true
            if cleanupCompleted { return [] }
            if let cleanupTask { return await cleanupTask.value }
            let task = Task { @MainActor in
                defer { self.cleanupTask = nil }
                let failures = await self.drainRuntime(self.runtime)
                guard failures.isEmpty else { return failures }
                guard self.settings.flushSync() else {
                    return ["Shell UI test settings could not be saved. Temporary resources were retained for retry."]
                }
                do { try Self.removeOwnedDirectory(self.directory) } catch {
                    return ["Temporary shell UI test files could not be removed. Retry cleanup."]
                }
                self.defaults.removePersistentDomain(forName: self.defaultsSuiteName)
                self.hostWindow?.orderOut(nil)
                self.hostWindow?.close()
                self.hostWindow = nil
                self.cleanupCompleted = true
                return []
            }
            cleanupTask = task
            return await task.value
        }

        private static func removeOwnedDirectory(_ directory: URL) throws {
            do { try FileManager.default.removeItem(at: directory) } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            {
                return
            }
        }
    }

    @MainActor
    private final class ShellUITestFactoryProbe {
        private(set) var attempts: [UtilityModuleID: Int] = [:]

        func refuse<Service>(_ module: UtilityModuleID) throws -> Service {
            attempts[module, default: 0] += 1
            throw UtilityLifecycleError.unavailable("Service startup is unavailable in shell UI tests.")
        }
    }
#endif
