#if !APP_STORE

import Foundation
import Testing
import AudioToolbox
@testable import Semper

@Suite("DDC write ledger")
struct DDCWriteLedgerTests {
    private let deviceID: AudioDeviceID = 42

    @Test("A saved DDC volume is clamped before unmute")
    func unmuteClamp() {
        #expect(DDCController.restoredVolume(85, maximumVolume: 40) == 40)
        #expect(DDCController.restoredVolume(35, maximumVolume: 40) == 35)
        #expect(DDCController.restoredVolume(85, maximumVolume: nil) == 85)
    }

    @Test("Superseded debounce restores the last physical value")
    func supersededDebounceRestoresConfirmedVolume() {
        var ledger = DDCWriteLedger()
        ledger.replaceConfirmedVolumes([deviceID: 80])

        let first = ledger.beginWrite(for: deviceID)
        let second = ledger.beginWrite(for: deviceID)

        #expect(ledger.finishWrite(
            for: deviceID,
            generation: second,
            requestedVolume: 40,
            succeeded: false
        ) == .failed(restoredVolume: 80))
        #expect(ledger.finishWrite(
            for: deviceID,
            generation: first,
            requestedVolume: 60,
            succeeded: false
        ) == nil)
    }

    @Test("A completed running write becomes the rollback value")
    func runningWriteSuccessBecomesRollbackValue() {
        var ledger = DDCWriteLedger()
        ledger.replaceConfirmedVolumes([deviceID: 80])

        let running = ledger.beginWrite(for: deviceID)
        let current = ledger.beginWrite(for: deviceID)

        #expect(ledger.finishWrite(
            for: deviceID,
            generation: running,
            requestedVolume: 60,
            succeeded: true
        ) == nil)
        #expect(ledger.finishWrite(
            for: deviceID,
            generation: current,
            requestedVolume: 40,
            succeeded: false
        ) == .failed(restoredVolume: 60))
    }

    @Test("A stale success cannot complete the current write")
    func staleSuccessDoesNotResolveCurrentWrite() {
        var ledger = DDCWriteLedger()
        ledger.replaceConfirmedVolumes([deviceID: 80])

        let first = ledger.beginWrite(for: deviceID)
        let second = ledger.beginWrite(for: deviceID)

        #expect(ledger.finishWrite(
            for: deviceID,
            generation: first,
            requestedVolume: 60,
            succeeded: true
        ) == nil)
        #expect(ledger.finishWrite(
            for: deviceID,
            generation: second,
            requestedVolume: 40,
            succeeded: true
        ) == .applied(40))
    }

    @Test("Cancellation rejects the current write at the confirmed value")
    func cancellationRestoresConfirmedVolume() {
        var ledger = DDCWriteLedger()
        ledger.replaceConfirmedVolumes([deviceID: 80])

        let generation = ledger.beginWrite(for: deviceID)

        #expect(ledger.cancelWrite(
            for: deviceID,
            generation: generation
        ) == .failed(restoredVolume: 80))
    }

    @Test("A write from replaced services cannot change confirmed state")
    func replacedServiceWriteCannotChangeConfirmedState() {
        var ledger = DDCWriteLedger()
        ledger.replaceConfirmedVolumes([deviceID: 80])
        let oldGeneration = ledger.beginWrite(for: deviceID)
        _ = ledger.cancelWrite(for: deviceID, generation: oldGeneration)

        ledger.replaceConfirmedVolumes([deviceID: 55])
        #expect(ledger.finishWrite(
            for: deviceID,
            generation: oldGeneration,
            requestedVolume: 60,
            succeeded: true
        ) == nil)
        #expect(ledger.confirmedVolumes[deviceID] == 55)
    }
}

@Suite("Device volume monitor DDC completion")
@MainActor
struct DeviceVolumeMonitorDDCCompletionTests {
    private func makeMonitor() -> DeviceVolumeMonitor {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory)
        return DeviceVolumeMonitor(
            deviceMonitor: AudioDeviceMonitor(),
            settingsManager: settings,
            ddcController: DDCController(settingsManager: settings)
        )
    }

    @Test("Failure publishes restored state before rejection")
    func failurePublishesRestoredStateBeforeRejection() {
        let monitor = makeMonitor()
        let deviceID: AudioDeviceID = 42
        var events: [String] = []
        monitor.onVolumeChanged = { _, _ in events.append("volume") }
        monitor.onMuteChanged = { _, _ in events.append("mute") }
        monitor.onOutputWriteCompleted = { _, succeeded in
            events.append("completed:\(succeeded)")
        }
        monitor.onOutputWriteFailed = { _ in events.append("rejected") }

        monitor.handleDDCWriteResult(
            deviceID: deviceID,
            result: .failed(restoredVolume: 35, restoredMute: true)
        )

        #expect(abs((monitor.volumes[deviceID] ?? 0) - 0.35) < 0.0001)
        #expect(monitor.muteStates[deviceID] == true)
        #expect(events == ["volume", "mute", "completed:false", "rejected"])
    }

    @Test("Success publishes applied state before completion")
    func successPublishesAppliedStateBeforeCompletion() {
        let monitor = makeMonitor()
        let deviceID: AudioDeviceID = 42
        var events: [String] = []
        monitor.onVolumeChanged = { _, _ in events.append("volume") }
        monitor.onMuteChanged = { _, _ in events.append("mute") }
        monitor.onOutputWriteCompleted = { _, succeeded in
            events.append("completed:\(succeeded)")
        }

        monitor.handleDDCWriteResult(deviceID: deviceID, result: .applied(55))

        #expect(abs((monitor.volumes[deviceID] ?? 0) - 0.55) < 0.0001)
        #expect(monitor.muteStates[deviceID] == false)
        #expect(events == ["volume", "mute", "completed:true"])
    }
}

#endif
