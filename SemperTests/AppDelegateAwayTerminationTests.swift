import AppKit
import CoreServices
import Testing

@testable import Semper

@Suite("App delegate Away termination", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AppDelegateAwayTerminationTests {
    @Test("Guarded Quit authenticates before any cleanup or failure decision")
    func guardedQuitWaitsForSuccessfulAuthentication() async throws {
        try await withDelegate { delegate, probe in
            let away = try #require(probe.away)
            for _ in 0..<2 {
                #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            }
            #expect(away.quitRequestCount == 2)
            #expect(probe.terminationRequests == 0)
            #expect(probe.drainCount == 0)
            #expect(probe.decisions.isEmpty)
            #expect(probe.replies.isEmpty)

            delegate.permitTerminationAfterAwayAuthentication()
            #expect(probe.terminationRequests == 1)
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            try await waitForEvent(probe.drainEvents)
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            #expect(probe.drainCount == 1)
            #expect(away.quitRequestCount == 2)
            #expect(probe.replies.isEmpty)
            probe.release()
            await delegate.waitForTerminationDrain()

            #expect(probe.replies == [true])
            #expect(probe.decisions.isEmpty)
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        }
    }

    @Test("An authenticated permit is consumed even when no shell needs draining")
    func authenticatedPermitIsSingleUse() {
        let away = RecordingAwayTerminationHandler()
        var requests = 0
        let delegate = AppDelegate(
            terminateApplication: { requests += 1 }, isSystemTerminationRequest: { false }, currentAway: { away })
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        delegate.permitTerminationAfterAwayAuthentication()
        #expect(requests == 1)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(away.quitRequestCount == 2)
    }

    @Test("System termination bypasses authentication only for that request")
    func systemTerminationRequestIsCorrelated() {
        let probe = TerminationProbe()
        probe.isSystemRequest = true
        let delegate = AppDelegate(
            terminateApplication: {}, isSystemTerminationRequest: { probe.isSystemRequest },
            currentAway: { probe.away })
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        probe.isSystemRequest = false
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(probe.away?.quitRequestCount == 1)
    }

    @Test("Only logout, shutdown, restart, and quit-all reasons are system termination")
    func systemTerminationReasons() {
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
            #expect(AppDelegate.isSystemTerminationReason(reason))
        }
        #expect(!AppDelegate.isSystemTerminationReason(nil))
        #expect(!AppDelegate.isSystemTerminationReason(OSType(kAEQuitApplication)))
    }

    @Test("System termination still waits for the complete shell drain")
    func systemTerminationStillDrains() async throws {
        try await withDelegate { delegate, probe in
            probe.isSystemRequest = true
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            try await waitForEvent(probe.drainEvents)
            #expect(probe.away?.quitRequestCount == 0)
            #expect(probe.replies.isEmpty)
            probe.release()
            await delegate.waitForTerminationDrain()
            #expect(probe.replies == [true])
            #expect(probe.drainCount == 1)
        }
    }

    @Test("Keep Open clears authorization and permits a deliberate cleanup retry", arguments: [false, true])
    func keepOpenRetriesCleanup(systemRequest: Bool) async throws {
        try await withDelegate { delegate, probe in
            probe.failures = ["A retained resource still needs cleanup."]
            probe.isSystemRequest = systemRequest
            if !systemRequest { delegate.permitTerminationAfterAwayAuthentication() }
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            try await waitForEvent(probe.drainEvents)
            #expect(probe.decisions.isEmpty)
            let requests = probe.terminationRequests
            delegate.permitTerminationAfterAwayAuthentication()
            #expect(probe.terminationRequests == requests)
            probe.release()
            await delegate.waitForTerminationDrain()
            #expect(probe.replies == [false])
            #expect(probe.decisions == [probe.failures])

            probe.isSystemRequest = false
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            #expect(probe.drainCount == 1)
            probe.failures = []
            delegate.permitTerminationAfterAwayAuthentication()
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            await delegate.waitForTerminationDrain()
            #expect(probe.drainCount == 2)
            #expect(probe.replies == [false, true])
            #expect(probe.decisions.count == 1)
        }
    }

    @Test("Explicit Quit after cleanup failure replies only after the drain and decision")
    func quitAfterCleanupFailure() async throws {
        try await withDelegate { delegate, probe in
            probe.failures = ["Unfinished cleanup"]
            probe.shouldQuitAfterFailure = true
            delegate.permitTerminationAfterAwayAuthentication()
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            try await waitForEvent(probe.drainEvents)
            #expect(probe.replies.isEmpty)
            #expect(probe.decisions.isEmpty)
            probe.release()
            await delegate.waitForTerminationDrain()
            #expect(probe.decisions == [["Unfinished cleanup"]])
            #expect(probe.replies == [true])
        }
    }

    @Test("An authenticated permit cannot authorize a replacement Away coordinator")
    func replacementInvalidatesAuthenticatedPermit() async throws {
        try await withDelegate { delegate, probe in
            let first = try #require(probe.away)
            delegate.permitTerminationAfterAwayAuthentication()
            let replacement = RecordingAwayTerminationHandler()
            probe.away = replacement
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            #expect(first.quitRequestCount == 0)
            #expect(replacement.quitRequestCount == 1)
            #expect(probe.drainCount == 0)
            #expect(probe.replies.isEmpty)
        }
    }

    @Test("No Away instance is created or authorized by passive termination inspection")
    func absentAwayRemainsAbsent() async throws {
        try await withDelegate { delegate, probe in
            probe.away = nil
            delegate.permitTerminationAfterAwayAuthentication()
            #expect(probe.terminationRequests == 0)
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            try await waitForEvent(probe.drainEvents)
            #expect(probe.away == nil)
            probe.release()
            await delegate.waitForTerminationDrain()
            #expect(probe.replies == [true])
        }
    }

    @Test("Termination event waits preserve arrivals before registration")
    func bufferedTerminationEvent() async throws {
        let (events, continuation) = AsyncStream.makeStream(of: Void.self)
        continuation.yield(())
        continuation.finish()
        try await waitForEvent(events)
    }

    @Test("Cancellation releases an event waiter before late cleanup starts", arguments: [false, true])
    func cancellationReleasesEventWait(waitUntilStarted: Bool) async throws {
        let probe = TerminationProbe()
        let (started, continuation) = AsyncStream.makeStream(of: Void.self)
        let waiter = Task {
            continuation.yield(())
            continuation.finish()
            try await waitForEvent(probe.drainEvents)
        }
        if waitUntilStarted {
            var iterator = started.makeAsyncIterator()
            await iterator.next()
        }
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("The cancelled event wait returned successfully")
        } catch is CancellationError {}

        probe.release()
        #expect(await probe.drain().isEmpty)
        #expect(probe.drainCount == 1)
    }

    private func withDelegate(
        _ body: (AppDelegate, TerminationProbe) async throws -> Void
    ) async throws {
        let probe = TerminationProbe()
        let delegate = AppDelegate(
            terminateApplication: { probe.terminationRequests += 1 },
            isSystemTerminationRequest: { probe.isSystemRequest },
            currentAway: { probe.away }, terminationDrain: { await probe.drain() },
            confirmIncompleteCleanup: { failures in
                probe.decisions.append(failures)
                return probe.shouldQuitAfterFailure
            },
            replyToTerminationRequest: { _, result in probe.replies.append(result) })
        do { try await body(delegate, probe) } catch {
            probe.release()
            await delegate.waitForTerminationDrain()
            throw error
        }
        probe.release()
        await delegate.waitForTerminationDrain()
    }

    private func waitForEvent(_ events: AsyncStream<Void>) async throws {
        var iterator = events.makeAsyncIterator()
        let event: Void? = await iterator.next()
        try Task.checkCancellation()
        try #require(event != nil)
    }
}

@MainActor
private final class RecordingAwayTerminationHandler: AwayTerminationHandling {
    var isGuarding = true
    private(set) var quitRequestCount = 0
    func requestQuit() { quitRequestCount += 1 }
}

@MainActor
private final class TerminationProbe {
    var away: RecordingAwayTerminationHandler? = RecordingAwayTerminationHandler()
    var isSystemRequest = false
    var failures: [String] = []
    var shouldQuitAfterFailure = false
    var terminationRequests = 0
    var decisions: [[String]] = []
    var replies: [Bool] = []
    private(set) var drainCount = 0
    let drainEvents: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init() {
        (drainEvents, signal) = AsyncStream.makeStream()
    }

    func drain() async -> [String] {
        drainCount += 1
        signal.yield(())
        if !isReleased { await withCheckedContinuation { continuation = $0 } }
        return failures
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
