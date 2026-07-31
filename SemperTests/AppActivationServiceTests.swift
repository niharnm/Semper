import Testing
@testable import Semper

@Suite("App activation resolution")
struct AppActivationServiceTests {

    @Test("Exact PID wins over another app with the same bundle ID")
    func exactPIDWins() {
        let candidates = [
            RunningAppIdentity(pid: 10, bundleID: "com.example.Player"),
            RunningAppIdentity(pid: 20, bundleID: "com.example.Player"),
        ]

        let result = AppActivationService.preferredIdentity(
            pid: 20,
            bundleID: "com.example.Player",
            candidates: candidates
        )

        #expect(result == candidates[1])
    }

    @Test("Bundle ID finds the owning app when the audio PID is a helper")
    func bundleFallback() {
        let owner = RunningAppIdentity(pid: 10, bundleID: "com.example.Player")

        let result = AppActivationService.preferredIdentity(
            pid: 99,
            bundleID: "com.example.Player",
            candidates: [owner]
        )

        #expect(result == owner)
    }

    @Test("Iconless headless process remains unresolved")
    func headlessProcess() {
        let result = AppActivationService.preferredIdentity(
            pid: 99,
            bundleID: nil,
            candidates: [RunningAppIdentity(pid: 10, bundleID: "com.example.Player")]
        )

        #expect(result == nil)
    }
}
