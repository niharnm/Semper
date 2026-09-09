import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Module registry")
struct ModuleRegistryTests {
    @Test("Migration adds Sound and Awake with no active runtime or permission request")
    func initialState() throws {
        try withRegistry { registry, _ in
            #expect(registry.addedModuleIDs == [.sound, .awake])
            for module in UtilityModuleID.allCases {
                #expect(registry.state(for: module)?.runtime == .stopped)
                #expect(registry.state(for: module)?.permission == .unknown)
            }
            #expect(registry.search("").isEmpty)
        }
    }

    @Test("Adding a module changes presence without starting runtime or changing permission")
    func addingDoesNotStartRuntime() throws {
        try withRegistry { registry, _ in
            try registry.setPermission(.denied, for: .workspace)
            try registry.add(.workspace)

            #expect(
                registry.state(for: .workspace)
                    == ModuleState(
                        presence: .added, runtime: .stopped, permission: .denied
                    ))
            try registry.setRuntime(.limited(reason: "Accessibility access required"), for: .workspace)
            #expect(registry.state(for: .workspace)?.presence == .added)
            #expect(registry.state(for: .workspace)?.permission == .denied)
            try registry.add(.workspace)
            #expect(registry.state(for: .workspace)?.runtime == .limited(reason: "Accessibility access required"))
        }
    }

    @Test("An Awake and Shelf configuration keeps Sound available and stopped")
    func startupWithoutSound() throws {
        try withRegistry { _, defaults in
            defaults.set(["awake", "shelf"], forKey: ModuleRegistry.PersistenceKey.addedModules)
            let registry = try ModuleRegistry(defaults: defaults)

            #expect(registry.addedModuleIDs == [.awake, .shelf])
            #expect(
                registry.state(for: .sound)
                    == ModuleState(
                        presence: .available, runtime: .stopped, permission: .unknown
                    ))
        }
    }

    @Test("Duplicate catalog module identifiers are rejected")
    func duplicateModules() throws {
        try withRegistry { registry, defaults in
            let descriptor = try #require(registry.descriptor(for: .sound))
            #expect(throws: ModuleRegistryError.duplicateModule(.sound)) {
                try ModuleRegistry(defaults: defaults, modules: [descriptor, descriptor])
            }
            #expect(throws: ModuleRegistryError.duplicateModule(.sound)) {
                try registry.register(module: descriptor)
            }
        }
    }

    @Test("An action batch rejects duplicates atomically")
    func duplicateActions() throws {
        try withRegistry { registry, _ in
            let first = action("awake.start", title: "Start Awake")
            let second = action("awake.stop", title: "Stop Awake")
            #expect(throws: ModuleRegistryError.duplicateAction(first.id)) {
                try registry.register(actions: [first, second, first])
            }
            #expect(registry.search("").isEmpty)
            try registry.register(actions: [first])
            #expect(throws: ModuleRegistryError.duplicateAction(first.id)) {
                try registry.register(actions: [second, first])
            }
            #expect(registry.actionMetadata(for: second.id) == nil)
        }
    }

    @Test("Actions for modules outside the catalog are rejected atomically")
    func unknownActionModule() throws {
        let onlySound = UtilityModuleDescriptor.catalog.filter { $0.id == .sound }
        try withRegistry(modules: onlySound) { registry, _ in
            let unknown = action("awake.start", title: "Start Awake")
            #expect(throws: ModuleRegistryError.unknownModule(.awake)) {
                try registry.register(actions: [unknown])
            }
            #expect(registry.actionMetadata(for: unknown.id) == nil)
        }
    }

    @Test("Search matches every case-insensitive term and orders equal titles by stable ID")
    func deterministicSearch() throws {
        try withRegistry { registry, _ in
            let actions = [
                action("awake.stop", title: "Stop", keywords: ["rest", "timer"]),
                action("awake.start.z", title: "START", keywords: ["timer"]),
                action("awake.start.a", title: "Start", keywords: ["timer"]),
                action("sound.start", module: .sound, title: "Start", keywords: ["play"]),
            ]
            try registry.register(actions: actions)

            #expect(
                registry.search("  AWAKE   tiMER ").map(\.id.rawValue) == [
                    "awake.start.a", "awake.start.z", "awake.stop",
                ])
            #expect(registry.search("missing").isEmpty)
            #expect(registry.search("play").map(\.id.rawValue) == ["sound.start"])
            #expect(
                registry.search("").map(\.id.rawValue) == [
                    "awake.start.a", "awake.start.z", "sound.start", "awake.stop",
                ])
        }
    }

    @Test("Available and paused modules are excluded from search and action admission")
    func visibility() throws {
        try withRegistry { registry, _ in
            let shelfAction = action("shelf.open", module: .shelf, title: "Open Shelf")
            try registry.register(actions: [shelfAction])
            #expect(registry.search("").isEmpty)
            #expect(registry.action(for: shelfAction.id) == nil)
            #expect(registry.actionMetadata(for: shelfAction.id) == shelfAction)

            try registry.add(.shelf)
            #expect(registry.action(for: shelfAction.id) == shelfAction)
            try registry.beginPause(.shelf)
            #expect(registry.search("").isEmpty)
            #expect(registry.action(for: shelfAction.id) == nil)
            try registry.completePause(.shelf)
            try registry.resume(.shelf)
            #expect(registry.action(for: shelfAction.id) == shelfAction)
            #expect(registry.state(for: .shelf)?.runtime == .stopped)
        }
    }

    @Test("Pause blocks starts and resume until draining completes")
    func pauseDrainGuard() throws {
        try withRegistry { registry, _ in
            try registry.setRuntime(.active, for: .awake)
            try registry.beginPause(.awake)
            #expect(throws: ModuleRegistryError.transitionInProgress(.awake)) {
                try registry.resume(.awake)
            }
            #expect(throws: ModuleRegistryError.transitionInProgress(.awake)) {
                try registry.setRuntime(.active, for: .awake)
            }
            #expect(throws: ModuleRegistryError.noMatchingTransition(.awake)) {
                try registry.completeRemoval(.awake)
            }
            try registry.completePause(.awake)
            #expect(throws: ModuleRegistryError.modulePaused(.awake)) {
                try registry.setRuntime(.ready, for: .awake)
            }
            try registry.resume(.awake)
            #expect(registry.state(for: .awake)?.runtime == .stopped)
        }
    }

    @Test("Removal blocks starts, retains unrelated data, prunes favorites, and permits stopped re-add")
    func removalAndReaddition() throws {
        try withRegistry { registry, defaults in
            let awakeAction = action("awake.start", title: "Start Awake")
            try registry.register(actions: [awakeAction])
            try registry.setFavorite(true, for: awakeAction.id)
            defaults.set("keep", forKey: "awake.savedSession")
            try registry.setPermission(.notRequired, for: .awake)
            try registry.setRuntime(.active, for: .awake)
            try registry.beginRemoval(.awake)

            #expect(registry.state(for: .awake)?.runtime == .removing)
            #expect(registry.action(for: awakeAction.id) == nil)
            #expect(throws: ModuleRegistryError.transitionInProgress(.awake)) {
                try registry.setRuntime(.preparing, for: .awake)
            }
            #expect(throws: ModuleRegistryError.transitionInProgress(.awake)) {
                try registry.add(.awake)
            }
            try registry.completeRemoval(.awake)
            #expect(registry.favoriteIDs.isEmpty)
            #expect(defaults.string(forKey: "awake.savedSession") == "keep")
            #expect(registry.state(for: .awake)?.presence == .available)
            #expect(registry.state(for: .awake)?.permission == .notRequired)
            #expect(throws: ModuleRegistryError.moduleNotAdded(.awake)) {
                try registry.setRuntime(.preparing, for: .awake)
            }
            try registry.add(.awake)
            #expect(registry.state(for: .awake)?.runtime == .stopped)
            #expect(registry.action(for: awakeAction.id) == awakeAction)
        }
    }

    @Test("A failed drain keeps actions unavailable until explicit resume")
    func failedDrain() throws {
        try withRegistry { registry, _ in
            let awakeAction = action("awake.start", title: "Start Awake")
            try registry.register(actions: [awakeAction])
            try registry.beginRemoval(.awake)
            try registry.failTransition(.awake, reason: "Shutdown failed")

            #expect(registry.state(for: .awake)?.presence == .added)
            #expect(registry.state(for: .awake)?.runtime == .failed(reason: "Shutdown failed"))
            #expect(registry.action(for: awakeAction.id) == nil)
            #expect(throws: ModuleRegistryError.modulePaused(.awake)) {
                try registry.setRuntime(.preparing, for: .awake)
            }
            try registry.resume(.awake)
            #expect(registry.state(for: .awake)?.runtime == .stopped)
        }
    }

    @Test("Lifecycle-only runtime states cannot bypass draining methods")
    func lifecycleStatesRequireTransitions() throws {
        try withRegistry { registry, _ in
            #expect(throws: ModuleRegistryError.lifecycleStateRequiresTransition(.paused)) {
                try registry.setRuntime(.paused, for: .awake)
            }
            #expect(throws: ModuleRegistryError.lifecycleStateRequiresTransition(.removing)) {
                try registry.setRuntime(.removing, for: .awake)
            }
            #expect(registry.state(for: .awake)?.runtime == .stopped)
        }
    }

    @Test("Favorites are stable, capped at four, and persisted in order")
    func favoritePersistenceAndLimit() throws {
        try withRegistry { registry, defaults in
            let actions = (1...5).map { action("awake.\($0)", title: "Action \($0)") }
            try registry.register(actions: actions)
            for action in actions.prefix(4) {
                try registry.setFavorite(true, for: action.id)
            }
            try registry.setFavorite(true, for: actions[0].id)
            #expect(throws: ModuleRegistryError.favoriteLimitReached) {
                try registry.setFavorite(true, for: actions[4].id)
            }

            let reloaded = try ModuleRegistry(defaults: defaults)
            try reloaded.register(actions: actions)
            reloaded.finishActionRegistration()
            #expect(reloaded.favoriteActions == Array(actions.prefix(4)))
            try reloaded.setFavorite(false, for: actions[1].id)
            try reloaded.setFavorite(true, for: actions[4].id)
            #expect(reloaded.favoriteIDs == [actions[0].id, actions[2].id, actions[3].id, actions[4].id])
        }
    }

    @Test("Incremental action registration retains known favorites and prunes stale identifiers on completion")
    func favoritePruning() throws {
        try withRegistry { _, defaults in
            defaults.set(
                ["awake.start", "unknown.action", "sound.open", "shelf.open"],
                forKey: ModuleRegistry.PersistenceKey.favoriteActions
            )
            let registry = try ModuleRegistry(defaults: defaults)
            let awakeAction = action("awake.start", title: "Start Awake")
            let soundAction = action("sound.open", module: .sound, title: "Open Sound")
            let shelfAction = action("shelf.open", module: .shelf, title: "Open Shelf")
            try registry.register(actions: [awakeAction])
            #expect(registry.favoriteIDs.count == 4)
            try registry.register(actions: [soundAction, shelfAction])
            registry.finishActionRegistration()

            #expect(registry.favoriteIDs == [awakeAction.id, soundAction.id])
            #expect(
                defaults.stringArray(forKey: ModuleRegistry.PersistenceKey.favoriteActions) == [
                    "awake.start", "sound.open",
                ])
        }
    }

    @Test("Paused favorites persist and reappear after resume")
    func pausedFavorites() throws {
        try withRegistry { registry, defaults in
            let awakeAction = action("awake.start", title: "Start Awake")
            try registry.register(actions: [awakeAction])
            try registry.setFavorite(true, for: awakeAction.id)
            try registry.beginPause(.awake)
            try registry.completePause(.awake)

            let reloaded = try ModuleRegistry(defaults: defaults)
            try reloaded.register(actions: [awakeAction])
            reloaded.finishActionRegistration()
            #expect(reloaded.favoriteActions.isEmpty)
            #expect(reloaded.favoriteIDs == [awakeAction.id])
            #expect(reloaded.state(for: .awake)?.runtime == .paused)
            try reloaded.resume(.awake)
            #expect(reloaded.favoriteActions == [awakeAction])
        }
    }

    @Test("Stale persisted module IDs are ignored and an empty saved selection stays empty")
    func staleModulePersistence() throws {
        try withRegistry { _, defaults in
            defaults.set(["awake", "retired-module"], forKey: ModuleRegistry.PersistenceKey.addedModules)
            defaults.set(["awake", "shelf", "retired-module"], forKey: ModuleRegistry.PersistenceKey.pausedModules)
            let registry = try ModuleRegistry(defaults: defaults)
            #expect(registry.addedModuleIDs == [.awake])
            #expect(registry.pausedModuleIDs == [.awake])

            defaults.set([String](), forKey: ModuleRegistry.PersistenceKey.addedModules)
            let empty = try ModuleRegistry(defaults: defaults)
            #expect(empty.addedModules.isEmpty)
            #expect(empty.pausedModuleIDs.isEmpty)
        }
    }

    @Test("Unsupported modules carry their exact catalog reason and cannot be added")
    func unsupportedModule() throws {
        let descriptor = UtilityModuleDescriptor(
            id: .displays, title: "Displays", summary: "Brightness", symbolName: "display",
            unsupportedReason: "Requires a supported display connection"
        )
        try withRegistry(modules: [descriptor]) { registry, _ in
            #expect(
                registry.state(for: .displays)?.presence
                    == .unsupported(
                        reason: "Requires a supported display connection"
                    ))
            #expect(
                throws: ModuleRegistryError.unsupportedModule(
                    .displays, reason: "Requires a supported display connection"
                )
            ) {
                try registry.add(.displays)
            }
        }
    }

    private func action(
        _ id: String,
        module: UtilityModuleID = .awake,
        title: String,
        keywords: [String] = []
    ) -> UtilityActionDescriptor {
        UtilityActionDescriptor(
            id: UtilityActionID(rawValue: id), module: module, title: title,
            keywords: keywords, symbolName: "play"
        )
    }

    private func withRegistry(
        modules: [UtilityModuleDescriptor] = UtilityModuleDescriptor.catalog,
        body: (ModuleRegistry, UserDefaults) throws -> Void
    ) throws {
        let suite = "ModuleRegistryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(ModuleRegistry(defaults: defaults, modules: modules), defaults)
    }
}
