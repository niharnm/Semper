import Foundation
import Observation

enum UtilityModuleID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case sound
    case awake
    case displays
    case workspace
    case shelf
    case storage
    case scenes
    case away
    case presentation

    var id: String { rawValue }
}

struct UtilityModuleDescriptor: Identifiable, Equatable, Sendable {
    let id: UtilityModuleID
    let title: String
    let summary: String
    let symbolName: String
    var unsupportedReason: String? = nil
    var disclosure: UtilityModuleDisclosure = .init()

    static let catalog: [Self] = [
        .init(
            id: .sound, title: "Sound", summary: "Control app and device audio.", symbolName: "speaker.wave.2.fill",
            disclosure: .init(
                permissionReasons: [
                    .init(
                        name: "Screen & System Audio Recording",
                        reason: "Required to control audio from individual apps."),
                    .init(name: "Accessibility", reason: "Optional access for system media-key controls."),
                    .init(
                        name: "Microphone",
                        reason: "macOS may request access for audio devices that also expose microphone inputs."),
                ],
                idleBackgroundPolicy: "No audio monitoring starts when Sound is added.",
                runningBackgroundPolicy:
                    "Observes audio apps and devices while running. Processing applies to controlled audio; media-key listening runs when enabled.",
                localDataPolicy:
                    "App and device audio preferences, imported EQ profiles, and downloaded AutoEQ data are stored locally. Removing Sound keeps these files.",
                settingsSchemaVersion: 17,
                resources: .optionalDownloads(
                    description:
                        "Opening AutoEQ search can fetch its catalog. Selected headphone profiles are downloaded and cached for reuse.",
                    sizeBytes: nil
                )
            )
        ),
        .init(
            id: .awake, title: "Awake", summary: "Keep your Mac awake for a chosen duration.",
            symbolName: "sun.max.fill",
            disclosure: .init(
                permissionReasons: [],
                runningBackgroundPolicy:
                    "Listens for wake events while running. Active sessions hold sleep assertions; timed sessions also schedule an expiry timer.",
                localDataPolicy:
                    "The current Awake session is held in memory. Quitting ends it; it is not restored on launch.",
                hardwareRequirements: ["Closing the lid or choosing Sleep still works."]
            )
        ),
        .init(id: .displays, title: "Displays", summary: "Adjust supported display brightness.", symbolName: "display"),
        .init(
            id: .workspace, title: "Workspace Restore", summary: "Save and restore app window positions.",
            symbolName: "macwindow.on.rectangle"),
        .init(
            id: .shelf, title: "File Shelf", summary: "Keep references to files close at hand.", symbolName: "tray.fill"
        ),
        .init(id: .storage, title: "Safe Eject", summary: "Eject removable volumes safely.", symbolName: "eject.fill"),
        .init(
            id: .scenes, title: "Scenes", summary: "Apply saved utility settings together.",
            symbolName: "square.stack.3d.up.fill"),
        .init(id: .away, title: "Away", summary: "Start a protected away session.", symbolName: "lock.shield.fill"),
        .init(
            id: .presentation, title: "Presentation", summary: "Prepare a timed presentation session.",
            symbolName: "play.rectangle.fill",
            disclosure: .init(requiredModules: [.awake], selectedModules: [.displays, .workspace, .sound])
        ),
    ]
}

struct UtilityPermissionDisclosure: Equatable, Sendable {
    let name: String
    let reason: String
}

enum UtilityModuleResources: Equatable, Sendable {
    case builtIn
    case optionalDownloads(description: String, sizeBytes: Int64?)
}

struct UtilityModuleDisclosure: Equatable, Sendable {
    var permissionReasons: [UtilityPermissionDisclosure]? = nil
    var idleBackgroundPolicy = "Adding this module starts no service or background monitoring."
    var runningBackgroundPolicy: String? = nil
    var localDataPolicy = "Removing this module keeps its saved data. Data deletion is a separate action."
    var requiredModules: [UtilityModuleID] = []
    var selectedModules: [UtilityModuleID] = []
    var conflicts: [String] = []
    var settingsSchemaVersion: Int? = nil
    var minimumOS = "macOS 15.4 or later"
    var hardwareRequirements: [String] = []
    var resources: UtilityModuleResources = .builtIn
}

struct UtilityActionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

struct UtilityActionDescriptor: Identifiable, Equatable, Sendable {
    let id: UtilityActionID
    let module: UtilityModuleID
    let title: String
    let keywords: [String]
    let symbolName: String
    var confirmationMessage: String? = nil
}

enum ModulePresence: Equatable, Sendable {
    case available
    case added
    case unsupported(reason: String)
}

enum ModuleRuntimeState: Equatable, Sendable {
    case stopped
    case preparing
    case ready
    case active
    case paused
    case limited(reason: String)
    case failed(reason: String)
    case removing
}

enum ModulePermissionState: Equatable, Sendable {
    case unknown
    case notRequired
    case notDetermined
    case granted
    case denied
    case restricted
    case revoked
}

struct ModuleState: Equatable, Sendable {
    let presence: ModulePresence
    let runtime: ModuleRuntimeState
    let permission: ModulePermissionState
}

enum ModuleRegistryError: Error, Equatable {
    case duplicateModule(UtilityModuleID)
    case duplicateAction(UtilityActionID)
    case unknownModule(UtilityModuleID)
    case unknownAction(UtilityActionID)
    case unsupportedModule(UtilityModuleID, reason: String)
    case moduleNotAdded(UtilityModuleID)
    case modulePaused(UtilityModuleID)
    case transitionInProgress(UtilityModuleID)
    case noMatchingTransition(UtilityModuleID)
    case lifecycleStateRequiresTransition(ModuleRuntimeState)
    case actionUnavailable(UtilityActionID)
    case favoriteLimitReached
}

@Observable
@MainActor
final class ModuleRegistry {
    static let maximumFavorites = 4

    enum PersistenceKey {
        static let addedModules = "modules.added.v1"
        static let pausedModules = "modules.paused.v1"
        static let favoriteActions = "modules.favorites.v1"
    }

    private(set) var modules: [UtilityModuleDescriptor]
    private(set) var favoriteIDs: [UtilityActionID]
    private(set) var addedModuleIDs: Set<UtilityModuleID>
    private(set) var pausedModuleIDs: Set<UtilityModuleID>

    private var descriptors: [UtilityModuleID: UtilityModuleDescriptor]
    private var actions: [UtilityActionID: UtilityActionDescriptor] = [:]
    private var runtimeStates: [UtilityModuleID: ModuleRuntimeState] = [:]
    private var permissions: [UtilityModuleID: ModulePermissionState] = [:]
    private var pendingChanges: [UtilityModuleID: PendingChange] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    private enum PendingChange {
        case pause
        case removal
    }

    init(
        defaults: UserDefaults = .standard,
        modules: [UtilityModuleDescriptor] = UtilityModuleDescriptor.catalog
    ) throws {
        var catalog: [UtilityModuleID: UtilityModuleDescriptor] = [:]
        for module in modules {
            guard catalog[module.id] == nil else {
                throw ModuleRegistryError.duplicateModule(module.id)
            }
            catalog[module.id] = module
        }
        self.defaults = defaults
        self.modules = modules
        descriptors = catalog

        let storedAdded = defaults.stringArray(forKey: PersistenceKey.addedModules)
        let loadedAdded = Set((storedAdded ?? ["sound", "awake"]).compactMap(UtilityModuleID.init(rawValue:)))
            .intersection(catalog.keys)
        addedModuleIDs = loadedAdded
        pausedModuleIDs = Set(
            (defaults.stringArray(forKey: PersistenceKey.pausedModules) ?? [])
                .compactMap(UtilityModuleID.init(rawValue:))
        ).intersection(loadedAdded)
        var seenFavorites: Set<UtilityActionID> = []
        favoriteIDs = (defaults.stringArray(forKey: PersistenceKey.favoriteActions) ?? [])
            .map(UtilityActionID.init(rawValue:))
            .filter { seenFavorites.insert($0).inserted }
            .prefix(Self.maximumFavorites).map { $0 }
        for id in pausedModuleIDs {
            runtimeStates[id] = .paused
        }
        persistModules()
    }

    var addedModules: [UtilityModuleDescriptor] {
        modules.filter { state(for: $0.id)?.presence == .added }
    }

    var favoriteActions: [UtilityActionDescriptor] {
        favoriteIDs.compactMap { action(for: $0) }
    }

    func descriptor(for id: UtilityModuleID) -> UtilityModuleDescriptor? {
        descriptors[id]
    }

    func state(for id: UtilityModuleID) -> ModuleState? {
        guard let descriptor = descriptors[id] else { return nil }
        let presence: ModulePresence
        if let reason = descriptor.unsupportedReason {
            presence = .unsupported(reason: reason)
        } else {
            presence = addedModuleIDs.contains(id) ? .added : .available
        }
        return ModuleState(
            presence: presence,
            runtime: runtimeStates[id] ?? .stopped,
            permission: permissions[id] ?? .unknown
        )
    }

    func register(module: UtilityModuleDescriptor) throws {
        guard descriptors[module.id] == nil else {
            throw ModuleRegistryError.duplicateModule(module.id)
        }
        modules.append(module)
        descriptors[module.id] = module
    }

    func register(actions additions: [UtilityActionDescriptor]) throws {
        var newIDs: Set<UtilityActionID> = []
        for action in additions {
            guard descriptors[action.module] != nil else {
                throw ModuleRegistryError.unknownModule(action.module)
            }
            guard actions[action.id] == nil, newIDs.insert(action.id).inserted else {
                throw ModuleRegistryError.duplicateAction(action.id)
            }
        }
        for action in additions {
            actions[action.id] = action
        }
    }

    func finishActionRegistration() {
        favoriteIDs.removeAll { id in
            guard let action = actions[id] else { return true }
            return state(for: action.module)?.presence != .added
        }
        persistFavorites()
    }

    func actionMetadata(for id: UtilityActionID) -> UtilityActionDescriptor? {
        actions[id]
    }

    func action(for id: UtilityActionID) -> UtilityActionDescriptor? {
        guard let action = actions[id], isVisible(action) else { return nil }
        return action
    }

    func search(_ query: String) -> [UtilityActionDescriptor] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return actions.values.filter { action in
            guard isVisible(action) else { return false }
            let module = descriptors[action.module]
            let searchable = ([action.title, action.module.rawValue, module?.title ?? ""] + action.keywords)
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { searchable.contains($0) }
        }.sorted { first, second in
            let firstTitle = first.title.lowercased()
            let secondTitle = second.title.lowercased()
            if firstTitle != secondTitle { return firstTitle < secondTitle }
            return first.id.rawValue < second.id.rawValue
        }
    }

    func setFavorite(_ isFavorite: Bool, for id: UtilityActionID) throws {
        guard actions[id] != nil else { throw ModuleRegistryError.unknownAction(id) }
        if isFavorite {
            guard action(for: id) != nil else { throw ModuleRegistryError.actionUnavailable(id) }
            guard !favoriteIDs.contains(id) else { return }
            guard favoriteIDs.count < Self.maximumFavorites else {
                throw ModuleRegistryError.favoriteLimitReached
            }
            favoriteIDs.append(id)
        } else {
            favoriteIDs.removeAll { $0 == id }
        }
        persistFavorites()
    }

    func add(_ id: UtilityModuleID) throws {
        try requireSupported(id)
        try requireNoPendingChange(id)
        guard addedModuleIDs.insert(id).inserted else { return }
        runtimeStates[id] = .stopped
        persistModules()
    }

    func resume(_ id: UtilityModuleID) throws {
        try requireAdded(id)
        try requireNoPendingChange(id)
        guard pausedModuleIDs.remove(id) != nil else { return }
        runtimeStates[id] = .stopped
        persistModules()
    }

    func setRuntime(_ runtime: ModuleRuntimeState, for id: UtilityModuleID) throws {
        try requireAdded(id)
        try requireNoPendingChange(id)
        guard !pausedModuleIDs.contains(id) else { throw ModuleRegistryError.modulePaused(id) }
        guard runtime != .paused, runtime != .removing else {
            throw ModuleRegistryError.lifecycleStateRequiresTransition(runtime)
        }
        runtimeStates[id] = runtime
    }

    func setPermission(_ permission: ModulePermissionState, for id: UtilityModuleID) throws {
        guard descriptors[id] != nil else { throw ModuleRegistryError.unknownModule(id) }
        permissions[id] = permission
    }

    func beginPause(_ id: UtilityModuleID) throws {
        try requireAdded(id)
        try requireNoPendingChange(id)
        pendingChanges[id] = .pause
        pausedModuleIDs.insert(id)
        runtimeStates[id] = .paused
        persistModules()
    }

    func completePause(_ id: UtilityModuleID) throws {
        guard pendingChanges[id] == .pause else { throw ModuleRegistryError.noMatchingTransition(id) }
        pendingChanges[id] = nil
    }

    func beginRemoval(_ id: UtilityModuleID) throws {
        try requireAdded(id)
        try requireNoPendingChange(id)
        pendingChanges[id] = .removal
        runtimeStates[id] = .removing
    }

    func completeRemoval(_ id: UtilityModuleID) throws {
        guard pendingChanges[id] == .removal else { throw ModuleRegistryError.noMatchingTransition(id) }
        pendingChanges[id] = nil
        addedModuleIDs.remove(id)
        pausedModuleIDs.remove(id)
        runtimeStates[id] = .stopped
        favoriteIDs.removeAll { actions[$0]?.module == id }
        persistModules()
        persistFavorites()
    }

    func failTransition(_ id: UtilityModuleID, reason: String) throws {
        guard pendingChanges[id] != nil else { throw ModuleRegistryError.noMatchingTransition(id) }
        pendingChanges[id] = nil
        pausedModuleIDs.insert(id)
        runtimeStates[id] = .failed(reason: reason)
        persistModules()
    }

    private func isVisible(_ action: UtilityActionDescriptor) -> Bool {
        state(for: action.module)?.presence == .added
            && !pausedModuleIDs.contains(action.module)
            && pendingChanges[action.module] == nil
    }

    private func requireSupported(_ id: UtilityModuleID) throws {
        guard let descriptor = descriptors[id] else { throw ModuleRegistryError.unknownModule(id) }
        if let reason = descriptor.unsupportedReason {
            throw ModuleRegistryError.unsupportedModule(id, reason: reason)
        }
    }

    private func requireAdded(_ id: UtilityModuleID) throws {
        try requireSupported(id)
        guard addedModuleIDs.contains(id) else { throw ModuleRegistryError.moduleNotAdded(id) }
    }

    private func requireNoPendingChange(_ id: UtilityModuleID) throws {
        guard pendingChanges[id] == nil else { throw ModuleRegistryError.transitionInProgress(id) }
    }

    private func persistModules() {
        defaults.set(addedModuleIDs.map(\.rawValue).sorted(), forKey: PersistenceKey.addedModules)
        defaults.set(pausedModuleIDs.map(\.rawValue).sorted(), forKey: PersistenceKey.pausedModules)
    }

    private func persistFavorites() {
        defaults.set(favoriteIDs.map(\.rawValue), forKey: PersistenceKey.favoriteActions)
    }
}
