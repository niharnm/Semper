import Foundation
import Testing

@testable import Semper

#if !APP_STORE
    @MainActor
    @Suite("DDC work draining")
    struct DDCDrainTests {
        @Test("Stopping waits for work already on the shared transport queue")
        func waitsForQueuedWork() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let settings = SettingsManager(directory: directory)
            defer {
                settings.flushSync()
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
            }
            let queue = DispatchQueue(label: "SemperTests.DDCDrain")
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            queue.async {
                entered.signal()
                release.wait()
            }
            let didEnter = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success)
                }
            }
            #expect(didEnter)
            let controller = DDCController(settingsManager: settings, ddcQueue: queue)
            var finished = false
            let stopping = Task {
                await controller.stopAndDrain()
                finished = true
            }
            for _ in 0..<5 { await Task.yield() }
            #expect(!finished)
            release.signal()
            await stopping.value
            #expect(finished)
            await controller.stopAndDrain()
            let queueStillAvailable = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: true) }
            }
            #expect(queueStillAvailable)
        }
    }
#endif
