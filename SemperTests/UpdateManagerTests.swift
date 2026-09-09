import Foundation
import Sparkle
import Testing
@testable import Semper

@Suite("Update manager")
@MainActor
struct UpdateManagerTests {
    private let validPublicKey = Data(repeating: 1, count: 32).base64EncodedString()

    @Test("app bundle contains valid updater metadata")
    func bundledConfiguration() {
        let info = Bundle(for: UpdateManager.self).infoDictionary

        #expect(
            UpdaterConfiguration.isValid(
                feedURL: info?["SUFeedURL"] as? String,
                publicKey: info?["SUPublicEDKey"] as? String
            )
        )
    }

    @Test("accepts a valid HTTPS feed and Ed25519 public key")
    func validConfiguration() {
        #expect(
            UpdaterConfiguration.isValid(
                feedURL: "https://example.com/appcast.xml",
                publicKey: validPublicKey
            )
        )
    }

    @Test("rejects missing or malformed update metadata")
    func invalidConfiguration() {
        #expect(!UpdaterConfiguration.isValid(feedURL: nil, publicKey: validPublicKey))
        #expect(
            !UpdaterConfiguration.isValid(
                feedURL: "http://example.com/appcast.xml",
                publicKey: validPublicKey
            )
        )
        #expect(!UpdaterConfiguration.isValid(feedURL: "https://", publicKey: validPublicKey))
        #expect(
            !UpdaterConfiguration.isValid(
                feedURL: "https://example.com/appcast.xml",
                publicKey: "$(SPARKLE_PUBLIC_ED_KEY)"
            )
        )
        #expect(
            !UpdaterConfiguration.isValid(
                feedURL: "https://example.com/appcast.xml",
                publicKey: Data(repeating: 1, count: 31).base64EncodedString()
            )
        )
    }

    @Test("automatic updates require checks and downloads")
    func automaticUpdateState() {
        let enabled = AutomaticUpdateState(isEnabled: true)
        #expect(enabled.checksForUpdates)
        #expect(enabled.downloadsUpdates)
        #expect(enabled.isEnabled)

        #expect(
            !AutomaticUpdateState(
                checksForUpdates: true,
                downloadsUpdates: false
            ).isEnabled
        )
    }

    @Test("installation continues immediately when relaunch is not deferred")
    func installationIsNotDeferred() {
        let deferral = UpdateInstallationDeferral()
        var invocationCount = 0

        #expect(!deferral.postpone { invocationCount += 1 })
        deferral.resume()

        #expect(invocationCount == 0)
    }

    @Test("deferred installation handlers resume exactly once")
    func deferredInstallationResumesOnce() {
        let deferral = UpdateInstallationDeferral()
        deferral.shouldDefer = { true }
        var firstInvocationCount = 0
        var secondInvocationCount = 0

        #expect(deferral.postpone { firstInvocationCount += 1 })
        #expect(deferral.postpone { secondInvocationCount += 1 })
        #expect(firstInvocationCount == 0)
        #expect(secondInvocationCount == 0)

        deferral.resume()
        deferral.resume()

        #expect(firstInvocationCount == 1)
        #expect(secondInvocationCount == 1)
    }

    @Test("Sparkle delegate postpones relaunch while Away requests deferral")
    func sparkleDelegateDefersRelaunch() {
        let suiteName = "SemperUpdateManagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = UpdateManager(
            bundle: Bundle(for: UpdateManagerTestAnchor.self),
            userDefaults: defaults
        )
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        manager.shouldDeferRelaunch = { true }
        var invocationCount = 0

        let postponed = manager.updater(
            controller.updater,
            shouldPostponeRelaunchForUpdate: SUAppcastItem.empty(),
            untilInvokingBlock: { invocationCount += 1 }
        )

        #expect(postponed)
        #expect(invocationCount == 0)
        manager.resumeDeferredInstallation()
        #expect(invocationCount == 1)
    }
}

private final class UpdateManagerTestAnchor: NSObject {}
