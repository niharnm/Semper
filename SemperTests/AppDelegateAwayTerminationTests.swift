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
