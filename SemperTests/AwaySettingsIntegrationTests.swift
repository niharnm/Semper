import Foundation
import Testing
@testable import Semper

@Suite("Away settings integration")
struct AwaySettingsIntegrationTests {
    @Test("Settings schema is version 18")
    func schemaVersion() {
        #expect(SettingsManager.Settings.currentVersion == 18)
    }

    @Test("Older settings decode with Away defaults")
    func olderSettingsUseDefaults() throws {
        let data = Data(#"{"version":17,"appSettings":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appSettings.awayModePreferences == AwayModePreferences())
    }

    @Test("Away preferences survive a settings round trip")
    func roundTrip() throws {
        var settings = SettingsManager.Settings()
        settings.appSettings.awayModePreferences.authenticationMethod = .pin
        settings.appSettings.awayModePreferences.theme = .quietOrbits
        settings.appSettings.awayModePreferences.customMessage = "Back soon"
        settings.appSettings.awayModePreferences.keepsDisplayAwake = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appSettings.awayModePreferences == settings.appSettings.awayModePreferences)
    }

    @Test("Serialized settings contain no PIN credential material")
    func noPINCredentialMaterial() throws {
        var settings = SettingsManager.Settings()
        settings.appSettings.awayModePreferences.authenticationMethod = .pin

        let encoded = try JSONEncoder().encode(settings)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains("0420"))
        #expect(!text.contains("verifier"))
        #expect(!text.contains("salt"))
        #expect(!text.contains("iterations"))
    }

    @Test("Reset errors distinguish authentication, blocked, and partial cleanup")
    func resetErrorMessages() {
        #expect(
            AwayModeDataError.authenticationFailed.message
                == "Mac authentication was canceled or failed. No data or settings were changed."
        )
        #expect(
            AwayModeDataError.mutationUnavailable.message
                == "Away Mode data cannot be reset right now. No data or settings were changed."
        )
        #expect(
            AwayModeDataError.deletionFailed(
                completed: [.pin, .unusedPhotos],
                failed: [.managedPhoto]
            ).message
                == "Reset partially finished. Completed: Away PIN data, unused Away photos. Failed: the managed Away photo. No other settings were reset."
        )
    }
}
