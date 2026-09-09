import Foundation
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
}
