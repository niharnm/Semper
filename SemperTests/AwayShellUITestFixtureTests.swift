#if DEBUG
    import Foundation
    import Synchronization
    import Testing

    @testable import Semper

    @Suite("Away shell UI test fixture", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct AwayShellUITestFixtureTests {
        private let options = AwayUITestLaunchOptions(
            authenticationMethod: .pin, pin: "0427", systemAuthenticationResult: .success,
            startsCountdownAutomatically: true)

        @Test(
            "Explicit Away UI test options take precedence over either XCTest host signal",
            arguments: [false, true], [false, true])
        func explicitAwayLaunchPrecedesTestHost(hasConfiguration: Bool, hasClass: Bool) {
            let mode = SemperDebugLaunchMode.select(
                arguments: [
                    "Semper", "--away-ui-testing", "--away-ui-auth=pin", "--away-ui-pin=0427",
                    "--away-ui-system-auth=success", "--away-ui-auto-countdown",
                ],
                hasXCTestConfiguration: hasConfiguration, hasXCTestClass: hasClass)
            #expect(mode == .awayUITest(options))
        }

        @Test(
            "Without the Away enable flag either XCTest signal selects the dormant host",
            arguments: [false, true], [false, true])
        func genericTestHostSelection(hasConfiguration: Bool, hasClass: Bool) {
            let mode = SemperDebugLaunchMode.select(
                arguments: ["Semper", "--away-ui-auth=pin", "--away-ui-auto-countdown"],
                hasXCTestConfiguration: hasConfiguration, hasXCTestClass: hasClass)
            #expect(mode == (hasConfiguration || hasClass ? .testHost : .regular))
        }

        @Test("Construction applies canonical options without starting a countdown or creating a host")
        func constructionRemainsInactive() async throws {
            let fixture = try AwayShellUITestFixture(options: options)
            let directory = fixture.settingsDirectory
            #expect(fixture.coordinator.state == .inactive)
            #expect(!fixture.coordinator.isGuarding)
            #expect(fixture.coordinator.makeCurtainContent != nil)
            #expect(fixture.coordinator.hasEventAccess)
            #expect(fixture.coordinator.preferences.authenticationMethod == .pin)
            #expect(fixture.coordinator.preferences.disclosureCompleted)
            #expect(fixture.coordinator.preferences.motionLevel == .off)
            #expect(!fixture.coordinator.preferences.keepsDisplayAwake)
            #expect(directory.lastPathComponent.hasPrefix("Semper-Away-UITests-"))
            #expect(await fixture.shutdownAndDrain().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(await fixture.shutdownAndDrain().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }

        @Test("Each fixture owns a unique settings directory inside the supplied temporary root")
        func settingsAreIsolated() async throws {
            let root = try temporaryRoot()
            defer { removeRoot(root) }
            let first = try AwayShellUITestFixture(options: options, temporaryDirectory: root)
            let second = try AwayShellUITestFixture(options: options, temporaryDirectory: root)
            #expect(first.settingsDirectory != second.settingsDirectory)
            for directory in [first.settingsDirectory, second.settingsDirectory] {
                #expect(directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
                #expect(FileManager.default.fileExists(atPath: directory.path))
            }
            #expect(await first.shutdownAndDrain().isEmpty)
            #expect(FileManager.default.fileExists(atPath: second.settingsDirectory.path))
            #expect(await second.shutdownAndDrain().isEmpty)
        }

        @Test("Cleanup retains settings while awaiting coordinator drain")
        func waitsForCoordinatorDrain() async throws {
            let root = try temporaryRoot()
            defer { removeRoot(root) }
            let gate = AwayFixtureDrainGate()
            let fixture = try AwayShellUITestFixture(
                options: options, temporaryDirectory: root,
                drainCoordinator: { coordinator in
                    await gate.suspend()
                    return await coordinator.shutdownAndDrain()
                })
            var returned = false
            let cleanup = Task { @MainActor in
                let failures = await fixture.shutdownAndDrain()
                returned = true
                return failures
            }
            await gate.waitUntilEntered()
            #expect(!returned)
            #expect(FileManager.default.fileExists(atPath: fixture.settingsDirectory.path))
            gate.release()
            #expect(await cleanup.value.isEmpty)
            #expect(returned)
            #expect(!FileManager.default.fileExists(atPath: fixture.settingsDirectory.path))
        }

        @Test(
            "Incomplete coordinator cleanup retains resources until a successful retry",
            arguments: [
                AwayModeCleanupResult.ownedWorkPending, .powerAssertionPending, .mutationAdmissionPending,
            ])
        func retainsIncompleteCleanup(_ pendingResult: AwayModeCleanupResult) async throws {
            let root = try temporaryRoot()
            defer { removeRoot(root) }
            var shouldDefer = true
            let fixture = try AwayShellUITestFixture(
                options: options, temporaryDirectory: root,
                drainCoordinator: { coordinator in
                    let result = await coordinator.shutdownAndDrain()
                    return result == .complete && shouldDefer ? pendingResult : result
                })
            let failures = await fixture.shutdownAndDrain()
            let expected: String
            switch pendingResult {
            case .ownedWorkPending: expected = "Away UI test work is still stopping. Retry cleanup."
            case .powerAssertionPending: expected = "Away UI test power cleanup is still pending. Retry cleanup."
            case .mutationAdmissionPending:
                expected = "Away UI test mutation ownership is still retained. Retry cleanup."
            case .complete:
                Issue.record("Complete is not a pending test case.")
                return
            }
            #expect(failures == [expected])
            #expect(FileManager.default.fileExists(atPath: fixture.settingsDirectory.path))
            shouldDefer = false
            #expect(await fixture.shutdownAndDrain().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.settingsDirectory.path))
        }

        @Test("Concurrent shutdown callers share the same awaited cleanup")
        func concurrentShutdownSharesDrain() async throws {
            let root = try temporaryRoot()
            defer { removeRoot(root) }
            let gate = AwayFixtureDrainGate()
            let secondEntered = AwayFixtureSignal()
            var calls = 0
            let fixture = try AwayShellUITestFixture(
                options: options, temporaryDirectory: root,
                drainCoordinator: { coordinator in
                    calls += 1
                    await gate.suspend()
                    return await coordinator.shutdownAndDrain()
                })
            let first = Task { await fixture.shutdownAndDrain() }
            await gate.waitUntilEntered()
            let second = Task {
                secondEntered.signal()
                return await fixture.shutdownAndDrain()
            }
            await secondEntered.wait()
            #expect(calls == 1)
            gate.release()
            #expect(await first.value.isEmpty)
            #expect(await second.value.isEmpty)
            #expect(calls == 1)
        }

        @Test("Settings flush failure preserves resources and a retry drains writes before deletion")
        func settingsFailureRetainsResources() async throws {
            let root = try temporaryRoot()
            defer { removeRoot(root) }
            let rejectsWrite = Mutex(true)
            let writer = SettingsPersistenceWriter { data, url in
                if rejectsWrite.withLock({ $0 }) { throw AwayFixtureWriteFailure.refused }
                try data.write(to: url, options: .atomic)
            }
            let fixture = try AwayShellUITestFixture(
                options: options, temporaryDirectory: root, persistenceWriter: writer)
            #expect(
                await fixture.shutdownAndDrain()
                    == ["Away UI test settings could not be saved. Temporary resources were retained for retry."])
            #expect(FileManager.default.fileExists(atPath: fixture.settingsDirectory.path))
            rejectsWrite.withLock { $0 = false }
            #expect(await fixture.shutdownAndDrain().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.settingsDirectory.path))
            #expect(await fixture.shutdownAndDrain().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.settingsDirectory.path))
        }

        private func temporaryRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "AwayShellFixtureTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private func removeRoot(_ root: URL) {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
    }

    @MainActor
    private final class AwayFixtureSignal {
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
    private final class AwayFixtureDrainGate {
        private let entered = AwayFixtureSignal()
        private let released = AwayFixtureSignal()

        func suspend() async {
            entered.signal()
            await released.wait()
        }

        func waitUntilEntered() async { await entered.wait() }
        func release() { released.signal() }
    }

    private enum AwayFixtureWriteFailure: Error { case refused }
#endif
