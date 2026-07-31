import Foundation
import Testing
@testable import Semper

@MainActor
@Suite("URLHandler")
struct URLHandlerTests {
    @Test("Update URL starts a user-requested update check")
    func updateURLStartsUpdateCheck() {
        let engine = URLHandlerEngineStub()
        var updateCheckCount = 0
        let handler = URLHandler(audioEngine: engine) {
            updateCheckCount += 1
        }

        handler.handleURL(URL(string: "semper://update")!)

        #expect(updateCheckCount == 1)
    }

    @Test("Unknown URL does not start an update check")
    func unknownURLDoesNotStartUpdateCheck() {
        let engine = URLHandlerEngineStub()
        var updateCheckCount = 0
        let handler = URLHandler(audioEngine: engine) {
            updateCheckCount += 1
        }

        handler.handleURL(URL(string: "semper://unknown")!)

        #expect(updateCheckCount == 0)
    }
}

@MainActor
private final class URLHandlerEngineStub: URLHandlerEngine {
    let settingsManager = SettingsManager(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("URLHandlerTests-\(UUID().uuidString)", isDirectory: true),
        managesLaunchAtLogin: false
    )
    var apps: [AudioApp] = []

    func setVolume(for app: AudioApp, to volume: Float) {}
    func getVolume(for app: AudioApp) -> Float { 1 }
    func setMute(for app: AudioApp, to muted: Bool) {}
    func getMute(for app: AudioApp) -> Bool { false }
    func setDevice(for app: AudioApp, deviceUID: String?) {}
    func setVolumeForInactive(identifier: String, to volume: Float) {}
    func setMuteForInactive(identifier: String, to muted: Bool) {}
    func getMuteForInactive(identifier: String) -> Bool { false }
}
