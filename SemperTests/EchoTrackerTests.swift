import Testing
@testable import Semper

@Suite("Echo tracker cancellation")
@MainActor
struct EchoTrackerTests {
    @Test("Cancel removes only the matching echo token")
    func exactCancellation() {
        let tracker = EchoTracker(label: "Test")
        let first = tracker.increment("output")
        _ = tracker.increment("output")

        tracker.cancel("output", token: first)

        #expect(tracker.consume("output"))
        #expect(!tracker.consume("output"))
    }
}
