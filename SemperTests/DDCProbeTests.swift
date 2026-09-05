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

        let completedID: UInt64 = await withCheckedContinuation { continuation in
            DDCProbeRunner.submit(
                on: queue,
                input: input,
                operation: { input in
                    dispatchPrecondition(condition: .onQueue(queue))
                    return DDCProbeTestValues.result(for: input)
                },
                completion: { result in
                    MainActor.preconditionIsolated()
                    continuation.resume(returning: result.id)
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

    @Test("A superseded probe cannot publish its completed result")
    func supersededProbeDoesNotPublish() async {
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

        await withCheckedContinuation { continuation in
            controller.onProbeCompleted = { [weak controller] in
                completionCount += 1
                if controller?.isDDCBacked(currentDeviceID) == true {
                    continuation.resume()
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
        }
        controller.onProbeCompleted = nil

        #expect(completionCount == 1)
        #expect(!controller.isDDCBacked(staleDeviceID))
        #expect(controller.getVolume(for: staleDeviceID) == nil)
        #expect(controller.isDDCBacked(currentDeviceID))
        #expect(controller.getVolume(for: currentDeviceID) == 37)
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
