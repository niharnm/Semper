import Foundation
import Testing
@testable import Semper

@Suite("Update manager")
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
}
