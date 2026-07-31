// SemperTests/AppearancePreferenceCodableTests.swift
// Tests for AppearancePreference Codable conformance and AppSettings round-trip.

import Testing
import Foundation
@testable import Semper

@Suite("AppearancePreference — Codable round-trip")
struct AppearancePreferenceCodableTests {

    @Test("All cases round-trip through JSON as their raw String value")
    func roundTripAllCases() throws {
        for preference in AppearancePreference.allCases {
            let data = try JSONEncoder().encode(preference)
            let decoded = try JSONDecoder().decode(AppearancePreference.self, from: data)
            #expect(decoded == preference)
        }
    }

    @Test("system encodes as \"system\"")
    func systemRawEncoding() throws {
        let data = try JSONEncoder().encode(AppearancePreference.system)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"system\"")
    }

    @Test("light encodes as \"light\"")
    func lightRawEncoding() throws {
        let data = try JSONEncoder().encode(AppearancePreference.light)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"light\"")
    }

    @Test("dark encodes as \"dark\"")
    func darkRawEncoding() throws {
        let data = try JSONEncoder().encode(AppearancePreference.dark)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"dark\"")
    }

    @Test("AppearancePreference.allCases has exactly 3 entries")
    func allCasesCount() {
        #expect(AppearancePreference.allCases.count == 3)
    }

    @Test("id property matches rawValue")
    func idMatchesRawValue() {
        for preference in AppearancePreference.allCases {
            #expect(preference.id == preference.rawValue)
        }
    }

    @Test("AppSettings.appearance defaults to .system")
    func appSettingsAppearanceDefault() {
        let settings = AppSettings()
        #expect(settings.appearance == .system)
    }

    @Test("AppSettings with appearance=.light round-trips through JSON")
    @MainActor
    func appSettingsAppearanceLightRoundTrip() throws {
        var settings = AppSettings()
        settings.appearance = .light
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.appearance == .light)
    }

    @Test("AppSettings with appearance=.dark round-trips through JSON")
    @MainActor
    func appSettingsAppearanceDarkRoundTrip() throws {
        var settings = AppSettings()
        settings.appearance = .dark
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.appearance == .dark)
    }

    @Test("Decoding AppSettings without appearance key produces .system default")
    @MainActor
    func missingAppearanceProducesSystemDefault() throws {
        // Minimal JSON missing the new appearance key.
        // decodeIfPresent must fall back to .system.
        let json = """
        {
          "launchAtLogin": false,
          "menuBarIconStyle": "Default",
          "defaultNewAppVolume": 1.0,
          "lockInputDevice": true,
          "showDeviceDisconnectAlerts": true,
          "hudStyle": "tahoe",
          "mediaKeyControlEnabled": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.appearance == .system)
    }

    @Test("SettingsManager.Settings round-trip preserves appearance")
    @MainActor
    func settingsManagerAppearanceRoundTrip() throws {
        var settings = SettingsManager.Settings()
        settings.appSettings.appearance = .light
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appSettings.appearance == .light)
    }
}
