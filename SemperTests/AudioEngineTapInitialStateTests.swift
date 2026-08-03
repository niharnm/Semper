// SemperTests/AudioEngineTapInitialStateTests.swift
//
// Verifies AudioEngine derives TapInitialState from persisted settings and
// hands it to activate(initial:) before any post-activation mutation.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Semper

// MARK: - Recording Mock

/// Records every method invocation against `ProcessTapControlling` in order.
/// Tests assert on `events` to verify the engine's apply-initial-state contract.
@MainActor
final class RecordingProcessTapController: ProcessTapControlling {
    enum Event: Equatable {
        case activate(TapInitialStateSnapshot)
        case updateEQSettings(EQSettings)
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case invalidate
    }

    /// Plain snapshot of `TapInitialState` so test asserts don't depend on
    /// the source-type's identity (defensive against future mutations).
    struct TapInitialStateSnapshot: Equatable {
        var eqSettings: EQSettings
        var autoEQProfileID: String?
        var autoEQPreampEnabled: Bool
        var loudnessVolume: Float
        var loudnessCompensationEnabled: Bool
        var loudnessEqualizerSettings: LoudnessEqualizerSettings

        @MainActor
        init(_ s: TapInitialState) {
            self.eqSettings = s.eqSettings
            self.autoEQProfileID = s.autoEQProfile?.id
            self.autoEQPreampEnabled = s.autoEQPreampEnabled
            self.loudnessVolume = s.loudnessVolume
            self.loudnessCompensationEnabled = s.loudnessCompensationEnabled
            self.loudnessEqualizerSettings = s.loudnessEqualizerSettings
        }
    }

    let app: AudioApp
    private(set) var events: [Event] = []

    // Mutable surface — recorded as plain property writes (not events).
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var balance: Float = 0
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil
    var shouldFailDeviceSwitch = false
    private(set) var lastSwitchRequiredExclusiveOutput: Bool?

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        events.append(.activate(TapInitialStateSnapshot(initial)))
    }

    func invalidate() {
        events.append(.invalidate)
    }

    func updateEQSettings(_ settings: EQSettings) {
        events.append(.updateEQSettings(settings))
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        events.append(.updateAutoEQProfile(profileID: profile?.id))
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        events.append(.setAutoEQPreampEnabled(enabled))
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        events.append(.updateLoudnessCompensation(volume: volume, enabled: enabled))
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        events.append(.updateLoudnessEqualization(settings))
    }

    func updateBalance(_ balance: Float) {
        self.balance = balance
    }

    func switchDevice(
        to newDeviceUID: String,
        preferredTapSourceDeviceUID: String?,
        requiresExclusiveOutput: Bool
    ) async throws {
        if shouldFailDeviceSwitch {
            throw NSError(
                domain: "SemperTests.Route",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Test route failed"]
            )
        }
        lastSwitchRequiredExclusiveOutput = requiresExclusiveOutput
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(
        to newDeviceUIDs: [String],
        preferredTapSourceDeviceUID: String?,
        requiresExclusiveOutput: Bool
    ) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {}
}

// MARK: - Process monitor stub

@MainActor
final class StubProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let processMonitor: StubProcessMonitor
    let app: AudioApp
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
}

@MainActor
private func makeFixture(
    supportsAutoEQ: Bool = true,
    deviceVolume: Float = 0.75,
    outputTopology: OutputDeviceTopology = .assumedStereo
) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: supportsAutoEQ,
        outputTopology: outputTopology
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = deviceVolume

    let app = AudioApp(
        id: 12345,
        processObjectIDs: [],
        name: "TestApp",
        icon: NSImage(),
        bundleID: "com.test.tapinitial"
    )

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    // Capture every tap the factory hands out so tests can read the captured
    // event log. Mutable box lets the closure write into the test scope.
    let box = TapBox()

    // ensureTapExists guards on permission.status == .authorized. The TCC SPI
    // preflight returns -1 (unknown) under xctest, so we force it to authorized
    // via the internal(set) status property exposed by @testable import.
    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(loadCatalogAutomatically: false),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            box.last = tap
            return tap
        },
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        deviceVolume: mockVolume,
        processMonitor: processMonitor,
        app: app,
        device: device,
        lastTap: { box.last }
    )
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
}

@Suite("Output device topology")
struct OutputDeviceTopologyTests {
    @Test("An exact stereo output supports independent balance")
    func stereoSupportsBalance() {
        let topology = OutputDeviceTopology(
            channelCount: 2,
            preferredStereoPair: nil,
            isAlive: true,
            isAggregate: false
        )
        #expect(topology.supportsProcessedAudio)
        #expect(topology.supportsIndependentBalance)
    }

    @Test("Multichannel output needs a valid preferred stereo pair")
    func multichannelNeedsPreferredPair() {
        let valid = OutputDeviceTopology(
            channelCount: 6,
            preferredStereoPair: StereoChannelPair(left: 2, right: 3),
            isAlive: true,
            isAggregate: false
        )
        let missing = OutputDeviceTopology(
            channelCount: 6,
            preferredStereoPair: nil,
            isAlive: true,
            isAggregate: false
        )
        let invalid = OutputDeviceTopology(
            channelCount: 6,
            preferredStereoPair: StereoChannelPair(left: 2, right: 8),
            isAlive: true,
            isAggregate: false
        )

        #expect(valid.supportsIndependentBalance)
        #expect(!missing.supportsIndependentBalance)
        #expect(!invalid.supportsIndependentBalance)
    }

    @Test("A logical aggregate does not claim per-device balance")
    func aggregateHidesIndependentBalance() {
        let topology = OutputDeviceTopology(
            channelCount: 2,
            preferredStereoPair: StereoChannelPair(left: 0, right: 1),
            isAlive: true,
            isAggregate: true
        )
        #expect(topology.supportsProcessedAudio)
        #expect(!topology.supportsIndependentBalance)
    }
}

@Suite("App route presentation")
struct AppRoutePresentationTests {
    private let airPods = AudioDevice(
        id: 201,
        uid: "airpods",
        name: "AirPods Pro",
        icon: nil,
        supportsAutoEQ: false
    )
    private let speaker = AudioDevice(
        id: 202,
        uid: "speaker",
        name: "GS515",
        icon: nil,
        supportsAutoEQ: false
    )

    @Test("Following the default names the current system output")
    func systemOutputNamesDefault() {
        let subtitle = DevicePicker.routingSubtitle(
            devices: [airPods, speaker],
            selectedDeviceUID: speaker.uid,
            selectedDeviceUIDs: [],
            isFollowingDefault: true,
            defaultDeviceUID: speaker.uid,
            mode: .single,
            lifecycle: .active(deviceUIDs: [speaker.uid])
        )
        #expect(subtitle == "System Output · GS515")
    }

    @Test("Pending and failed routes do not claim success")
    func pendingAndFailureStayTruthful() {
        let pending = DevicePicker.routingSubtitle(
            devices: [airPods, speaker],
            selectedDeviceUID: speaker.uid,
            selectedDeviceUIDs: [],
            isFollowingDefault: false,
            mode: .single,
            lifecycle: .preparing(deviceUIDs: [airPods.uid])
        )
        let failed = DevicePicker.routingSubtitle(
            devices: [airPods, speaker],
            selectedDeviceUID: speaker.uid,
            selectedDeviceUIDs: [],
            isFollowingDefault: false,
            mode: .single,
            lifecycle: .failed(
                previousDeviceUIDs: [speaker.uid],
                message: "Test failure"
            )
        )

        #expect(pending == "Routing to AirPods Pro…")
        #expect(failed == "Route failed · Still on GS515")
    }
}

// MARK: - Suite

@Suite("AudioEngine.tapInitialState — first-sound fix (PR-1)")
@MainActor
struct AudioEngineTapInitialStateTests {

    // MARK: Single-knob derivation

    @Test("EQ settings persisted for this app land in TapInitialState.eqSettings")
    func eqSettingsAreCarried() throws {
        let fix = makeFixture()
        let custom = EQSettings(bandGains: [3, 0, -2, 0, 0, 0, 0, 0, 0, 4], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.eqSettings == custom)
    }

    @Test("autoEQPreampEnabled mirrors settingsManager.autoEQPreampEnabled",
          arguments: [true, false])
    func autoEQPreampEnabledMirrored(value: Bool) throws {
        let fix = makeFixture()
        fix.settings.autoEQPreampEnabled = value

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQPreampEnabled == value)
    }

    @Test("loudnessCompensationEnabled mirrors appSettings.loudnessCompensationEnabled",
          arguments: [true, false])
    func loudnessCompensationFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessCompensationEnabled == value)
    }

    @Test("loudnessEqualizerSettings.enabled mirrors appSettings.loudnessEqualizationEnabled",
          arguments: [true, false])
    func loudnessEqualizerFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessEqualizationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessEqualizerSettings.enabled == value)
    }

    @Test("loudnessVolume = currentDeviceVolume × per-app volume")
    func loudnessVolumeIsProduct() throws {
        let fix = makeFixture(deviceVolume: 0.5)
        fix.engine.volumeState.setVolume(for: fix.app.id, to: 0.4, identifier: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        // applyTapOutputState() runs before tapInitialState() is built, so
        // currentDeviceVolume is 0.5 (from MockDeviceVolumeProviding.volumes).
        // loudnessVolume should be deviceVolume (0.5) × appVolume (0.4) = 0.2.
        #expect(abs(snap.loudnessVolume - 0.2) < 1e-6)
    }

    @Test("Master output boost holds hardware at unity and multiplies tap gain")
    func masterOutputBoostUsesTapGain() throws {
        let fix = makeFixture(deviceVolume: 0.4)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setMasterOutputVolume(for: fix.device, to: 3)

        let lastWrite = try #require(fix.deviceVolume.setVolumeCalls.last)
        #expect(lastWrite.deviceID == fix.device.id)
        #expect(lastWrite.volume == 1)
        #expect(tap.volume == 3)
        #expect(fix.engine.masterOutputVolume(for: fix.device) == 3)
    }

    @Test("Boost is capped at 100% until a single-output route activates")
    func boostRequiresVerifiedSingleOutputRoute() {
        let fix = makeFixture()

        let before = fix.engine.outputCapabilities(for: fix.device)
        #expect(before.maximumGain == 1)
        #expect(!before.isRouteVerified)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let after = fix.engine.outputCapabilities(for: fix.device)
        #expect(after.maximumGain == 3)
        #expect(after.isRouteVerified)
        #expect(after.supportsBalance)
    }

    @Test("Mono output can boost after route activation but cannot expose balance")
    func monoOutputHidesBalance() {
        let topology = OutputDeviceTopology(
            channelCount: 1,
            preferredStereoPair: nil,
            isAlive: true,
            isAggregate: false
        )
        let fix = makeFixture(outputTopology: topology)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let capabilities = fix.engine.outputCapabilities(for: fix.device)
        #expect(capabilities.maximumGain == 3)
        #expect(!capabilities.supportsBalance)

        fix.engine.setOutputBalance(for: fix.device.uid, to: 0.8)
        #expect(fix.engine.outputBalance(for: fix.device.uid) == 0)
    }

    @Test("Failed device switch keeps the previous route and saved device")
    func failedSwitchKeepsPreviousRoute() async throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        let secondDevice = AudioDevice(
            id: 100,
            uid: "uid-second",
            name: "Second Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(secondDevice)
        tap.shouldFailDeviceSwitch = true

        fix.engine.setDevice(for: fix.app, deviceUID: secondDevice.uid)
        for _ in 0..<20 {
            if case .failed = fix.engine.routeLifecycle(for: fix.app) {
                break
            }
            await Task.yield()
        }

        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.device.uid)
        #expect(
            fix.settings.getDeviceRouting(for: fix.app.persistenceIdentifier)
                == fix.device.uid
        )
        guard case .failed(let previousUIDs, _) = fix.engine.routeLifecycle(for: fix.app) else {
            Issue.record("Expected failed route lifecycle")
            return
        }
        #expect(previousUIDs == [fix.device.uid])
    }

    @Test("Manual app route switches without overlapping the previous output")
    func manualRouteRequiresExclusiveOutput() async throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        let secondDevice = AudioDevice(
            id: 100,
            uid: "uid-second",
            name: "Second Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(secondDevice)

        fix.engine.setDevice(for: fix.app, deviceUID: secondDevice.uid)
        for _ in 0..<20 {
            if tap.lastSwitchRequiredExclusiveOutput != nil {
                break
            }
            await Task.yield()
        }

        #expect(tap.lastSwitchRequiredExclusiveOutput == true)
        #expect(tap.currentDeviceUID == secondDevice.uid)
    }

    @Test("A newly discovered helper process rebuilds the app tap")
    func helperMembershipChangeRebuildsTap() async throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let firstTap = try #require(fix.lastTap())

        let updatedApp = AudioApp(
            id: fix.app.id,
            processObjectIDs: [777],
            name: fix.app.name,
            icon: fix.app.icon,
            bundleID: fix.app.bundleID,
            isHelperBacked: true
        )
        fix.processMonitor.activeApps = [updatedApp]
        fix.processMonitor.onAppsChanged?([updatedApp])

        for _ in 0..<50 {
            if let current = fix.lastTap(),
               current !== firstTap,
               current.app.processObjectIDs == [777] {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let rebuiltTap = try #require(fix.lastTap())
        #expect(rebuiltTap !== firstTap)
        #expect(rebuiltTap.app.processObjectIDs == [777])
        #expect(rebuiltTap.currentDeviceUID == fix.device.uid)
    }

    @Test("Idle helper churn does not rebuild an existing tap")
    func idleHelperMembershipIsIgnored() {
        let shouldRefresh = AudioEngine.shouldRefreshTapMembership(
            currentObjectIDs: [100],
            latestObjectIDs: [100, 200],
            isRunning: { _ in false }
        )

        #expect(!shouldRefresh)
    }

    @Test("A newly active helper requests a tap refresh")
    func activeHelperMembershipRequestsRefresh() {
        let shouldRefresh = AudioEngine.shouldRefreshTapMembership(
            currentObjectIDs: [100],
            latestObjectIDs: [100, 200],
            isRunning: { $0 == 200 }
        )

        #expect(shouldRefresh)
    }

    @Test("Per-device balance is applied to its single-device taps")
    func deviceBalanceReachesTap() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setOutputBalance(for: fix.device.uid, to: -0.6)

        #expect(abs(tap.balance - (-0.6)) < 1e-6)
        #expect(abs(fix.engine.outputBalance(for: fix.device.uid) - (-0.6)) < 1e-6)
    }

    @Test("Output status identifies active per-app attenuation")
    func outputStatusShowsQuietApp() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.audioLevel = 0.5

        fix.engine.setVolume(for: fix.app, to: 0.075)

        #expect(fix.engine.outputAttenuationNotice(for: fix.device.uid) == "TestApp 27% app volume")
    }

    @Test("Output status identifies loudness processing")
    func outputStatusShowsLoudnessProcessing() {
        let fix = makeFixture()
        var appSettings = fix.settings.appSettings
        appSettings.loudnessEqualizationEnabled = true
        fix.settings.updateAppSettings(appSettings)

        #expect(fix.engine.outputAttenuationNotice(for: fix.device.uid) == "Loudness processing on")
    }

    @Test("Persisted master gain and balance reach a new tap")
    func persistedMasterStateReachesNewTap() throws {
        let fix = makeFixture()
        fix.settings.setOutputMasterGain(for: fix.device.uid, to: 2.25)
        fix.settings.setOutputBalance(for: fix.device.uid, to: 0.35)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        #expect(abs(tap.volume - 2.25) < 1e-6)
        #expect(abs(tap.balance - 0.35) < 1e-6)
        #expect(abs(fix.engine.masterOutputVolume(for: fix.device) - 2.25) < 1e-6)
    }

    @Test("Silent unconfigured monitor app does not allocate a tap")
    func silentUnconfiguredAppDoesNotPrewarm() {
        let fix = makeFixture()
        fix.deviceVolume.defaultDeviceUID = fix.device.uid

        fix.engine.applyPersistedSettings()

        #expect(fix.lastTap() == nil)
        #expect(fix.engine.displayableApps.isEmpty)
    }

    @Test("Silent configured app is prepared but hidden until playback")
    func silentConfiguredAppIsPreparedBeforePlayback() throws {
        let fix = makeFixture()
        fix.deviceVolume.defaultDeviceUID = fix.device.uid
        fix.settings.setDeviceRouting(
            for: fix.app.persistenceIdentifier,
            deviceUID: fix.device.uid
        )

        fix.engine.applyPersistedSettings()

        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUID == fix.device.uid)
        #expect(fix.engine.displayableApps.isEmpty)
    }

    // MARK: AutoEQ profile resolution

    @Test("autoEQProfile is nil when the device does not support AutoEQ")
    func autoEQNilForUnsupportedDevice() throws {
        let fix = makeFixture(supportsAutoEQ: false)
        // Even if a selection exists, an unsupported device must skip AutoEQ.
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when no selection is persisted for the device")
    func autoEQNilWithNoSelection() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        // Don't set any selection.

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when the selection is disabled")
    func autoEQNilWhenSelectionDisabled() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: false)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when selection is enabled but profile is not in the cache")
    func autoEQNilWhenProfileNotCached() throws {
        // Default AutoEQProfileManager has no profiles cached for "missing-id".
        // The pre-activate synchronous lookup must return nil so that
        // ensureTapExists falls through to the async resolve branch.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    // MARK: Ordering / post-activation behaviour

    @Test("activate(initial:) is the first event the controller observes")
    func activateIsFirstEvent() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let firstEvent = try #require(tap.events.first)
        if case .activate = firstEvent {
            // ok
        } else {
            Issue.record("First event was \(firstEvent), expected .activate")
        }
    }

    @Test("No EQ/AutoEQ/Loudness mutation runs BEFORE activate(initial:) — the apply-initial-state contract")
    func noMutationBeforeActivate() throws {
        // The core PR-1 invariant: every processor-state knob the audio thread
        // can observe must be set via TapInitialState, not via post-construction
        // calls that race with AudioDeviceStart. We assert this by checking
        // that no .updateEQSettings / .updateAutoEQProfile / .setAutoEQPreampEnabled
        // / .updateLoudnessCompensation / .updateLoudnessEqualization is recorded
        // BEFORE the .activate event in the tap's event log.
        //
        // Exercises a realistic config (AutoEQ-capable device with an enabled
        // selection whose profile is uncached) so applyAutoEQToTap runs
        // post-activate — proving the engine's fallback path doesn't accidentally
        // fire before activate.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )
        let custom = EQSettings(bandGains: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = true
        s.loudnessEqualizationEnabled = true
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let activateIndex = try #require(tap.events.firstIndex { event in
            if case .activate = event { return true }
            return false
        })

        for event in tap.events.prefix(activateIndex) {
            switch event {
            case .updateEQSettings, .updateAutoEQProfile, .setAutoEQPreampEnabled,
                 .updateLoudnessCompensation, .updateLoudnessEqualization:
                Issue.record("Pre-activate mutation breaks the apply-initial-state contract: \(event)")
            case .activate, .invalidate:
                break
            }
        }
    }

    @Test("Cache-miss AutoEQ: applyAutoEQToTap fires its sync nil-set after activate")
    func cacheMissTriggersPostActivateNilSet() throws {
        // Device supports AutoEQ + selection is enabled but profile is missing
        // from cache → ensureTapExists calls applyAutoEQToTap, which sets the
        // profile to nil synchronously before kicking off async resolution.
        // Verifies the engine's fallback path is reached when (and only when)
        // the synchronous pre-activate lookup misses.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        // The first event must still be .activate (apply-initial-state ordering)
        if case .activate = tap.events.first {
            // ok
        } else {
            Issue.record("activate(initial:) was not first event")
        }
        // A post-activate updateAutoEQProfile(nil) must be present from
        // applyAutoEQToTap's sync nil-set on cache miss.
        let postActivateAutoEQ = tap.events.dropFirst().compactMap { event -> String?? in
            if case let .updateAutoEQProfile(id) = event { return Optional(id) }
            return nil
        }
        #expect(postActivateAutoEQ.contains(where: { $0 == nil }))
    }
}

// MARK: - Helpers

@MainActor
private func capturedInitial(_ fix: Fixture) -> RecordingProcessTapController.TapInitialStateSnapshot? {
    guard let tap = fix.lastTap() else { return nil }
    for event in tap.events {
        if case let .activate(snapshot) = event { return snapshot }
    }
    return nil
}

// MARK: - Mock contract

@Suite("RecordingProcessTapController — protocol contract")
@MainActor
struct RecordingProcessTapControllerContractTests {
    @Test("Mock records activate, then mutation events, in invocation order")
    func recordsCallOrder() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        try tap.activate(initial: TapInitialState())
        tap.updateEQSettings(EQSettings.flat)
        tap.updateAutoEQProfile(nil)

        #expect(tap.events.count == 3)
        if case .activate = tap.events[0] {} else { Issue.record("expected .activate at 0") }
        if case .updateEQSettings = tap.events[1] {} else { Issue.record("expected .updateEQSettings at 1") }
        if case .updateAutoEQProfile = tap.events[2] {} else { Issue.record("expected .updateAutoEQProfile at 2") }
    }

    @Test("Default property values match real controller defaults")
    func defaultsMatchProductionController() {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // ProcessTapController's nonisolated(unsafe) defaults from source.
        #expect(tap.volume == 1.0)
        #expect(tap.isMuted == false)
        #expect(tap.currentDeviceVolume == 1.0)
        #expect(tap.isDeviceMuted == false)
        #expect(tap.audioLevel == 0.0)
        #expect(tap.tapSourceDeviceUID == nil)
        #expect(tap.currentDeviceUID == "uid")
    }

    @Test("Backward-compatible activate() convenience routes through activate(initial:)")
    func convenienceActivateRoutesThroughInitial() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // Convenience extension on the protocol: should funnel through activate(initial:)
        // with a default TapInitialState — proves no caller can sneak around the
        // initial-state contract by calling the old no-arg overload.
        try tap.activate()
        if case let .activate(snap) = tap.events.first {
            #expect(snap.autoEQProfileID == nil)
            #expect(snap.loudnessCompensationEnabled == false)
            #expect(snap.loudnessEqualizerSettings.enabled == false)
            #expect(snap.autoEQPreampEnabled == false)
            #expect(snap.eqSettings == EQSettings.flat)
            #expect(snap.loudnessVolume == 1.0)
        } else {
            Issue.record("activate() did not record an .activate event")
        }
    }
}
