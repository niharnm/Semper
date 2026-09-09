import Foundation
import Testing
@testable import Semper

@Suite("AwayModePreferences")
struct AwayModePreferencesTests {
    @Test("Defaults match the initial Away Mode configuration")
    func defaults() {
        let preferences = AwayModePreferences()

        #expect(preferences.authenticationMethod == .system)
        #expect(!preferences.disclosureCompleted)
        #expect(preferences.theme == .aurora)
        #expect(preferences.accent == .blue)
        #expect(preferences.customMessage.isEmpty)
        #expect(preferences.showsClock)
        #expect(preferences.showsElapsedTime)
        #expect(preferences.showsBattery)
        #expect(preferences.showsAwakeState)
        #expect(preferences.widgetPlacement == .bottomLeft)
        #expect(preferences.managedPhotoFilename == nil)
        #expect(preferences.photoFit == .fill)
        #expect(preferences.motionLevel == .subtle)
        #expect(!preferences.keepsDisplayAwake)
        #expect(preferences.dimDelay == .fiveMinutes)
        #expect(preferences.dimDelay.timeInterval == 300)
    }

    @Test("Missing keys decode to defaults")
    func missingKeys() throws {
        let decoded = try JSONDecoder().decode(AwayModePreferences.self, from: Data("{}".utf8))

        #expect(decoded == AwayModePreferences())
    }

    @Test("Invalid managed photo filenames are discarded while decoding")
    func invalidManagedPhotoFilenameIsDiscarded() throws {
        var preferences = AwayModePreferences()
        preferences.managedPhotoFilename = "../outside.jpg"

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AwayModePreferences.self, from: data)

        #expect(decoded.managedPhotoFilename == nil)
    }

    @Test("Every setting round-trips through JSON")
    func roundTrip() throws {
        let original = AwayModePreferences(
            authenticationMethod: .pin,
            disclosureCompleted: true,
            theme: .customPhoto,
            accent: .amber,
            customMessage: "Back soon",
            showsClock: false,
            showsElapsedTime: false,
            showsBattery: false,
            showsAwakeState: false,
            widgetPlacement: .topLeft,
            managedPhotoFilename: "away-photo-00000000-0000-0000-0000-000000000000.jpg",
            photoFit: .fit,
            motionLevel: .standard,
            keepsDisplayAwake: true,
            dimDelay: .fifteenMinutes
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AwayModePreferences.self, from: data)

        #expect(decoded == original)
    }

    @Test("Enum raw values remain stable")
    func stableRawValues() {
        #expect(AwayModeTheme.allCases.map(\.rawValue) == [
            "stillGradient", "aurora", "quietOrbits", "customPhoto",
        ])
        #expect(AwayModeAccent.allCases.map(\.rawValue) == ["blue", "violet", "teal", "amber"])
        #expect(AwayWidgetPlacement.allCases.map(\.rawValue) == [
            "topLeft", "center", "bottomLeft", "bottomRight",
        ])
        #expect(AwayPhotoFit.allCases.map(\.rawValue) == ["fill", "fit"])
        #expect(AwayMotionLevel.allCases.map(\.rawValue) == ["off", "subtle", "standard"])
        #expect(AwayDimDelay.allCases.map(\.rawValue) == [0, 60, 300, 900])
    }

    @Test("Custom message strips controls and limits characters")
    func messageSanitizer() {
        var preferences = AwayModePreferences(customMessage: "hello\nworld\u{0000}")
        #expect(preferences.customMessage == "helloworld")

        preferences.customMessage = String(repeating: "é", count: 141)
        #expect(preferences.customMessage.count == 140)
    }

    @Test("Decoded custom message is sanitized")
    func decodedMessageSanitizer() throws {
        let message = String(repeating: "x", count: 140) + "\nextra"
        let data = try JSONSerialization.data(withJSONObject: ["customMessage": message])
        let decoded = try JSONDecoder().decode(AwayModePreferences.self, from: data)

        #expect(decoded.customMessage.count == 140)
        #expect(!decoded.customMessage.contains("\n"))
    }
}
