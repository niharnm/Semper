import AppKit
import CoreServices
import Testing
@testable import Semper

@Suite("App delegate Away termination")
@MainActor
struct AppDelegateAwayTerminationTests {
    @Test("Guarded Quit waits for successful Away authentication")
    func guardedQuitWaitsForSuccessfulAuthentication() {
        var terminationRequestCount = 0
        let delegate = AppDelegate(terminateApplication: {
            terminationRequestCount += 1
        })
        let awayMode = RecordingAwayTerminationHandler()
        awayMode.onAuthenticatedQuit = {
            delegate.permitTerminationAfterAwayAuthentication()
        }
        delegate.awayMode = awayMode

        let guardedReply = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(guardedReply == .terminateCancel)
        #expect(awayMode.quitRequestCount == 1)
        #expect(terminationRequestCount == 0)

        let repeatedReply = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(repeatedReply == .terminateCancel)
        #expect(awayMode.quitRequestCount == 2)
        #expect(terminationRequestCount == 0)

        awayMode.succeedAuthentication()

        #expect(terminationRequestCount == 1)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(awayMode.quitRequestCount == 2)

        let laterQuit = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(laterQuit == .terminateCancel)
        #expect(awayMode.quitRequestCount == 3)
    }

    @Test("A system termination request bypasses Away authentication only for that request")
    func systemTerminationRequestIsCorrelated() {
        let request = SystemTerminationRequestProbe(value: true)
        let delegate = AppDelegate(
            terminateApplication: {},
            isSystemTerminationRequest: { request.value }
        )
        let awayMode = RecordingAwayTerminationHandler()
        delegate.awayMode = awayMode

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        request.value = false
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(awayMode.quitRequestCount == 1)
    }

    @Test("Only logout, shutdown, restart, and quit-all reasons are system termination")
    func systemTerminationReasons() {
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
            #expect(AppDelegate.isSystemTerminationReason(reason))
        }
        #expect(!AppDelegate.isSystemTerminationReason(nil))
        #expect(!AppDelegate.isSystemTerminationReason(OSType(kAEQuitApplication)))
    }

    @Test("Authenticated Quit waits for the termination drain exactly once")
    func authenticatedQuitWaitsForTerminationDrain() async {
        let drain = TerminationDrainProbe()
        var terminationRequestCount = 0
        var replyCount = 0
        let delegate = AppDelegate(
            terminateApplication: {
                terminationRequestCount += 1
            },
            terminationDrain: {
                await drain.run()
            },
            replyToTerminationRequest: { _, shouldTerminate in
                #expect(shouldTerminate)
                replyCount += 1
            }
        )
        let awayMode = RecordingAwayTerminationHandler()
        awayMode.onAuthenticatedQuit = {
            delegate.permitTerminationAfterAwayAuthentication()
        }
        delegate.awayMode = awayMode

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        awayMode.succeedAuthentication()
        #expect(terminationRequestCount == 1)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        await drain.waitUntilStarted()

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(replyCount == 0)
        drain.finish()
        await waitUntil { replyCount == 1 }

        #expect(drain.events == ["display.stop", "ddc.stop"])
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(replyCount == 1)
    }

    @Test("System termination bypasses authentication but still drains")
    func systemTerminationStillDrains() async {
        let drain = TerminationDrainProbe()
        drain.finish()
        var replyCount = 0
        let delegate = AppDelegate(
            terminateApplication: {},
            isSystemTerminationRequest: { true },
            terminationDrain: {
                await drain.run()
            },
            replyToTerminationRequest: { _, shouldTerminate in
                #expect(shouldTerminate)
                replyCount += 1
            }
        )
        let awayMode = RecordingAwayTerminationHandler()
        delegate.awayMode = awayMode

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        await waitUntil { replyCount == 1 }

        #expect(awayMode.quitRequestCount == 0)
        #expect(drain.events == ["display.stop", "ddc.stop"])
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(replyCount == 1)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the termination operation")
    }
}

@MainActor
private final class SystemTerminationRequestProbe {
    var value: Bool

    init(value: Bool) {
        self.value = value
    }
}

@MainActor
private final class RecordingAwayTerminationHandler: AwayTerminationHandling {
    var isGuarding = true
    var onAuthenticatedQuit: (() -> Void)?
    private(set) var quitRequestCount = 0

    func requestQuit() {
        quitRequestCount += 1
    }

    func succeedAuthentication() {
        onAuthenticatedQuit?()
    }
}

@MainActor
private final class TerminationDrainProbe {
    private(set) var events: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func run() async {
        events.append("display.stop")
        if !isFinished {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        events.append("ddc.stop")
    }

    func waitUntilStarted() async {
        for _ in 0..<1_000 {
            if !events.isEmpty { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the termination drain")
    }

    func finish() {
        isFinished = true
        continuation?.resume()
        continuation = nil
    }
}
