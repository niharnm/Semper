import Foundation
import Testing

@testable import Semper

@MainActor
private final class AdmissionAlertWriter {
    var writes: [Int] = []
    var continuation: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?

    func write(_ percent: Int) async throws {
        writes.append(percent)
        started?.resume()
        started = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if writes.isEmpty { await withCheckedContinuation { started = $0 } }
    }
}

@Suite("Alert volume mutation admission")
@MainActor
struct AlertVolumeMutationAdmissionTests {
    @Test("Away blocks alert changes before local state or the writer changes")
    func deniedAlertWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        let writer = AdmissionAlertWriter()
        let monitor = DeviceVolumeMonitor(
            deviceMonitor: AudioDeviceMonitor(), settingsManager: settings,
            alertVolumeWriter: writer.write)
        let gate = MutationAdmissionGate()
        try monitor.installMutationAdmission(gate)
        let away = try gate.acquire(owner: .awayMode, mode: .exclusive)
        let previous = monitor.alertVolume
        monitor.setAlertVolume(0.25)
        #expect(monitor.alertVolume == previous)
        #expect(writer.writes.isEmpty)
        #expect(monitor.mutationAdmissionError as? MutationAdmissionError == .exclusivePermitActive(owner: .awayMode))
        monitor.stop()
        gate.release(away)
        settings.flushSync()
        try FileManager.default.removeItem(at: directory)
    }

    @Test("Accepted alert write holds admission through stop until the writer settles")
    func delayedWriteDrainsBeforeAway() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        let writer = AdmissionAlertWriter()
        let monitor = DeviceVolumeMonitor(
            deviceMonitor: AudioDeviceMonitor(), settingsManager: settings,
            alertVolumeWriter: writer.write)
        let gate = MutationAdmissionGate()
        try monitor.installMutationAdmission(gate)
        let task = try #require(monitor.flushAlertVolumeWrite { monitor.setAlertVolume(0.25) })
        #expect(gate.activeSharedPermitCount == 1)
        await writer.waitUntilStarted()
        monitor.stop()
        #expect(throws: MutationAdmissionError.self) { try gate.acquire(owner: .awayMode, mode: .exclusive) }
        writer.continuation?.resume()
        writer.continuation = nil
        #expect(await task.value)
        #expect(await monitor.drainAlertVolumeWrites())
        #expect(gate.activeSharedPermitCount == 0)
        settings.flushSync()
        try FileManager.default.removeItem(at: directory)
    }

    @Test("Stopping an unsubmitted debounce releases its admission without a write")
    func cancelledDebounce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        let writer = AdmissionAlertWriter()
        let monitor = DeviceVolumeMonitor(
            deviceMonitor: AudioDeviceMonitor(), settingsManager: settings,
            alertVolumeWriter: writer.write)
        let gate = MutationAdmissionGate()
        try monitor.installMutationAdmission(gate)
        monitor.setAlertVolume(0.25)
        #expect(gate.activeSharedPermitCount == 1)
        monitor.stop()
        #expect(gate.activeSharedPermitCount == 0)
        #expect(writer.writes.isEmpty)
        settings.flushSync()
        try FileManager.default.removeItem(at: directory)
    }
}
