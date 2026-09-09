#if SOUND_RUNTIME_ALERT_HARNESS
    import Foundation
    import Testing

    @testable import Semper

    @MainActor
    private final class RuntimeAlertWriter {
        enum Failure: Error { case rejected }
        var rejectsManual = false
        var writes: [Int] = []
        var actualPercent = 100
        var isDrained = true
        var retainsProcessAfterFailure = false

        func write(_ percent: Int) async throws {
            writes.append(percent)
            if rejectsManual && percent == 60 {
                if retainsProcessAfterFailure { isDrained = false }
                throw Failure.rejected
            }
            actualPercent = percent
        }
    }

    @Suite("Sound runtime alert recovery")
    @MainActor
    struct SoundRuntimeAlertRecoveryTests {
        private func fixture() -> (SoundRuntime, RuntimeAlertWriter, URL) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
            settings.appSettings.callModeQuietAlerts = true
            let writer = RuntimeAlertWriter()
            let monitor = DeviceVolumeMonitor(
                deviceMonitor: AudioDeviceMonitor(), settingsManager: settings,
                alertVolumeWriter: writer.write, alertVolumeIsDrained: { writer.isDrained })
            let callMode = CallModeCoordinator(
                settings: settings, overlayStore: AudioModeOverlayStore(), activityStore: AudioActivityStore(),
                currentInputDeviceUID: { nil }, claimInputDevice: { _ in false }, releaseInputDevice: {},
                readAlertVolume: { monitor.alertVolume }, writeAlertVolume: monitor.setAlertVolume
            )
            return (SoundRuntime(monitor: monitor, callMode: callMode), writer, directory)
        }

        private func quiet(_ runtime: SoundRuntime) async throws {
            let task = try #require(
                runtime.deviceVolumeMonitor.flushAlertVolumeWrite {
                    runtime.callMode.start(applicationIdentifier: "test.call", displayName: "Call")
                })
            #expect(await task.value)
        }

        private func stopResult(_ runtime: SoundRuntime) async -> String {
            do {
                try await runtime.shutdownAndDrain()
                return "stopped"
            } catch SoundRuntimeShutdownError.alertVolumeRestoration {
                return "alert failure"
            } catch SoundRuntimeShutdownError.audioResourceCleanup {
                return "resource failure"
            } catch {
                Issue.record("Unexpected shutdown failure: \(error)")
                return "unexpected failure"
            }
        }

        @Test("Ending Call Mode cannot discard the pending manual intent at Sound shutdown")
        func endedSessionPendingWrite() async throws {
            let (runtime, writer, directory) = fixture()
            try await quiet(runtime)
            runtime.deviceVolumeMonitor.setAlertVolume(0.6)
            runtime.callMode.end()
            #expect(!runtime.callMode.isActive)
            #expect(await stopResult(runtime) == "stopped")
            #expect(writer.actualPercent == 60)
            #expect(writer.writes == [25, 60])
            try FileManager.default.removeItem(at: directory)
        }

        @Test("An ended Call Mode session cannot hide a completed manual failure")
        func endedSessionFailedWrite() async throws {
            let (runtime, writer, directory) = fixture()
            try await quiet(runtime)
            writer.rejectsManual = true
            let manual = try #require(
                runtime.deviceVolumeMonitor.flushAlertVolumeWrite {
                    runtime.deviceVolumeMonitor.setAlertVolume(0.6)
                })
            #expect(await manual.value == false)
            runtime.callMode.end()
            #expect(await stopResult(runtime) == "alert failure")
            #expect(writer.actualPercent == 25)
            try FileManager.default.removeItem(at: directory)
        }

        @Test(
            "Retry Stop writes the same intended value again and clears only successful recovery",
            arguments: [false, true])
        func retrySameValue(externalCorrection: Bool) async throws {
            let (runtime, writer, directory) = fixture()
            try await quiet(runtime)
            writer.rejectsManual = true
            runtime.deviceVolumeMonitor.setAlertVolume(0.6)
            #expect(await stopResult(runtime) == "alert failure")
            #expect(runtime.isShutDown)
            #expect(writer.writes == [25, 60])
            if externalCorrection { writer.actualPercent = 60 }
            writer.rejectsManual = false
            #expect(await stopResult(runtime) == "stopped")
            #expect(writer.writes == [25, 60, 60])
            #expect(writer.actualPercent == 60)
            #expect(await stopResult(runtime) == "stopped")
            #expect(writer.writes == [25, 60, 60])
            try FileManager.default.removeItem(at: directory)
        }

        @Test("Failed retries stay visible and cannot bypass Away admission")
        func retryRespectsFailureAndGate() async throws {
            let (runtime, writer, directory) = fixture()
            let gate = MutationAdmissionGate()
            try runtime.deviceVolumeMonitor.installMutationAdmission(gate)
            try await quiet(runtime)
            writer.rejectsManual = true
            runtime.deviceVolumeMonitor.setAlertVolume(0.6)
            #expect(await stopResult(runtime) == "alert failure")
            #expect(await stopResult(runtime) == "alert failure")
            #expect(writer.writes == [25, 60, 60])
            writer.rejectsManual = false
            let away = try gate.acquire(owner: .awayMode, mode: .exclusive)
            #expect(await stopResult(runtime) == "alert failure")
            #expect(writer.writes == [25, 60, 60])
            gate.release(away)
            #expect(await stopResult(runtime) == "stopped")
            #expect(writer.writes == [25, 60, 60, 60])
            #expect(gate.activeSharedPermitCount == 0)
            try FileManager.default.removeItem(at: directory)
        }

        @Test("Audio resource cleanup failure blocks alert recovery retry")
        func doesNotClearResourceFailure() async throws {
            let (runtime, writer, directory) = fixture()
            try await quiet(runtime)
            writer.rejectsManual = true
            runtime.deviceVolumeMonitor.setAlertVolume(0.6)
            #expect(await stopResult(runtime) == "alert failure")
            writer.rejectsManual = false
            runtime.audioEngine.shutdownCleanupResult.failureCount = 1
            #expect(await stopResult(runtime) == "resource failure")
            #expect(writer.writes == [25, 60])
            try FileManager.default.removeItem(at: directory)
        }

        @Test("Retry waits for the owned alert process exit and retains admission until then")
        func retryAfterLateProcessExit() async throws {
            let (runtime, writer, directory) = fixture()
            let gate = MutationAdmissionGate()
            try runtime.deviceVolumeMonitor.installMutationAdmission(gate)
            try await quiet(runtime)
            writer.rejectsManual = true
            writer.retainsProcessAfterFailure = true
            runtime.deviceVolumeMonitor.setAlertVolume(0.6)
            #expect(await stopResult(runtime) == "resource failure")
            #expect(gate.activeSharedPermitCount == 1)
            #expect(await stopResult(runtime) == "resource failure")
            #expect(writer.writes == [25, 60])
            #expect(throws: MutationAdmissionError.self) { try gate.acquire(owner: .awayMode, mode: .exclusive) }

            writer.isDrained = true
            writer.rejectsManual = false
            #expect(await stopResult(runtime) == "stopped")
            #expect(writer.writes == [25, 60, 60])
            #expect(writer.actualPercent == 60)
            #expect(gate.activeSharedPermitCount == 0)
            try FileManager.default.removeItem(at: directory)
        }
    }
#endif
