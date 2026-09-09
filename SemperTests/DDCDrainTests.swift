import Foundation
import Synchronization
import Testing

@testable import Semper

#if !APP_STORE
    @MainActor
    @Suite("DDC work draining")
    struct DDCDrainTests {
        @Test("Sound drains its admitted probe and leaves the shared transport usable", arguments: [true, false])
        func waitsForOwnedProbe(returnsNil: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings = SettingsManager(directory: directory, managesLaunchAtLogin: false)
            defer {
                settings.flushSync()
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
            }
            let queue = DispatchQueue(label: "SemperTests.DDCDrain")
            let entered = DDCDrainAcknowledgement()
            let returned = DDCDrainAcknowledgement()
            let stopEntered = DDCDrainAcknowledgement()
            let stopped = DDCDrainAcknowledgement()
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let probeReturned = Mutex((returned: false, cancelled: false, timedOut: false))
            let gate = MutationAdmissionGate()
            let controller = DDCController(settingsManager: settings, ddcQueue: queue)
            #expect(controller.installMutationAdmission(gate))
            var publicationCount = 0
            controller.onProbeCompleted = { publicationCount += 1 }

            controller.probe(operation: { input in
                entered.signal()
                let released = release.wait(timeout: .now() + 20) == .success
                probeReturned.withLock {
                    $0 = (returned: true, cancelled: input.isCancelled, timedOut: !released)
                }
                returned.signal()
                return returnsNil ? nil : DDCProbeResult(id: input.id, publication: .unavailable, logs: [])
            })
            let didEnter = await entered.wait()
            #expect(didEnter)

            var finished = false
            let stopping = Task { @MainActor in
                stopEntered.signal()
                await controller.stopAndDrain()
                await controller.stopAndDrain()
                finished = true
                stopped.signal()
            }
            let didStartStopping = await stopEntered.wait()
            #expect(didStartStopping)
            #expect(!finished)
            #expect(!probeReturned.withLock { $0.returned })
            #expect(publicationCount == 0)

            release.signal()
            let didReturn = await returned.wait()
            #expect(didReturn, "The released probe did not return")
            let didStop = await stopped.wait()
            #expect(didStop, "Sound probe cleanup did not reach terminal completion")
            await stopping.value
            #expect(finished)
            #expect(probeReturned.withLock { $0.returned && $0.cancelled && !$0.timedOut })
            #expect(publicationCount == 0)
            #expect(gate.activeSharedPermitCount == 0)

            let reused = DDCDrainAcknowledgement()
            let displayOperation = Task { @MainActor in
                defer { reused.signal() }
                return try await controller.performSerialized { context in
                    try context.claimMutation()
                    return 42
                }
            }
            let didReuse = await reused.wait()
            #expect(didReuse, "Stopping Sound must leave the Displays transport usable")
            #expect(try await displayOperation.value == 42)
        }
    }

    private nonisolated struct DDCDrainAcknowledgement: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }

        func signal() {
            continuation.yield(())
            continuation.finish()
        }

        func wait() async -> Bool {
            let timeout = DispatchWorkItem { continuation.finish() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel() }
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
    }
#endif
