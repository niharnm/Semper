import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Semper

@MainActor
@Suite("Utility runtime startup", .serialized)
struct UtilityRuntimeTests {
    @Test(
        "Default and saved module selections leave Sound and Awake unconstructed",
        arguments: [nil, [], ["awake", "shelf"], ["sound", "awake"]] as [[String]?])
    func constructionIsDormant(addedModules: [String]?) async throws {
        try await withRuntime(addedModules: addedModules) { runtime, probe, defaults in
            #expect(runtime.sound == nil)
            #expect(runtime.awake == nil)
            #expect(probe.creationCount == 0)
            #expect(!runtime.updateManager.isConfigured)
            #expect(
                defaults.string(forKey: ExperimentManager.subjectKey)
                    == runtime.experiments.subjectID.uuidString.lowercased())
            for module in runtime.registry.modules {
                #expect(runtime.registry.state(for: module.id)?.runtime == .stopped)
                #expect(runtime.registry.state(for: module.id)?.permission == .unknown)
            }
            for _ in 0..<3 { await Task.yield() }
            #expect(runtime.sound == nil)
            #expect(runtime.awake == nil)
            #expect(probe.creationCount == 0)
        }
    }

    @Test(
        "Adding, pausing, removing, and adding again never starts a dormant module",
        arguments: [UtilityModuleID.sound, .awake, .shelf])
    func moduleManagementIsDormant(module: UtilityModuleID) async throws {
        try await withRuntime(addedModules: []) { runtime, probe, _ in
            try runtime.registry.add(module)
            #expect(runtime.registry.state(for: module)?.runtime == .stopped)
            try await runtime.pause(module)
            #expect(runtime.registry.state(for: module)?.runtime == .paused)
            try runtime.registry.resume(module)
            #expect(runtime.registry.state(for: module)?.runtime == .stopped)
            try await runtime.remove(module)
            #expect(runtime.registry.state(for: module)?.presence == .available)
            try runtime.registry.add(module)
            #expect(runtime.registry.state(for: module)?.presence == .added)
            #expect(runtime.registry.state(for: module)?.runtime == .stopped)
            #expect(runtime.registry.state(for: module)?.permission == .unknown)
            #expect(runtime.sound == nil)
            #expect(runtime.awake == nil)
            #expect(probe.creationCount == 0)
        }
    }

    @Test("Home summaries, search, and favorites read dormant state without starting services")
    func homeQueriesAreDormant() async throws {
        try await withRuntime { runtime, probe, _ in
            let openSound = UtilityActionID(rawValue: "sound.open")
            try runtime.registry.setFavorite(true, for: openSound)
            #expect(runtime.registry.favoriteActions.map(\.id) == [openSound])
            #expect(runtime.registry.search("sound").map(\.id) == [openSound])
            #expect(runtime.commands.disabledReason(for: openSound) == nil)
            #expect(
                runtime.commands.disabledReason(for: .init(rawValue: "awake.stop"))
                    == "No manual Awake session is active.")
            #expect(runtime.summary(for: .sound) == "Open Sound to start audio controls.")
            #expect(runtime.summary(for: .awake) == "No active Awake session")
            for module in runtime.registry.modules { _ = runtime.summary(for: module.id) }
            #expect(runtime.sound == nil)
            #expect(runtime.awake == nil)
            #expect(probe.creationCount == 0)
        }
    }

    @Test("Home and Modules render without constructing services or attaching shell actions")
    func dormantViewsRender() async throws {
        try await withRuntime { runtime, probe, _ in
            for (destination, path) in [
                (UtilityDestination.home, "/tmp/semper-shell-home.png"),
                (UtilityDestination.modules, "/tmp/semper-shell-modules.png"),
            ] {
                runtime.destination = destination
                let view = NSHostingView(
                    rootView: UtilityShellView(runtime: runtime, connectsShellActions: false)
                        .frame(width: 960, height: 760)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, .light))
                view.frame = NSRect(x: 0, y: 0, width: 960, height: 760)
                view.layoutSubtreeIfNeeded()
                await Task.yield()
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                #expect(view.window == nil)
                #expect(bitmap.pixelsWide >= 960)
                #expect(bitmap.pixelsHigh >= 760)
                #expect(bitmap.pixelsWide * 760 == bitmap.pixelsHigh * 960)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                #expect(runtime.onOpenDetail == nil)
                #expect(runtime.sound == nil)
                #expect(runtime.awake == nil)
                #expect(probe.creationCount == 0)
                for module in runtime.registry.modules {
                    #expect(runtime.registry.state(for: module.id)?.permission == .unknown)
                    #expect(runtime.registry.state(for: module.id)?.runtime == .stopped)
                }
            }
        }
    }

    @Test("Resetting dormant Sound settings does not create Sound")
    func resetsDormantSettings() async throws {
        try await withRuntime { runtime, probe, _ in
            runtime.settings.appSettings.defaultNewAppVolume = 0.4
            runtime.resetSoundSettings()
            #expect(runtime.settings.appSettings.defaultNewAppVolume == 1)
            #expect(probe.creationCount == 0)
            #expect(runtime.sound == nil)
        }
    }

    @Test("Repeated search requests select Home and send a new focus request")
    func requestsSearchFocus() async throws {
        try await withRuntime { runtime, probe, _ in
            runtime.destination = .modules
            let first = runtime.searchFocusRequest
            runtime.requestSearchFocus()
            let second = runtime.searchFocusRequest
            #expect(first != second)
            #expect(runtime.destination == .home)
            runtime.requestSearchFocus()
            #expect(runtime.searchFocusRequest != second)
            #expect(probe.creationCount == 0)
        }
    }

    private func withRuntime(
        addedModules: [String]? = nil,
        _ operation: (UtilityRuntime, SoundCreationProbe, UserDefaults) async throws -> Void
    ) async throws {
        let suite = "SemperUtilityRuntimeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if let addedModules {
            defaults.set(addedModules, forKey: ModuleRegistry.PersistenceKey.addedModules)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        defer {
            settings.flushSync()
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) } catch {
                    Issue.record(error, "Could not remove test settings")
                }
            }
        }
        let updater = UpdateManager(bundle: Bundle(for: NSObject.self), userDefaults: defaults)
        let probe = SoundCreationProbe()
        let runtime = try UtilityRuntime(
            settings: settings,
            defaults: defaults,
            updateManager: updater,
            soundFactory: probe.makeSound
        )
        #expect(runtime.updateManager === updater)
        do {
            try await operation(runtime, probe, defaults)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
        #expect(runtime.sound == nil)
        #expect(runtime.awake == nil)
        #expect(probe.creationCount == 0)
    }
}

@MainActor
private final class SoundCreationProbe {
    private(set) var creationCount = 0

    func makeSound(
        _ settings: SettingsManager,
        _ ddc: AudioEngine.SharedDDCController?
    ) throws -> SoundRuntime {
        creationCount += 1
        throw UnexpectedSoundCreation.attempted
    }
}

private enum UnexpectedSoundCreation: Error {
    case attempted
}
