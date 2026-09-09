import Foundation
import KeyboardShortcuts

@MainActor
protocol SceneShortcutManaging: AnyObject {
    var scenes: [SemperScene] { get }
    func apply(scene: SemperScene)
    func setShortcut(_ shortcut: SceneShortcut?, for sceneID: UUID) throws
}

extension SceneManager: SceneShortcutManaging {}

@Observable
@MainActor
final class SceneShortcutRegistry {
    private let settings: SettingsManager
    private let sceneManager: any SceneShortcutManaging
    private var registeredSceneIDs = Set<UUID>()
    private var didStart = false

    private(set) var conflicts: [UUID: String] = [:]
    private(set) var persistenceErrors: [UUID: String] = [:]

    init(settings: SettingsManager, sceneManager: any SceneShortcutManaging) {
        self.settings = settings
        self.sceneManager = sceneManager
    }

    func name(for sceneID: UUID) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("scene-\(sceneID.uuidString.lowercased())")
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        sync()
    }

    func sync() {
        let scenes = sceneManager.scenes
        let currentIDs = Set(scenes.map(\.id))
        let duplicateSceneShortcuts = Dictionary(grouping: scenes.compactMap { scene in
            scene.shortcut.map { ($0, scene) }
        }, by: \.0).filter { $0.value.count > 1 }

        for removedID in registeredSceneIDs.subtracting(currentIDs) {
            let removedName = name(for: removedID)
            KeyboardShortcuts.removeHandler(for: removedName)
            KeyboardShortcuts.setShortcut(nil, for: removedName)
            conflicts[removedID] = nil
            persistenceErrors[removedID] = nil
        }

        for scene in scenes {
            let sceneName = name(for: scene.id)
            KeyboardShortcuts.removeHandler(for: sceneName)

            guard let shortcut = scene.shortcut else {
                KeyboardShortcuts.setShortcut(nil, for: sceneName)
                conflicts[scene.id] = nil
                continue
            }

            if let conflict = builtInConflictDescription(for: shortcut) {
                KeyboardShortcuts.setShortcut(nil, for: sceneName)
                conflicts[scene.id] = conflict
                continue
            }

            if let owners = duplicateSceneShortcuts[shortcut] {
                let otherNames = owners
                    .filter { $0.1.id != scene.id }
                    .map { $0.1.name }
                    .sorted()
                    .joined(separator: ", ")
                KeyboardShortcuts.setShortcut(nil, for: sceneName)
                conflicts[scene.id] = "Also assigned to \(otherNames)."
                continue
            }

            conflicts[scene.id] = nil
            KeyboardShortcuts.setShortcut(shortcut.keyboardShortcut, for: sceneName)
            if didStart {
                KeyboardShortcuts.onKeyDown(for: sceneName) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let current = self.sceneManager.scenes.first(where: { $0.id == scene.id }) else {
                            return
                        }
                        self.sceneManager.apply(scene: current)
                    }
                }
            }
        }
        registeredSceneIDs = currentIDs
    }

    func recordCallback(
        for scene: SemperScene
    ) -> @MainActor (KeyboardShortcuts.Shortcut?) -> Void {
        { [weak self] shortcut in
            self?.record(shortcut, for: scene)
        }
    }

    private func record(_ shortcut: KeyboardShortcuts.Shortcut?, for scene: SemperScene) {
        if let shortcut, let conflict = conflictDescription(
            for: SceneShortcut.from(shortcut),
            excluding: scene.id
        ) {
            sync()
            conflicts[scene.id] = conflict
            persistenceErrors[scene.id] = nil
            return
        }

        do {
            try sceneManager.setShortcut(shortcut.map(SceneShortcut.from), for: scene.id)
            sync()
            conflicts[scene.id] = nil
            persistenceErrors[scene.id] = nil
        } catch {
            sync()
            persistenceErrors[scene.id] = error.localizedDescription
        }
    }

    private func conflictDescription(
        for shortcut: SceneShortcut,
        excluding sceneID: UUID
    ) -> String? {
        if let builtInConflict = builtInConflictDescription(for: shortcut) {
            return builtInConflict
        }

        if let other = sceneManager.scenes.first(where: {
            $0.id != sceneID && $0.shortcut == shortcut
        }) {
            return "Already used by \(other.name)."
        }
        return nil
    }

    private func builtInConflictDescription(for shortcut: SceneShortcut) -> String? {
        for action in ShortcutAction.allCases {
            let assigned = settings.appSettings.customShortcuts[action.rawValue]
                ?? KeyboardShortcuts.getShortcut(
                    for: KeyboardShortcuts.Name(stableID(for: action))
                ).map(ShortcutCodable.from)
            if assigned.map(SceneShortcut.init) == shortcut {
                return "Already used by \(action.displayName)."
            }
        }
        return nil
    }

    private func stableID(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "toggle-popup"
        case .targetAppVolumeUp: "frontmost-app-volume-up"
        case .targetAppVolumeDown: "frontmost-app-volume-down"
        case .targetAppMuteToggle: "frontmost-app-mute-toggle"
        }
    }
}

private extension SceneShortcut {
    init(_ shortcut: ShortcutCodable) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    static func from(_ shortcut: KeyboardShortcuts.Shortcut) -> SceneShortcut {
        SceneShortcut(
            keyCode: shortcut.carbonKeyCode,
            modifiers: UInt(shortcut.carbonModifiers)
        )
    }

    var keyboardShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: keyCode,
            carbonModifiers: Int(modifiers)
        )
    }
}
