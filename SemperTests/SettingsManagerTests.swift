// SemperTests/SettingsManagerTests.swift
// Tests for SettingsManager.Settings JSON round-trip, merge algorithm, and pruning.
// Uses temp directories — no real settings files affected.

import Testing
import Foundation
@testable import Semper

@Suite("Settings persistence writer")
struct SettingsPersistenceWriterTests {
    @Test("Synchronous write waits for queued writes and completes last")
    func synchronousWriteCompletesLast() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        let olderData = Data("older".utf8)
        let currentData = Data("current".utf8)
        let olderWriteStarted = DispatchSemaphore(value: 0)
        let releaseOlderWrite = DispatchSemaphore(value: 0)
        let asyncWriteFailed = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        let flushFailed = DispatchSemaphore(value: 0)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SettingsPersistenceWriter { data, destination in
            if data == olderData {
                olderWriteStarted.signal()
                releaseOlderWrite.wait()
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }

        writer.enqueue(olderData, to: url) { _ in
            asyncWriteFailed.signal()
        }
        #expect(olderWriteStarted.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            do {
                try writer.writeSynchronously(currentData, to: url)
            } catch {
                flushFailed.signal()
            }
            flushFinished.signal()
        }

        #expect(flushFinished.wait(timeout: .now() + 0.1) == .timedOut)
        releaseOlderWrite.signal()
        #expect(flushFinished.wait(timeout: .now() + 2) == .success)
        #expect(asyncWriteFailed.wait(timeout: .now()) == .timedOut)
        #expect(flushFailed.wait(timeout: .now()) == .timedOut)
        #expect(try Data(contentsOf: url) == currentData)
    }
}

// MARK: - Settings JSON Round-Trip

@Suite("SettingsManager.Settings — JSON serialization")
@MainActor
struct SettingsJSONTests {

    @Test("Default Settings encodes and decodes to equal value")
    func defaultRoundTrip() throws {
        let original = SettingsManager.Settings()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == original.version)
        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.systemSoundsFollowsDefault == original.systemSoundsFollowsDefault)
    }

    @Test("Populated Settings round-trips all fields")
    func populatedRoundTrip() throws {
        var original = SettingsManager.Settings()
        original.appVolumes = ["com.test.app": 0.5]
        original.appMutes = ["com.test.app": true]
        original.appBoosts = ["com.test.app": 2.0]
        original.appDeviceRouting = ["com.test.app": "device-uid-123"]
        original.pinnedApps = Set(["com.test.app"])
        original.outputDevicePriority = ["uid-a", "uid-b", "uid-c"]
        original.ddcVolumes = ["monitor-1": 75]
        original.ddcMuteStates = ["monitor-1": false]
        original.autoEQPreampEnabled = false
        original.hiddenOutputDeviceUIDs = ["uid-hidden-out-1", "uid-hidden-out-2"]
        original.hiddenInputDeviceUIDs = ["uid-hidden-in-1"]
        original.deviceIconOverrides = ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"]
        original.outputMasterGains = ["uid-a": 2.5]
        original.outputBalances = ["uid-a": -0.4]
        original.outputVolumeLimits = ["uid-a": 0.75]
        original.audioProcessingMode = .bypassed
        original.callModePreferences = ["us.zoom.xos": .always]
        original.bluetoothHDGuardPreferences = [
            "headset-output": BluetoothHDGuardPreferenceRecord(
                behavior: BluetoothHDGuardBehavior.always.rawValue,
                headsetName: "Headset",
                microphoneUID: "built-in-input",
                microphoneName: "MacBook Microphone"
            ),
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.appBoosts == original.appBoosts)
        #expect(decoded.appDeviceRouting == original.appDeviceRouting)
        #expect(decoded.pinnedApps == original.pinnedApps)
        #expect(decoded.outputDevicePriority == original.outputDevicePriority)
        #expect(decoded.ddcVolumes == original.ddcVolumes)
        #expect(decoded.ddcMuteStates == original.ddcMuteStates)
        #expect(decoded.autoEQPreampEnabled == false)
        #expect(decoded.hiddenOutputDeviceUIDs == original.hiddenOutputDeviceUIDs)
        #expect(decoded.hiddenInputDeviceUIDs == original.hiddenInputDeviceUIDs)
        #expect(decoded.deviceIconOverrides == original.deviceIconOverrides)
        #expect(decoded.outputMasterGains == original.outputMasterGains)
        #expect(decoded.outputBalances == original.outputBalances)
        #expect(decoded.outputVolumeLimits == original.outputVolumeLimits)
        #expect(decoded.audioProcessingMode == .bypassed)
        #expect(decoded.callModePreferences == original.callModePreferences)
        #expect(
            decoded.bluetoothHDGuardPreferences
                == original.bluetoothHDGuardPreferences
        )
    }

    @Test("Decoding empty JSON produces valid defaults")
    func emptyJSONDefaults() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 9)
        #expect(decoded.appVolumes.isEmpty)
        #expect(decoded.appMutes.isEmpty)
        #expect(decoded.systemSoundsFollowsDefault == true)
        #expect(decoded.autoEQPreampEnabled == true)
        #expect(decoded.hiddenOutputDeviceUIDs.isEmpty)
        #expect(decoded.hiddenInputDeviceUIDs.isEmpty)
        #expect(decoded.deviceIconOverrides.isEmpty)
        #expect(decoded.outputMasterGains.isEmpty)
        #expect(decoded.outputBalances.isEmpty)
        #expect(decoded.outputVolumeLimits.isEmpty)
        #expect(decoded.audioProcessingMode == .active)
        #expect(decoded.callModePreferences.isEmpty)
        #expect(decoded.bluetoothHDGuardPreferences.isEmpty)
    }

    @Test("Decoding with extra unknown keys is tolerated")
    func unknownKeysIgnored() throws {
        let json = """
        {"version": 9, "unknownField": "hello", "anotherNew": 42}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 9)
    }

    @Test("Volume values above 1.0 are clamped to 1.0 on decode")
    func volumeClampedAboveOne() throws {
        let json = """
        {"appVolumes": {"com.test.app": 1.5, "com.other.app": 0.8}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == 1.0)
        #expect(decoded.appVolumes["com.other.app"] == 0.8)
    }

    @Test("Negative volume values are filtered out on decode")
    func negativeVolumesFiltered() throws {
        let json = """
        {"appVolumes": {"com.test.app": -0.5, "com.good.app": 0.7}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == nil, "Negative volume should be filtered out")
        #expect(decoded.appVolumes["com.good.app"] == 0.7)
    }

    @Test("Non-finite volume values cannot be encoded to JSON")
    func nonFiniteVolumesCannotEncode() throws {
        // JSON spec does not support NaN or Infinity.
        // JSONEncoder throws when encountering non-finite floats.
        // This verifies the boundary: production code's filter on decode handles
        // finite-but-invalid values (negative, >1.0); non-finite values are
        // prevented at the encoding layer.
        var settings = SettingsManager.Settings()
        settings.appVolumes["inf_app"] = Float.infinity

        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(settings)
        }
    }

    @Test("Invalid defaultNewAppVolume is reset to 1.0 on decode")
    func invalidDefaultVolumeReset() throws {
        // AppSettings uses auto-synthesized Codable — all keys required.
        // MenuBarIconStyle raw value is capitalized ("Default", not "default").
        let json = """
        {"appSettings": {"launchAtLogin": false, "menuBarIconStyle": "Default", "defaultNewAppVolume": -5.0, "lockInputDevice": true, "showDeviceDisconnectAlerts": true}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appSettings.defaultNewAppVolume == 1.0,
                "Negative defaultNewAppVolume should be reset to 1.0")
    }
}

@Suite("Bluetooth HD Guard settings")
@MainActor
struct BluetoothHDGuardSettingsTests {
    @Test("Schema 15 settings default to prompt-first Bluetooth protection")
    func migrationDefaults() throws {
        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(#"{"version":15,"appSettings":{}}"#.utf8)
        )

        #expect(decoded.appSettings.bluetoothHDGuardEnabled)
        #expect(decoded.bluetoothHDGuardPreferences.isEmpty)
    }

    @Test("Preference decoding drops unknown behavior and blank headset records")
    func lossyPreferenceDecode() throws {
        let json = #"{"bluetoothHDGuardPreferences":{"headset-a":{"behavior":"always","headsetName":"Headset A","microphoneUID":"mic-a","microphoneName":"Mic A"},"headset-b":{"behavior":"sometimes","headsetName":"Headset B"}," ":{"behavior":"never","headsetName":"Blank UID"},"headset-c":{"behavior":"never","headsetName":" "}}}"#
        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(json.utf8)
        )

        #expect(decoded.bluetoothHDGuardPreferences == [
            "headset-a": BluetoothHDGuardPreferenceRecord(
                behavior: "always",
                headsetName: "Headset A",
                microphoneUID: "mic-a",
                microphoneName: "Mic A"
            ),
        ])
    }

    @Test("Typed headset choices persist and reset")
    func preferenceLifecycle() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperBluetoothSettingsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        manager.setBluetoothHDGuardPreference(
            BluetoothHDGuardPreference(
                headsetUID: "headset-a",
                headsetName: "Headset A",
                behavior: .always,
                microphoneUID: "mic-a",
                microphoneName: "Mic A"
            )
        )

        #expect(manager.bluetoothHDGuardPreference(
            for: "headset-a",
            headsetName: "Fallback"
        ).behavior == .always)
        #expect(manager.bluetoothHDGuardPreferences.count == 1)

        manager.resetAllSettings()
        #expect(manager.bluetoothHDGuardPreferences.isEmpty)
    }
}

@Suite("Call Mode settings")
@MainActor
struct CallModeSettingsTests {
    @Test("Older settings default to prompt-first Call Mode")
    func migrationDefaults() throws {
        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(#"{"version":14,"appSettings":{}}"#.utf8)
        )

        #expect(decoded.appSettings.callModeEnabled)
        #expect(!decoded.appSettings.callModeQuietAlerts)
        #expect(decoded.callModePreferences.isEmpty)
    }

    @Test("Call Mode preference decoding drops unknown and blank entries")
    func lossyPreferenceDecode() throws {
        let json = #"{"callModePreferences":{"us.zoom.xos":"always","com.apple.FaceTime":"never","bad":"sometimes"," ":"always"}}"#
        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(json.utf8)
        )

        #expect(decoded.callModePreferences == [
            "us.zoom.xos": .always,
            "com.apple.FaceTime": .never,
        ])
    }

    @Test("Ask uses the default and removes a saved preference")
    func askRemovesSavedPreference() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperCallModeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)

        manager.setCallModePreference(.always, for: "us.zoom.xos")
        #expect(manager.callModePreference(for: "us.zoom.xos") == .always)
        manager.setCallModePreference(.ask, for: "us.zoom.xos")
        #expect(manager.callModePreference(for: "us.zoom.xos") == .ask)
    }
}

@Suite("SettingsManager output volume limits")
@MainActor
struct OutputVolumeLimitPersistenceTests {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperVolumeLimitTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Default settings use schema 16")
    func schemaVersion() {
        #expect(SettingsManager.Settings().version == 16)
    }

    @Test("Loading an older file advances its schema on the next write")
    func olderSchemaAdvancesOnWrite() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"version":13}"#.utf8).write(to: url, options: .atomic)

        let manager = SettingsManager(directory: directory)
        manager.flushSync()

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["version"] as? Int == 16)
    }

    @Test("Limits clamp, persist by UID, and clear with nil")
    func setPersistAndClear() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = SettingsManager(directory: directory)
        manager.setOutputVolumeLimit(for: "uid-low", to: 0.05)
        manager.setOutputVolumeLimit(for: "uid-high", to: 1.4)
        manager.setOutputVolumeLimit(for: "uid-normal", to: 0.65)
        manager.flushSync()

        var reloaded = SettingsManager(directory: directory)
        #expect(reloaded.outputVolumeLimit(for: "uid-low") == 0.1)
        #expect(reloaded.outputVolumeLimit(for: "uid-high") == 1.0)
        #expect(reloaded.outputVolumeLimit(for: "uid-normal") == 0.65)

        reloaded.setOutputVolumeLimit(for: "uid-normal", to: nil)
        reloaded.flushSync()
        reloaded = SettingsManager(directory: directory)
        #expect(reloaded.outputVolumeLimit(for: "uid-normal") == nil)
    }

    @Test("Invalid values and blank UIDs are not stored")
    func invalidInputs() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)

        manager.setOutputVolumeLimit(for: "uid-a", to: 0.7)
        manager.setOutputVolumeLimit(for: "uid-a", to: .infinity)
        manager.setOutputVolumeLimit(for: "   ", to: 0.5)

        #expect(manager.outputVolumeLimit(for: "uid-a") == nil)
        #expect(manager.outputVolumeLimit(for: "   ") == nil)
    }

    @Test("Decode normalizes limits and filters invalid entries")
    func decodeNormalization() throws {
        let json = """
        {
          "outputVolumeLimits": {
            "uid-low": 0.05,
            "uid-high": 1.4,
            "uid-normal": 0.65,
            "uid-invalid": 0,
            " ": 0.5
          }
        }
        """

        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(json.utf8)
        )

        #expect(decoded.outputVolumeLimits == [
            "uid-low": 0.1,
            "uid-high": 1.0,
            "uid-normal": 0.65
        ])
    }

    @Test("Reset clears every output limit")
    func resetClearsLimits() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        manager.setOutputVolumeLimit(for: "uid-a", to: 0.4)
        manager.setOutputVolumeLimit(for: "uid-b", to: 0.8)

        manager.resetAllSettings()

        #expect(manager.outputVolumeLimit(for: "uid-a") == nil)
        #expect(manager.outputVolumeLimit(for: "uid-b") == nil)
    }
}

@Suite("SettingsManager audio processing recovery")
@MainActor
struct AudioProcessingModePersistenceTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Schema 13 defaults audio processing to active")
    func olderSchemaDefaultsActive() throws {
        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(#"{"version":13}"#.utf8)
        )

        #expect(decoded.audioProcessingMode == .active)
    }

    @Test("Unknown audio processing values fail open to active")
    func unknownValueDefaultsActive() throws {
        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(#"{"audioProcessingMode":"future-value"}"#.utf8)
        )

        #expect(decoded.audioProcessingMode == .active)
    }

    @Test("Bypass and resume requests persist across reloads")
    func modesPersist() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)

        manager.setAudioProcessingMode(.bypassed)
        manager.flushSync()
        #expect(SettingsManager(directory: directory).audioProcessingMode == .bypassed)

        manager.setAudioProcessingMode(.resumeRequested)
        manager.flushSync()
        #expect(SettingsManager(directory: directory).audioProcessingMode == .resumeRequested)
    }

    @Test("Reset preserves a bypass request")
    func resetPreservesMode() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        manager.setAudioProcessingMode(.bypassed)

        manager.resetAllSettings()

        #expect(manager.audioProcessingMode == .bypassed)
    }
}

@Suite("SettingsManager master output persistence")
@MainActor
struct MasterOutputPersistenceTests {

    @Test("Master gain and balance survive a disk reload")
    func diskReload() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        let original = SettingsManager(directory: directory)
        original.setOutputMasterGain(for: "uid-a", to: 2.5)
        original.setOutputBalance(for: "uid-a", to: -0.4)
        original.flushSync()

        let reloaded = SettingsManager(directory: directory)
        #expect(reloaded.getOutputMasterGain(for: "uid-a") == 2.5)
        #expect(reloaded.getOutputBalance(for: "uid-a") == -0.4)
    }
}

@Suite("SettingsManager app audio configuration")
@MainActor
struct AppAudioConfigurationTests {

    @Test("Only apps with saved controls are marked configured")
    func savedControlsMarkAppConfigured() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let manager = SettingsManager(directory: directory)

        #expect(!manager.hasSavedAudioConfiguration(for: "com.test.idle"))

        manager.setDeviceRouting(
            for: "com.test.routed",
            deviceUID: "device-uid"
        )
        manager.setVolume(for: "com.test.volume", to: 0.8)

        #expect(manager.hasSavedAudioConfiguration(for: "com.test.routed"))
        #expect(manager.hasSavedAudioConfiguration(for: "com.test.volume"))
    }
}

// MARK: - mergePriorityOrder

@Suite("SettingsManager — mergePriorityOrder algorithm")
@MainActor
struct MergePriorityOrderTests {

    @Test("No disconnected devices: returns connectedOrder as-is")
    func noDisconnected() {
        let old = ["A", "B", "C"]
        let connected = ["C", "A", "B"] // user reordered
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["C", "A", "B"])
    }

    @Test("Disconnected device anchored between two connected devices")
    func disconnectedBetween() {
        let old = ["A", "D", "B"] // D is disconnected (not in connectedOrder)
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D was after A in old, so anchored to A. Result: A, D, B
        #expect(result == ["A", "D", "B"])
    }

    @Test("Disconnected device at the beginning (no preceding connected device)")
    func disconnectedAtStart() {
        let old = ["D", "A", "B"] // D is disconnected, before all connected
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D has nil anchor → inserted at front
        #expect(result == ["D", "A", "B"])
    }

    @Test("Multiple disconnected devices with same anchor")
    func multipleDisconnectedSameAnchor() {
        let old = ["A", "D1", "D2", "B"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["A", "D1", "D2", "B"])
    }

    @Test("All devices disconnected: returns disconnected in old order")
    func allDisconnected() {
        let old = ["A", "B", "C"]
        let connected: [String] = []
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // All disconnected, anchored to nil → inserted at front in order
        #expect(result == ["A", "B", "C"])
    }

    @Test("Empty old priority: returns connectedOrder")
    func emptyOldPriority() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: ["X", "Y"])
        #expect(result == ["X", "Y"])
    }

    @Test("Both empty: returns empty")
    func bothEmpty() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: [])
        #expect(result.isEmpty)
    }

    @Test("Reordering connected devices preserves disconnected anchors")
    func reorderPreservesAnchors() {
        let old = ["A", "D1", "B", "D2", "C"]
        let connected = ["C", "A", "B"] // user moved C to front
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D1 anchored to A, D2 anchored to B
        // Result: C, A, D1, B, D2
        #expect(result == ["C", "A", "D1", "B", "D2"])
    }

    @Test("Disconnected device at end (anchored to last connected)")
    func disconnectedAtEnd() {
        let old = ["A", "B", "D"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D anchored to B → after B
        #expect(result == ["A", "B", "D"])
    }
}

// MARK: - AppSettings Defaults

@Suite("AppSettings — Default values")
struct AppSettingsDefaultTests {

    @Test("Default AppSettings has expected values")
    func defaults() {
        let settings = AppSettings()
        #expect(settings.launchAtLogin == false)
        #expect(settings.menuBarIconStyle == .default)
        #expect(settings.defaultNewAppVolume == 1.0)
        #expect(settings.lockInputDevice == true)
        #expect(settings.showDeviceDisconnectAlerts == true)
    }

    @Test("loudnessEqualizationEnabled defaults to false")
    func loudnessEqualizationEnabledDefault() {
        let settings = AppSettings()
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled round-trips through JSON as true")
    func loudnessEqualizationEnabledRoundTrip() throws {
        var settings = AppSettings()
        settings.loudnessEqualizationEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.loudnessEqualizationEnabled == true)
    }

    @Test("Unified loudness toggle updates compensation and equalization together")
    func unifiedLoudnessToggleSetsBothFlags() {
        var settings = AppSettings()

        settings.setUnifiedLoudnessEnabled(true)
        #expect(settings.loudnessCompensationEnabled == true)
        #expect(settings.loudnessEqualizationEnabled == true)

        settings.setUnifiedLoudnessEnabled(false)
        #expect(settings.loudnessCompensationEnabled == false)
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled persists via SettingsManager")
    @MainActor
    func loudnessEqualizationEnabledPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let manager = SettingsManager(directory: tempDir)
        var newSettings = manager.appSettings
        newSettings.loudnessEqualizationEnabled = true
        manager.updateAppSettings(newSettings)
        #expect(manager.appSettings.loudnessEqualizationEnabled == true)
    }

    @Test("volumeHotkeyStep defaults to .normal")
    func volumeHotkeyStepDefault() {
        let settings = AppSettings()
        #expect(settings.volumeHotkeyStep == .normal)
    }

    @Test("volumeHotkeyStep round-trips through JSON")
    func volumeHotkeyStepRoundTrip() throws {
        var settings = AppSettings()
        settings.volumeHotkeyStep = .fine
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.volumeHotkeyStep == .fine)
    }

    @Test("Missing volumeHotkeyStep key decodes to .normal")
    func volumeHotkeyStepMissingKeyDefault() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.volumeHotkeyStep == .normal)
    }

}

// MARK: - Hidden Devices

@Suite("SettingsManager — hidden device UIDs")
@MainActor
struct SettingsManagerHiddenDevicesTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("hideOutputDevice / unhideOutputDevice / isOutputDeviceHidden round-trip")
    func outputHideUnhideParity() {
        let m = makeManager()
        let uid = "uid-output-1"

        #expect(m.isOutputDeviceHidden(uid) == false)
        m.hideOutputDevice(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == true)
        #expect(m.hiddenOutputDeviceUIDs.contains(uid))
        m.unhideOutputDevice(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == false)
        #expect(m.hiddenOutputDeviceUIDs.contains(uid) == false)
    }

    @Test("hideInputDevice / unhideInputDevice / isInputDeviceHidden round-trip")
    func inputHideUnhideParity() {
        let m = makeManager()
        let uid = "uid-input-1"

        #expect(m.isInputDeviceHidden(uid) == false)
        m.hideInputDevice(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == true)
        m.unhideInputDevice(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == false)
    }

    @Test("toggleOutputDeviceHidden flips based on persisted state")
    func toggleOutputFlipsFromPersisted() {
        let m = makeManager()
        let uid = "uid-output-2"

        m.toggleOutputDeviceHidden(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == true)
        m.toggleOutputDeviceHidden(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == false)
    }

    @Test("toggleInputDeviceHidden flips based on persisted state")
    func toggleInputFlipsFromPersisted() {
        let m = makeManager()
        let uid = "uid-input-2"

        m.toggleInputDeviceHidden(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == true)
        m.toggleInputDeviceHidden(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == false)
    }

    @Test("Hidden output and input sets are independent")
    func outputAndInputSetsIndependent() {
        let m = makeManager()
        m.hideOutputDevice(uid: "shared-uid")
        #expect(m.isOutputDeviceHidden("shared-uid") == true)
        #expect(m.isInputDeviceHidden("shared-uid") == false)
    }
}

// MARK: - Device Icon Override API

@Suite("SettingsManager — deviceIconOverrides API")
@MainActor
struct DeviceIconOverrideTests {
    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("get/set round-trip for a single UID")
    func setAndGet() {
        let manager = makeManager()
        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)

        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")

        manager.setDeviceIconOverride(for: "uid-a", to: "gamecontroller.fill")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "gamecontroller.fill")
    }

    @Test("Passing nil clears the override")
    func clearOverride() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")

        manager.setDeviceIconOverride(for: "uid-a", to: nil)
        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
    }

    @Test("Overrides for different UIDs are independent")
    func independentPerUID() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")

        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-b") == "gamecontroller.fill")
        #expect(manager.deviceIconOverrides == ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"])
    }

    @Test("resetAllSettings clears all overrides")
    func resetClearsOverrides() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")

        manager.resetAllSettings()

        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
        #expect(manager.getDeviceIconOverride(for: "uid-b") == nil)
        #expect(manager.deviceIconOverrides.isEmpty)
    }
}

// MARK: - MenuBarIconStyle

@Suite("MenuBarIconStyle — Enumeration")
struct MenuBarIconStyleTests {

    @Test("allCases has 5 styles")
    func allCasesCount() {
        #expect(MenuBarIconStyle.allCases.count == 5)
    }

    @Test("All menu bar styles use system symbols")
    func allUseSystemSymbols() {
        for style in MenuBarIconStyle.allCases {
            #expect(style.isSystemSymbol)
        }
    }

    @Test("Every style has a non-empty icon name")
    func allHaveIconNames() {
        for style in MenuBarIconStyle.allCases {
            #expect(!style.iconName.isEmpty, "Style \(style.rawValue) has empty icon name")
        }
    }

    @Test("Styles have distinct symbols and display names")
    func distinctPresentation() {
        let iconNames = MenuBarIconStyle.allCases.map(\.iconName)
        let displayNames = MenuBarIconStyle.allCases.map(\.displayName)

        #expect(Set(iconNames).count == MenuBarIconStyle.allCases.count)
        #expect(Set(displayNames).count == MenuBarIconStyle.allCases.count)
        #expect(displayNames == ["Semper", "Volume", "Output", "Signal", "Levels"])
    }

    @Test("Round-trip through JSON Codable")
    func codableRoundTrip() throws {
        for style in MenuBarIconStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MenuBarIconStyle.self, from: data)
            #expect(decoded == style)
        }
    }
}
