import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import Semper

@MainActor
private struct AudioSceneSafetyFixture {
    let engine: AudioEngine
    let commands: AudioCommandDispatcher
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let volumeMonitor: MockDeviceVolumeProviding
    let processMonitor: StubProcessMonitor
    let current: AudioDevice
    let target: AudioDevice
    let directory: URL
    let lastTap: () -> RecordingProcessTapController?
}

@MainActor
private final class AudioSceneSafetyTapBox {
    var tap: RecordingProcessTapController?
}

@MainActor
private func makeAudioSceneSafetyFixture(withApp: Bool = false) -> AudioSceneSafetyFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SemperAudioSceneSafety-\(UUID().uuidString)")
    let settings = SettingsManager(directory: directory)
    let deviceMonitor = MockAudioDeviceMonitor()
    let current = AudioDevice(
        id: AudioDeviceID(301),
        uid: "scene-current-output",
        name: "Current Output",
        icon: nil,
        supportsAutoEQ: false
    )
    let target = AudioDevice(
        id: AudioDeviceID(302),
        uid: "scene-target-output",
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

    let processMonitor = StubProcessMonitor()
    if withApp {
        processMonitor.activeApps = [AudioApp(
            id: 30_001,
            processObjectIDs: [],
            name: "Scene Audio App",
            icon: NSImage(),
            bundleID: "com.semper.tests.scene-audio"
        )]
    }

    let tapBox = AudioSceneSafetyTapBox()
    let permission = AudioRecordingPermission()
    permission.status = .authorized
    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(loadCatalogAutomatically: false),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: volumeMonitor,
        tapFactory: { app, deviceUIDs, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: deviceUIDs)
            tapBox.tap = tap
            return tap
        },
        isAlive: { _ in true },
        startMonitorsAutomatically: false
    )
    let commands = AudioCommandDispatcher(
        backend: AudioEngineCommandBackend(engine: engine)
    )
    return AudioSceneSafetyFixture(
        engine: engine,
        commands: commands,
        settings: settings,
        deviceMonitor: deviceMonitor,
        volumeMonitor: volumeMonitor,
        processMonitor: processMonitor,
        current: current,
        target: target,
        directory: directory,
        lastTap: { tapBox.tap }
    )
}

@MainActor
private func waitForAudioSceneCondition(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Audio scene safety")
@MainActor
struct AudioSceneSafetyTests {
    @Test("A capped destination restore settles at the configured limit")
    func cappedDestinationRestoreSettlesAtLimit() async throws {
        let fixture = makeAudioSceneSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.settings.setOutputVolumeLimit(for: fixture.target.uid, to: 0.4)
        let journal = FileSceneJournalStore(directory: fixture.directory)
        let unusedAdapter = SceneControlAdapterMock()
        let coordinator = SceneCoordinator(
            adapters: SceneAdapterRegistry(
                audio: AudioSceneAdapter(engine: fixture.engine, commands: fixture.commands),
                display: unusedAdapter,
                power: unusedAdapter
            ),
            journalStore: journal
        )
        let volume = SceneControl.audioOutputVolume(deviceID: fixture.target.uid)
        let scene = SemperScene(name: "Capped destination", actions: [
            SceneAction(control: .audioOutputDevice, target: .text(fixture.target.uid), importance: .required),
            SceneAction(control: volume, target: .number(0.4), importance: .optional),
        ])

        guard fixture.commands.beginSceneTransaction() else {
            Issue.record("Expected scene transaction admission")
            return
        }
        _ = try await coordinator.apply(scene)
        fixture.commands.endSceneTransaction()

        #expect(fixture.volumeMonitor.defaultDeviceUID == fixture.target.uid)
        #expect(fixture.volumeMonitor.volumes[fixture.target.id] == 0.4)

        guard fixture.commands.beginSceneTransaction() else {
            Issue.record("Expected restore transaction admission")
            return
        }
        let report = try #require(try await coordinator.restore())
        fixture.commands.endSceneTransaction()

        #expect(report.journalCleared)
        #expect(fixture.volumeMonitor.defaultDeviceUID == fixture.current.uid)
        #expect(fixture.volumeMonitor.volumes[fixture.target.id] == 0.4)
        #expect(fixture.volumeMonitor.setVolumeCalls.map(\.volume) == [0.4])
        #expect(try journal.load() == nil)
    }

    @Test("Route settlement waits for system sounds that follow default")
    func routeSettlementWaitsForSystemSounds() {
        let fixture = makeAudioSceneSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.volumeMonitor.isSystemFollowingDefault = true
        fixture.volumeMonitor.systemDeviceUID = fixture.current.uid

        #expect(fixture.engine.beginSceneTransaction())
        #expect(
            fixture.engine.requestPreparedDefaultOutputDeviceSwitch(fixture.target.id)
                == .applied
        )
        #expect(!fixture.engine.isDefaultOutputRouteSettled(on: fixture.target.uid))

        fixture.volumeMonitor.systemDeviceUID = fixture.target.uid
        #expect(fixture.engine.isDefaultOutputRouteSettled(on: fixture.target.uid))
        fixture.engine.endSceneTransaction()
    }

    @Test("Route settlement waits for follow-default taps")
    func routeSettlementWaitsForFollowDefaultTap() async throws {
        let fixture = makeAudioSceneSafetyFixture(withApp: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try #require(fixture.processMonitor.activeApps.first)
        fixture.engine.setDevice(for: app, deviceUID: nil)
        defer { fixture.engine.stop() }
        let tap = try #require(fixture.lastTap())
        tap.switchDeviceDelays[fixture.target.uid] = .milliseconds(100)

        #expect(fixture.engine.beginSceneTransaction())
        #expect(
            fixture.engine.requestPreparedDefaultOutputDeviceSwitch(fixture.target.id)
                == .applied
        )
        #expect(!fixture.engine.isDefaultOutputRouteSettled(on: fixture.target.uid))
        #expect(await waitForAudioSceneCondition {
            fixture.engine.isDefaultOutputRouteSettled(on: fixture.target.uid)
        })
        fixture.engine.endSceneTransaction()
    }
}
