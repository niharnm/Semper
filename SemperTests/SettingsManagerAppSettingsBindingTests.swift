// SemperTests/SettingsManagerAppSettingsBindingTests.swift
import Foundation
import Testing
@testable import Semper

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeManager(directory: URL? = nil) -> SettingsManager {
        return SettingsManager(
            directory: directory ?? makeDirectory(),
            managesLaunchAtLogin: false
        )
    }

    @Test("A fresh install enables launch at login")
    func freshInstallEnablesLaunchAtLogin() {
        let manager = makeManager()

        #expect(manager.appSettings.launchAtLogin)
    }

    @Test("A saved launch-at-login choice is preserved")
    func savedLaunchAtLoginChoiceIsPreserved() {
        let directory = makeDirectory()
        let manager = makeManager(directory: directory)
        var settings = manager.appSettings
        settings.launchAtLogin = false
        manager.appSettings = settings
        manager.flushSync()

        let reloaded = makeManager(directory: directory)

        #expect(!reloaded.appSettings.launchAtLogin)
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
