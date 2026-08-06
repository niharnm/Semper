import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import Semper

@MainActor
private final class RecoveryTapStore {
    var taps: [RecordingProcessTapController] = []
    var lifecycleEvents: [String] = []
    var invalidationDelay: Duration?
    var invalidationResult = TapResourceCleanupResult.empty
}

@MainActor
private final class CleanupResultStore {
    var results: [OrphanedTapCleanupResult]
    private(set) var callCount = 0
    let tapStore: RecoveryTapStore

    init(
        tapStore: RecoveryTapStore,
        results: [OrphanedTapCleanupResult] = [.empty]
    ) {
        self.tapStore = tapStore
        self.results = results
    }

    func next() -> OrphanedTapCleanupResult {
        tapStore.lifecycleEvents.append("cleanup")
        let index = min(callCount, results.index(before: results.endIndex))
        callCount += 1
        return results[index]
    }
}

@MainActor
private struct RecoveryFixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let permission: AudioRecordingPermission
    let processMonitor: StubProcessMonitor
    let tapStore: RecoveryTapStore
    let cleanupStore: CleanupResultStore
    let directory: URL
    let app: AudioApp
    let device: AudioDevice

    func tearDown() {
        engine.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func makeRecoveryFixture(
    mode: AudioProcessingMode = .active,
    permissionStatus: AudioCapturePermissionStatus = .authorized,
    initialCleanupResult: OrphanedTapCleanupResult = .empty,
    cleanupResults: [OrphanedTapCleanupResult] = [.empty],
    resourceCleanupResult: TapResourceCleanupResult = .empty,
    createTap: Bool = true,
    startMonitorsAutomatically: Bool = false,
    persistenceWriter: SettingsPersistenceWriter = SettingsPersistenceWriter()
) -> RecoveryFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SemperBypassTests-\(UUID().uuidString)", isDirectory: true)
    let settings = SettingsManager(
        directory: directory,
        persistenceWriter: persistenceWriter
    )
    settings.setAudioProcessingMode(mode)
    settings.flushSync()

    let permission = AudioRecordingPermission()
    permission.status = permissionStatus
    let processMonitor = StubProcessMonitor()
    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(812),
        uid: "recovery-output",
        name: "Recovery Output",
        icon: nil,
        supportsAutoEQ: false
    )
    deviceMonitor.addOutputDevice(device)
    let deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    deviceVolume.volumes[device.id] = 0.7
    let app = AudioApp(
        id: 8842,
        processObjectIDs: [],
        name: "Recovery Test App",
        icon: NSImage(),
        bundleID: "systems.semper.tests.recovery"
    )
    processMonitor.activeApps = [app]

    let tapStore = RecoveryTapStore()
    tapStore.invalidationResult = resourceCleanupResult
    let cleanupStore = CleanupResultStore(
        tapStore: tapStore,
        results: cleanupResults
    )
    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(loadCatalogAutomatically: false),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: deviceVolume,
        tapFactory: { app, deviceUIDs, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: deviceUIDs)
            tap.invalidationDelay = tapStore.invalidationDelay
            tap.invalidationResult = tapStore.invalidationResult
            tap.onInvalidate = {
                tapStore.lifecycleEvents.append("invalidate")
            }
            tapStore.taps.append(tap)
            return tap
        },
        initialCleanupResult: initialCleanupResult,
        orphanedTapCleanup: {
            cleanupStore.next()
        },
        startMonitorsAutomatically: startMonitorsAutomatically
    )

    if createTap, mode == .active, permissionStatus == .authorized {
        processMonitor.start()
        engine.setDevice(for: app, deviceUID: device.uid)
    }

    return RecoveryFixture(
        engine: engine,
        settings: settings,
        permission: permission,
        processMonitor: processMonitor,
        tapStore: tapStore,
        cleanupStore: cleanupStore,
        directory: directory,
        app: app,
        device: device
    )
}

@Suite("Audio processing bypass and recovery")
@MainActor
struct AudioEngineBypassRecoveryTests {
    private struct ExpectedWriteFailure: Error {}

    @Test("Failed startup cleanup blocks capture work")
    func failedStartupCleanup() async {
        let fixture = makeRecoveryFixture(
            initialCleanupResult: OrphanedTapCleanupResult(failedCount: 1),
            createTap: false,
            startMonitorsAutomatically: true
        )
        defer { fixture.tearDown() }

        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(fixture.engine.audioProcessingState == .failed(.aggregateCleanup))
        #expect(fixture.processMonitor.startCount == 0)
        #expect(fixture.engine.activeProcessingTapCount == 0)
    }

    @Test("Persisted bypass starts without capture work")
    func persistedBypassStartup() async {
        let fixture = makeRecoveryFixture(
            mode: .bypassed,
            createTap: false,
            startMonitorsAutomatically: true
        )
        defer { fixture.tearDown() }

        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(fixture.engine.audioProcessingState == .bypassed)
        #expect(fixture.processMonitor.startCount == 0)
        #expect(fixture.engine.activeProcessingTapCount == 0)
    }

    @Test("An already active engine accepts resume without cleanup")
    func activeResumeIsIdempotent() {
        let fixture = makeRecoveryFixture(createTap: false)
        defer { fixture.tearDown() }

        let result = fixture.engine.requestAudioProcessingMode(.active)

        #expect(result == .applied(.active))
        #expect(fixture.cleanupStore.callCount == 0)
    }

    @Test("Bypass awaits tap invalidation before orphan cleanup")
    func bypassTeardownOrder() async {
        let fixture = makeRecoveryFixture()
        defer { fixture.tearDown() }
        let dispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: fixture.engine)
        )
        fixture.engine.onCommandValueObserved = { key, value in
            dispatcher.completeAccepted(key, observed: value)
        }

        let result = dispatcher.dispatch(
            .setAudioProcessingMode(.bypassed),
            context: AudioCommandContext(source: .popup, reason: .bypass)
        )
        guard case .accepted = result else {
            Issue.record("Expected asynchronous bypass")
            return
        }
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.settings.audioProcessingMode == .bypassed)
        #expect(fixture.engine.audioProcessingState == .bypassed)
        #expect(fixture.engine.activeProcessingTapCount == 0)
        #expect(fixture.processMonitor.stopCount == 1)
        #expect(fixture.tapStore.lifecycleEvents == ["invalidate", "cleanup"])
    }

    @Test("Authorized resume rebuilds persisted taps once")
    func authorizedResume() async {
        let fixture = makeRecoveryFixture()
        defer { fixture.tearDown() }
        let dispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: fixture.engine)
        )
        fixture.engine.onCommandValueObserved = { key, value in
            dispatcher.completeAccepted(key, observed: value)
        }

        dispatcher.dispatch(
            .setAudioProcessingMode(.bypassed),
            context: AudioCommandContext(source: .popup, reason: .bypass)
        )
        await fixture.engine.waitForAudioProcessingTransition()
        dispatcher.dispatch(
            .setAudioProcessingMode(.active),
            context: AudioCommandContext(source: .popup, reason: .bypass)
        )
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.settings.audioProcessingMode == .active)
        #expect(fixture.engine.audioProcessingState == .active)
        #expect(fixture.engine.activeProcessingTapCount == 1)
        #expect(fixture.processMonitor.startCount == 2)
        #expect(fixture.cleanupStore.callCount == 2)
    }

    @Test("Denied resume waits without starting a monitor or tap")
    func deniedResume() {
        let fixture = makeRecoveryFixture(
            mode: .bypassed,
            permissionStatus: .denied,
            createTap: false
        )
        defer { fixture.tearDown() }
        let dispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: fixture.engine)
        )

        let result = dispatcher.dispatch(
            .setAudioProcessingMode(.active),
            context: AudioCommandContext(source: .popup, reason: .bypass)
        )

        guard case .applied(let receipt) = result else {
            Issue.record("Expected the resume request to persist")
            return
        }
        #expect(receipt.observedValue == .mode(AudioProcessingMode.resumeRequested.rawValue))
        #expect(fixture.settings.audioProcessingMode == .resumeRequested)
        #expect(fixture.engine.audioProcessingState == .waitingForPermission)
        #expect(fixture.processMonitor.startCount == 0)
        #expect(fixture.engine.activeProcessingTapCount == 0)
    }

    @Test("Permission grant resumes one pending request")
    func permissionGrantResumes() async {
        let fixture = makeRecoveryFixture(
            mode: .bypassed,
            permissionStatus: .denied,
            createTap: false
        )
        defer { fixture.tearDown() }
        let dispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: fixture.engine)
        )
        fixture.engine.onCommandValueObserved = { key, value in
            dispatcher.completeAccepted(key, observed: value)
        }
        dispatcher.dispatch(
            .setAudioProcessingMode(.active),
            context: AudioCommandContext(source: .popup, reason: .bypass)
        )

        fixture.permission.status = .authorized
        fixture.engine.handleAudioPermissionChange()
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.engine.audioProcessingState == .active)
        #expect(fixture.settings.audioProcessingMode == .active)
        #expect(fixture.processMonitor.startCount == 1)
        #expect(fixture.engine.activeProcessingTapCount == 0)
    }

    @Test("Permission loss tears down active taps and waits")
    func permissionLossTearsDown() async {
        let fixture = makeRecoveryFixture()
        defer { fixture.tearDown() }

        fixture.permission.status = .denied
        fixture.engine.handleAudioPermissionChange()
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.settings.audioProcessingMode == .resumeRequested)
        #expect(fixture.engine.audioProcessingState == .waitingForPermission)
        #expect(fixture.engine.activeProcessingTapCount == 0)
        #expect(fixture.tapStore.lifecycleEvents == ["invalidate", "cleanup"])
    }

    @Test("Permission loss with a failed write tears down and reports failure")
    func permissionLossPersistenceFailure() async {
        let writer = SettingsPersistenceWriter { _, _ in
            throw ExpectedWriteFailure()
        }
        let fixture = makeRecoveryFixture(persistenceWriter: writer)
        defer { fixture.tearDown() }

        fixture.permission.status = .denied
        fixture.engine.handleAudioPermissionChange()
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.settings.audioProcessingMode == .active)
        #expect(fixture.engine.audioProcessingState == .failed(.settingsPersistence))
        #expect(fixture.engine.activeProcessingTapCount == 0)
        #expect(fixture.tapStore.lifecycleEvents == ["invalidate", "cleanup"])
    }

    @Test("A residual aggregate keeps recovery in a failed state")
    func cleanupFailure() async {
        let fixture = makeRecoveryFixture(
            cleanupResults: [OrphanedTapCleanupResult(
                scannedAggregateCount: 1,
                matchedCount: 1,
                destroyedCount: 0,
                failedCount: 1
            )]
        )
        defer { fixture.tearDown() }

        _ = fixture.engine.requestAudioProcessingMode(.bypassed)
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.settings.audioProcessingMode == .bypassed)
        #expect(fixture.engine.audioProcessingState == .failed(.aggregateCleanup))
        #expect(fixture.engine.activeProcessingTapCount == 0)
        #expect(fixture.engine.audioRecoveryReport.contains("Failure code: aggregateCleanup"))
    }

    @Test("A tap resource failure keeps recovery failed")
    func resourceCleanupFailure() async {
        let fixture = makeRecoveryFixture(
            resourceCleanupResult: TapResourceCleanupResult(ioProcFailureCount: 1)
        )
        defer { fixture.tearDown() }

        _ = fixture.engine.requestAudioProcessingMode(.bypassed)
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.settings.audioProcessingMode == .bypassed)
        #expect(fixture.engine.audioProcessingState == .failed(.resourceCleanup))
        #expect(fixture.engine.audioRecoveryReport.contains("IO proc cleanup failures: 1"))
    }

    @Test("A failed mode write does not begin bypass")
    func persistenceFailureRejectsBypass() {
        let writer = SettingsPersistenceWriter { _, _ in
            throw ExpectedWriteFailure()
        }
        let fixture = makeRecoveryFixture(persistenceWriter: writer)
        defer { fixture.tearDown() }

        let result = fixture.engine.requestAudioProcessingMode(.bypassed)

        #expect(result == .rejected)
        #expect(fixture.settings.audioProcessingMode == .active)
        #expect(fixture.engine.audioProcessingState == .active)
        #expect(fixture.engine.activeProcessingTapCount == 1)
        #expect(fixture.engine.audioRecoveryReport.contains("Failure code: settingsPersistence"))
    }

    @Test("Resume requested during teardown ends active")
    func resumeDuringTeardown() async {
        let fixture = makeRecoveryFixture()
        defer { fixture.tearDown() }
        fixture.tapStore.invalidationDelay = .milliseconds(50)
        fixture.tapStore.taps.first?.invalidationDelay = .milliseconds(50)

        _ = fixture.engine.requestAudioProcessingMode(.bypassed)
        for _ in 0..<100 where fixture.engine.audioProcessingState != .bypassing {
            await Task.yield()
        }
        _ = fixture.engine.requestAudioProcessingMode(.active)
        await fixture.engine.waitForAudioProcessingTransition()

        #expect(fixture.engine.audioProcessingState == .active)
        #expect(fixture.settings.audioProcessingMode == .active)
        #expect(fixture.engine.activeProcessingTapCount == 1)
    }
}

@Suite("Audio recovery diagnostics")
struct AudioRecoveryDiagnosticsTests {
    @Test("Export contains fixed state and counts only")
    func privacyFilteredReport() {
        var diagnostics = AudioRecoveryDiagnostics()
        diagnostics.recordBypass(
            cleanup: OrphanedTapCleanupResult(
                scannedAggregateCount: 3,
                matchedCount: 1,
                destroyedCount: 1,
                failedCount: 0
            ),
            resources: .empty
        )

        let report = diagnostics.report(
            state: .bypassed,
            permission: .denied,
            activeTapCount: 0
        )

        #expect(report.contains("Processing state: Bypassed"))
        #expect(report.contains("Aggregates destroyed: 1"))
        #expect(!report.contains("systems.semper.tests.recovery"))
        #expect(!report.contains("recovery-output"))
        #expect(!report.contains("Recovery Test App"))
        #expect(!report.contains("/Users/"))
    }
}
