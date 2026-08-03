import Foundation
import Testing
@testable import Semper

@MainActor
private final class CallModeTestIO {
    var inputUID: String? = "built-in-input"
    var claimedUIDs: [String] = []
    var releaseCount = 0
    var alertVolume: Float = 0.8
    var alertWrites: [Float] = []

    func claim(_ uid: String) -> Bool {
        claimedUIDs.append(uid)
        return true
    }

    func release() {
        releaseCount += 1
    }

    func writeAlertVolume(_ volume: Float) {
        alertVolume = volume
        alertWrites.append(volume)
    }
}

@Suite("Call Mode coordinator")
@MainActor
struct CallModeCoordinatorTests {
    private let zoom = CallModeAppActivity(
        identifier: "us.zoom.xos",
        displayName: "Zoom",
        isUsingInput: true
    )
    private let music = CallModeAppActivity(
        identifier: "com.example.music",
        displayName: "Music",
        isUsingInput: false
    )

    private func makeSubject(
        settings: SettingsManager,
        io: CallModeTestIO,
        overlayStore: AudioModeOverlayStore = AudioModeOverlayStore(),
        activityStore: AudioActivityStore = AudioActivityStore(),
        endDelay: TimeInterval = 2
    ) -> (CallModeCoordinator, AudioModeOverlayStore, AudioActivityStore) {
        let coordinator = CallModeCoordinator(
            settings: settings,
            overlayStore: overlayStore,
            activityStore: activityStore,
            currentInputDeviceUID: { io.inputUID },
            claimInputDevice: { io.claim($0) },
            releaseInputDevice: { io.release() },
            readAlertVolume: { io.alertVolume },
            writeAlertVolume: { io.writeAlertVolume($0) },
            endDelay: endDelay,
            now: { Date(timeIntervalSince1970: 100) }
        )
        return (coordinator, overlayStore, activityStore)
    }

    private func makeSettings() -> (SettingsManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperCallModeTests-\(UUID().uuidString)", isDirectory: true)
        return (SettingsManager(directory: directory), directory)
    }

    @Test("Only exact verified applications prompt while using input")
    func promptUsesExactIdentifiersAndInputState() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, _, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([
            CallModeAppActivity(
                identifier: "com.example.zoom",
                displayName: "Zoom Copy",
                isUsingInput: true
            ),
            CallModeAppActivity(
                identifier: "us.zoom.xos",
                displayName: "Zoom",
                isUsingInput: false
            ),
        ])
        #expect(coordinator.pendingPrompt == nil)

        coordinator.handleActivities([zoom])
        #expect(coordinator.pendingPrompt == CallModePrompt(
            applicationIdentifier: "us.zoom.xos",
            displayName: "Zoom"
        ))
    }

    @Test("Start once lowers other apps and owns the current input")
    func startOnce() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, overlays, activities) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom, music])
        coordinator.respond(.startOnce)

        #expect(coordinator.activeSession?.applicationIdentifier == "us.zoom.xos")
        #expect(coordinator.activeSession?.startedAt == Date(timeIntervalSince1970: 100))
        #expect(overlays.effectiveGain(for: "us.zoom.xos") == 1)
        #expect(overlays.effectiveGain(for: "com.example.music") == 0.25)
        #expect(io.claimedUIDs == ["built-in-input"])
        #expect(activities.visibleActivity?.presentation.actionTitle == "End")
    }

    @Test("New applications receive the active 25 percent overlay")
    func updatesOverlaysDuringSession() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, overlays, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom, music])
        coordinator.respond(.startOnce)
        coordinator.handleActivities([
            zoom,
            CallModeAppActivity(
                identifier: "com.example.video",
                displayName: "Video",
                isUsingInput: false
            ),
        ])

        #expect(overlays.effectiveGain(for: "com.example.music") == 1)
        #expect(overlays.effectiveGain(for: "com.example.video") == 0.25)
    }

    @Test("Not Now suppresses another prompt until input stops")
    func notNowSuppressesOccurrence() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, _, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom])
        coordinator.respond(.notNow)
        coordinator.handleActivities([zoom])
        #expect(coordinator.pendingPrompt == nil)

        coordinator.handleActivities([
            CallModeAppActivity(identifier: zoom.identifier, displayName: zoom.displayName, isUsingInput: false)
        ])
        coordinator.handleActivities([zoom])
        #expect(coordinator.pendingPrompt?.applicationIdentifier == zoom.identifier)
    }

    @Test("Always is remembered and starts the next occurrence")
    func alwaysPersists() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, _, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom])
        coordinator.respond(.always)
        #expect(settings.callModePreference(for: zoom.identifier) == .always)
        coordinator.end()
        coordinator.handleActivities([])
        coordinator.handleActivities([zoom])

        #expect(coordinator.isActive)
        #expect(coordinator.pendingPrompt == nil)
    }

    @Test("Never is remembered and does not prompt again")
    func neverPersists() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, _, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom])
        coordinator.respond(.never)
        coordinator.handleActivities([])
        coordinator.handleActivities([zoom])

        #expect(settings.callModePreference(for: zoom.identifier) == .never)
        #expect(coordinator.pendingPrompt == nil)
        #expect(!coordinator.isActive)
    }

    @Test("Call Mode ends automatically when input use stops")
    func automaticEnd() async {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, overlays, _) = makeSubject(
            settings: settings,
            io: io,
            endDelay: 0
        )

        coordinator.handleActivities([zoom, music])
        coordinator.respond(.startOnce)
        coordinator.handleActivities([music])
        await Task.yield()
        await Task.yield()

        #expect(!coordinator.isActive)
        #expect(overlays.effectiveGain(for: music.identifier) == 1)
        #expect(io.releaseCount == 1)
    }

    @Test("Quiet alerts restore only the value Call Mode applied")
    func quietAlertsRestoreOwnedValue() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.appSettings.callModeQuietAlerts = true
        let io = CallModeTestIO()
        let (coordinator, _, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom])
        coordinator.respond(.startOnce)
        #expect(io.alertWrites == [0.25])
        coordinator.setQuietAlertsEnabled(true)
        coordinator.end()

        #expect(io.alertWrites == [0.25, 0.8])
    }

    @Test("An unavailable input cannot be claimed for Call Mode")
    func unavailableInputClaimFails() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        io.inputUID = nil
        let (coordinator, _, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom])
        coordinator.respond(.startOnce)

        #expect(coordinator.activeSession?.inputDeviceUID == nil)
        #expect(io.claimedUIDs.isEmpty)
    }

    @Test("A user alert-volume change is preserved when Call Mode ends")
    func quietAlertsPreserveUserChange() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.appSettings.callModeQuietAlerts = true
        let io = CallModeTestIO()
        let (coordinator, _, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom])
        coordinator.respond(.startOnce)
        io.alertVolume = 0.5
        coordinator.end()

        #expect(io.alertWrites == [0.25])
        #expect(io.alertVolume == 0.5)
    }

    @Test("Disabling Call Mode clears prompts, sessions, and overlays")
    func disableClearsState() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = CallModeTestIO()
        let (coordinator, overlays, _) = makeSubject(settings: settings, io: io)

        coordinator.handleActivities([zoom, music])
        coordinator.respond(.startOnce)
        settings.appSettings.callModeEnabled = false
        coordinator.setEnabled(false)

        #expect(coordinator.pendingPrompt == nil)
        #expect(!coordinator.isActive)
        #expect(overlays.effectiveGain(for: music.identifier) == 1)
        #expect(io.releaseCount == 1)
    }

    @Test("Current and classic Teams identifiers are verified exactly")
    func teamsIdentifiers() {
        #expect(VerifiedCallApplication.matching("com.microsoft.teams2")?.displayName == "Microsoft Teams")
        #expect(VerifiedCallApplication.matching("com.microsoft.teams")?.displayName == "Microsoft Teams Classic")
        #expect(VerifiedCallApplication.matching("com.microsoft.teams.helper") == nil)
    }
}
