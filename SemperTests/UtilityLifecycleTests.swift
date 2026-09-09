import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Utility lifecycle")
struct UtilityLifecycleTests {
    @Test("Catalog registration and adding Shelf never start services or request permissions")
    func addingIsDormant() async throws {
        try await withLifecycle { registry, lifecycle in
            var soundStarts = 0
            var shelfStarts = 0
            try lifecycle.register(.sound, binding: .init(start: { soundStarts += 1 }, stop: { _ in }))
            try lifecycle.register(.shelf, binding: .init(start: { shelfStarts += 1 }, stop: { _ in }))
            try registry.add(.shelf)

            #expect(soundStarts == 0)
            #expect(shelfStarts == 0)
            #expect(registry.state(for: .shelf)?.runtime == .stopped)
            #expect(registry.state(for: .shelf)?.permission == .unknown)
            try await lifecycle.start(.shelf)
            #expect(shelfStarts == 1)
            #expect(soundStarts == 0)
        }
    }

    @Test("Concurrent callers share startup and do not return before ready")
    func concurrentStarts() async throws {
        try await withLifecycle { registry, lifecycle in
            let entered = LifecycleLatch()
            let release = LifecycleLatch()
            var starts = 0
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        starts += 1
                        entered.open()
                        await release.wait()
                    }, stop: { _ in }))
            let first = Task { try await lifecycle.start(.awake) }
            await entered.wait()
            let second = Task { try await lifecycle.start(.awake) }
            await advanceTasks()
            #expect(starts == 1)
            #expect(registry.state(for: .awake)?.runtime == .preparing)
            release.open()
            try await second.value
            #expect(registry.state(for: .awake)?.runtime == .ready)
            try await first.value
            try await lifecycle.start(.awake)
            #expect(starts == 1)
        }
    }

    @Test("Pause cancels a suspended start, then waits for service drain")
    func pauseDuringStartup() async throws {
        try await withLifecycle { registry, lifecycle in
            let startEntered = LifecycleLatch()
            let startRelease = LifecycleLatch()
            let stopEntered = LifecycleLatch()
            let stopRelease = LifecycleLatch()
            var stopCount = 0
            var startupCancelled = false
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        startEntered.open()
                        await startRelease.wait()
                        startupCancelled = Task.isCancelled
                    },
                    stop: { reason in
                        #expect(reason == .pause)
                        stopCount += 1
                        stopEntered.open()
                        await stopRelease.wait()
                    }))
            let startup = Task { try await lifecycle.start(.awake) }
            await startEntered.wait()
            var pauseFinished = false
            let pause = Task {
                try await lifecycle.pause(.awake)
                pauseFinished = true
            }
            await advanceTasks()
            #expect(lifecycle.stopping.contains(.awake))
            #expect(stopCount == 0)
            startRelease.open()
            await stopEntered.wait()
            #expect(startupCancelled)
            #expect(!pauseFinished)
            await #expect(throws: CancellationError.self) { try await startup.value }
            stopRelease.open()
            try await pause.value
            #expect(registry.state(for: .awake)?.runtime == .paused)
            #expect(lifecycle.stopping.isEmpty)
            #expect(stopCount == 1)
        }
    }

    @Test("Removal hides commands before drain and re-add starts a fresh service")
    func removalAndReaddition() async throws {
        try await withLifecycle { registry, lifecycle in
            let service = LifecycleServiceProbe()
            let entered = LifecycleLatch()
            let release = LifecycleLatch()
            let action = UtilityActionDescriptor(
                id: .init(rawValue: "awake.start"), module: .awake, title: "Start Awake",
                keywords: [], symbolName: "play"
            )
            try registry.register(actions: [action])
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        service.start()
                    },
                    stop: { reason in
                        entered.open()
                        await release.wait()
                        service.stop(reason)
                    }))
            try await lifecycle.start(.awake)
            let firstID = service.currentID
            let removal = Task { try await lifecycle.remove(.awake) }
            await entered.wait()
            #expect(registry.action(for: action.id) == nil)
            #expect(registry.state(for: .awake)?.runtime == .removing)
            #expect(throws: ModuleRegistryError.transitionInProgress(.awake)) { try registry.add(.awake) }
            release.open()
            try await removal.value
            #expect(service.currentID == nil)
            try registry.add(.awake)
            #expect(service.starts == 1)
            try await lifecycle.start(.awake)
            #expect(service.starts == 2)
            #expect(service.currentID != firstID)
            #expect(registry.action(for: action.id) == action)
        }
    }

    @Test("Startup failure remains in preparing until cleanup finishes and then displays its reason")
    func startupFailureWaitsForCleanup() async throws {
        try await withLifecycle { registry, lifecycle in
            let cleanupEntered = LifecycleLatch()
            let cleanupRelease = LifecycleLatch()
            var starts = 0
            var cleanups = 0
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        starts += 1
                        throw LifecycleTestError.start
                    },
                    stop: { _ in
                        cleanups += 1
                        cleanupEntered.open()
                        await cleanupRelease.wait()
                    }))
            let first = Task { try await lifecycle.start(.awake) }
            await cleanupEntered.wait()
            let second = Task { try await lifecycle.start(.awake) }
            await advanceTasks()
            #expect(starts == 1)
            #expect(cleanups == 1)
            #expect(registry.state(for: .awake)?.runtime == .preparing)
            cleanupRelease.open()
            await #expect(throws: LifecycleTestError.start) { try await first.value }
            await #expect(throws: LifecycleTestError.start) { try await second.value }
            #expect(lifecycle.failures[.awake] == "Test startup failed.")
            #expect(registry.state(for: .awake)?.runtime == .failed(reason: "Test startup failed."))
        }
    }

    @Test("Cleanup failure reports its own reason while preserving the startup error")
    func startupCleanupFailure() async throws {
        try await withLifecycle { registry, lifecycle in
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        throw LifecycleTestError.start
                    }, stop: { _ in throw LifecycleTestError.stop }))
            await #expect(throws: LifecycleTestError.start) { try await lifecycle.start(.awake) }
            #expect(lifecycle.failures[.awake] == "Startup cleanup failed: Test stop failed.")
            #expect(
                registry.state(for: .awake)?.runtime
                    == .failed(
                        reason: "Startup cleanup failed: Test stop failed."
                    ))
        }
    }

    @Test("A failed removal displays its reason and keeps actions unavailable")
    func removalFailure() async throws {
        try await withLifecycle { registry, lifecycle in
            try lifecycle.register(.awake, binding: .init(start: {}, stop: { _ in throw LifecycleTestError.stop }))
            try await lifecycle.start(.awake)
            await #expect(throws: LifecycleTestError.stop) { try await lifecycle.remove(.awake) }
            #expect(lifecycle.failures[.awake] == "Test stop failed.")
            #expect(registry.state(for: .awake)?.runtime == .failed(reason: "Test stop failed."))
            #expect(registry.state(for: .awake)?.presence == .added)
            #expect(registry.pausedModuleIDs.contains(.awake))
            #expect(lifecycle.stopping.isEmpty)
        }
    }

    @Test("A failed drain blocks restart until an explicit cleanup retry succeeds")
    func failedDrainRequiresCleanup() async throws {
        try await withLifecycle { registry, lifecycle in
            var starts = 0
            var shouldFailStop = true
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        starts += 1
                    },
                    stop: { _ in
                        if shouldFailStop { throw LifecycleTestError.stop }
                    }))
            try await lifecycle.start(.awake)
            await #expect(throws: LifecycleTestError.stop) { try await lifecycle.pause(.awake) }
            try registry.resume(.awake)
            await #expect(throws: UtilityLifecycleError.self) { try await lifecycle.start(.awake) }
            #expect(starts == 1)
            #expect(registry.state(for: .awake)?.runtime == .failed(reason: "Test stop failed."))
            shouldFailStop = false
            try await lifecycle.pause(.awake)
            try registry.resume(.awake)
            try await lifecycle.start(.awake)
            #expect(starts == 2)
            #expect(lifecycle.failures[.awake] == nil)
            #expect(registry.state(for: .awake)?.runtime == .ready)
        }
    }

    @Test("Pause waits for failed-start cleanup without replacing the startup error")
    func pauseDuringStartupCleanup() async throws {
        try await withLifecycle { registry, lifecycle in
            let cleanupEntered = LifecycleLatch()
            let cleanupRelease = LifecycleLatch()
            var events: [String] = []
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        throw LifecycleTestError.start
                    },
                    stop: { _ in
                        if events.isEmpty {
                            events.append("startup cleanup began")
                            cleanupEntered.open()
                            await cleanupRelease.wait()
                            events.append("startup cleanup finished")
                        } else {
                            events.append("pause cleanup")
                        }
                    }))
            let startup = Task { try await lifecycle.start(.awake) }
            await cleanupEntered.wait()
            let pause = Task { try await lifecycle.pause(.awake) }
            await advanceTasks()
            #expect(events == ["startup cleanup began"])
            cleanupRelease.open()
            await #expect(throws: LifecycleTestError.start) { try await startup.value }
            try await pause.value
            #expect(events == ["startup cleanup began", "startup cleanup finished", "pause cleanup"])
            #expect(registry.state(for: .awake)?.runtime == .paused)
            #expect(lifecycle.failures[.awake] == nil)
        }
    }

    @Test(
        "Shutdown waits for in-flight pause or removal before terminal cleanup",
        arguments: [UtilityStopReason.pause, .removal])
    func shutdownDuringStop(reason: UtilityStopReason) async throws {
        try await withLifecycle { _, lifecycle in
            let stopEntered = LifecycleLatch()
            let stopRelease = LifecycleLatch()
            var events: [String] = []
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {},
                    stop: { currentReason in
                        if currentReason == .termination {
                            events.append("termination")
                        } else {
                            events.append("drain began")
                            stopEntered.open()
                            await stopRelease.wait()
                            events.append("drain finished")
                        }
                    }))
            try await lifecycle.start(.awake)
            let stop = Task {
                if reason == .pause { try await lifecycle.pause(.awake) } else { try await lifecycle.remove(.awake) }
            }
            await stopEntered.wait()
            var shutdownFinished = false
            let shutdown = Task {
                await lifecycle.shutdown()
                shutdownFinished = true
            }
            await advanceTasks()
            #expect(lifecycle.isShuttingDown)
            #expect(!shutdownFinished)
            #expect(events == ["drain began"])
            stopRelease.open()
            try await stop.value
            await shutdown.value
            #expect(events == ["drain began", "drain finished", "termination"])
        }
    }

    @Test("Shutdown waits for startup-failure cleanup already in progress")
    func shutdownDuringStartupCleanup() async throws {
        try await withLifecycle { _, lifecycle in
            let cleanupEntered = LifecycleLatch()
            let cleanupRelease = LifecycleLatch()
            var events: [String] = []
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        throw LifecycleTestError.start
                    },
                    stop: { reason in
                        if reason == .termination {
                            events.append("termination")
                        } else {
                            events.append("cleanup began")
                            cleanupEntered.open()
                            await cleanupRelease.wait()
                            events.append("cleanup finished")
                        }
                    }))
            let startup = Task { try await lifecycle.start(.awake) }
            await cleanupEntered.wait()
            let shutdown = Task { await lifecycle.shutdown() }
            await advanceTasks()
            #expect(events == ["cleanup began"])
            cleanupRelease.open()
            await #expect(throws: LifecycleTestError.start) { try await startup.value }
            await shutdown.value
            #expect(events == ["cleanup began", "cleanup finished", "termination"])
        }
    }

    @Test("Shutdown cancels and awaits startup before terminal cleanup")
    func shutdownDuringStartup() async throws {
        try await withLifecycle { _, lifecycle in
            let entered = LifecycleLatch()
            let release = LifecycleLatch()
            var events: [String] = []
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        entered.open()
                        await release.wait()
                        #expect(Task.isCancelled)
                        events.append("start finished")
                    },
                    stop: { reason in
                        #expect(reason == .termination)
                        events.append("termination")
                    }))
            let startup = Task { try await lifecycle.start(.awake) }
            await entered.wait()
            let shutdown = Task { await lifecycle.shutdown() }
            await advanceTasks()
            #expect(events.isEmpty)
            release.open()
            await #expect(throws: CancellationError.self) { try await startup.value }
            await shutdown.value
            #expect(events == ["start finished", "termination"])
        }
    }

    @Test("Shutdown restores composed sessions first and shares one cleanup across callers")
    func shutdownOrderAndIdempotence() async throws {
        try await withLifecycle { registry, lifecycle in
            var order: [UtilityModuleID] = []
            for id in UtilityModuleID.allCases {
                try registry.add(id)
                try lifecycle.register(
                    id,
                    binding: .init(
                        start: {},
                        stop: { reason in
                            #expect(reason == .termination)
                            order.append(id)
                        }))
            }
            let first = Task { await lifecycle.shutdown() }
            let second = Task { await lifecycle.shutdown() }
            await first.value
            await second.value
            await lifecycle.shutdown()
            #expect(order == [.presentation, .away, .scenes, .workspace, .shelf, .storage, .displays, .sound, .awake])
            await #expect(throws: UtilityLifecycleError.self) { try await lifecycle.start(.awake) }
            await #expect(throws: UtilityLifecycleError.self) { try await lifecycle.pause(.awake) }
            await #expect(throws: UtilityLifecycleError.self) { try await lifecycle.remove(.awake) }
        }
    }

    @Test("A shutdown failure is reported while remaining modules still drain")
    func shutdownFailureContinuesCleanup() async throws {
        try await withLifecycle { _, lifecycle in
            var awakeStopped = false
            try lifecycle.register(
                .presentation,
                binding: .init(
                    start: {},
                    stop: { _ in
                        throw LifecycleTestError.stop
                    }))
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {},
                    stop: { _ in
                        awakeStopped = true
                    }))
            await lifecycle.shutdown()
            #expect(awakeStopped)
            #expect(lifecycle.failures[.presentation] == "Test stop failed.")
        }
    }

    @Test("Successful shutdown clears earlier startup and cleanup failures", arguments: [false, true])
    func shutdownClearsResolvedFailures(cleanupFails: Bool) async throws {
        try await withLifecycle { _, lifecycle in
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {
                        throw LifecycleTestError.start
                    },
                    stop: { reason in
                        if cleanupFails, reason == .pause { throw LifecycleTestError.stop }
                    }))
            await #expect(throws: LifecycleTestError.start) { try await lifecycle.start(.awake) }
            #expect(lifecycle.failures[.awake] != nil)
            await lifecycle.shutdown()
            #expect(lifecycle.failures.isEmpty)
            #expect(lifecycle.isShuttingDown)
            await #expect(throws: UtilityLifecycleError.self) { try await lifecycle.start(.awake) }
        }
    }

    @Test("Failed shutdown retries only unfinished services and shares the retry between callers")
    func shutdownRetry() async throws {
        try await withLifecycle { _, lifecycle in
            let retryEntered = LifecycleLatch()
            let retryRelease = LifecycleLatch()
            var presentationStops = 0
            var awakeStops = 0
            try lifecycle.register(
                .presentation,
                binding: .init(
                    start: {},
                    stop: { _ in
                        presentationStops += 1
                        if presentationStops == 1 { throw LifecycleTestError.stop }
                        retryEntered.open()
                        await retryRelease.wait()
                    }))
            try lifecycle.register(
                .awake,
                binding: .init(
                    start: {},
                    stop: { _ in
                        awakeStops += 1
                    }))
            await lifecycle.shutdown()
            #expect(lifecycle.failures[.presentation] == "Test stop failed.")
            #expect(presentationStops == 1)
            #expect(awakeStops == 1)
            await #expect(throws: UtilityLifecycleError.self) { try await lifecycle.start(.awake) }
            let firstRetry = Task { await lifecycle.shutdown() }
            await advanceTasks()
            #expect(presentationStops == 2)
            #expect(retryEntered.isOpen)
            let secondRetry = Task { await lifecycle.shutdown() }
            await advanceTasks()
            #expect(presentationStops == 2)
            #expect(awakeStops == 1)
            retryRelease.open()
            await firstRetry.value
            await secondRetry.value
            #expect(lifecycle.failures.isEmpty)
            #expect(lifecycle.isShuttingDown)
            await lifecycle.shutdown()
            #expect(presentationStops == 2)
            #expect(awakeStops == 1)
        }
    }

    private func withLifecycle(_ body: (ModuleRegistry, UtilityLifecycle) async throws -> Void) async throws {
        let suite = "UtilityLifecycleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = try ModuleRegistry(defaults: defaults)
        try await body(registry, UtilityLifecycle(registry: registry))
    }

    private func advanceTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class LifecycleLatch {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class LifecycleServiceProbe {
    private(set) var starts = 0
    private(set) var currentID: UUID?

    func start() {
        if currentID == nil { currentID = UUID() }
        starts += 1
    }

    func stop(_ reason: UtilityStopReason) {
        if reason != .pause { currentID = nil }
    }
}

private enum LifecycleTestError: LocalizedError, Equatable {
    case start, stop

    var errorDescription: String? {
        switch self {
        case .start: "Test startup failed."
        case .stop: "Test stop failed."
        }
    }
}
