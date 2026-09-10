import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Module library presentation")
struct ModuleLibraryPresentationTests {
    @Test("Filters track module presence while keeping paused tools in Added")
    func filtersTrackPresence() throws {
        try withRegistry { registry, _ in
            #expect(ModuleLibraryFilter.all.modules(in: registry).map(\.id) == registry.modules.map(\.id))
            #expect(ModuleLibraryFilter.added.modules(in: registry).map(\.id) == [.sound, .awake])
            #expect(ModuleLibraryFilter.available.modules(in: registry).count == registry.modules.count - 2)

            try registry.add(.workspace)
            try registry.beginPause(.awake)
            try registry.failTransition(.awake, reason: "Stop needs another attempt.")

            #expect(ModuleLibraryFilter.added.modules(in: registry).map(\.id) == [.sound, .awake, .workspace])
            #expect(!ModuleLibraryFilter.available.modules(in: registry).contains { $0.id == .workspace })
            #expect(ModuleLibraryFilter.added.modules(in: registry, matching: "awake").map(\.id) == [.awake])
        }
    }

    @Test("Search matches every term across titles and summaries regardless of case or whitespace")
    func searchMatchesToolPurpose() throws {
        try withRegistry { registry, _ in
            #expect(ModuleLibraryFilter.all.modules(in: registry, matching: "  AUDIO\tdevice\n").map(\.id) == [.sound])
            #expect(ModuleLibraryFilter.all.modules(in: registry, matching: "window restore").map(\.id) == [.workspace])
            #expect(ModuleLibraryFilter.all.modules(in: registry, matching: "FILES").map(\.id) == [.shelf])
            #expect(ModuleLibraryFilter.all.modules(in: registry, matching: "audio window").isEmpty)
            #expect(ModuleLibraryFilter.added.modules(in: registry, matching: "files").isEmpty)
            #expect(ModuleLibraryFilter.available.modules(in: registry, matching: "files").map(\.id) == [.shelf])
            #expect(ModuleLibraryFilter.all.modules(in: registry, matching: " \n\t ").count == registry.modules.count)
        }
    }

    @Test("Unsupported modules remain discoverable without appearing available to add")
    func unsupportedModulesRemainVisible() throws {
        var modules = UtilityModuleDescriptor.catalog
        let displayIndex = try #require(modules.firstIndex { $0.id == .displays })
        modules[displayIndex].unsupportedReason = "This Mac does not support this display control."

        try withRegistry(modules: modules) { registry, _ in
            #expect(ModuleLibraryFilter.all.modules(in: registry, matching: "display").map(\.id) == [.displays])
            #expect(ModuleLibraryFilter.available.modules(in: registry, matching: "display").isEmpty)
            #expect(ModuleLibraryFilter.added.modules(in: registry, matching: "display").isEmpty)
        }
    }

    @Test("Browsing filters preserves permission, runtime and saved module state")
    func browsingDoesNotMutateState() throws {
        try withRegistry { registry, defaults in
            try registry.setPermission(.denied, for: .workspace)
            let states = registry.modules.map { registry.state(for: $0.id) }
            let added = defaults.stringArray(forKey: ModuleRegistry.PersistenceKey.addedModules)
            let paused = defaults.stringArray(forKey: ModuleRegistry.PersistenceKey.pausedModules)

            for filter in ModuleLibraryFilter.allCases {
                _ = filter.modules(in: registry)
                _ = filter.modules(in: registry, matching: "windows")
            }

            #expect(registry.modules.map { registry.state(for: $0.id) } == states)
            #expect(defaults.stringArray(forKey: ModuleRegistry.PersistenceKey.addedModules) == added)
            #expect(defaults.stringArray(forKey: ModuleRegistry.PersistenceKey.pausedModules) == paused)
        }
    }

    private func withRegistry(
        modules: [UtilityModuleDescriptor] = UtilityModuleDescriptor.catalog,
        body: (ModuleRegistry, UserDefaults) throws -> Void
    ) throws {
        let suite = "ModuleLibraryPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(ModuleRegistry(defaults: defaults, modules: modules), defaults)
    }
}
