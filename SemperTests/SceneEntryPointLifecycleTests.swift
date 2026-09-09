import Foundation
import KeyboardShortcuts
import Testing

@testable import Semper

@MainActor
@Suite("Scene entrypoint lifecycle", .serialized)
struct SceneEntryPointLifecycleTests {
    @Test("Intent queries stay dormant while execution lazily activates the current owner")
    func lazyIntentActivation() async throws {
        let owner = NSObject()
        let commands = EntryPointSceneProbe()
        var activations = 0
        SemperSceneAppIntentRuntime.installActivation(owner: owner) {
            activations += 1
            SemperSceneAppIntentRuntime.install(commands)
        }
        defer {
            SemperSceneAppIntentRuntime.uninstallActivation(owner: owner)
            SemperSceneAppIntentRuntime.uninstall(commands)
        }
        #expect(SemperSceneAppIntentRuntime.scenes().isEmpty)
        #expect(activations == 0)
        _ = try await SemperSceneAppIntentRuntime.applyScene(id: commands.scenes[0].id)
        #expect(activations == 1)
        #expect(commands.applies == 1)
        #expect(SemperSceneAppIntentRuntime.scenes().count == 1)
    }

    @Test("An old owner cannot uninstall a newer intent installation")
    func ownerIdentity() async throws {
        let oldOwner = NSObject()
        let newOwner = NSObject()
        let oldCommands = EntryPointSceneProbe()
        let newCommands = EntryPointSceneProbe()
        var activations = 0
        SemperSceneAppIntentRuntime.install(oldCommands)
        SemperSceneAppIntentRuntime.install(newCommands)
        SemperSceneAppIntentRuntime.installActivation(owner: newOwner) { activations += 1 }
        defer {
            SemperSceneAppIntentRuntime.uninstall(newCommands)
            SemperSceneAppIntentRuntime.uninstallActivation(owner: newOwner)
        }
        SemperSceneAppIntentRuntime.uninstall(oldCommands)
        SemperSceneAppIntentRuntime.uninstallActivation(owner: oldOwner)
        _ = try await SemperSceneAppIntentRuntime.restoreScene()
        #expect(activations == 1)
        #expect(newCommands.restores == 1)
        #expect(oldCommands.restores == 0)
    }

    @Test("Stopped shortcut registries drain work and reject stale recorder callbacks")
    func shortcutsStopAndDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneEntrypointTests-\(UUID())")
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        defer {
            settings.flushSync()
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) } catch {
                    Issue.record(error, "Could not remove shortcut test settings")
                }
            }
        }
        let commands = EntryPointSceneProbe()
        let entered = EntryPointLatch()
        let release = EntryPointLatch()
        commands.applyHook = {
            entered.open()
            await release.wait()
            try Task.checkCancellation()
        }
        let registry = SceneShortcutRegistry(settings: settings, sceneManager: commands)
        let scene = commands.scenes[0]
        let callback = registry.recordCallback(for: scene)
        let applying = Task { await registry.performShortcut(for: scene.id) }
        await entered.wait()
        var stopped = false
        let shutdown = Task {
            await registry.shutdown()
            stopped = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!stopped)
        release.open()
        await shutdown.value
        await applying.value
        callback(KeyboardShortcuts.Shortcut(carbonKeyCode: 18, carbonModifiers: 768))
        registry.sync()
        registry.start()
        await registry.performShortcut(for: scene.id)
        #expect(commands.applies == 1)
        #expect(commands.shortcutChanges == 0)
        #expect(commands.reportedFailures.isEmpty)
    }
}

@MainActor
private final class EntryPointSceneProbe: SceneCommandHandling, SceneShortcutManaging {
    var scenes = [
        SemperScene(
            name: "Test",
            actions: [
                SceneAction(control: .awakeMode, target: .awake(.system), importance: .required)
            ])
    ]
    var applies = 0
    var restores = 0
    var shortcutChanges = 0
    var reportedFailures: [String] = []
    var applyHook: (() async throws -> Void)?
    func availableScenes() -> [SceneCommandDescriptor] { scenes.map { .init(id: $0.id, name: $0.name) } }
    func applyScene(id: UUID) async throws -> SceneCommandExecution {
        applies += 1
        try await applyHook?()
        return .init(message: "Applied")
    }
    func restoreScene() async throws -> SceneCommandExecution {
        restores += 1
        return .init(message: "Restored")
    }
    func setShortcut(_ shortcut: SceneShortcut?, for sceneID: UUID) throws { shortcutChanges += 1 }
    func reportSceneCommandFailure(_ message: String) { reportedFailures.append(message) }
}

@MainActor
private final class EntryPointLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
