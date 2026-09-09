#if DEBUG
    import Foundation
    import Synchronization
    import Testing

    @testable import Semper

    @MainActor
    @Suite("Shell UI test fixture", .serialized, .timeLimit(.minutes(1)))
    struct ShellUITestFixtureTests {
        @Test("Construction, Home queries and module metadata never create services or a host")
        func constructionAndMetadataRemainDormant() async throws {
            try await withFixture { fixture in
                let runtime = fixture.runtime
                #expect(ShellUITestFixture.enabledArgument == "--shell-ui-testing")
                #expect(runtime.registry.addedModuleIDs == [.sound])
                #expect(!runtime.updateManager.isConfigured)
                #expect(!runtime.updateManager.hasUpdaterControllerForTesting)
                #expect(!runtime.updateManager.canCheckForUpdates)
                #expect(!runtime.updateManager.automaticUpdatesEnabled)
                #expect(!fixture.hasHostWindow)
                expectDormant(fixture)
                let openSound = UtilityActionID(rawValue: "sound.open")
                try runtime.registry.setFavorite(true, for: openSound)
                #expect(runtime.registry.favoriteActions.map(\.id) == [openSound])
                runtime.searchText = "Sound"
                #expect(runtime.registry.search(runtime.searchText).count == 3)
                #expect(runtime.commands.disabledReason(for: openSound) == nil)
                for module in runtime.registry.modules {
                    _ = runtime.summary(for: module.id)
                    try runtime.registry.add(module.id)
                    runtime.destination = .module(module.id)
                    #expect(runtime.registry.state(for: module.id)?.runtime == .stopped)
                    try await runtime.pause(module.id)
                    try runtime.registry.resume(module.id)
                    try await runtime.remove(module.id)
                    #expect(runtime.registry.state(for: module.id)?.presence == .available)
                }
                runtime.destination = .modules
                #expect(!fixture.hasHostWindow)
                expectDormant(fixture)
                #expect(try FileSceneLibraryStore(directory: fixture.sceneDirectory).loadScenes().isEmpty)
                #expect(try FileSceneJournalStore(directory: fixture.sceneDirectory).load() == nil)
            }
        }

        @Test(
            "Explicit startup records the unavailable factory without creating its service",
            arguments: [UtilityModuleID.sound, .awake, .workspace, .shelf, .storage, .displays, .away])
        func factoriesRejectStartup(_ module: UtilityModuleID) async throws {
            try await withFixture { fixture in
                try fixture.runtime.registry.add(module)
                await #expect(throws: UtilityLifecycleError.self) { try await fixture.runtime.start(module) }
                #expect(fixture.factoryAttempts == [module: 1])
                expectServicesAbsent(fixture.runtime)
                #expect(!fixture.hasHostWindow)
            }
        }

        @Test("Temporary directories and defaults are unique, and cleanup preserves other fixtures")
        func resourcesAreIsolated() async throws {
            try await withFixture { first in
                try await withFixture { second in
                    #expect(first.directory != second.directory)
                    #expect(first.defaultsSuiteName != second.defaultsSuiteName)
                    #expect(first.settingsDirectory.deletingLastPathComponent() == first.directory)
                    #expect(first.sceneDirectory.deletingLastPathComponent() == first.directory)
                    let firstDefaults = try #require(UserDefaults(suiteName: first.defaultsSuiteName))
                    let secondDefaults = try #require(UserDefaults(suiteName: second.defaultsSuiteName))
                    firstDefaults.set("first", forKey: "fixture-marker")
                    secondDefaults.set("second", forKey: "fixture-marker")
                    #expect(await first.shutdownAndDrain().isEmpty)
                    #expect(!FileManager.default.fileExists(atPath: first.directory.path))
                    #expect(firstDefaults.persistentDomain(forName: first.defaultsSuiteName)?.isEmpty != false)
                    #expect(FileManager.default.fileExists(atPath: second.directory.path))
                    #expect(secondDefaults.string(forKey: "fixture-marker") == "second")
                }
            }
        }

        @Test("Concurrent cleanup waits for and shares the actual runtime drain")
        func cleanupWaitsAndCoalesces() async throws {
            let gate = ShellFixtureDrainGate()
            let secondEntered = ShellFixtureSignal()
            var calls = 0
            try await withFixture(
                drainRuntime: { runtime in
                    calls += 1
                    await gate.suspend()
                    await runtime.shutdown()
                    return runtime.lifecycle.failures.values.sorted()
                },
                { fixture in
                    let defaults = try #require(UserDefaults(suiteName: fixture.defaultsSuiteName))
                    var returned = false
                    let first = Task { @MainActor in
                        let failures = await fixture.shutdownAndDrain()
                        returned = true
                        return failures
                    }
                    await gate.waitUntilEntered()
                    let second = Task {
                        secondEntered.signal()
                        return await fixture.shutdownAndDrain()
                    }
                    await secondEntered.wait()
                    #expect(calls == 1)
                    #expect(!returned)
                    #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
                    #expect(defaults.persistentDomain(forName: fixture.defaultsSuiteName)?.isEmpty == false)
                    gate.release()
                    #expect(await first.value.isEmpty)
                    #expect(await second.value.isEmpty)
                    #expect(calls == 1)
                    #expect(returned)
                    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
                    expectDormant(fixture)
                })
        }

        @Test("Failed runtime cleanup preserves owned files and defaults until retry succeeds")
        func incompleteDrainRetainsResources() async throws {
            var pending = true
            var calls = 0
            try await withFixture(
                drainRuntime: { runtime in
                    calls += 1
                    await runtime.shutdown()
                    return pending
                        ? ["A fixture resource still needs cleanup."] : runtime.lifecycle.failures.values.sorted()
                },
                { fixture in
                    let defaults = try #require(UserDefaults(suiteName: fixture.defaultsSuiteName))
                    defaults.set("retained", forKey: "fixture-marker")
                    #expect(await fixture.shutdownAndDrain() == ["A fixture resource still needs cleanup."])
                    #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
                    #expect(defaults.string(forKey: "fixture-marker") == "retained")
                    #expect(calls == 1)
                    pending = false
                    #expect(await fixture.shutdownAndDrain().isEmpty)
                    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
                    #expect(defaults.persistentDomain(forName: fixture.defaultsSuiteName)?.isEmpty != false)
                    #expect(await fixture.shutdownAndDrain().isEmpty)
                    #expect(calls == 2)
                })
        }

        @Test("Settings flush failure retains files and defaults before successful cleanup")
        func settingsFailureRetainsResources() async throws {
            let rejectsWrite = Mutex(true)
            let writer = SettingsPersistenceWriter { data, url in
                if rejectsWrite.withLock({ $0 }) { throw ShellFixtureWriteFailure.refused }
                try data.write(to: url, options: .atomic)
            }
            try await withFixture(persistenceWriter: writer) { fixture in
                let defaults = try #require(UserDefaults(suiteName: fixture.defaultsSuiteName))
                defaults.set("retained", forKey: "fixture-marker")
                #expect(
                    await fixture.shutdownAndDrain()
                        == ["Shell UI test settings could not be saved. Temporary resources were retained for retry."])
                #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
                #expect(defaults.string(forKey: "fixture-marker") == "retained")
                rejectsWrite.withLock { $0 = false }
                #expect(await fixture.shutdownAndDrain().isEmpty)
                #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
                #expect(defaults.persistentDomain(forName: fixture.defaultsSuiteName)?.isEmpty != false)
                #expect(await fixture.shutdownAndDrain().isEmpty)
                #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
            }
        }

        private func withFixture(
            persistenceWriter: SettingsPersistenceWriter = SettingsPersistenceWriter(),
            drainRuntime: @escaping @MainActor (UtilityRuntime) async -> [String] = {
                await $0.shutdown()
                return $0.lifecycle.failures.values.sorted()
            },
            _ body: (ShellUITestFixture) async throws -> Void
        ) async throws {
            let fixture = try ShellUITestFixture(
                temporaryDirectory: FileManager.default.temporaryDirectory,
                persistenceWriter: persistenceWriter, drainRuntime: drainRuntime)
            do { try await body(fixture) } catch {
                let failures = await fixture.shutdownAndDrain()
                if !failures.isEmpty { Issue.record(failures.joined(separator: "\n")) }
                throw error
            }
            #expect(await fixture.shutdownAndDrain().isEmpty)
            #expect(!fixture.hasHostWindow)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        }

        private func expectDormant(_ fixture: ShellUITestFixture) {
            #expect(fixture.factoryAttempts.isEmpty)
            expectServicesAbsent(fixture.runtime)
        }

        private func expectServicesAbsent(_ runtime: UtilityRuntime) {
            #expect(runtime.sound == nil && runtime.awake == nil && runtime.workspace == nil)
            #expect(runtime.shelf == nil && runtime.storage == nil && runtime.displays == nil)
            #expect(runtime.away == nil && runtime.scenes == nil && runtime.presentation == nil)
            #expect(runtime.sceneShortcuts == nil && runtime.onOpenDetail == nil)
            #expect(runtime.commands.running.isEmpty)
        }
    }

    @MainActor
    private final class ShellFixtureSignal {
        private var signaled = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if signaled { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func signal() {
            signaled = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class ShellFixtureDrainGate {
        private let entered = ShellFixtureSignal()
        private let released = ShellFixtureSignal()

        func suspend() async {
            entered.signal()
            await released.wait()
        }

        func waitUntilEntered() async { await entered.wait() }
        func release() { released.signal() }
    }

    private enum ShellFixtureWriteFailure: Error { case refused }
#endif
