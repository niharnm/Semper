import AppKit
import Foundation
import KeyboardShortcuts
import Testing

@testable import Semper

@MainActor
@Suite("Workspace shortcut isolation", .serialized)
struct WorkspaceShortcutIsolationTests {
    @Test("Every placement has one distinct shell-owned shortcut action")
    func placementShortcutCoverage() {
        let actions = ShortcutAction.windowLayoutActions
        let placements = actions.compactMap(\.windowLayoutAction)
        #expect(placements.count == WindowLayoutAction.allCases.count)
        #expect(Set(placements) == Set(WindowLayoutAction.allCases))
        #expect(Set(actions.map(\.rawValue)).count == actions.count)
        #expect(
            actions.allSatisfy { ShortcutAction.shellActions.contains($0) && !ShortcutAction.soundActions.contains($0) }
        )
    }

    @Test("Window shortcuts remain shell-owned when Sound clears its shortcuts", arguments: ShortcutAction.windowLayoutActions)
    func soundDoesNotOwnWindowLayout(_ action: ShortcutAction) throws {
        try withSynchronousSettings { settings in
            let chord = KeyboardShortcuts.Shortcut(.l, modifiers: [.control, .option])
            settings.appSettings.customShortcuts[action.rawValue] = ShortcutCodable.from(chord)
            KeyboardShortcuts.setShortcut(chord, for: action.keyboardShortcutName)
            KeyboardShortcuts.onKeyDown(for: action.keyboardShortcutName) {}
            defer { KeyboardShortcuts.removeHandler(for: action.keyboardShortcutName) }
            let sound = makeRegistry(settings)
            defer { sound.stop() }
            sound.start()
            #expect(!sound.dispatch(action))
            #expect(!action.supportsRepeat)
            sound.clearAllShortcuts()
            #expect(settings.appSettings.customShortcuts[action.rawValue] == ShortcutCodable.from(chord))
            #expect(KeyboardShortcuts.isEnabled(for: action.keyboardShortcutName))
        }
    }

    @Test("Sound registration and Clear All leave Workspace owned by the shell")
    func soundDoesNotOwnWorkspace() throws {
        try withSynchronousSettings { settings in
            let workspace = ShortcutAction.restoreWorkspace
            let chord = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
            settings.appSettings.customShortcuts[workspace.rawValue] = ShortcutCodable.from(chord)
            KeyboardShortcuts.setShortcut(chord, for: workspace.keyboardShortcutName)
            KeyboardShortcuts.onKeyDown(for: workspace.keyboardShortcutName) {}
            defer { KeyboardShortcuts.removeHandler(for: workspace.keyboardShortcutName) }
            let sound = makeRegistry(settings)
            defer { sound.stop() }
            sound.start()
            #expect(!sound.hasAssignedShortcuts)
            #expect(!sound.dispatch(.restoreWorkspace))
            sound.recordCallback(for: .restoreWorkspace)(nil)
            sound.clearAllShortcuts()
            #expect(settings.appSettings.customShortcuts[workspace.rawValue] == ShortcutCodable.from(chord))
            #expect(KeyboardShortcuts.getShortcut(for: workspace.keyboardShortcutName) == chord)
            #expect(KeyboardShortcuts.isEnabled(for: workspace.keyboardShortcutName))
            sound.stop()
            #expect(KeyboardShortcuts.isEnabled(for: workspace.keyboardShortcutName))
        }
    }

    @Test("Sound recorder restores Search and Workspace registration after rejecting duplicate chords")
    func soundRejectsShellConflicts() throws {
        try withSynchronousSettings { settings in
            let workspace = ShortcutAction.restoreWorkspace
            let workspaceChord = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
            let searchChord = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
            settings.appSettings.customShortcuts[workspace.rawValue] = ShortcutCodable.from(workspaceChord)
            KeyboardShortcuts.setShortcut(workspaceChord, for: workspace.keyboardShortcutName)
            KeyboardShortcuts.onKeyDown(for: workspace.keyboardShortcutName) {}
            KeyboardShortcuts.setShortcut(searchChord, for: ShortcutAction.searchShortcut)
            KeyboardShortcuts.onKeyDown(for: ShortcutAction.searchShortcut) {}
            defer {
                KeyboardShortcuts.removeHandler(for: workspace.keyboardShortcutName)
                KeyboardShortcuts.removeHandler(for: ShortcutAction.searchShortcut)
            }
            let sound = makeRegistry(settings)
            defer { sound.stop() }
            sound.start()
            let edited = ShortcutAction.targetAppMuteToggle
            for (shortcut, reason) in [
                (workspaceChord, "Already used by Restore workspace."),
                (searchChord, "Already used by Search Semper."),
            ] {
                KeyboardShortcuts.setShortcut(shortcut, for: edited.keyboardShortcutName)
                sound.recordCallback(for: edited)(shortcut)
                #expect(sound.conflictDescription(for: edited) == reason)
                #expect(settings.appSettings.customShortcuts[edited.rawValue] == nil)
                #expect(KeyboardShortcuts.getShortcut(for: edited.keyboardShortcutName) == nil)
                #expect(KeyboardShortcuts.isEnabled(for: workspace.keyboardShortcutName))
                #expect(KeyboardShortcuts.isEnabled(for: ShortcutAction.searchShortcut))
            }
        }
    }

    @Test("Scene recorder preserves shell incumbents when rejecting Workspace and Search chords")
    func sceneRejectsShellConflicts() async throws {
        try await withSettings { settings in
            let workspace = ShortcutAction.restoreWorkspace
            let workspaceChord = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
            let searchChord = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
            settings.appSettings.customShortcuts[workspace.rawValue] = ShortcutCodable.from(workspaceChord)
            KeyboardShortcuts.setShortcut(workspaceChord, for: workspace.keyboardShortcutName)
            KeyboardShortcuts.onKeyDown(for: workspace.keyboardShortcutName) {}
            KeyboardShortcuts.setShortcut(searchChord, for: ShortcutAction.searchShortcut)
            KeyboardShortcuts.onKeyDown(for: ShortcutAction.searchShortcut) {}
            defer {
                KeyboardShortcuts.removeHandler(for: workspace.keyboardShortcutName)
                KeyboardShortcuts.removeHandler(for: ShortcutAction.searchShortcut)
            }
            let scene = SemperScene(name: "Desk", actions: [])
            let manager = WorkspaceShortcutSceneStub(scenes: [scene])
            let registry = SceneShortcutRegistry(settings: settings, sceneManager: manager)
            registry.start()
            for (shortcut, reason) in [
                (workspaceChord, "Already used by Restore workspace."),
                (searchChord, "Already used by Search Semper."),
            ] {
                KeyboardShortcuts.setShortcut(shortcut, for: registry.name(for: scene.id))
                registry.recordCallback(for: scene)(shortcut)
                #expect(registry.conflicts[scene.id] == reason)
                #expect(manager.scenes.first?.shortcut == nil)
                #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: scene.id)) == nil)
                #expect(KeyboardShortcuts.isEnabled(for: workspace.keyboardShortcutName))
                #expect(KeyboardShortcuts.isEnabled(for: ShortcutAction.searchShortcut))
            }
            await registry.shutdown()
            #expect(KeyboardShortcuts.isEnabled(for: workspace.keyboardShortcutName))
            #expect(KeyboardShortcuts.isEnabled(for: ShortcutAction.searchShortcut))
        }
    }

    private func makeRegistry(_ settings: SettingsManager) -> ShortcutsRegistry {
        ShortcutsRegistry(
            settings: settings, popupController: RecordingPopupController(), resolver: StubTargetResolver(target: nil),
            audioEngine: RecordingAudioEngine(apps: []), audioCommands: RecordingAudioCommandSink(),
            hud: RecordingHUDController())
    }

    private func withSynchronousSettings(_ body: (SettingsManager) throws -> Void) throws {
        let fixture = try WorkspaceShortcutFixture()
        defer { fixture.cleanUp() }
        try body(fixture.settings)
    }

    private func withSettings(_ body: (SettingsManager) async throws -> Void) async throws {
        let fixture = try WorkspaceShortcutFixture()
        defer { fixture.cleanUp() }
        try await body(fixture.settings)
    }
}

@MainActor
private final class WorkspaceShortcutFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceShortcuts-\(UUID())")
    let settings: SettingsManager
    private let saved: [(KeyboardShortcuts.Name, Any?, KeyboardShortcuts.Shortcut?, Bool)]

    init() throws {
        let names = ShortcutAction.allCases.map(\.keyboardShortcutName) + [ShortcutAction.searchShortcut]
        saved = names.map { name in
            (
                name, UserDefaults.standard.object(forKey: "KeyboardShortcuts_" + name.rawValue),
                KeyboardShortcuts.getShortcut(for: name), KeyboardShortcuts.isEnabled(for: name)
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        for name in names { KeyboardShortcuts.setShortcut(nil, for: name) }
    }

    func cleanUp() {
        settings.flushSync()
        for (name, object, shortcut, _) in saved {
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            if let object {
                UserDefaults.standard.set(object, forKey: "KeyboardShortcuts_" + name.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_" + name.rawValue)
            }
        }
        for (name, _, _, enabled) in saved {
            if enabled { KeyboardShortcuts.enable(name) } else { KeyboardShortcuts.disable(name) }
        }
        do { try FileManager.default.removeItem(at: directory) } catch {
            Issue.record(error, "Could not remove Workspace shortcut test files")
        }
    }
}

@MainActor
private final class WorkspaceShortcutSceneStub: SceneShortcutManaging {
    var scenes: [SemperScene]
    init(scenes: [SemperScene]) { self.scenes = scenes }
    func applyScene(id: UUID) async throws -> SceneCommandExecution { .init(message: "Applied") }
    func reportSceneCommandFailure(_ message: String) { Issue.record("Unexpected Scene shortcut: \(message)") }
    func setShortcut(_ shortcut: SceneShortcut?, for sceneID: UUID) throws {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagerError.sceneNotFound(sceneID)
        }
        scenes[index].shortcut = shortcut
    }
}
