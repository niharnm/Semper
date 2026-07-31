// SemperTests/SettingsManagerAppSettingsBindingTests.swift
import Foundation
import Testing
@testable import Semper

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {
    private func makeManager() -> SettingsManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsManager(
            directory: directory,
            managesLaunchAtLogin: false
        )
    }

    @Test("Direct assignment to appSettings persists the new value")
    func directAssignmentPersists() async {
        let manager = makeManager()
        var newSettings = manager.appSettings
        newSettings.defaultNewAppVolume = 0.42
        newSettings.lockInputDevice = true

        manager.appSettings = newSettings

        #expect(manager.appSettings.defaultNewAppVolume == 0.42)
        #expect(manager.appSettings.lockInputDevice == true)
    }

    @Test("Direct assignment persists launch-at-login preference")
    func directAssignmentPersistsLaunchAtLogin() async {
        let manager = makeManager()
        var newSettings = manager.appSettings
        let original = newSettings.launchAtLogin
        newSettings.launchAtLogin = !original

        manager.appSettings = newSettings

        #expect(manager.appSettings.launchAtLogin == !original)
    }

    @Test("Direct assignment is equivalent to updateAppSettings for the same input")
    func directAssignmentEquivalentToUpdate() async {
        let managerA = makeManager()
        let managerB = makeManager()

        var modified = managerA.appSettings
        modified.defaultNewAppVolume = 0.7
        modified.mediaKeyControlEnabled = true
        modified.showDeviceDisconnectAlerts = false

        managerA.appSettings = modified
        managerB.updateAppSettings(modified)

        #expect(managerA.appSettings == managerB.appSettings)
    }
}
