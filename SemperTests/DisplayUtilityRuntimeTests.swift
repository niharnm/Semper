#if !APP_STORE
    import AppKit
    import Foundation
    import Synchronization
    import Testing

    @testable import Semper

    @Suite("Display utility runtime", .serialized)
    @MainActor
    struct DisplayUtilityRuntimeTests {
        @Test("Displays starts independently and reuses only a paused service")
        func independentLifecycle() async throws {
            try await withRuntime { runtime, probe in
                #expect(runtime.displays == nil)
                #expect(probe.displayCreations == 0)
                #expect(probe.transport.discoveries == 0)
                try await runtime.start(.displays)
                let service = try #require(runtime.displays)
                #expect(service.isRunning)
                #expect(probe.displayCreations == 1)
                #expect(probe.transport.discoveries == 1)
                #expect(service.displays.first?.features[.brightness]?.current == 40)
                #expect(runtime.registry.state(for: .displays)?.permission == .notRequired)
                #expect(probe.admission === runtime.mutationAdmission)

                try await runtime.pause(.displays)
                #expect(runtime.displays === service)
                #expect(!service.isRunning)
                #expect(try await service.set(0.8, feature: .brightness, for: probe.identity) == .unavailable)
                try runtime.registry.resume(.displays)
                try await runtime.start(.displays)
                #expect(runtime.displays === service)
                #expect(probe.displayCreations == 1)
                #expect(probe.transport.discoveries == 2)

                try await runtime.remove(.displays)
                #expect(runtime.displays == nil)
                #expect(!service.isRunning)
                try runtime.registry.add(.displays)
                try await runtime.start(.displays)
                #expect(runtime.displays !== service)
                #expect(probe.displayCreations == 2)
                #expect(probe.transport.discoveries == 3)
                #expect(runtime.sound == nil)
                #expect(probe.soundCreations == 0)
            }
        }

        @Test("Displays and audio DDC share admission before any transport write")
        func sharedMutationAdmission() async throws {
            try await withRuntime { runtime, probe in
                try await runtime.start(.displays)
                let service = try #require(runtime.displays)
                let controller = try #require(probe.controller)
                let away = try runtime.mutationAdmission.acquire(owner: .awayMode, mode: .exclusive)
                await #expect(throws: MutationAdmissionError.self) {
                    try await service.set(0.8, feature: .brightness, for: probe.identity)
                }
                #expect(!controller.setVolume(for: 4242, to: 80))
                #expect(probe.transport.writes.isEmpty)
                #expect(service.displays.first?.features[.brightness]?.current == 40)
                #expect(runtime.mutationAdmission.release(away))

                let result = try await service.set(0.8, feature: .brightness, for: probe.identity)
                #expect(result == .applied(try #require(DisplayFeatureReading(current: 80, maximum: 100))))
                #expect(probe.transport.writes == [80])
                #expect(runtime.mutationAdmission.activeSharedPermitCount == 0)
            }
        }

        @Test("Unreadable displays report limited controls")
        func unreadableDisplayStatus() async throws {
            try await withRuntime { runtime, probe in
                probe.transport.rejectReads = true
                try await runtime.start(.displays)
                let service = try #require(runtime.displays)
                #expect(service.displays.isEmpty)
                #expect(runtime.summary(for: .displays) == "No readable display controls")
                #expect(
                    runtime.registry.state(for: .displays)?.runtime
                        == .limited(reason: "No readable display controls were found."))
                #expect(runtime.registry.state(for: .displays)?.permission == .notRequired)
                #expect(!service.isSceneEligible(.brightness, for: probe.identity))
                #expect(probe.transport.writes.isEmpty)
            }
        }

        @Test("Scene recovery retains the actual Displays service until its journal settles")
        func sceneRecoveryRetainsService() async throws {
            try await withRuntime { runtime, probe in
                try await runtime.start(.displays)
                let service = try #require(runtime.displays)
                let manager = try await runtime.ensureSceneManager()
                let token = try await manager.reservePresentation()
                let preview = try await manager.previewPresentation(probe.scene, token: token)
                let report = try await manager.applyPresentation(probe.scene, token: token, expectedPreview: preview)
                let transaction = try #require(report.transactionID)

                await #expect(throws: UtilityCleanupDeferral.self) { try await runtime.pause(.displays) }
                await #expect(throws: UtilityCleanupDeferral.self) { try await runtime.remove(.displays) }
                #expect(runtime.displays === service)
                #expect(service.isRunning)
                #expect(probe.transport.writes == [70])
                #expect(runtime.registry.state(for: .displays)?.presence == .added)

                let restored = try await manager.restorePresentation(transactionID: transaction, token: token)
                #expect(restored?.journalCleared == true)
                try await manager.releasePresentation(token)
                #expect(probe.transport.writes == [70, 40])
                try await runtime.remove(.displays)
                #expect(runtime.displays == nil)
                #expect(!service.isRunning)
            }
        }

        @Test("A reviewed Presentation retains Displays without acquiring Awake or starting Sound")
        func presentationPreviewRetainsService() async throws {
            try await withRuntime { runtime, probe in
                try await runtime.start(.displays)
                try await runtime.start(.presentation)
                let service = try #require(runtime.displays)
                let presentation = try #require(runtime.presentation)
                try await presentation.prepare(
                    PresentationDraft(
                        duration: .thirtyMinutes, keepsDisplayAwake: false,
                        scene: probe.scene, workspacePlan: nil))

                await #expect(throws: UtilityCleanupDeferral.self) { try await runtime.pause(.displays) }
                #expect(runtime.displays === service)
                #expect(service.isRunning)
                #expect(runtime.awake == nil)
                #expect(runtime.sound == nil)
                #expect(probe.transport.writes.isEmpty)
                try await presentation.stop()
                try await runtime.pause(.displays)
                #expect(!service.isRunning)
            }
        }

        @Test("Pause drains a suspended read and cancels a queued write before releasing Displays")
        func pauseDrainsOwnedOperations() async throws {
            try await withRuntime { runtime, probe in
                try await runtime.start(.displays)
                let service = try #require(runtime.displays)
                probe.transport.suspendNextRead()
                defer { probe.transport.resumeRead() }
                let read = Task { await service.read(.brightness, for: probe.identity) }
                try #require(try await waitUntil { probe.transport.readIsSuspended })
                let write = Task { try await service.set(0.8, feature: .brightness, for: probe.identity) }
                try #require(try await waitUntil { runtime.mutationAdmission.activeSharedPermitCount == 1 })
                var pauseFinished = false
                let pause = Task {
                    defer { pauseFinished = true }
                    try await runtime.pause(.displays)
                }
                try #require(try await waitUntil { !service.isRunning })
                #expect(!pauseFinished)
                #expect(runtime.displays === service)
                pause.cancel()
                probe.transport.resumeRead()
                #expect(await read.value == nil)
                await #expect(throws: CancellationError.self) { try await write.value }
                try await pause.value

                #expect(pauseFinished)
                #expect(probe.transport.writes.isEmpty)
                #expect(runtime.mutationAdmission.activeSharedPermitCount == 0)
                #expect(runtime.registry.state(for: .displays)?.runtime == .paused)
            }
        }

        @Test("Sound audio DDC drain leaves the independent Displays queue usable")
        func soundDrainPreservesDisplays() async throws {
            try await withRuntime { runtime, probe in
                try await runtime.start(.displays)
                let service = try #require(runtime.displays)
                let controller = try #require(probe.controller)
                var volumeCompletions = 0
                controller.onWriteResult = { _, _ in volumeCompletions += 1 }
                #expect(controller.setVolume(for: 4242, to: 60))
                #expect(runtime.mutationAdmission.activeSharedPermitCount == 1)

                try await runtime.pause(.sound)

                #expect(volumeCompletions == 1)
                #expect(runtime.mutationAdmission.activeSharedPermitCount == 0)
                #expect(runtime.displays === service)
                #expect(service.isRunning)
                let result = try await service.set(0.6, feature: .brightness, for: probe.identity)
                #expect(result == .applied(try #require(DisplayFeatureReading(current: 60, maximum: 100))))
                #expect(probe.transport.writes == [60])
                #expect(runtime.sound == nil)
                #expect(probe.soundCreations == 0)
                controller.onWriteResult = nil
            }
        }

        private func waitUntil(_ condition: @MainActor () -> Bool) async throws -> Bool {
            for _ in 0..<200 {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        private func withRuntime(_ body: (UtilityRuntime, DisplayRuntimeProbe) async throws -> Void) async throws {
            let suite = "DisplayUtilityRuntimeTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(
                ["displays", "sound", "scenes", "awake", "presentation"],
                forKey: ModuleRegistry.PersistenceKey.addedModules)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings = SettingsManager(
                directory: directory.appendingPathComponent("Settings"), managesLaunchAtLogin: false)
            let probe = DisplayRuntimeProbe()
            defer {
                settings.flushSync()
                defaults.removePersistentDomain(forName: suite)
                do { try FileManager.default.removeItem(at: directory) } catch {
                    Issue.record(error, "Could not remove Displays runtime test files")
                }
            }
            let runtime = try UtilityRuntime(
                settings: settings, defaults: defaults,
                updateManager: UpdateManager(bundle: Bundle(for: NSObject.self), userDefaults: defaults),
                soundFactory: { _, _ in
                    probe.soundCreations += 1
                    throw DisplayRuntimeProbe.Failure.unexpectedSound
                },
                awakeFactory: { throw DisplayRuntimeProbe.Failure.unexpectedAwake },
                sceneLibraryStore: FileSceneLibraryStore(directory: directory.appendingPathComponent("Scenes")),
                sceneJournalStore: FileSceneJournalStore(directory: directory.appendingPathComponent("Scenes")),
                displayFactory: probe.makeDisplays)
            do {
                try await body(runtime, probe)
                await runtime.shutdown()
            } catch {
                probe.transport.resumeRead()
                await runtime.shutdown()
                throw error
            }
            #expect(runtime.displays == nil)
            #expect(runtime.sound == nil)
            #expect(probe.soundCreations == 0)
        }
    }

    @MainActor
    private final class DisplayRuntimeProbe {
        enum Failure: Error { case unexpectedSound, unexpectedAwake, missingTransport }
        let transport = DisplayRuntimeTransport()
        var controller: DDCController?
        var admission: MutationAdmissionGate?
        var displayCreations = 0
        var soundCreations = 0
        var identity: DisplayIdentity { transport.identity }
        lazy var scene: SemperScene = {
            SemperScene(
                name: "Display test",
                actions: [
                    SceneAction(
                        control: .displayBrightness(displayID: identity.rawValue),
                        target: .number(0.7), importance: .required)
                ])
        }()

        func makeDisplays(_ controller: AudioEngine.SharedDDCController?, _ admission: MutationAdmissionGate) throws
            -> DisplayControlService
        {
            guard let controller else { throw Failure.missingTransport }
            displayCreations += 1
            self.controller = controller
            self.admission = admission
            return DisplayControlService(
                ddcController: controller, mutationAdmission: admission,
                discover: transport.discover, read: transport.read, write: transport.write)
        }
    }

    private nonisolated final class DisplayRuntimeTransport: Sendable {
        private enum Failure: Error { case unreadable }
        private struct State {
            var discoveries = 0
            var brightness: UInt16 = 40
            var writes: [UInt16] = []
            var suspendNextRead = false
            var readIsSuspended = false
            var rejectReads = false
        }
        private let state = Mutex(State())
        private let readRelease = DispatchSemaphore(value: 0)
        private let service = DDCService(service: kCFBooleanTrue)
        var identity: DisplayIdentity { DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)! }
        var discoveries: Int { state.withLock { $0.discoveries } }
        var writes: [UInt16] { state.withLock { $0.writes } }
        var readIsSuspended: Bool { state.withLock { $0.readIsSuspended } }
        var rejectReads: Bool {
            get { state.withLock { $0.rejectReads } }
            set { state.withLock { $0.rejectReads = newValue } }
        }

        func discover() -> [DDCExternalDisplayRecord] {
            state.withLock { $0.discoveries += 1 }
            return [
                DDCExternalDisplayRecord(
                    registryID: DDCDisplayCandidate.ID(rawValue: 901), name: "Test Display",
                    edid: DDCDisplayEDID(vendorID: 101, productID: 202, serialNumber: 303), service: service)
            ]
        }

        func read(_ service: DDCService, _ feature: DisplayFeature) throws -> (current: UInt16, maximum: UInt16) {
            if rejectReads { throw Failure.unreadable }
            let shouldWait = state.withLock {
                let shouldWait = $0.suspendNextRead
                $0.suspendNextRead = false
                $0.readIsSuspended = shouldWait
                return shouldWait
            }
            if shouldWait {
                readRelease.wait()
                state.withLock { $0.readIsSuspended = false }
            }
            return state.withLock { (feature == .brightness ? $0.brightness : 20, 100) }
        }

        func write(_ service: DDCService, _ feature: DisplayFeature, _ value: UInt16) throws {
            state.withLock {
                $0.writes.append(value)
                if feature == .brightness { $0.brightness = value }
            }
        }

        func suspendNextRead() { state.withLock { $0.suspendNextRead = true } }
        func resumeRead() { readRelease.signal() }
    }
#endif
