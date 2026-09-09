// SemperTests/DDCProbeTests.swift

import AudioToolbox
import CoreFoundation
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import Semper

@Suite("DDC probe actor boundary")
@MainActor
struct DDCProbeTests {
    @Test("A newer request cancels and rejects the previous request")
    func requestStateRejectsStaleResults() {
        var state = DDCProbeRequestState()
        let first = state.begin()
        let second = state.begin()
        let acceptedFirst = state.accept(DDCProbeTestValues.result(for: first))
        let acceptedSecond = state.accept(DDCProbeTestValues.result(for: second))

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(!acceptedFirst)
        #expect(acceptedSecond)

        let third = state.begin()
        state.cancel()
        let acceptedThird = state.accept(DDCProbeTestValues.result(for: third))

        #expect(third.isCancelled)
        #expect(!acceptedThird)
    }

    @Test("Runner executes on its DDC queue and completes on the main actor")
    func runnerUsesExplicitExecutionDomains() async {
        let queue = DispatchQueue(label: "com.semper.tests.ddc-probe")
        let input = DDCProbeInput(id: 41)

        let completedID: UInt64? = await withCheckedContinuation { continuation in
            DDCProbeRunner.submit(
                on: queue,
                input: input,
                operation: { input in
                    dispatchPrecondition(condition: .onQueue(queue))
                    return DDCProbeTestValues.result(for: input)
                },
                completion: { result in
                    MainActor.preconditionIsolated()
                    continuation.resume(returning: result?.id)
                }
            )
        }

        #expect(completedID == input.id)
    }

    @Test("Runner skips work cancelled before execution")
    func runnerSkipsPreCancelledWork() {
        let input = DDCProbeInput(id: 1)
        let operationCalls = Mutex(0)
        input.cancel()

        let result = DDCProbeRunner.execute(input: input) { input in
            operationCalls.withLock { $0 += 1 }
            return DDCProbeTestValues.result(for: input)
        }

        #expect(result == nil)
        #expect(operationCalls.withLock { $0 } == 0)
    }

    @Test("Runner drops a result cancelled during execution")
    func runnerDropsResultCancelledDuringWork() {
        let input = DDCProbeInput(id: 2)
        let operationCalls = Mutex(0)

        let result = DDCProbeRunner.execute(input: input) { input in
            operationCalls.withLock { $0 += 1 }
            input.cancel()
            return DDCProbeTestValues.result(for: input)
        }

        #expect(result == nil)
        #expect(input.isCancelled)
        #expect(operationCalls.withLock { $0 } == 1)
    }

    @Test("Runner reports terminal completion when an operation returns nil")
    func runnerReportsNilTerminalCompletion() async throws {
        let queue = DispatchQueue(label: "com.semper.tests.ddc-probe-nil")
        let input = DDCProbeInput(id: 3)
        let completionResult = Mutex<Bool?>(nil)
        let completed = DDCBoundedTestSignal()

        DDCProbeRunner.submit(
            on: queue,
            input: input,
            operation: { _ in nil },
            completion: { result in
                completionResult.withLock { $0 = result == nil }
                completed.signal()
            }
        )

        try #require(await completed.wait())
        #expect(completionResult.withLock { $0 } == true)
    }

    @Test("Serialized work cancelled while queued never starts")
    func serializedWorkSkipsCancelledCallerBeforeQueueEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCQueueTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = DispatchQueue(label: "com.semper.tests.ddc-serialized-cancellation")
        let releaseBlocker = DispatchSemaphore(value: 0)
        await withCheckedContinuation { blockerStarted in
            queue.async {
                blockerStarted.resume()
                releaseBlocker.wait()
            }
        }
        defer { releaseBlocker.signal() }

        let operationCalls = Mutex(0)
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: queue
        )
        var caller: Task<Void, Error>?

        await withCheckedContinuation { callerStarted in
            caller = Task { @MainActor in
                callerStarted.resume()
                try await controller.performSerialized {
                    operationCalls.withLock { $0 += 1 }
                }
            }
        }

        let callerTask = try #require(caller)
        callerTask.cancel()
        releaseBlocker.signal()

        do {
            try await callerTask.value
            Issue.record("Cancelled serialized work returned success")
        } catch is CancellationError {
        } catch {
            Issue.record("Cancelled serialized work returned \(error)")
        }

        #expect(operationCalls.withLock { $0 } == 0)
    }

    @Test("Serialized mutation cancelled before its claim does not run")
    func serializedMutationSkipsCancellationBeforeClaim() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCClaimTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = DispatchQueue(label: "com.semper.tests.ddc-mutation-cancellation")
        let releasePrewrite = DispatchSemaphore(value: 0)
        defer { releasePrewrite.signal() }
        let writeCalls = Mutex(0)
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: queue
        )
        var caller: Task<Void, Error>?

        await withCheckedContinuation { prewriteReached in
            caller = Task { @MainActor in
                try await controller.performSerialized { context in
                    prewriteReached.resume()
                    releasePrewrite.wait()
                    try context.claimMutation()
                    writeCalls.withLock { $0 += 1 }
                }
            }
        }

        let callerTask = try #require(caller)
        callerTask.cancel()
        releasePrewrite.signal()

        do {
            try await callerTask.value
            Issue.record("Cancelled serialized mutation returned success")
        } catch is CancellationError {
        } catch {
            Issue.record("Cancelled serialized mutation returned \(error)")
        }

        #expect(writeCalls.withLock { $0 } == 0)
    }

    @Test("Serialized mutation claimed before cancellation completes once")
    func serializedMutationCompletesAfterClaimWins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCClaimTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = DispatchQueue(label: "com.semper.tests.ddc-mutation-claim")
        let releaseWrite = DispatchSemaphore(value: 0)
        defer { releaseWrite.signal() }
        let writeCalls = Mutex(0)
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: queue
        )
        var caller: Task<Int, Error>?

        await withCheckedContinuation { mutationClaimed in
            caller = Task { @MainActor in
                try await controller.performSerialized { context in
                    try context.claimMutation()
                    mutationClaimed.resume()
                    releaseWrite.wait()
                    writeCalls.withLock { $0 += 1 }
                    return 73
                }
            }
        }

        let callerTask = try #require(caller)
        callerTask.cancel()
        releaseWrite.signal()

        #expect(try await callerTask.value == 73)
        #expect(writeCalls.withLock { $0 } == 1)
    }

    @Test("A delayed volume write keeps admission until its cancelled item finishes")
    func delayedVolumeWriteDrainsBeforeReleasingAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCDrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scheduler = DeferredDDCWriteScheduler()
        let writeCalls = Mutex(0)
        let gate = MutationAdmissionGate()
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: DispatchQueue(label: "com.semper.tests.ddc-delayed-drain"),
            writeScheduler: scheduler.schedule,
            volumeWrite: { _, _ in writeCalls.withLock { $0 += 1 } }
        )
        let installed = controller.installMutationAdmission(gate)
        let accepted = controller.setVolume(for: 61, to: 72)

        #expect(installed)
        #expect(accepted)
        await scheduler.waitUntilScheduled()
        controller.stop()

        let drainStarted = DDCTestSignal()
        let drainCompleted = Mutex(false)
        let drainTask = Task { @MainActor in
            drainStarted.signal()
            await controller.stopAndDrain()
            drainCompleted.withLock { $0 = true }
        }
        await drainStarted.wait()

        #expect(!drainCompleted.withLock { $0 })
        #expect(gate.activeSharedPermitCount == 1)
        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.manual])) {
            try gate.acquire(owner: .awayMode, mode: .exclusive)
        }
        #expect(writeCalls.withLock { $0 } == 0)

        scheduler.submit()
        await drainTask.value

        #expect(drainCompleted.withLock { $0 })
        #expect(writeCalls.withLock { $0 } == 0)
        #expect(gate.activeSharedPermitCount == 0)
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)
        let released = gate.release(exclusive)
        #expect(released)
    }

    @Test("A queued volume write drains before Away gains exclusive admission")
    func queuedVolumeWriteDrainsBeforeAwayAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCDrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = DispatchQueue(label: "com.semper.tests.ddc-queued-drain")
        let blockerStarted = DDCTestSignal()
        let releaseBlocker = DispatchSemaphore(value: 0)
        defer { releaseBlocker.signal() }
        queue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        await blockerStarted.wait()

        let writeCalls = Mutex(0)
        let gate = MutationAdmissionGate()
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: queue,
            writeScheduler: { queue, item in queue.async(execute: item) },
            volumeWrite: { _, _ in writeCalls.withLock { $0 += 1 } }
        )
        let installed = controller.installMutationAdmission(gate)
        let accepted = controller.setVolume(for: 62, to: 73)

        #expect(installed)
        #expect(accepted)
        controller.stop()

        let drainStarted = DDCTestSignal()
        let drainCompleted = Mutex(false)
        let drainTask = Task { @MainActor in
            drainStarted.signal()
            await controller.stopAndDrain()
            drainCompleted.withLock { $0 = true }
        }
        await drainStarted.wait()

        #expect(!drainCompleted.withLock { $0 })
        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.manual])) {
            try gate.acquire(owner: .awayMode, mode: .exclusive)
        }
        #expect(writeCalls.withLock { $0 } == 0)

        releaseBlocker.signal()
        await drainTask.value

        #expect(drainCompleted.withLock { $0 })
        #expect(writeCalls.withLock { $0 } == 0)
        #expect(controller.getVolume(for: 62) == nil)
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)
        let released = gate.release(exclusive)
        #expect(released)
    }

    @Test("Cancellation after a volume mutation claim waits for its actual result")
    func claimedVolumeWriteCompletesBeforeDrainReturns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCDrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writeStarted = DDCTestSignal()
        let releaseWrite = DispatchSemaphore(value: 0)
        defer { releaseWrite.signal() }
        let writeCalls = Mutex(0)
        let gate = MutationAdmissionGate()
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: DispatchQueue(label: "com.semper.tests.ddc-native-drain"),
            writeScheduler: { queue, item in queue.async(execute: item) },
            volumeWrite: { _, _ in
                writeCalls.withLock { $0 += 1 }
                writeStarted.signal()
                releaseWrite.wait()
            }
        )
        let installed = controller.installMutationAdmission(gate)
        let accepted = controller.setVolume(for: 63, to: 74)

        #expect(installed)
        #expect(accepted)
        await writeStarted.wait()
        controller.stop()

        let drainStarted = DDCTestSignal()
        let drainCompleted = Mutex(false)
        let drainTask = Task { @MainActor in
            drainStarted.signal()
            await controller.stopAndDrain()
            drainCompleted.withLock { $0 = true }
        }
        await drainStarted.wait()

        #expect(!drainCompleted.withLock { $0 })
        #expect(writeCalls.withLock { $0 } == 1)
        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.manual])) {
            try gate.acquire(owner: .awayMode, mode: .exclusive)
        }

        releaseWrite.signal()
        await drainTask.value

        #expect(drainCompleted.withLock { $0 })
        #expect(writeCalls.withLock { $0 } == 1)
        #expect(controller.getConfirmedVolume(for: 63) == 74)
        #expect(controller.getVolume(for: 63) == 74)
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)
        let released = gate.release(exclusive)
        #expect(released)
    }

    @Test("Exclusive admission rejects volume and mute changes without side effects")
    func exclusiveAdmissionRejectsAudioStateChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCAdmissionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settingsManager = SettingsManager(directory: directory)
        let scheduleCalls = Mutex(0)
        let writeCalls = Mutex(0)
        let gate = MutationAdmissionGate()
        let controller = DDCController(
            settingsManager: settingsManager,
            writeScheduler: { _, _ in scheduleCalls.withLock { $0 += 1 } },
            volumeWrite: { _, _ in writeCalls.withLock { $0 += 1 } }
        )
        let deviceID: AudioDeviceID = 64
        let uid = "exclusive-admission-display"
        controller.applyProbePublication(.matched(
            services: [deviceID: DDCService(service: kCFBooleanTrue)],
            deviceUIDs: [deviceID: uid],
            readVolumes: [deviceID: 65]
        ))
        let installed = controller.installMutationAdmission(gate)
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)

        let volumeAccepted = controller.setVolume(for: deviceID, to: 20)
        let muteAccepted = controller.mute(for: deviceID)

        #expect(installed)
        #expect(!volumeAccepted)
        #expect(!muteAccepted)
        #expect(controller.getVolume(for: deviceID) == 65)
        #expect(!controller.isMuted(for: deviceID))
        #expect(settingsManager.getDDCVolume(for: uid) == nil)
        #expect(settingsManager.getDDCSavedVolume(for: uid) == nil)

        settingsManager.setDDCMuteState(for: uid, to: true)
        settingsManager.setDDCSavedVolume(for: uid, to: 71)
        let unmuteAccepted = controller.unmute(for: deviceID)

        #expect(!unmuteAccepted)
        #expect(controller.getVolume(for: deviceID) == 65)
        #expect(controller.isMuted(for: deviceID))
        #expect(settingsManager.getDDCSavedVolume(for: uid) == 71)
        #expect(scheduleCalls.withLock { $0 } == 0)
        #expect(writeCalls.withLock { $0 } == 0)
        #expect(gate.activeSharedPermitCount == 0)
        let released = gate.release(exclusive)
        #expect(released)
    }

    @Test("Concurrent drain callers wait for the same pending write")
    func concurrentDrainCallersWaitForPendingWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCDrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scheduler = DeferredDDCWriteScheduler()
        let writeCalls = Mutex(0)
        let gate = MutationAdmissionGate()
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: DispatchQueue(label: "com.semper.tests.ddc-concurrent-drain"),
            writeScheduler: scheduler.schedule,
            volumeWrite: { _, _ in writeCalls.withLock { $0 += 1 } }
        )
        let installed = controller.installMutationAdmission(gate)
        let accepted = controller.setVolume(for: 65, to: 75)

        #expect(installed)
        #expect(accepted)
        await scheduler.waitUntilScheduled()
        controller.stop()

        let firstStarted = DDCTestSignal()
        let secondStarted = DDCTestSignal()
        let firstCompleted = Mutex(false)
        let secondCompleted = Mutex(false)
        let firstDrain = Task { @MainActor in
            firstStarted.signal()
            await controller.stopAndDrain()
            firstCompleted.withLock { $0 = true }
        }
        await firstStarted.wait()
        let secondDrain = Task { @MainActor in
            secondStarted.signal()
            await controller.stopAndDrain()
            secondCompleted.withLock { $0 = true }
        }
        await secondStarted.wait()

        #expect(!firstCompleted.withLock { $0 })
        #expect(!secondCompleted.withLock { $0 })
        #expect(gate.activeSharedPermitCount == 1)

        scheduler.submit()
        await firstDrain.value
        await secondDrain.value

        #expect(firstCompleted.withLock { $0 })
        #expect(secondCompleted.withLock { $0 })
        #expect(writeCalls.withLock { $0 } == 0)
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)
        let released = gate.release(exclusive)
        #expect(released)
    }

    @Test("Concurrent drain callers wait for a cancelled native probe to return")
    func concurrentDrainCallersWaitForHeldProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCProbeDrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let probeStarted = DDCBoundedTestSignal()
        let probeReturned = DDCBoundedTestSignal()
        let firstDrainStarted = DDCBoundedTestSignal()
        let secondDrainStarted = DDCBoundedTestSignal()
        let firstDrainCompleted = DDCBoundedTestSignal()
        let secondDrainCompleted = DDCBoundedTestSignal()
        let firstCompleted = Mutex(false)
        let secondCompleted = Mutex(false)
        let probeObservedCancellation = Mutex(false)
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: DispatchQueue(label: "com.semper.tests.ddc-held-probe-drain")
        )

        #expect(controller.probe { input in
            probeStarted.signal()
            releaseProbe.wait()
            probeObservedCancellation.withLock { $0 = input.isCancelled }
            probeReturned.signal()
            return DDCProbeTestValues.result(for: input)
        })
        try #require(await probeStarted.wait())

        let firstDrain = Task { @MainActor in
            firstDrainStarted.signal()
            await controller.stopAndDrain()
            firstCompleted.withLock { $0 = true }
            firstDrainCompleted.signal()
        }
        try #require(await firstDrainStarted.wait())

        let secondDrain = Task { @MainActor in
            secondDrainStarted.signal()
            await controller.stopAndDrain()
            secondCompleted.withLock { $0 = true }
            secondDrainCompleted.signal()
        }
        try #require(await secondDrainStarted.wait())

        #expect(!firstCompleted.withLock { $0 })
        #expect(!secondCompleted.withLock { $0 })

        releaseProbe.signal()
        try #require(await probeReturned.wait())
        try #require(await firstDrainCompleted.wait())
        try #require(await secondDrainCompleted.wait())
        await firstDrain.value
        await secondDrain.value

        #expect(firstCompleted.withLock { $0 })
        #expect(secondCompleted.withLock { $0 })
        #expect(probeObservedCancellation.withLock { $0 })
    }

    @Test("A probe cancelled before queue entry still reaches terminal completion")
    func queuedCancelledProbeDrainsWithoutRunningOperation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCProbeDrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = DispatchQueue(label: "com.semper.tests.ddc-queued-probe-drain")
        let releaseBlocker = DispatchSemaphore(value: 0)
        defer { releaseBlocker.signal() }
        let blockerStarted = DDCBoundedTestSignal()
        queue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        try #require(await blockerStarted.wait())

        let operationCalls = Mutex(0)
        let drainStarted = DDCBoundedTestSignal()
        let drainCompleted = DDCBoundedTestSignal()
        let didDrain = Mutex(false)
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: queue
        )

        #expect(controller.probe { input in
            operationCalls.withLock { $0 += 1 }
            return DDCProbeTestValues.result(for: input)
        })
        let drainTask = Task { @MainActor in
            drainStarted.signal()
            await controller.stopAndDrain()
            didDrain.withLock { $0 = true }
            drainCompleted.signal()
        }
        try #require(await drainStarted.wait())

        #expect(!didDrain.withLock { $0 })
        #expect(operationCalls.withLock { $0 } == 0)

        releaseBlocker.signal()
        try #require(await drainCompleted.wait())
        await drainTask.value

        #expect(didDrain.withLock { $0 })
        #expect(operationCalls.withLock { $0 } == 0)
    }

    @Test("A held superseded probe remains in drain accounting")
    func heldSupersededProbeDrainsBothTerminalPaths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCProbeDrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let releaseFirstProbe = DispatchSemaphore(value: 0)
        defer { releaseFirstProbe.signal() }
        let firstProbeStarted = DDCBoundedTestSignal()
        let firstProbeReturned = DDCBoundedTestSignal()
        let drainStarted = DDCBoundedTestSignal()
        let drainCompleted = DDCBoundedTestSignal()
        let secondOperationCalls = Mutex(0)
        let didDrain = Mutex(false)
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: DispatchQueue(label: "com.semper.tests.ddc-superseded-probe-drain")
        )
        var publicationCount = 0
        controller.onProbeCompleted = {
            publicationCount += 1
        }

        #expect(controller.probe { input in
            firstProbeStarted.signal()
            releaseFirstProbe.wait()
            firstProbeReturned.signal()
            return DDCProbeTestValues.result(for: input)
        })
        try #require(await firstProbeStarted.wait())
        #expect(controller.probe { input in
            secondOperationCalls.withLock { $0 += 1 }
            return DDCProbeTestValues.result(for: input)
        })

        let drainTask = Task { @MainActor in
            drainStarted.signal()
            await controller.stopAndDrain()
            didDrain.withLock { $0 = true }
            drainCompleted.signal()
        }
        try #require(await drainStarted.wait())
        #expect(!didDrain.withLock { $0 })

        releaseFirstProbe.signal()
        try #require(await firstProbeReturned.wait())
        try #require(await drainCompleted.wait())
        await drainTask.value
        controller.onProbeCompleted = nil

        #expect(didDrain.withLock { $0 })
        #expect(secondOperationCalls.withLock { $0 } == 0)
        #expect(publicationCount == 0)
    }

    @Test("Stopped probe admission rejects late tasks and start reopens it")
    func stoppedProbeAdmissionRejectsLateTaskUntilRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCProbeAdmissionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lateTaskStarted = DDCBoundedTestSignal()
        let allowLateProbe = DDCBoundedTestSignal()
        let restartedProbeCompleted = DDCBoundedTestSignal()
        let operationCalls = Mutex(0)
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: DispatchQueue(label: "com.semper.tests.ddc-probe-admission")
        )

        let lateProbe = Task { @MainActor in
            lateTaskStarted.signal()
            guard await allowLateProbe.wait() else { return true }
            return controller.probe { input in
                operationCalls.withLock { $0 += 1 }
                return DDCProbeTestValues.result(for: input)
            }
        }
        try #require(await lateTaskStarted.wait())
        controller.stop()
        allowLateProbe.signal()

        #expect(await lateProbe.value == false)
        #expect(operationCalls.withLock { $0 } == 0)

        controller.onProbeCompleted = {
            restartedProbeCompleted.signal()
        }
        controller.start { input in
            operationCalls.withLock { $0 += 1 }
            return DDCProbeTestValues.result(for: input)
        }

        try #require(await restartedProbeCompleted.wait())
        controller.onProbeCompleted = nil
        #expect(operationCalls.withLock { $0 } == 1)
        await controller.stopAndDrain()
    }

    @Test("A superseded probe cannot publish its completed result")
    func supersededProbeDoesNotPublish() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCProbeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ddcQueue = DispatchQueue(label: "com.semper.tests.ddc-probe-delivery")
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: ddcQueue
        )
        let staleDeviceID: AudioDeviceID = 51
        let currentDeviceID: AudioDeviceID = 52
        var completionCount = 0

        let currentProbeCompleted = DDCBoundedTestSignal()
        controller.onProbeCompleted = { [weak controller] in
            completionCount += 1
            if controller?.isDDCBacked(currentDeviceID) == true {
                currentProbeCompleted.signal()
            }
        }
        controller.probe { input in
            DDCProbeTestValues.matchedResult(
                for: input,
                deviceID: staleDeviceID,
                uid: "stale-display",
                volume: 91
            )
        }
        ddcQueue.sync {}
        controller.probe { input in
            DDCProbeTestValues.matchedResult(
                for: input,
                deviceID: currentDeviceID,
                uid: "current-display",
                volume: 37
            )
        }
        try #require(await currentProbeCompleted.wait())
        controller.onProbeCompleted = nil

        #expect(completionCount == 1)
        #expect(!controller.isDDCBacked(staleDeviceID))
        #expect(controller.getVolume(for: staleDeviceID) == nil)
        #expect(controller.isDDCBacked(currentDeviceID))
        #expect(controller.getVolume(for: currentDeviceID) == 37)
        await controller.stopAndDrain()
    }

    @Test("Saved volume wins and schedules a restore")
    func savedVolumePrecedesReadVolume() {
        let first: AudioDeviceID = 11
        let second: AudioDeviceID = 22
        let third: AudioDeviceID = 33

        let plan = DDCProbeVolumePlan.make(
            deviceIDs: [first, second, third],
            readVolumes: [first: 15, second: 25],
            savedVolumes: [first: 80, third: 35]
        )

        #expect(plan.cachedVolumes == [first: 80, second: 25, third: 35])
        #expect(plan.restoreVolumes == [first: 80, third: 35])
    }

    @Test("Unavailable publication preserves UID and cached-volume state")
    func publicationPreservesExistingUnavailableSemantics() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DDCProbeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settingsManager = SettingsManager(directory: directory)
        let controller = DDCController(settingsManager: settingsManager)
        let deviceID: AudioDeviceID = 44
        let uid = "display-audio-uid"
        let service = DDCService(service: kCFBooleanTrue)
        var completionCount = 0

        settingsManager.setDDCMuteState(for: uid, to: true)
        controller.onProbeCompleted = { completionCount += 1 }
        controller.applyProbePublication(.matched(
            services: [deviceID: service],
            deviceUIDs: [deviceID: uid],
            readVolumes: [deviceID: 64]
        ))

        #expect(controller.isDDCBacked(deviceID))
        #expect(controller.getVolume(for: deviceID) == 64)
        #expect(controller.isMuted(for: deviceID))

        controller.applyProbePublication(.unavailable)

        #expect(!controller.isDDCBacked(deviceID))
        #expect(controller.getVolume(for: deviceID) == 64)
        #expect(controller.isMuted(for: deviceID))
        #expect(completionCount == 2)
    }
}

private nonisolated enum DDCProbeTestValues {
    static func result(for input: DDCProbeInput) -> DDCProbeResult {
        DDCProbeResult(id: input.id, publication: .unavailable, logs: [])
    }

    static func matchedResult(
        for input: DDCProbeInput,
        deviceID: AudioDeviceID,
        uid: String,
        volume: Int
    ) -> DDCProbeResult {
        DDCProbeResult(
            id: input.id,
            publication: .matched(
                services: [deviceID: DDCService(service: kCFBooleanTrue)],
                deviceUIDs: [deviceID: uid],
                readVolumes: [deviceID: volume]
            ),
            logs: [.info("probe \(input.id)")]
        )
    }
}

private nonisolated final class DDCTestSignal: @unchecked Sendable {
    private struct State {
        var isSignalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func signal() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            guard !state.isSignalled else { return [] }
            state.isSignalled = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                if state.isSignalled {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

private nonisolated final class DDCBoundedTestSignal: @unchecked Sendable {
    private struct State {
        var isSignalled = false
        var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }

    private let state = Mutex(State())

    func signal() {
        let continuations = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            guard !state.isSignalled else { return [] }
            state.isSignalled = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume(returning: true) }
    }

    func wait() async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isSignalled else { return true }
                state.continuations[id] = continuation
                return false
            }
            if shouldResume {
                continuation.resume(returning: true)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishWait(id, result: false)
            }
        }
    }

    private func finishWait(_ id: UUID, result: Bool) {
        let continuation = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
        continuation?.resume(returning: result)
    }
}

private nonisolated final class DeferredDDCWriteScheduler: @unchecked Sendable {
    private struct State {
        var queue: DispatchQueue?
        var item: DeferredDDCWorkItem?
    }

    private let state = Mutex(State())
    private let scheduled = DDCTestSignal()

    func schedule(on queue: DispatchQueue, item: sending DispatchWorkItem) {
        let item = DeferredDDCWorkItem(item)
        state.withLock { state in
            precondition(state.item == nil)
            state.queue = queue
            state.item = item
        }
        scheduled.signal()
    }

    func waitUntilScheduled() async {
        await scheduled.wait()
    }

    func submit() {
        let work = state.withLock { state -> (DispatchQueue, DeferredDDCWorkItem)? in
            guard let queue = state.queue, let item = state.item else { return nil }
            state.queue = nil
            state.item = nil
            return (queue, item)
        }
        guard let work else {
            preconditionFailure("No deferred DDC write was scheduled")
        }
        work.1.submit(on: work.0)
    }
}

private nonisolated final class DeferredDDCWorkItem: @unchecked Sendable {
    private let item: DispatchWorkItem

    init(_ item: sending DispatchWorkItem) {
        self.item = item
    }

    func submit(on queue: DispatchQueue) {
        queue.async(execute: item)
    }
}
