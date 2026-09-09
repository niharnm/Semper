import Foundation
import KeyboardShortcuts

@MainActor
protocol SceneShortcutManaging: AnyObject {
    var scenes: [SemperScene] { get }
    func applyScene(id: UUID) async throws -> SceneCommandExecution
    func reportSceneCommandFailure(_ message: String)
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
    private var isShutDown = false
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

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
        guard !didStart, !isShutDown else { return }
        didStart = true
        sync()
    }

    func sync() {
        guard !isShutDown else { return }
        ShortcutAction.preservingOtherRegistrations(excluding: []) {
            let scenes = sceneManager.scenes
            let currentIDs = Set(scenes.map(\.id))
            let duplicateSceneShortcuts = Dictionary(
                grouping: scenes.compactMap { scene in
                    scene.shortcut.map { ($0, scene) }
                }, by: \.0
            ).filter { $0.value.count > 1 }

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
                    let otherNames =
                        owners
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
                        _ = self?.beginShortcut(for: scene.id)
                    }
                }
            }
            registeredSceneIDs = currentIDs
        }
    }

    func performShortcut(for sceneID: UUID) async {
        guard let task = beginShortcut(for: sceneID) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func beginShortcut(for sceneID: UUID) -> Task<Void, Never>? {
        guard !isShutDown, !Task.isCancelled else { return nil }
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.tasks[id] = nil }
            do {
                try Task.checkCancellation()
                _ = try await self.sceneManager.applyScene(id: sceneID)
            } catch {
                if !self.isShutDown { self.sceneManager.reportSceneCommandFailure(error.localizedDescription) }
            }
        }
        tasks[id] = task
        return task
    }

    func shutdown() async {
        isShutDown = true
        didStart = false
        ShortcutAction.preservingOtherRegistrations(excluding: []) {
            for id in registeredSceneIDs { KeyboardShortcuts.removeHandler(for: name(for: id)) }
        }
        registeredSceneIDs.removeAll()
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }

    func recordCallback(
        for scene: SemperScene
    ) -> @MainActor (KeyboardShortcuts.Shortcut?) -> Void {
        { [weak self] shortcut in
            self?.record(shortcut, for: scene)
        }
    }

    private func record(_ shortcut: KeyboardShortcuts.Shortcut?, for scene: SemperScene) {
        guard !isShutDown else { return }
        if let shortcut,
            let conflict = conflictDescription(
                for: SceneShortcut.from(shortcut),
                excluding: scene.id
            )
        {
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
        if ShortcutAction.conflictsWithSearch(ShortcutCodable(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
        {
            return "Already used by Search Semper."
        }
        for action in ShortcutAction.allCases {
            let assigned =
                settings.appSettings.customShortcuts[action.rawValue]
                ?? KeyboardShortcuts.getShortcut(
                    for: action.keyboardShortcutName
                ).map(ShortcutCodable.from)
            if assigned.map(SceneShortcut.init) == shortcut {
                return "Already used by \(action.displayName)."
            }
        }
        return nil
    }

}

extension SceneShortcut {
    fileprivate init(_ shortcut: ShortcutCodable) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    fileprivate static func from(_ shortcut: KeyboardShortcuts.Shortcut) -> SceneShortcut {
        SceneShortcut(
            keyCode: shortcut.carbonKeyCode,
            modifiers: UInt(shortcut.carbonModifiers)
        )
    }

    fileprivate var keyboardShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: keyCode,
            carbonModifiers: Int(modifiers)
        )
    }
}
