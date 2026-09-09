import Foundation
import KeyboardShortcuts
import Testing
@testable import Semper

@Suite("SceneShortcutRegistry", .serialized)
@MainActor
struct SceneShortcutRegistryTests {
    @Test("A scene shortcut matching a built-in shortcut is not registered")
    func rejectsStoredBuiltInConflict() {
        let settings = makeSettings()
        let shortcut = SceneShortcut(keyCode: 18, modifiers: 768)
        settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] = ShortcutCodable(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        )
        let scene = makeScene(name: "Studio", shortcut: shortcut)
        let manager = SceneShortcutManagerStub(scenes: [scene])
        let registry = SceneShortcutRegistry(settings: settings, sceneManager: manager)

        registry.start()

        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: scene.id)) == nil)
        #expect(registry.conflicts[scene.id] == "Already used by Toggle Semper Popup.")
        clear(registry, sceneIDs: [scene.id])
    }

    @Test("A scene shortcut cannot reuse the Away Mode shortcut")
    func rejectsAwayModeConflict() {
        let settings = makeSettings()
        let shortcut = SceneShortcut(keyCode: 19, modifiers: 768)
        settings.appSettings.customShortcuts[ShortcutAction.toggleAwayMode.rawValue] = ShortcutCodable(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        )
        let scene = makeScene(name: "Studio", shortcut: shortcut)
        let manager = SceneShortcutManagerStub(scenes: [scene])
        let registry = SceneShortcutRegistry(settings: settings, sceneManager: manager)

        registry.start()

        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: scene.id)) == nil)
        #expect(registry.conflicts[scene.id] == "Already used by Away Mode.")
        clear(registry, sceneIDs: [scene.id])
    }

    @Test("Duplicate stored scene shortcuts are all left unregistered")
    func rejectsStoredSceneConflicts() {
        let settings = makeSettings()
        let shortcut = SceneShortcut(keyCode: 19, modifiers: 768)
        let first = makeScene(name: "Studio", shortcut: shortcut)
        let second = makeScene(name: "Calls", shortcut: shortcut)
        let manager = SceneShortcutManagerStub(scenes: [first, second])
        let registry = SceneShortcutRegistry(settings: settings, sceneManager: manager)

        registry.start()

        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: first.id)) == nil)
        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: second.id)) == nil)
        #expect(registry.conflicts[first.id] == "Also assigned to Calls.")
        #expect(registry.conflicts[second.id] == "Also assigned to Studio.")
        clear(registry, sceneIDs: [first.id, second.id])
    }

    @Test("A conflict recorded before start is removed from global storage")
    func rejectsConflictBeforeStart() {
        let settings = makeSettings()
        let shortcut = SceneShortcut(keyCode: 22, modifiers: 768)
        settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] = ShortcutCodable(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        )
        let scene = makeScene(name: "Studio", shortcut: shortcut)
        let manager = SceneShortcutManagerStub(scenes: [scene])
        let registry = SceneShortcutRegistry(settings: settings, sceneManager: manager)
        KeyboardShortcuts.setShortcut(keyboardShortcut(shortcut), for: registry.name(for: scene.id))

        registry.recordCallback(for: scene)(keyboardShortcut(shortcut))

        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: scene.id)) == nil)
        #expect(registry.conflicts[scene.id] == "Already used by Toggle Semper Popup.")
        clear(registry, sceneIDs: [scene.id])
    }

    @Test("A built-in shortcut edit revalidates scene registrations")
    func builtInEditRevalidatesScenes() {
        let settings = makeSettings()
        let shortcut = SceneShortcut(keyCode: 20, modifiers: 768)
        let scene = makeScene(name: "Studio", shortcut: shortcut)
        let sceneManager = SceneShortcutManagerStub(scenes: [scene])
        let sceneRegistry = SceneShortcutRegistry(settings: settings, sceneManager: sceneManager)
        let builtInRegistry = ShortcutsRegistry(
            settings: settings,
            popupController: RecordingPopupController(),
            resolver: StubTargetResolver(target: nil),
            audioEngine: RecordingAudioEngine(apps: []),
            audioCommands: RecordingAudioCommandSink(),
            hud: RecordingHUDController()
        )
        builtInRegistry.onShortcutsChanged = { sceneRegistry.sync() }

        builtInRegistry.start()
        sceneRegistry.start()
        #expect(KeyboardShortcuts.getShortcut(for: sceneRegistry.name(for: scene.id)) == keyboardShortcut(shortcut))

        builtInRegistry.recordCallback(for: .togglePopup)(keyboardShortcut(shortcut))

        #expect(KeyboardShortcuts.getShortcut(for: sceneRegistry.name(for: scene.id)) == nil)
        #expect(sceneRegistry.conflicts[scene.id] == "Already used by Toggle Semper Popup.")

        builtInRegistry.clearAllShortcuts()
        #expect(KeyboardShortcuts.getShortcut(for: sceneRegistry.name(for: scene.id)) == keyboardShortcut(shortcut))
        #expect(sceneRegistry.conflicts[scene.id] == nil)
        clear(sceneRegistry, sceneIDs: [scene.id])
    }

    @Test("Duplicate stored built-in shortcuts register only one action")
    func filtersStoredBuiltInConflicts() {
        let settings = makeSettings()
        let shortcut = ShortcutCodable(keyCode: 21, modifiers: 768)
        settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] = shortcut
        settings.appSettings.customShortcuts[ShortcutAction.targetAppVolumeUp.rawValue] = shortcut
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: RecordingPopupController(),
            resolver: StubTargetResolver(target: nil),
            audioEngine: RecordingAudioEngine(apps: []),
            audioCommands: RecordingAudioCommandSink(),
            hud: RecordingHUDController()
        )

        registry.start()

        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup)) == shortcut.keyboardShortcut)
        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: .targetAppVolumeUp)) == nil)
        #expect(registry.conflictingAction(for: .targetAppVolumeUp) == .togglePopup)
        registry.clearAllShortcuts()
    }

    @Test("A scene shortcut reports application failures")
    func reportsApplyFailure() async {
        let settings = makeSettings()
        let scene = makeScene(
            name: "Studio",
            shortcut: SceneShortcut(keyCode: 23, modifiers: 768)
        )
        let manager = SceneShortcutManagerStub(scenes: [scene])
        manager.applyError = SceneManagerError.mutationsBlocked
        let registry = SceneShortcutRegistry(settings: settings, sceneManager: manager)

        await registry.performShortcut(for: scene.id)

        #expect(manager.reportedFailure == SceneManagerError.mutationsBlocked.localizedDescription)
    }

    @Test("Away Mode suppresses scene shortcut dispatch")
    func awayModeSuppressesSceneShortcut() async {
        let settings = makeSettings()
        let scene = makeScene(
            name: "Studio",
            shortcut: SceneShortcut(keyCode: 23, modifiers: 768)
        )
        let manager = SceneShortcutManagerStub(scenes: [scene])
        let registry = SceneShortcutRegistry(
            settings: settings,
            sceneManager: manager,
            allowsShortcuts: { false }
        )

        await registry.performShortcut(for: scene.id)

        #expect(manager.applyCallCount == 0)
        #expect(manager.reportedFailure == nil)
    }

    private func makeSettings() -> SettingsManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperSceneShortcutTests-\(UUID().uuidString)")
        return SettingsManager(directory: directory)
    }

    private func makeScene(name: String, shortcut: SceneShortcut) -> SemperScene {
        SemperScene(
            name: name,
            actions: [
                SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            ],
            shortcut: shortcut
        )
    }

    private func keyboardShortcut(_ shortcut: SceneShortcut) -> KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: shortcut.keyCode,
            carbonModifiers: Int(shortcut.modifiers)
        )
    }

    private func clear(_ registry: SceneShortcutRegistry, sceneIDs: [UUID]) {
        for sceneID in sceneIDs {
            let name = registry.name(for: sceneID)
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.setShortcut(nil, for: name)
        }
    }
}

@MainActor
private final class SceneShortcutManagerStub: SceneShortcutManaging {
    var scenes: [SemperScene]
    var applyError: (any Error)?
    private(set) var reportedFailure: String?
    private(set) var applyCallCount = 0

    init(scenes: [SemperScene]) {
        self.scenes = scenes
    }

    func applyScene(id: UUID) async throws -> SceneCommandExecution {
        applyCallCount += 1
        if let applyError { throw applyError }
        return SceneCommandExecution(message: "Applied")
    }

    func reportSceneCommandFailure(_ message: String) {
        reportedFailure = message
    }

    func setShortcut(_ shortcut: SceneShortcut?, for sceneID: UUID) throws {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagerError.sceneNotFound(sceneID)
        }
        scenes[index].shortcut = shortcut
    }
}
