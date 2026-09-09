import AppKit
import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Lazy scene runtime", .serialized)
struct LazySceneRuntimeTests {
    @Test("Starting and saving Scenes leaves dormant Sound, Awake, and Displays untouched")
    func dormantDomains() async throws {
        try await withRuntime { runtime, probe in
            #expect(runtime.scenes == nil)
            try await runtime.start(.scenes)
            let manager = try #require(runtime.scenes)
            #expect(runtime.sceneShortcuts != nil)
            #expect(runtime.registry.state(for: .scenes)?.runtime == .ready)
            let saved = await withCheckedContinuation { continuation in
                manager.saveCurrent(named: "Dormant") { continuation.resume(returning: $0) }
            }
            #expect(!saved)
            #expect(manager.statusMessage == SceneManagerError.noCurrentControls.localizedDescription)
            #expect(runtime.sound == nil && runtime.awake == nil && runtime.displays == nil)
            #expect(probe.creations.isEmpty)
        }
    }

    @Test("Scenes pause retains its manager and recreates only the shortcut registry on resume")
    func pauseAndResume() async throws {
        try await withRuntime { runtime, probe in
            try await runtime.start(.scenes)
            let manager = try #require(runtime.scenes)
            let shortcuts = try #require(runtime.sceneShortcuts)
            try await runtime.pause(.scenes)
            #expect(runtime.scenes === manager)
            #expect(manager.isSuspended)
            #expect(runtime.sceneShortcuts == nil)
            try runtime.registry.resume(.scenes)
            try await runtime.start(.scenes)
            #expect(runtime.scenes === manager)
            #expect(runtime.sceneShortcuts !== shortcuts)
            #expect(!manager.isSuspended)
            try await runtime.remove(.scenes)
            #expect(runtime.scenes == nil)
            #expect(runtime.sceneShortcuts == nil)
            #expect(manager.isShutDown)
            #expect(probe.creations.isEmpty)
        }
    }

    @Test("A pending scene blocks removal before module state or recovery ownership changes")
    func pendingRecoveryRetainsManager() async throws {
        try await withRuntime(pending: true) { runtime, probe in
            try await runtime.start(.scenes)
            let manager = try #require(runtime.scenes)
            let before = runtime.registry.state(for: .scenes)
            await #expect(throws: UtilityCleanupDeferral.self) { try await runtime.remove(.scenes) }
            #expect(runtime.scenes === manager)
            #expect(runtime.sceneShortcuts != nil)
            #expect(runtime.registry.state(for: .scenes) == before)
            #expect(!manager.isSuspended && manager.hasPendingRestore)
            #expect(runtime.sound == nil && runtime.awake == nil && runtime.displays == nil)
            #expect(probe.creations.isEmpty)
            _ = try await manager.recoverPendingScene(keepingCurrent: true)
            #expect(!manager.hasPendingRestore)
        }
    }

    @Test("Terminal shutdown closes Scene entry points even when Presentation retains its manager")
    func retainedScenesCloseEntryPoints() async throws {
        try await withRuntime { runtime, probe in
            try await runtime.start(.scenes)
            let manager = try #require(runtime.scenes)
            let shortcuts = try #require(runtime.sceneShortcuts)
            #expect(!SemperSceneAppIntentRuntime.scenes().isEmpty)
            try runtime.registry.add(.presentation)
            try await runtime.start(.presentation)
            let presentation = try #require(runtime.presentation)
            try await presentation.prepare(
                .init(duration: .thirtyMinutes, keepsDisplayAwake: false, scene: nil, workspacePlan: nil))
            let token = try #require(presentation.reservation)
            let unexpectedJournal = probe.pendingTransaction()
            try probe.journal.save(unexpectedJournal)

            await runtime.shutdown()

            #expect(runtime.lifecycle.failures[.presentation] != nil)
            #expect(runtime.lifecycle.failures[.scenes] != nil)
            #expect(runtime.scenes === manager)
            #expect(runtime.sceneShortcuts == nil)
            #expect(manager.isSuspended)
            #expect(presentation.reservation == token)
            #expect(try probe.journal.load()?.id == unexpectedJournal.id)
            #expect(SemperSceneAppIntentRuntime.scenes().isEmpty)
            #expect(UtilityShellView(runtime: runtime).sceneRecoveryDestination == nil)

            try probe.journal.clear()
            try await presentation.stop()
            #expect(presentation.reservation == nil)
            #expect(manager.isSuspended)
            await #expect(throws: SceneCommandRuntimeError.self) {
                try await SemperSceneAppIntentRuntime.applyScene(id: probe.savedScene.id)
            }
            let previousMessage = manager.statusMessage
            await shortcuts.performShortcut(for: UUID())
            #expect(manager.statusMessage == previousMessage)
            await #expect(throws: UtilityLifecycleError.self) { try await runtime.start(.scenes) }
            await runtime.shutdown()
            #expect(runtime.scenes == nil)
            #expect(runtime.lifecycle.failures.isEmpty)
        }
    }

    @Test("Home recovery remains reachable after shutdown without an added Scenes module")
    func internalSceneRecoveryNavigation() async throws {
        try await withRuntime(pending: true, addedModules: [.awake, .presentation]) { runtime, probe in
            try await runtime.start(.presentation)
            let presentation = try #require(runtime.presentation)
            await #expect(throws: SceneApplyError.self) {
                try await presentation.prepare(
                    .init(duration: .thirtyMinutes, keepsDisplayAwake: false, scene: nil, workspacePlan: nil))
            }
            let manager = try #require(runtime.scenes)
            #expect(runtime.registry.state(for: .scenes)?.presence == .available)
            #expect(!runtime.registry.addedModules.contains { $0.id == .scenes })
            runtime.searchText = "a search with no matches"
            let shell = UtilityShellView(runtime: runtime, connectsShellActions: false)
            #expect(shell.sceneRecoveryDestination == .module(.scenes))

            await runtime.shutdown()

            #expect(runtime.presentation == nil)
            #expect(runtime.scenes === manager)
            #expect(manager.isSuspended && manager.hasPendingRestore)
            #expect(runtime.sceneShortcuts == nil)
            runtime.destination = try #require(shell.sceneRecoveryDestination)
            #expect(runtime.destination == .module(.scenes))
            _ = try await manager.recoverPendingScene(keepingCurrent: true)
            #expect(shell.sceneRecoveryDestination == nil)
            #expect(try probe.journal.load() == nil)
            await runtime.shutdown()
            #expect(runtime.scenes == nil)
            #expect(runtime.lifecycle.failures.isEmpty)
            #expect(probe.creations.isEmpty)
        }
    }

    private func withRuntime(
        pending: Bool = false,
        addedModules: [UtilityModuleID] = [.scenes, .sound, .awake, .displays],
        _ body: (UtilityRuntime, LazySceneCreationProbe) async throws -> Void
    ) async throws {
        let suite = "LazySceneRuntimeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(addedModules.map(\.rawValue), forKey: ModuleRegistry.PersistenceKey.addedModules)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let settings = SettingsManager(
            directory: directory.appendingPathComponent("Settings"), managesLaunchAtLogin: false)
        let library = FileSceneLibraryStore(directory: directory)
        let journal = FileSceneJournalStore(directory: directory)
        let probe = LazySceneCreationProbe(journal: journal)
        try library.saveScenes([probe.savedScene])
        if pending { try journal.save(probe.pendingTransaction()) }
        defer {
            settings.flushSync()
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) } catch {
                    Issue.record(error, "Could not remove lazy scene test files")
                }
            }
        }
        let runtime = try UtilityRuntime(
            settings: settings, defaults: defaults,
            updateManager: UpdateManager(bundle: Bundle(for: NSObject.self), userDefaults: defaults),
            soundFactory: { _, _ in try probe.unexpected(.sound) },
            awakeFactory: { try probe.unexpected(.awake) },
            sceneLibraryStore: library, sceneJournalStore: journal)
        do {
            try await body(runtime, probe)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
        #expect(probe.creations.isEmpty)
    }
}

@MainActor
private final class LazySceneCreationProbe {
    private(set) var creations: [UtilityModuleID] = []
    let journal: FileSceneJournalStore
    let savedScene = SemperScene(
        name: "Saved", actions: [.init(control: .awakeMode, target: .awake(.off), importance: .required)])

    init(journal: FileSceneJournalStore) {
        self.journal = journal
    }

    func pendingTransaction() -> SceneTransaction {
        SceneTransaction(
            sceneID: UUID(), sceneName: "Pending", startedAt: Date(),
            entries: [
                .init(
                    control: .awakeMode, importance: .required, snapshotValue: .awake(.off),
                    targetValue: .awake(.system), appliedValue: .awake(.system), phase: .applied)
            ])
    }

    func unexpected<Service>(_ module: UtilityModuleID) throws -> Service {
        creations.append(module)
        throw CancellationError()
    }
}
