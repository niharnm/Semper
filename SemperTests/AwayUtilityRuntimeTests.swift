import AppKit
import Foundation
import IOKit.pwr_mgt
import KeyboardShortcuts
import Testing

@testable import Semper

@MainActor
@Suite("Away utility runtime", .serialized, .timeLimit(.minutes(1)))
struct AwayUtilityRuntimeTests {
    @Test("Adding Away and choosing its settings stay dormant; Open creates only Away")
    func dormantAddAndOpen() async throws {
        try await withRuntime { runtime, probe in
            runtime.requestAwaySettings()
            #expect(runtime.settingsTab == .away)
            try runtime.registry.add(.away)
            #expect(runtime.away == nil && runtime.awake == nil && runtime.sound == nil)
            #expect(runtime.registry.state(for: .away)?.runtime == .stopped)
            try await runtime.open(.away)
            let original = try #require(runtime.usableAway)
            #expect(original.state == .inactive)
            #expect(probe.awayCreations == 1 && probe.awakeCreations == 0)
            #expect(probe.input.requests == 0 && probe.windows.preparations == 0)
            #expect(probe.authenticator.calls == 0)
            try await runtime.pause(.away)
            #expect(runtime.away == nil)
            try runtime.registry.resume(.away)
            try await runtime.open(.away)
            #expect(runtime.away !== original)
            #expect(probe.awayCreations == 2 && probe.awakeCreations == 0)
            try await runtime.remove(.away)
            try runtime.registry.add(.away)
            #expect(runtime.away == nil)
        }
    }

    @Test(
        "Failed Away activation retains its actual Awake owner through terminal cleanup and retry",
        arguments: [false, true])
    func retainsFailedPowerCleanup(acquisitionFails: Bool) async throws {
        try await withRuntime { runtime, probe in
            try runtime.registry.add(.away)
            let coordinator = try await runtime.ensureAway()
            probe.power.refusesRelease = true
            probe.power.refusesDisplayCreation = acquisitionFails
            runtime.settings.appSettings.awayModePreferences.keepsDisplayAwake = acquisitionFails
            coordinator.startCountdown()
            coordinator.startNow()
            #expect(coordinator.state == .inactive)
            #expect(probe.windows.preparations == (acquisitionFails ? 0 : 1))
            #expect(probe.awakeCreations == 1)
            let awake = try #require(runtime.awake)
            #expect(!probe.power.active.isEmpty)
            #expect(runtime.mutationAdmission.activeExclusiveOwner == .awayMode)
            await runtime.shutdown()
            #expect(runtime.away === coordinator && runtime.awake === awake)
            #expect(runtime.awayCleanupResult == .powerAssertionPending)
            #expect(runtime.usableAway == nil)
            #expect(runtime.lifecycle.failures[.away] != nil && runtime.lifecycle.failures[.awake] != nil)
            #expect(!(await runtime.retryAwayCleanup()))
            #expect(runtime.away === coordinator)
            probe.power.refusesRelease = false
            #expect(await runtime.retryAwayCleanup())
            #expect(runtime.away == nil && runtime.awake == nil)
            #expect(runtime.lifecycle.failures.isEmpty)
            #expect(runtime.mutationAdmission.activeExclusiveOwner == nil)
            #expect(probe.power.active.isEmpty)
            #expect(probe.awayCreations == 1)
        }
    }

    @Test("Away shortcut stays independent, cancels countdown on pause, and preserves its saved chord")
    func independentShortcutLifecycle() async throws {
        try await withRuntime { runtime, probe in
            let chord = KeyboardShortcuts.Shortcut(.a, modifiers: [.control, .option])
            #expect(runtime.settings.appSettings.customShortcuts[ShortcutAction.toggleAwayMode.rawValue] == nil)
            runtime.recordAwayShortcut(chord)
            runtime.startShellShortcuts()
            #expect(await runtime.performAwayShortcut() == .cancelled)
            try runtime.registry.add(.away)
            runtime.recordAwayShortcut(chord)
            #expect(runtime.away == nil)
            #expect(await runtime.performAwayShortcut() == .accepted)
            let original = try #require(runtime.away)
            #expect(original.state == .countdown(remainingSeconds: 5))
            #expect(probe.awakeCreations == 0 && probe.input.requests == 0)
            try await runtime.pause(.away)
            #expect(original.state == .inactive)
            #expect(await runtime.performAwayShortcut() == .cancelled)
            #expect(
                runtime.settings.appSettings.customShortcuts[ShortcutAction.toggleAwayMode.rawValue]
                    == ShortcutCodable.from(chord))
            try runtime.registry.resume(.away)
            runtime.recordAwayShortcut(chord)
            let resumedResult = await runtime.performAwayShortcut()
            #expect(
                resumedResult == .accepted,
                "Result: \(String(describing: resumedResult)); message: \(runtime.message ?? "nil"); "
                    + "shortcut conflict: \(runtime.awayShortcutConflict ?? "nil")")
            #expect(runtime.away !== original)
            await runtime.shutdown()
            #expect(await runtime.performAwayShortcut() == .cancelled)
            #expect(probe.awakeCreations == 0)
        }
    }

    @Test("Stored Workspace collisions disable Away and rejected edits preserve incumbent registration")
    func preservesWorkspaceAndSearchIncumbents() async throws {
        try await withRuntime { runtime, _ in
            try runtime.registry.add(.away)
            try runtime.registry.add(.workspace)
            let chord = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
            let search = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
            runtime.settings.appSettings.customShortcuts[ShortcutAction.restoreWorkspace.rawValue] =
                ShortcutCodable.from(chord)
            runtime.settings.appSettings.customShortcuts[ShortcutAction.toggleAwayMode.rawValue] = ShortcutCodable.from(
                chord)
            runtime.startShellShortcuts()
            #expect(runtime.awayShortcutConflict == "Already used by Restore workspace.")
            #expect(runtime.workspaceShortcutConflict == nil)
            #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
            #expect(!KeyboardShortcuts.isEnabled(for: UtilityRuntime.awayShortcut))
            runtime.recordAwayShortcut(chord)
            #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
            KeyboardShortcuts.setShortcut(search, for: UtilityRuntime.searchShortcut)
            runtime.recordSearchShortcut(search)
            KeyboardShortcuts.setShortcut(search, for: UtilityRuntime.awayShortcut)
            runtime.recordAwayShortcut(search)
            #expect(runtime.awayShortcutConflict == "Already used by Search Semper.")
            #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.searchShortcut))
            #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
            #expect(runtime.away == nil && runtime.workspace == nil)
        }
    }

    @Test("Reset All creates a dormant coordinator without adding Away, and termination still drains it")
    func resetWithoutAwayMetadata() async throws {
        try await withRuntime { runtime, probe in
            #expect(runtime.registry.state(for: .away)?.presence == .available)
            #expect(runtime.away == nil)
            runtime.settings.appSettings.customVolumeHotkeyStepPercent = 27
            #expect(await runtime.resetAllSettings())
            #expect(
                runtime.settings.appSettings.customVolumeHotkeyStepPercent
                    == AppSettings().customVolumeHotkeyStepPercent)
            #expect(runtime.registry.state(for: .away)?.presence == .available)
            let coordinator = try #require(runtime.away)
            #expect(coordinator.state == .inactive)
            #expect(probe.awayCreations == 1 && probe.awakeCreations == 0)
            #expect(probe.input.requests == 0 && probe.windows.preparations == 0)
            await runtime.shutdown()
            #expect(runtime.away == nil)
            #expect(!(await runtime.resetAllSettings()))
            #expect(runtime.message == "Semper is shutting down. Finish cleanup before resetting settings.")
        }
    }

    @Test("Reset authentication failure preserves unrelated settings and does not start Sound")
    func resetFailurePreservesSettings() async throws {
        try await withRuntime { runtime, probe in
            runtime.settings.appSettings.customVolumeHotkeyStepPercent = 27
            probe.authenticator.refuses = true
            #expect(!(await runtime.resetAllSettings()))
            #expect(runtime.settings.appSettings.customVolumeHotkeyStepPercent == 27)
            #expect(probe.authenticator.calls == 1)
            #expect(runtime.message == AwayModeDataError.authenticationFailed.message)
            #expect(probe.awakeCreations == 0 && probe.input.requests == 0)
        }
    }

    @Test("Shutdown cancels held reset authentication and waits for its owned completion")
    func shutdownDrainsHeldAuthentication() async throws {
        try await withRuntime { runtime, probe in
            probe.authenticator.hold = true
            let reset = Task { await runtime.resetAllSettings() }
            await probe.authenticator.entered.wait()
            var shutdownFinished = false
            let shutdown = Task {
                await runtime.shutdown()
                shutdownFinished = true
            }
            await probe.authenticator.cancelled.wait()
            #expect(!shutdownFinished)
            #expect(runtime.away != nil)
            probe.authenticator.release()
            #expect(!(await reset.value))
            await shutdown.value
            #expect(runtime.away == nil)
            #expect(probe.awakeCreations == 0)
        }
    }

    @Test(
        "Stopping Away retains and drains held countdown completion",
        arguments: [UtilityStopReason.pause, .removal, .termination])
    func stopDrainsCountdown(reason: UtilityStopReason) async throws {
        try await withRuntime { runtime, probe in
            let countdown = AwayRuntimeCountdown()
            probe.countdown = countdown
            try runtime.registry.add(.away)
            let coordinator = try await runtime.ensureAway()
            coordinator.startCountdown()
            await countdown.entered.wait()
            var finished = false
            let stop = Task { @MainActor in
                switch reason {
                case .pause: try await runtime.pause(.away)
                case .removal: try await runtime.remove(.away)
                case .termination: await runtime.shutdown()
                }
                finished = true
            }
            await countdown.cancelled.wait()
            #expect(coordinator.shutdown() == .ownedWorkPending)
            #expect(!finished)
            #expect(runtime.away === coordinator)
            countdown.release()
            try await stop.value
            #expect(runtime.away == nil)
            #expect(probe.awakeCreations == 0 && probe.windows.preparations == 0)
        }
    }

    @Test("Reset rechecks a new Scene restore point after held authentication")
    func resetRechecksSceneRecovery() async throws {
        try await withRuntime { runtime, probe in
            runtime.settings.appSettings.customVolumeHotkeyStepPercent = 27
            probe.authenticator.hold = true
            let reset = Task { await runtime.resetAllSettings() }
            await probe.authenticator.entered.wait()
            _ = try await runtime.ensureSceneManager()
            let transaction = SceneTransaction(
                sceneID: UUID(), sceneName: "New recovery", startedAt: Date(),
                entries: [
                    .init(
                        control: .audioOutputVolume(deviceID: "fixture"), importance: .required,
                        snapshotValue: .number(1), targetValue: .number(0.25), appliedValue: .number(0.25),
                        phase: .applied)
                ])
            try probe.journal.save(transaction)
            defer {
                do { try probe.journal.clear() } catch {
                    Issue.record(error, "Could not clear test-owned Scene recovery")
                }
            }
            probe.authenticator.release()
            #expect(!(await reset.value))
            #expect(runtime.settings.appSettings.customVolumeHotkeyStepPercent == 27)
            #expect(
                runtime.message == "Restore the pending scene or keep the current setup before stopping this module.")
            #expect(try probe.journal.load()?.id == transaction.id)
            #expect(probe.awakeCreations == 0 && probe.input.requests == 0)
        }
    }

    @Test("Reset rechecks new Presentation ownership after held authentication")
    func resetRechecksPresentationRecovery() async throws {
        try await withRuntime { runtime, probe in
            runtime.settings.appSettings.customVolumeHotkeyStepPercent = 27
            probe.authenticator.hold = true
            let reset = Task { await runtime.resetAllSettings() }
            await probe.authenticator.entered.wait()
            try runtime.registry.add(.awake)
            try runtime.registry.add(.presentation)
            try await runtime.start(.presentation)
            let presentation = try #require(runtime.presentation)
            let scene = SemperScene(
                name: "Optional audio",
                actions: [
                    .init(control: .audioOutputVolume(deviceID: "fixture"), target: .number(0.5), importance: .optional)
                ])
            try await presentation.prepare(
                .init(duration: .thirtyMinutes, keepsDisplayAwake: false, scene: scene, workspacePlan: nil))
            #expect(presentation.retainedModules.contains(.sound))
            probe.authenticator.release()
            #expect(!(await reset.value))
            #expect(runtime.settings.appSettings.customVolumeHotkeyStepPercent == 27)
            #expect(runtime.message == "End Presentation and finish its recovery before stopping this module.")
            #expect(presentation.reservation != nil)
            #expect(probe.awakeCreations == 0 && probe.input.requests == 0)
            try await presentation.stop()
        }
    }

    @Test("Only the currently owned coordinator can forward authenticated quit")
    func ignoresStaleQuitCallback() async throws {
        try await withRuntime { runtime, _ in
            try runtime.registry.add(.away)
            var requests = 0
            runtime.onAuthenticatedAwayQuit = { requests += 1 }
            let old = try await runtime.ensureAway()
            let oldCallback = old.onAuthenticatedQuit
            oldCallback?()
            #expect(requests == 1)
            try await runtime.pause(.away)
            try runtime.registry.resume(.away)
            let current = try await runtime.ensureAway()
            oldCallback?()
            #expect(requests == 1)
            current.onAuthenticatedQuit?()
            #expect(requests == 2)
            let terminalCallback = current.onAuthenticatedQuit
            await runtime.shutdown()
            terminalCallback?()
            #expect(requests == 2)
        }
    }

    private func withRuntime(_ body: (UtilityRuntime, AwayRuntimeProbe) async throws -> Void) async throws {
        let suite = "AwayUtilityRuntimeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set([], forKey: ModuleRegistry.PersistenceKey.addedModules)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        settings.appSettings.awayModePreferences.disclosureCompleted = true
        let probe = AwayRuntimeProbe(directory: directory)
        let saved = (ShortcutAction.allCases.map(\.keyboardShortcutName) + [UtilityRuntime.searchShortcut]).map {
            (
                $0, UserDefaults.standard.object(forKey: "KeyboardShortcuts_" + $0.rawValue),
                KeyboardShortcuts.getShortcut(for: $0), KeyboardShortcuts.isEnabled(for: $0)
            )
        }
        defer {
            for (name, raw, shortcut, enabled) in saved {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
                if enabled { KeyboardShortcuts.enable(name) } else { KeyboardShortcuts.disable(name) }
                if let raw {
                    UserDefaults.standard.set(raw, forKey: "KeyboardShortcuts_" + name.rawValue)
                } else {
                    UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_" + name.rawValue)
                }
            }
            #expect(settings.flushSync())
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) } catch {
                Issue.record(error, "Could not remove Away runtime test settings")
            }
        }
        let runtime = try UtilityRuntime(
            settings: settings, defaults: defaults,
            updateManager: UpdateManager(bundle: Bundle(for: NSObject.self), userDefaults: defaults),
            soundFactory: { _, _ in
                probe.soundCreations += 1
                throw CancellationError()
            },
            awakeFactory: {
                probe.awakeCreations += 1
                return AwakeService(
                    backend: probe.power, scheduler: AwayRuntimeExpiry(),
                    workspaceNotificationCenter: NotificationCenter())
            },
            sceneLibraryStore: FileSceneLibraryStore(directory: directory.appendingPathComponent("Scenes")),
            sceneJournalStore: probe.journal,
            awayFactory: { settings, admission, provider in
                probe.awayCreations += 1
                return AwayModeCoordinator(
                    settings: settings, awakeServiceProvider: provider, mutationAdmission: admission,
                    windows: probe.windows, inputGuard: probe.input, authenticator: probe.authenticator,
                    pinStore: AwayRuntimePIN(), photoStore: AwayRuntimePhoto(), presentation: AwayRuntimePresentation(),
                    powerPolicy: AwayPowerPolicy(source: AwayRuntimePowerSource()),
                    sleep: { _ in try await probe.sleep() },
                    workspaceNotificationCenter: NotificationCenter())
            })
        do { try await body(runtime, probe) } catch {
            probe.power.refusesRelease = false
            probe.authenticator.release()
            probe.countdown?.release()
            await runtime.shutdown()
            throw error
        }
        probe.power.refusesRelease = false
        probe.authenticator.release()
        probe.countdown?.release()
        await runtime.shutdown()
        #expect(runtime.away == nil && runtime.awake == nil)
        #expect(probe.soundCreations == 0)
    }
}

@MainActor
private final class AwayRuntimeProbe {
    let journal: FileSceneJournalStore
    var countdown: AwayRuntimeCountdown?
    init(directory: URL) { journal = FileSceneJournalStore(directory: directory.appendingPathComponent("Scenes")) }
    func sleep() async throws {
        if let countdown { try await countdown.sleep() } else { try await Task.sleep(for: .seconds(3600)) }
    }
    var awayCreations = 0
    var awakeCreations = 0
    var soundCreations = 0
    let windows = AwayRuntimeWindows()
    let input = AwayRuntimeInput()
    let authenticator = AwayRuntimeAuthenticator()
    let power = AwayRuntimePower()
}

@MainActor
private final class AwayRuntimeSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class AwayRuntimeCountdown {
    let entered = AwayRuntimeSignal()
    let cancelled = AwayRuntimeSignal()
    private let completion = AwayRuntimeSignal()
    func sleep() async throws {
        entered.signal()
        await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            Task { @MainActor in self.cancelled.signal() }
        }
        try Task.checkCancellation()
    }
    func release() { completion.signal() }
}

@MainActor
private final class AwayRuntimeAuthenticator: AwaySystemAuthenticating {
    var calls = 0
    var refuses = false
    var hold = false
    let entered = AwayRuntimeSignal()
    let cancelled = AwayRuntimeSignal()
    private let completion = AwayRuntimeSignal()
    func isAvailable() -> Bool { true }
    func authenticate(reason: String) async throws {
        calls += 1
        entered.signal()
        if hold { await completion.wait() }
        if refuses { throw AwayAuthenticationError.denied }
    }
    func cancelAuthentication() { cancelled.signal() }
    func release() { completion.signal() }
}

@MainActor
private final class AwayRuntimeWindows: AwayWindowManaging {
    var isPresented = false
    var preparations = 0
    var onDegraded: ((AwayWindowFailure) -> Void)?
    var onRestored: (() -> Void)?
    func prepare(contentBuilder: @escaping @MainActor (AwayScreenSnapshot, Bool) throws -> NSView)
        -> AwayWindowPreparationResult
    {
        preparations += 1
        return .failed(.contentCreationFailed)
    }
    func presentPrepared() -> AwayWindowPresentationResult { .failed(.coverageVerificationFailed) }
    func reorderPanels() {}
    func dismiss() {}
}

@MainActor
private final class AwayRuntimeInput: AwayInputGuarding {
    var isActive = false
    var isFilteringOperational = false
    var hasEventAccess = true
    var requests = 0
    var onActivity: (() -> Void)?
    var onAuthenticationRequested: (() -> Void)?
    var onQuitRequested: (() -> Void)?
    var onFailure: ((AwayInputGuardFailure) -> Void)?
    var onRestored: (() -> Void)?
    func preflight() -> Bool { true }
    func requestEventAccess() { requests += 1 }
    func start(policy: AwayInputPolicy) -> Bool {
        Issue.record("Unexpected input activation")
        return false
    }
    func setPolicy(_ policy: AwayInputPolicy) {}
    func setAuthenticationShortcut(_ shortcut: ShortcutCodable?) {}
    func handleTapDisabled() {}
    func stop() {}
}

@MainActor
private final class AwayRuntimePower: PowerAssertionCreating {
    var refusesRelease = false
    var refusesDisplayCreation = false
    var active: Set<PowerAssertionID> = []
    private var next: PowerAssertionID = 1
    func createAssertion(kind: PowerAssertionKind, reason: String, timeout: TimeInterval?) throws(PowerAssertionError)
        -> PowerAssertionID
    {
        if refusesDisplayCreation, kind == .preventIdleDisplaySleep { throw .creationFailed(kIOReturnError) }
        let id = next
        next += 1
        active.insert(id)
        return id
    }
    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        if refusesRelease { throw .releaseFailed(kIOReturnError) }
        active.remove(id)
    }
}

@MainActor
private final class AwayRuntimeExpiry: AwakeExpiryScheduling {
    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {}
    func cancelScheduledExpiry() {}
}

private struct AwayRuntimePIN: AwayPINStoring {
    func hasPIN() throws -> Bool { false }
    func preparePIN(_ pin: String) throws -> AwayPreparedPIN { throw AwayPINStoreError.noStoredPIN }
    func commitPIN(_ preparedPIN: AwayPreparedPIN) throws { throw AwayPINStoreError.noStoredPIN }
    func verifyPIN(_ pin: String) throws -> Bool { false }
    func removePIN() throws {}
}

private struct AwayRuntimePhoto: AwayPhotoStoring {
    func importPhoto(from sourceURL: URL) throws -> AwayManagedPhoto {
        throw AwayPhotoStoreError.invalidManagedFilename
    }
    func managedPhotoURL(for filename: String) throws -> URL { throw AwayPhotoStoreError.invalidManagedFilename }
    func removePhoto(named filename: String) throws {}
    func removeUnreferencedPhotos(keeping filename: String?) throws {}
}

@MainActor
private final class AwayRuntimePresentation: AwayApplicationPresenting {
    var isActive = false
    func begin() throws { Issue.record("Unexpected presentation activation") }
    func restore() {}
}

@MainActor
private final class AwayRuntimePowerSource: AwayPowerReadingSource {
    func currentReading() -> AwayPowerReading {
        .init(
            isLowPowerModeEnabled: false, thermalPressure: .nominal, powerSupply: .ac(percentage: 80, isCharging: false)
        )
    }
    func startMonitoring(_ handler: @escaping @MainActor @Sendable () -> Void) {}
    func stopMonitoring() {}
}
