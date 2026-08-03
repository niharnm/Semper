import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import Semper

@MainActor
private struct SafeSwitchFixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let volumeMonitor: MockDeviceVolumeProviding
    let current: AudioDevice
    let target: AudioDevice
}

@MainActor
private func makeSafeSwitchFixture() -> SafeSwitchFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SemperSafeSwitchTests-\(UUID().uuidString)")
    let settings = SettingsManager(directory: directory)
    let deviceMonitor = MockAudioDeviceMonitor()
    let current = AudioDevice(
        id: AudioDeviceID(91),
        uid: "current-output",
        name: "Current Output",
        icon: nil,
        supportsAutoEQ: false
    )
    let target = AudioDevice(
        id: AudioDeviceID(92),
        uid: "target-output",
        name: "Target Output",
        icon: nil,
        supportsAutoEQ: false
    )
    deviceMonitor.addOutputDevice(current)
    deviceMonitor.addOutputDevice(target)

    let volumeMonitor = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    volumeMonitor.defaultDeviceID = current.id
    volumeMonitor.defaultDeviceUID = current.uid
    volumeMonitor.volumes[current.id] = 0.5
    volumeMonitor.volumes[target.id] = 0.8

    let permission = AudioRecordingPermission()
    permission.status = .authorized
    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(loadCatalogAutomatically: false),
        deviceProvider: deviceMonitor,
        processMonitor: StubProcessMonitor(),
        deviceVolumeMonitor: volumeMonitor,
        tapFactory: { app, uids, _ in
            RecordingProcessTapController(app: app, deviceUIDs: uids)
        },
        isAlive: { _ in true },
        startMonitorsAutomatically: false
    )
    return SafeSwitchFixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        volumeMonitor: volumeMonitor,
        current: current,
        target: target
    )
}

@Suite("Safe output switch integration")
@MainActor
struct SafeOutputSwitchIntegrationTests {
    @Test("An uncapped target switches immediately")
    func immediateSwitch() {
        let fixture = makeSafeSwitchFixture()

        let result = fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id)

        #expect(result == .applied)
        #expect(fixture.volumeMonitor.setDefaultDeviceCalls == [fixture.target.id])
        #expect(fixture.volumeMonitor.defaultDeviceUID == fixture.target.uid)
    }

    @Test("A capped target is lowered before switching")
    func cappedPreflight() async {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)

        let result = fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id)

        #expect(result == .accepted)
        #expect(fixture.volumeMonitor.setVolumeCalls.last?.deviceID == fixture.target.id)
        #expect(fixture.volumeMonitor.setVolumeCalls.last?.volume == 0.4)
        #expect(fixture.volumeMonitor.setDefaultDeviceCalls.isEmpty)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(fixture.volumeMonitor.setDefaultDeviceCalls == [fixture.target.id])
    }

    @Test("A failed cap write keeps the current output")
    func failedPreflight() async {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        fixture.volumeMonitor.volumeWritesSucceed = false
        var rejectedKeys: [AudioControlKey] = []
        fixture.engine.onCommandWriteRejected = { rejectedKeys.append($0) }

        let result = fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(result == .accepted)
        #expect(fixture.volumeMonitor.setDefaultDeviceCalls.isEmpty)
        #expect(fixture.volumeMonitor.defaultDeviceUID == fixture.current.uid)
        #expect(rejectedKeys == [.defaultOutput])
    }

    @Test("A failed default-device write is reported after preflight")
    func failedDefaultWrite() async {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        fixture.volumeMonitor.defaultDeviceWritesSucceed = false
        var rejectedKeys: [AudioControlKey] = []
        fixture.engine.onCommandWriteRejected = { rejectedKeys.append($0) }

        let result = fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(result == .accepted)
        #expect(fixture.volumeMonitor.defaultDeviceUID == fixture.current.uid)
        #expect(rejectedKeys == [.defaultOutput])
    }

    @Test("A DDC target requires a confirmed write")
    func ddcConfirmation() async {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        fixture.volumeMonitor.autoDetectedTiersByID[fixture.target.id] = .ddc
        var rejectedKeys: [AudioControlKey] = []
        fixture.engine.onCommandWriteRejected = { rejectedKeys.append($0) }

        let result = fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(result == .accepted)
        #expect(fixture.volumeMonitor.setDefaultDeviceCalls.isEmpty)
        #expect(rejectedKeys == [.defaultOutput])
    }

    @Test("A failed DDC write cannot use an optimistic cached limit")
    func failedDDCWriteRejectsOptimisticCache() {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        fixture.volumeMonitor.autoDetectedTiersByID[fixture.target.id] = .ddc
        fixture.volumeMonitor.volumes[fixture.target.id] = 0.4
        fixture.volumeMonitor.confirmedOutputVolumes[fixture.target.id] = 0.8
        var rejectedKeys: [AudioControlKey] = []
        fixture.engine.onCommandWriteRejected = { rejectedKeys.append($0) }

        let result = fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id)
        fixture.volumeMonitor.onOutputWriteCompleted?(fixture.target.id, false)

        #expect(result == .accepted)
        #expect(fixture.volumeMonitor.setDefaultDeviceCalls.isEmpty)
        #expect(rejectedKeys == [.defaultOutput])
    }

    @Test("A confirmed DDC cap authorizes the switch")
    func confirmedDDCSwitch() {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        fixture.volumeMonitor.autoDetectedTiersByID[fixture.target.id] = .ddc

        let result = fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id)
        fixture.volumeMonitor.onOutputWriteCompleted?(fixture.target.id, true)

        #expect(result == .accepted)
        #expect(fixture.volumeMonitor.setDefaultDeviceCalls == [fixture.target.id])
    }

    @Test("A newer immediate switch cancels an older preflight")
    func replacementSwitch() async {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        let replacement = AudioDevice(
            id: AudioDeviceID(93),
            uid: "replacement-output",
            name: "Replacement Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fixture.deviceMonitor.addOutputDevice(replacement)
        fixture.volumeMonitor.volumes[replacement.id] = 0.5
        var rejectedKeys: [AudioControlKey] = []
        fixture.engine.onCommandWriteRejected = { rejectedKeys.append($0) }

        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id) == .accepted)
        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(replacement.id) == .applied)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(fixture.volumeMonitor.setDefaultDeviceCalls == [replacement.id])
        #expect(fixture.volumeMonitor.defaultDeviceUID == replacement.uid)
        #expect(rejectedKeys == [.defaultOutput])
    }

    @Test("An unconfirmed default-device write is rejected after its deadline")
    func unconfirmedDefaultWrite() async {
        let fixture = makeSafeSwitchFixture()
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        fixture.volumeMonitor.autoDetectedTiersByID[fixture.target.id] = .ddc
        fixture.volumeMonitor.defaultDeviceWritesPublishState = false
        var rejectedKeys: [AudioControlKey] = []
        fixture.engine.onCommandWriteRejected = { rejectedKeys.append($0) }

        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id) == .accepted)
        fixture.volumeMonitor.onOutputWriteCompleted?(fixture.target.id, true)
        try? await Task.sleep(for: .milliseconds(550))

        #expect(fixture.volumeMonitor.setDefaultDeviceCalls == [fixture.target.id])
        #expect(fixture.volumeMonitor.defaultDeviceUID == fixture.current.uid)
        #expect(rejectedKeys == [.defaultOutput])
    }

    @Test("A stale default callback does not reject the newer switch")
    func staleDefaultCallback() async {
        let fixture = makeSafeSwitchFixture()
        let replacement = AudioDevice(
            id: AudioDeviceID(93),
            uid: "replacement-output",
            name: "Replacement Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fixture.deviceMonitor.addOutputDevice(replacement)
        fixture.volumeMonitor.volumes[replacement.id] = 0.5
        fixture.volumeMonitor.defaultDeviceWritesPublishState = false
        var rejectedKeys: [AudioControlKey] = []
        fixture.engine.onCommandWriteRejected = { rejectedKeys.append($0) }

        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id) == .accepted)
        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(replacement.id) == .accepted)
        fixture.volumeMonitor.onDefaultDeviceChanged?(fixture.target.uid)
        fixture.volumeMonitor.defaultDeviceID = replacement.id
        fixture.volumeMonitor.defaultDeviceUID = replacement.uid
        fixture.volumeMonitor.onDefaultDeviceChanged?(replacement.uid)
        try? await Task.sleep(for: .milliseconds(550))

        #expect(rejectedKeys == [.defaultOutput])
        #expect(fixture.volumeMonitor.defaultDeviceUID == replacement.uid)
    }

    @Test("A safe switch completes a pending ceiling without losing it")
    func safeSwitchOwnsPendingCeiling() {
        let fixture = makeSafeSwitchFixture()
        fixture.volumeMonitor.autoDetectedTiersByID[fixture.target.id] = .ddc
        fixture.volumeMonitor.confirmedOutputVolumes[fixture.target.id] = 0.8
        let dispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: fixture.engine)
        )

        fixture.engine.beginOutputVolumeLimitChange(for: fixture.target.uid, to: 0.4)
        let capResult = dispatcher.dispatch(
            .setOutputMasterGain(deviceUID: fixture.target.uid, gain: 0.8),
            context: AudioCommandContext(source: .popup, reason: .safeCap)
        )
        fixture.engine.resolveOutputVolumeLimitChange(
            for: fixture.target.uid,
            commandResult: capResult
        )

        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id) == .accepted)
        fixture.volumeMonitor.confirmedOutputVolumes[fixture.target.id] = 0.4
        fixture.volumeMonitor.onOutputWriteCompleted?(fixture.target.id, true)

        #expect(fixture.settings.outputVolumeLimit(for: fixture.target.uid) == 0.4)
        #expect(fixture.volumeMonitor.defaultDeviceUID == fixture.target.uid)
    }

    @Test("Replacing a safe switch rolls back its inherited ceiling transaction")
    func replacementRollsBackInheritedCeiling() {
        let fixture = makeSafeSwitchFixture()
        let replacement = AudioDevice(
            id: AudioDeviceID(93),
            uid: "replacement-output",
            name: "Replacement Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fixture.deviceMonitor.addOutputDevice(replacement)
        fixture.volumeMonitor.volumes[replacement.id] = 0.5
        fixture.volumeMonitor.autoDetectedTiersByID[fixture.target.id] = .ddc
        fixture.volumeMonitor.confirmedOutputVolumes[fixture.target.id] = 0.8
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.8)
        let dispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: fixture.engine)
        )

        fixture.engine.beginOutputVolumeLimitChange(for: fixture.target.uid, to: 0.4)
        let capResult = dispatcher.dispatch(
            .setOutputMasterGain(deviceUID: fixture.target.uid, gain: 0.8),
            context: AudioCommandContext(source: .popup, reason: .safeCap)
        )
        fixture.engine.resolveOutputVolumeLimitChange(
            for: fixture.target.uid,
            commandResult: capResult
        )
        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id) == .accepted)

        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(replacement.id) == .applied)
        #expect(fixture.settings.outputVolumeLimit(for: fixture.target.uid) == 0.8)
        #expect(!fixture.engine.hasPendingOutputVolumeLimitChange(for: fixture.target.uid))
    }

    @Test("A same-target replacement commits its inherited ceiling")
    func sameTargetReplacementCommitsInheritedCeiling() {
        let fixture = makeSafeSwitchFixture()
        fixture.volumeMonitor.autoDetectedTiersByID[fixture.target.id] = .ddc
        fixture.volumeMonitor.confirmedOutputVolumes[fixture.target.id] = 0.8
        let dispatcher = AudioCommandDispatcher(
            backend: AudioEngineCommandBackend(engine: fixture.engine)
        )

        fixture.engine.beginOutputVolumeLimitChange(for: fixture.target.uid, to: 0.4)
        let capResult = dispatcher.dispatch(
            .setOutputMasterGain(deviceUID: fixture.target.uid, gain: 0.8),
            context: AudioCommandContext(source: .popup, reason: .safeCap)
        )
        fixture.engine.resolveOutputVolumeLimitChange(
            for: fixture.target.uid,
            commandResult: capResult
        )
        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id) == .accepted)

        fixture.volumeMonitor.confirmedOutputVolumes[fixture.target.id] = 0.4
        #expect(fixture.engine.requestDefaultOutputDeviceSwitch(fixture.target.id) == .applied)
        #expect(fixture.settings.outputVolumeLimit(for: fixture.target.uid) == 0.4)
        #expect(!fixture.engine.hasPendingOutputVolumeLimitChange(for: fixture.target.uid))
    }
}
