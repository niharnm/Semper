import Foundation
import Testing

@testable import Semper

@MainActor
private final class AlertVolumeTestWriter {
    enum Failure: Error { case rejected }

    var started: [Int] = []
    var applied: [Int] = []
    var heldPercent: Int?
    var rejectedPercent: Int?
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var startWaiter: (percent: Int, continuation: CheckedContinuation<Void, Never>)?

    func write(_ percent: Int) async throws {
        started.append(percent)
        if startWaiter?.percent == percent {
            startWaiter?.continuation.resume()
            startWaiter = nil
        }
        if heldPercent == percent {
            await withCheckedContinuation { heldWrite = $0 }
        }
        if rejectedPercent == percent { throw Failure.rejected }
        applied.append(percent)
    }

    func waitForStart(_ percent: Int) async {
        guard !started.contains(percent) else { return }
        await withCheckedContinuation { startWaiter = (percent, $0) }
    }

    func releaseWrite() {
        heldWrite?.resume()
        heldWrite = nil
    }
}

@Suite("Alert volume shutdown")
@MainActor
struct AlertVolumeShutdownTests {
    private func makeFixture(writer: AlertVolumeTestWriter) -> (
        settings: SettingsManager, monitor: DeviceVolumeMonitor, callMode: CallModeCoordinator, directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperAlertVolumeTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
        settings.appSettings.callModeQuietAlerts = true
        let monitor = DeviceVolumeMonitor(
            deviceMonitor: AudioDeviceMonitor(), settingsManager: settings,
            alertVolumeWriter: writer.write
        )
        let callMode = CallModeCoordinator(
            settings: settings, overlayStore: AudioModeOverlayStore(), activityStore: AudioActivityStore(),
            currentInputDeviceUID: { nil }, claimInputDevice: { _ in false }, releaseInputDevice: {},
            readAlertVolume: { monitor.alertVolume }, writeAlertVolume: monitor.setAlertVolume
        )
        return (settings, monitor, callMode, directory)
    }

    private func removeSettingsDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove temporary alert-volume settings: \(error)")
        }
    }

    @Test("Shutdown finishes the owned restoration after stopping the monitor")
    func restoresAppliedQuietVolume() async throws {
        let writer = AlertVolumeTestWriter()
        let fixture = makeFixture(writer: writer)
        defer {
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        let quiet = try #require(
            fixture.monitor.flushAlertVolumeWrite {
                fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
            })
        #expect(await quiet.value)
        #expect(writer.applied == [25])

        let restoration = try #require(fixture.monitor.flushAlertVolumeWrite(producedBy: fixture.callMode.shutdown))
        fixture.monitor.stop()
        await fixture.monitor.drainAlertVolumeWrites()

        #expect(await restoration.value)
        #expect(writer.applied == [25, 100])
        #expect(fixture.monitor.alertVolume == 1)
        #expect(!fixture.callMode.isActive)
    }

    @Test("An in-flight quiet write finishes before restoration")
    func restorationWaitsForEarlierWrite() async throws {
        let writer = AlertVolumeTestWriter()
        writer.heldPercent = 25
        let fixture = makeFixture(writer: writer)
        defer {
            writer.releaseWrite()
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        _ = fixture.monitor.flushAlertVolumeWrite {
            fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
        }
        await writer.waitForStart(25)

        let restoration = try #require(fixture.monitor.flushAlertVolumeWrite(producedBy: fixture.callMode.shutdown))
        fixture.monitor.stop()
        #expect(writer.started == [25])
        writer.releaseWrite()
        await fixture.monitor.drainAlertVolumeWrites()

        #expect(await restoration.value)
        #expect(writer.applied == [25, 100])
    }

    @Test("Shutdown preserves an observed manual alert-volume change")
    func preservesManualChange() async throws {
        let writer = AlertVolumeTestWriter()
        let fixture = makeFixture(writer: writer)
        defer {
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        let quiet = try #require(
            fixture.monitor.flushAlertVolumeWrite {
                fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
            })
        #expect(await quiet.value)
        let manualChange = try #require(
            fixture.monitor.flushAlertVolumeWrite {
                fixture.monitor.setAlertVolume(0.6)
            })
        #expect(await manualChange.value)

        let restoration = fixture.monitor.flushAlertVolumeWrite(producedBy: fixture.callMode.shutdown)
        fixture.monitor.stop()
        await fixture.monitor.drainAlertVolumeWrites()

        #expect(restoration == nil)
        #expect(writer.applied == [25, 60])
        #expect(fixture.monitor.alertVolume == 0.6)
    }

    @Test("Shutdown preserves the pending manual edit that supersedes confirmed quieting", arguments: [false, true])
    func preservesPendingManualChange(rejectManualWrite: Bool) async throws {
        let writer = AlertVolumeTestWriter()
        let fixture = makeFixture(writer: writer)
        defer {
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        let quiet = try #require(fixture.monitor.flushAlertVolumeWrite {
            fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
        })
        #expect(await quiet.value)
        #expect(writer.applied == [25])
        if rejectManualWrite { writer.rejectedPercent = 60 }
        fixture.monitor.setAlertVolume(0.6)

        let shutdownWrite = fixture.monitor.flushAlertVolumeWrite(
            preservingPendingWrite: fixture.callMode.isActive,
            producedBy: fixture.callMode.shutdown
        )
        fixture.monitor.stop()
        #expect(await fixture.monitor.drainAlertVolumeWrites())

        #expect(shutdownWrite != nil)
        #expect(await shutdownWrite?.value == !rejectManualWrite)
        #expect(writer.started == [25, 60])
        #expect(writer.applied == (rejectManualWrite ? [25] : [25, 60]))
        #expect(!fixture.callMode.isActive)
        try await Task.sleep(for: .milliseconds(150))
        #expect(writer.started == [25, 60])
        #expect(await shutdownWrite?.value == !rejectManualWrite)
    }

    @Test("Shutdown retains the result of an in-flight manual edit")
    func reportsInFlightManualWriteFailure() async throws {
        let writer = AlertVolumeTestWriter()
        let fixture = makeFixture(writer: writer)
        defer {
            writer.releaseWrite()
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        let quiet = try #require(fixture.monitor.flushAlertVolumeWrite {
            fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
        })
        #expect(await quiet.value)
        writer.heldPercent = 60
        writer.rejectedPercent = 60
        _ = fixture.monitor.flushAlertVolumeWrite { fixture.monitor.setAlertVolume(0.6) }
        await writer.waitForStart(60)

        let shutdownWrite = fixture.monitor.flushAlertVolumeWrite(
            preservingPendingWrite: fixture.callMode.isActive,
            producedBy: fixture.callMode.shutdown
        )
        fixture.monitor.stop()
        writer.releaseWrite()
        #expect(await fixture.monitor.drainAlertVolumeWrites())

        #expect(shutdownWrite != nil)
        #expect(await shutdownWrite?.value == false)
        #expect(writer.applied == [25])
    }

    @Test("A completed manual failure remains reportable until a later edit succeeds", arguments: [false, true])
    func retainsCompletedManualFailure(laterEditSucceeds: Bool) async throws {
        let writer = AlertVolumeTestWriter()
        let fixture = makeFixture(writer: writer)
        defer {
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        let quiet = try #require(fixture.monitor.flushAlertVolumeWrite {
            fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
        })
        #expect(await quiet.value)
        writer.rejectedPercent = 60
        let failedManualEdit = try #require(fixture.monitor.flushAlertVolumeWrite {
            fixture.monitor.setAlertVolume(0.6)
        })
        #expect(await failedManualEdit.value == false)
        if laterEditSucceeds {
            let successfulManualEdit = try #require(fixture.monitor.flushAlertVolumeWrite {
                fixture.monitor.setAlertVolume(0.8)
            })
            #expect(await successfulManualEdit.value)
        }

        let shutdownWrite = fixture.monitor.flushAlertVolumeWrite(
            preservingPendingWrite: fixture.callMode.isActive,
            producedBy: fixture.callMode.shutdown
        )
        fixture.monitor.stop()
        #expect(await fixture.monitor.drainAlertVolumeWrites())
        if laterEditSucceeds {
            #expect(shutdownWrite == nil)
            #expect(writer.applied == [25, 80])
        } else {
            #expect(shutdownWrite != nil)
            #expect(await shutdownWrite?.value == false)
            #expect(writer.applied == [25])
        }
    }

    @Test("Shutdown does not promote an unrelated pending write")
    func cancelsUnrelatedPendingWrite() async throws {
        let writer = AlertVolumeTestWriter()
        let fixture = makeFixture(writer: writer)
        defer {
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        fixture.monitor.setAlertVolume(0.6)
        let restoration = fixture.monitor.flushAlertVolumeWrite(producedBy: fixture.callMode.shutdown)
        fixture.monitor.stop()
        await fixture.monitor.drainAlertVolumeWrites()
        try await Task.sleep(for: .milliseconds(150))

        #expect(restoration == nil)
        #expect(writer.started.isEmpty)
    }

    @Test("A canceled quiet debounce cannot write after restoration and drain")
    func cancelsStaleQuietWrite() async throws {
        let writer = AlertVolumeTestWriter()
        let fixture = makeFixture(writer: writer)
        defer {
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
        let restoration = try #require(fixture.monitor.flushAlertVolumeWrite(producedBy: fixture.callMode.shutdown))
        fixture.monitor.stop()
        await fixture.monitor.drainAlertVolumeWrites()
        fixture.monitor.setAlertVolume(0.4)
        try await Task.sleep(for: .milliseconds(150))

        #expect(await restoration.value)
        #expect(writer.applied == [100])
        #expect(fixture.monitor.alertVolume == 1)
    }

    @Test("The restoration result exposes a failed write")
    func reportsRestorationFailure() async throws {
        let writer = AlertVolumeTestWriter()
        writer.rejectedPercent = 100
        let fixture = makeFixture(writer: writer)
        defer {
            fixture.settings.flushSync()
            removeSettingsDirectory(fixture.directory)
        }
        fixture.callMode.start(applicationIdentifier: "us.zoom.xos", displayName: "Zoom")
        let restoration = try #require(fixture.monitor.flushAlertVolumeWrite(producedBy: fixture.callMode.shutdown))
        fixture.monitor.stop()
        await fixture.monitor.drainAlertVolumeWrites()

        #expect(await restoration.value == false)
        #expect(writer.started == [100])
        #expect(writer.applied.isEmpty)
    }
}

@MainActor
private final class AlertVolumeProcessTestDouble {
    enum Failure: Error { case launchRejected }

    var exitStatusesOnLaunch: [Int32] = []
    var exitStatusOnTerminate: Int32?
    var exitStatusOnSecondTerminate: Int32?
    var rejectsLaunch = false
    private var terminationRequests = 0
    private(set) var events: [String] = []
    private var completion: (@MainActor @Sendable (Int32) -> Void)?
    private var terminationWaiter: CheckedContinuation<Void, Never>?

    var operations: AlertVolumeProcessRun.Operations {
        .init(
            launch: { [self] completion in
                events.append("launch")
                self.completion = completion
                if rejectsLaunch { throw Failure.launchRejected }
                for status in exitStatusesOnLaunch { completion(status) }
            },
            terminate: { [self] in
                events.append("terminate")
                terminationRequests += 1
                terminationWaiter?.resume()
                terminationWaiter = nil
                if let exitStatusOnTerminate { complete(exitStatusOnTerminate) }
                if terminationRequests == 2, let exitStatusOnSecondTerminate {
                    complete(exitStatusOnSecondTerminate)
                }
            },
            detach: { [self] in
                events.append("detach")
                completion = nil
            }
        )
    }

    func complete(_ status: Int32) {
        events.append("exit")
        completion?(status)
    }

    func waitForTerminationRequest() async {
        guard !events.contains("terminate") else { return }
        await withCheckedContinuation { terminationWaiter = $0 }
    }
}

@Suite("Bounded alert volume process")
@MainActor
struct AlertVolumeProcessRunTests {
    @Test("Successful exit completes once even when completion is delivered twice")
    func successfulExitIsOneShot() async throws {
        let process = AlertVolumeProcessTestDouble()
        process.exitStatusesOnLaunch = [0, 9]
        let run = AlertVolumeProcessRun(operations: process.operations)

        try await run.run(timeout: .milliseconds(1))
        try await Task.sleep(for: .milliseconds(10))

        #expect(!process.events.contains("terminate"))
    }

    @Test("A nonzero exit reports the subprocess status")
    func unsuccessfulExit() async {
        let process = AlertVolumeProcessTestDouble()
        process.exitStatusesOnLaunch = [7]
        let run = AlertVolumeProcessRun(operations: process.operations)

        await #expect(throws: AlertVolumeProcessRun.Failure.processFailed(7)) {
            try await run.run()
        }
        #expect(process.events == ["launch", "detach"])
    }

    @Test("A launch failure detaches the completion handler")
    func launchFailure() async {
        let process = AlertVolumeProcessTestDouble()
        process.rejectsLaunch = true
        let run = AlertVolumeProcessRun(operations: process.operations)

        await #expect(throws: AlertVolumeProcessTestDouble.Failure.launchRejected) {
            try await run.run()
        }
        #expect(process.events == ["launch", "detach"])
    }

    @Test("Timeout waits for confirmed exit before reporting failure")
    func timeoutDrainsConfirmedExit() async {
        let process = AlertVolumeProcessTestDouble()
        let run = AlertVolumeProcessRun(operations: process.operations)
        var didReturn = false
        let execution = Task { @MainActor in
            defer { didReturn = true }
            try await run.run(timeout: .milliseconds(1), terminationGrace: .seconds(10))
        }

        await process.waitForTerminationRequest()
        await Task.yield()
        #expect(!didReturn)
        process.complete(15)

        await #expect(throws: AlertVolumeProcessRun.Failure.timedOut) {
            try await execution.value
        }
        #expect(didReturn)
        #expect(process.events == ["launch", "terminate", "exit", "detach"])
    }

    @Test("A second termination request still waits for confirmed exit")
    func timeoutRetriesTermination() async {
        let process = AlertVolumeProcessTestDouble()
        process.exitStatusOnSecondTerminate = 15
        let run = AlertVolumeProcessRun(operations: process.operations)

        await #expect(throws: AlertVolumeProcessRun.Failure.timedOut) {
            try await run.run(timeout: .milliseconds(1), terminationGrace: .milliseconds(1))
        }
        #expect(process.events == ["launch", "terminate", "terminate", "exit", "detach"])
    }

    @Test("An unconfirmed exit returns bounded cleanup failure and still observes late exit")
    func missingExitCannotBlockShutdown() async {
        let process = AlertVolumeProcessTestDouble()
        let run = AlertVolumeProcessRun(operations: process.operations)

        await #expect(throws: AlertVolumeProcessRun.Failure.terminationDidNotComplete) {
            try await run.run(
                timeout: .milliseconds(1), terminationGrace: .milliseconds(1), drainTimeout: .milliseconds(1)
            )
        }
        #expect(process.events == ["launch", "terminate", "terminate"])
        process.complete(15)
        #expect(process.events == ["launch", "terminate", "terminate", "exit", "detach"])
    }

    @Test("An unresolved owned process blocks later writes until confirmed exit")
    func unresolvedProcessBlocksLaterWrites() async throws {
        let process = AlertVolumeProcessTestDouble()
        let writer = AlertVolumeProcessWriter()

        await #expect(throws: AlertVolumeProcessRun.Failure.terminationDidNotComplete) {
            try await writer.run(
                operations: process.operations, timeout: .milliseconds(1),
                terminationGrace: .milliseconds(1), drainTimeout: .milliseconds(1)
            )
        }
        #expect(!writer.isDrained)
        let nextProcess = AlertVolumeProcessTestDouble()
        nextProcess.exitStatusesOnLaunch = [0]
        await #expect(throws: AlertVolumeProcessRun.Failure.cleanupPending) {
            try await writer.run(operations: nextProcess.operations)
        }
        #expect(nextProcess.events.isEmpty)

        process.complete(15)
        #expect(writer.isDrained)
        #expect(process.events.last == "detach")
        try await writer.run(operations: nextProcess.operations)
        #expect(writer.isDrained)
        #expect(nextProcess.events == ["launch", "detach"])
    }
}
