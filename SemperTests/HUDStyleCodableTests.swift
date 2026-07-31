// SemperTests/HUDStyleCodableTests.swift
// Tests for HUDStyle Codable conformance and AppSettings round-trip.

import Testing
import Foundation
@testable import Semper

@Suite("HUDStyle — Codable round-trip")
struct HUDStyleCodableTests {

    @Test("All cases round-trip through JSON as their raw String value")
    func roundTripAllCases() throws {
        for style in HUDStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(HUDStyle.self, from: data)
            #expect(decoded == style)
        }
    }

    @Test("tahoe encodes as \"tahoe\"")
    func tahoeRawEncoding() throws {
        let data = try JSONEncoder().encode(HUDStyle.tahoe)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"tahoe\"")
    }

    @Test("classic encodes as \"classic\"")
    func classicRawEncoding() throws {
        let data = try JSONEncoder().encode(HUDStyle.classic)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"classic\"")
    }

    @Test("HUDStyle.allCases has exactly 2 entries")
    func allCasesCount() {
        #expect(HUDStyle.allCases.count == 2)
    }

    @Test("id property matches rawValue")
    func idMatchesRawValue() {
        for style in HUDStyle.allCases {
            #expect(style.id == style.rawValue)
        }
    }

    @Test("AppSettings.hudStyle defaults to .tahoe")
    func appSettingsHUDStyleDefault() {
        let settings = AppSettings()
        #expect(settings.hudStyle == .tahoe)
    }

    @Test("AppSettings.mediaKeyControlEnabled defaults to true")
    func appSettingsMediaKeyControlDefault() {
        let settings = AppSettings()
        #expect(settings.mediaKeyControlEnabled == true)
    }

    @Test("AppSettings with hudStyle=classic round-trips through JSON")
    @MainActor
    func appSettingsHUDStyleRoundTrip() throws {
        var settings = AppSettings()
        settings.hudStyle = .classic
        settings.mediaKeyControlEnabled = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.hudStyle == .classic)
        #expect(decoded.mediaKeyControlEnabled == false)
    }

    @Test("Decoding AppSettings without hudStyle key produces .tahoe default")
    @MainActor
    func missingHUDStyleProducesDefault() throws {
        // Minimal JSON: only the required keys from pre-Phase2 AppSettings.
        // decodeIfPresent must fall back to .tahoe.
        let json = """
        {
          "launchAtLogin": false,
          "menuBarIconStyle": "Default",
          "defaultNewAppVolume": 1.0,
          "lockInputDevice": true,
          "showDeviceDisconnectAlerts": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.hudStyle == .tahoe)
        #expect(decoded.mediaKeyControlEnabled == true)
    }

    @Test("SettingsManager.Settings round-trip preserves hudStyle")
    @MainActor
    func settingsManagerHUDStyleRoundTrip() throws {
        var settings = SettingsManager.Settings()
        settings.appSettings.hudStyle = .classic
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appSettings.hudStyle == .classic)
    }
}
