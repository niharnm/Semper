import Foundation
import AppKit
import Testing

@testable import Semper

@Suite("Direct AudioEngine mutation admission")
@MainActor
struct AudioEngineMutationAdmissionTests {
    @Test("Away blocks inactive app settings and processing changes at the engine")
    func deniesDirectMutations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        let devices = MockAudioDeviceMonitor()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(loadCatalogAutomatically: false),
            deviceProvider: devices,
            processMonitor: StubProcessMonitor(),
            deviceVolumeMonitor: MockDeviceVolumeProviding(deviceMonitor: devices),
            orphanedTapCleanup: { .empty },
            startMonitorsAutomatically: false
        )
        let gate = MutationAdmissionGate()
        try engine.installMutationAdmission(gate)
        let identifier = "com.test.admission"
        let initialVolume = engine.getVolumeForInactive(identifier: identifier)
        let initialBoost = engine.getBoostForInactive(identifier: identifier)
        let initialMute = engine.getMuteForInactive(identifier: identifier)
        let initialMode = engine.audioProcessingMode
        let initialInputLock = settings.appSettings.lockInputDevice
        let away = try gate.acquire(owner: .awayMode, mode: .exclusive)
        engine.setVolumeForInactive(identifier: identifier, to: 0.1)
        engine.setBoostForInactive(identifier: identifier, to: .x4)
        engine.setMuteForInactive(identifier: identifier, to: !initialMute)
        engine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: "blocked-output")
        engine.setSelectedDeviceUIDsForInactive(identifier: identifier, to: ["blocked-output"])
        engine.setInputLockEnabled(!initialInputLock)
        #expect(engine.requestAudioProcessingMode(.bypassed) == .rejected)
        #expect(!engine.beginSceneTransaction())
        #expect(engine.getVolumeForInactive(identifier: identifier) == initialVolume)
        #expect(engine.getBoostForInactive(identifier: identifier) == initialBoost)
        #expect(engine.getMuteForInactive(identifier: identifier) == initialMute)
        #expect(engine.getDeviceRoutingForInactive(identifier: identifier) == nil)
        #expect(engine.getSelectedDeviceUIDsForInactive(identifier: identifier).isEmpty)
        #expect(engine.audioProcessingMode == initialMode)
        #expect(settings.appSettings.lockInputDevice == initialInputLock)
        #expect(engine.mutationAdmissionError as? MutationAdmissionError == .exclusivePermitActive(owner: .awayMode))
        gate.release(away)
        engine.setInputLockEnabled(!initialInputLock)
        #expect(settings.appSettings.lockInputDevice == !initialInputLock)
        engine.setVolumeForInactive(identifier: identifier, to: 0.1)
        #expect(engine.getVolumeForInactive(identifier: identifier) == 0.1)
        await engine.shutdownAndDrain()
        permission.shutdown()
        settings.flushSync()
        try FileManager.default.removeItem(at: directory)
    }

    @Test("A preferred output connected during Away is restored when admission reopens")
    func reconcilesConnectedPreferredOutput() async throws {
        let fixture = try DeviceReconciliationFixture()
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.connectHeadset()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.fallback.uid])
        #expect(fixture.tap.switchDeviceStarts.isEmpty)
        fixture.gate.release(away)
        await fixture.settle()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.headset.uid])
        #expect(fixture.settings.getDeviceRouting(for: fixture.app.persistenceIdentifier) == fixture.headset.uid)
        try await fixture.shutdown()
    }

    @Test("A disconnected preferred output falls back after Away without erasing its preference")
    func reconcilesDisconnectedPreferredOutput() async throws {
        let fixture = try DeviceReconciliationFixture(headsetInitiallyConnected: true)
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.disconnectHeadset()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.headset.uid])
        fixture.gate.release(away)
        await fixture.settle()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.fallback.uid])
        #expect(fixture.tap.lastSwitchRequiredExclusiveOutput == true)
        #expect(fixture.settings.getDeviceRouting(for: fixture.app.persistenceIdentifier) == fixture.headset.uid)
        try await fixture.shutdown()
    }

    @Test("A connect followed by disconnect during Away does not replay the obsolete connection")
    func discardsObsoleteConnection() async throws {
        let fixture = try DeviceReconciliationFixture()
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.connectHeadset()
        fixture.disconnectHeadset()
        fixture.gate.release(away)
        await fixture.settle()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.fallback.uid])
        #expect(fixture.tap.switchDeviceStarts.isEmpty)
        #expect(fixture.volume.setDefaultDeviceCalls.isEmpty)
        try await fixture.shutdown()
    }

    @Test("Reconciliation waits when Away reacquires admission before the release callback runs")
    func rechecksAdmissionAfterQueuedRelease() async throws {
        let fixture = try DeviceReconciliationFixture()
        let first = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.connectHeadset()
        fixture.gate.release(first)
        let second = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        await fixture.settle()
        #expect(fixture.tap.switchDeviceStarts.isEmpty)
        fixture.gate.release(second)
        await fixture.settle()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.headset.uid])
        try await fixture.shutdown()
    }

    @Test("An admitted callback cannot consume inventory changes awaiting reconciliation")
    func preservesPendingInventoryAcrossAdmittedCallback() async throws {
        let fixture = try DeviceReconciliationFixture()
        let unrelated = AudioDevice(id: 93, uid: "unrelated", name: "Unrelated", icon: nil, supportsAutoEQ: false)
        fixture.devices.addOutputDevice(unrelated)
        fixture.settings.setDevicePriorityOrder([fixture.headset.uid, fixture.fallback.uid, unrelated.uid])
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.connectHeadset()
        fixture.gate.release(away)
        fixture.devices.outputDevices.removeAll { $0.uid == unrelated.uid }
        fixture.devices.onDeviceDisconnected?(unrelated.uid, unrelated.name)
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.headset.uid)
        #expect(fixture.tap.currentDeviceUIDs == [fixture.headset.uid])
        try await fixture.shutdown()
    }

    @Test("Processing teardown cancels and drains reconciliation before invalidating taps")
    func bypassDrainsReconciliationWithoutPublishingFailure() async throws {
        let operation = ReconciliationRouteOperation()
        let fixture = try DeviceReconciliationFixture(controlledRoute: operation)
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.connectHeadset()
        fixture.gate.release(away)
        await fixture.settle()
        #expect(operation.isWaiting)
        #expect(fixture.engine.requestAudioProcessingMode(.bypassed) == .accepted)
        await fixture.settle()
        #expect(operation.cancellationRequested)
        #expect(operation.invalidationCount == 0)
        #expect(fixture.engine.audioProcessingState == .bypassing)
        #expect(fixture.gate.activeSharedPermitCount > 0)
        operation.finishCancellation()
        await fixture.engine.waitForAudioProcessingTransition()
        await fixture.settle()
        #expect(fixture.engine.audioProcessingState == .bypassed)
        #expect(fixture.gate.activeSharedPermitCount == 0)
        if case .failed = fixture.engine.routeLifecycle(for: fixture.app) {
            Issue.record("Canceled reconciliation published a route failure after processing teardown")
        }
        try await fixture.shutdown()
    }

    @Test("Shutdown invalidates pending and already queued admission reconciliation", arguments: [false, true])
    func shutdownDiscardsReconciliation(releaseBeforeShutdown: Bool) async throws {
        let fixture = try DeviceReconciliationFixture()
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.connectHeadset()
        if releaseBeforeShutdown { fixture.gate.release(away) }
        fixture.engine.shutdown()
        if !releaseBeforeShutdown { fixture.gate.release(away) }
        await fixture.settle()
        #expect(fixture.tap.switchDeviceStarts.isEmpty)
        #expect(fixture.volume.setDefaultDeviceCalls.isEmpty)
        #expect(fixture.processes.startCount == 0)
        #expect(fixture.engine.activeProcessingTapCount == 0)
        try await fixture.shutdown()
    }

    @Test("A default-only output change during Away is reconciled from the current default")
    func reconcilesDefaultOutputWithoutDeviceEvent() async throws {
        let fixture = try DeviceReconciliationFixture(headsetInitiallyConnected: true, followsDefault: true)
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.volume.defaultDeviceUID = fixture.headset.uid
        fixture.volume.defaultDeviceID = fixture.headset.id
        fixture.volume.onDefaultDeviceChanged?(fixture.headset.uid)
        #expect(fixture.tap.currentDeviceUIDs == [fixture.fallback.uid])
        fixture.gate.release(away)
        await fixture.settle()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.headset.uid])
        #expect(fixture.volume.setDefaultDeviceCalls.isEmpty)
        try await fixture.shutdown()
    }

    @Test("Reconciliation restores a multi-output selection without persisting missing devices")
    func reconcilesMultiOutputSelection() async throws {
        let fixture = try DeviceReconciliationFixture(multipleOutputs: true)
        let away = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.connectHeadset()
        fixture.gate.release(away)
        await fixture.settle()
        #expect(Set(fixture.tap.currentDeviceUIDs) == [fixture.fallback.uid, fixture.headset.uid])
        let second = try fixture.gate.acquire(owner: .awayMode, mode: .exclusive)
        fixture.disconnectHeadset()
        fixture.gate.release(second)
        await fixture.settle()
        #expect(fixture.tap.currentDeviceUIDs == [fixture.fallback.uid])
        #expect(
            fixture.settings.getSelectedDeviceUIDs(for: fixture.app.persistenceIdentifier) == [
                fixture.fallback.uid, fixture.headset.uid,
            ])
        try await fixture.shutdown()
    }

    @Test("An ordinary partial reconnect preserves other selected outputs that are still missing")
    func ordinaryReconnectPreservesMissingSelection() async throws {
        let fixture = try DeviceReconciliationFixture(multipleOutputs: true)
        let savedSelection: Set<String> = [fixture.fallback.uid, fixture.headset.uid, "still-missing"]
        fixture.settings.setDeviceRouting(for: fixture.app.persistenceIdentifier, deviceUID: fixture.fallback.uid)
        fixture.settings.setSelectedDeviceUIDs(for: fixture.app.persistenceIdentifier, to: savedSelection)
        fixture.engine.volumeState.setSelectedDeviceUIDs(
            for: fixture.app.id, to: [fixture.fallback.uid], persist: false)
        // Accepting the fake system default avoids the native transport probe on this callback path.
        fixture.volume.defaultDeviceUID = fixture.headset.uid
        fixture.volume.defaultDeviceID = fixture.headset.id
        fixture.connectHeadset()
        await fixture.settle()
        #expect(Set(fixture.tap.currentDeviceUIDs) == [fixture.fallback.uid, fixture.headset.uid])
        #expect(fixture.settings.getSelectedDeviceUIDs(for: fixture.app.persistenceIdentifier) == savedSelection)
        try await fixture.shutdown()
    }

    @Test("A temporary multi-output selection never persists through the stored identifier")
    func temporarySelectionPreservesSavedPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        let state = VolumeState(settingsManager: settings)
        let identifier = "com.test.temporary-selection"
        state.setSelectedDeviceUIDs(for: 42, to: ["fallback", "headset"], identifier: identifier)
        state.setSelectedDeviceUIDs(for: 42, to: ["fallback"], persist: false)
        #expect(state.getSelectedDeviceUIDs(for: 42) == ["fallback"])
        #expect(settings.getSelectedDeviceUIDs(for: identifier) == ["fallback", "headset"])
        state.setSelectedDeviceUIDs(for: 42, to: ["headset"])
        #expect(settings.getSelectedDeviceUIDs(for: identifier) == ["headset"])
        settings.flushSync()
        try FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class DeviceReconciliationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let settings: SettingsManager
    let devices = MockAudioDeviceMonitor()
    let processes = StubProcessMonitor()
    let permission = AudioRecordingPermission()
    let gate = MutationAdmissionGate()
    let fallback = AudioDevice(id: 91, uid: "fallback", name: "Fallback", icon: nil, supportsAutoEQ: false)
    let headset = AudioDevice(id: 92, uid: "headset", name: "Headset", icon: nil, supportsAutoEQ: false)
    let app = AudioApp(
        id: 12_391, processObjectIDs: [], name: "Test Audio", icon: NSImage(), bundleID: "com.test.reconciliation")
    let volume: MockDeviceVolumeProviding
    let tap: RecordingProcessTapController
    let engine: AudioEngine

    init(
        headsetInitiallyConnected: Bool = false,
        followsDefault: Bool = false,
        multipleOutputs: Bool = false,
        controlledRoute: ReconciliationRouteOperation? = nil
    ) throws {
        settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        settings.appSettings.showDeviceDisconnectAlerts = false
        if followsDefault {
            settings.setVolume(for: app.persistenceIdentifier, to: 0.8)
        } else {
            settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: headset.uid)
        }
        if multipleOutputs {
            settings.setDeviceSelectionMode(for: app.persistenceIdentifier, to: .multi)
            settings.setSelectedDeviceUIDs(for: app.persistenceIdentifier, to: [fallback.uid, headset.uid])
        }
        settings.setDevicePriorityOrder([fallback.uid, headset.uid])
        devices.addOutputDevice(fallback)
        if headsetInitiallyConnected { devices.addOutputDevice(headset) }
        volume = MockDeviceVolumeProviding(deviceMonitor: devices)
        volume.defaultDeviceID = fallback.id
        volume.defaultDeviceUID = fallback.uid
        volume.volumes = [fallback.id: 0.5, headset.id: 0.5]
        processes.activeApps = [app]
        permission.status = .authorized
        let tap = RecordingProcessTapController(
            app: app, deviceUIDs: [headsetInitiallyConnected && !followsDefault ? headset.uid : fallback.uid])
        self.tap = tap
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(loadCatalogAutomatically: false),
            deviceProvider: devices,
            processMonitor: processes,
            deviceVolumeMonitor: volume,
            tapFactory: { app, uids, _ in
                if let controlledRoute {
                    return ReconciliationTestTap(app: app, deviceUIDs: uids, operation: controlledRoute)
                }
                return tap
            },
            isAlive: { _ in true },
            orphanedTapCleanup: { .empty },
            startMonitorsAutomatically: false
        )
        engine.bluetoothDeviceMonitor.stop()
        engine.applyPersistedSettings()
        #expect(engine.activeProcessingTapCount == 1)
        try engine.installMutationAdmission(gate)
    }

    func connectHeadset() {
        devices.addOutputDevice(headset)
        devices.onDeviceConnected?(headset.uid, headset.name)
    }

    func disconnectHeadset() {
        devices.outputDevices.removeAll { $0.uid == headset.uid }
        devices.onDeviceDisconnected?(headset.uid, headset.name)
    }

    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    func shutdown() async throws {
        await engine.shutdownAndDrain()
        permission.shutdown()
        settings.flushSync()
        try FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class ReconciliationRouteOperation {
    private(set) var isWaiting = false
    private(set) var cancellationRequested = false
    var invalidationCount = 0
    private var continuation: CheckedContinuation<Void, any Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
                if Task.isCancelled { cancellationRequested = true }
            }
        } onCancel: {
            Task { @MainActor in self.cancellationRequested = true }
        }
    }

    func finishCancellation() {
        let pending = continuation
        continuation = nil
        isWaiting = false
        pending?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ReconciliationTestTap: ProcessTapControlling {
    let app: AudioApp
    let operation: ReconciliationRouteOperation
    var volume: Float = 1
    var isMuted = false
    var currentDeviceVolume: Float = 1
    var isDeviceMuted = false
    var audioLevel: Float = 0
    var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? { nil }

    init(app: AudioApp, deviceUIDs: [String], operation: ReconciliationRouteOperation) {
        self.app = app
        currentDeviceUIDs = deviceUIDs
        self.operation = operation
    }

    func activate(initial: TapInitialState) throws {}
    func invalidate() {
        operation.invalidationCount += 1
        operation.finishCancellation()
    }
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}
    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, requiresExclusiveOutput: Bool)
        async throws
    {
        try await operation.wait()
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, requiresExclusiveOutput: Bool)
        async throws
    {
        try await operation.wait()
        currentDeviceUIDs = newDeviceUIDs
    }
}
