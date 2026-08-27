// SemperTests/AppRowAccessibilityTests.swift
// Pins the VoiceOver wording for the per-app volume slider and mute button.
//
// AppRowControls applies these strings at the call site, so device and input
// rows keep the shared MuteButton's generic "Mute"/"Unmute" help text. The
// assertions below guard the app-specific wording and the mute label's
// action-phrasing contract (the label names what activating the button will
// do, not the state it is currently in).

import Testing
@testable import Semper

@Suite("AppRowControls — VoiceOver wording")
struct AppRowAccessibilityTests {

    // MARK: - Volume slider

    @Test("Volume label names the app")
    func volumeLabelNamesTheApp() {
        #expect(AppRowAccessibility.volumeLabel(appName: "Music") == "Volume for Music")
        #expect(AppRowAccessibility.volumeLabel(appName: "Safari") == "Volume for Safari")
    }

    @Test("Volume label carries the control purpose, not just the app name")
    func volumeLabelStatesPurpose() {
        let label = AppRowAccessibility.volumeLabel(appName: "Music")
        #expect(label.contains("Volume"))
        #expect(label.contains("Music"))
    }

    @Test("Volume label preserves app names with spaces and punctuation")
    func volumeLabelPreservesAppName() {
        let name = "Final Cut Pro"
        #expect(AppRowAccessibility.volumeLabel(appName: name) == "Volume for \(name)")
    }

    @Test(
        "Volume value reads as a spoken percentage",
        arguments: [(0, "0 percent"), (40, "40 percent"), (100, "100 percent")]
    )
    func volumeValueSpeaksPercentage(percentage: Int, expected: String) {
        #expect(AppRowAccessibility.volumeValue(percentage: percentage) == expected)
    }

    /// The announced value must equal the number drawn by EditablePercentage,
    /// which rounds the slider position rather than truncating it.
    @Test(
        "Volume value matches the percentage rendered in the row",
        arguments: [0.0, 0.005, 0.4, 0.455, 0.999, 1.0]
    )
    func volumeValueMatchesRenderedPercentage(sliderValue: Double) {
        let rendered = Int(round(sliderValue * 100))
        #expect(
            AppRowAccessibility.volumeValue(percentage: rendered) == "\(rendered) percent"
        )
    }

    // MARK: - Mute button

    @Test("Mute label offers to mute while the app is audible")
    func muteLabelWhenUnmuted() {
        #expect(
            AppRowAccessibility.muteLabel(appName: "Music", isMuted: false) == "Mute Music"
        )
    }

    @Test("Mute label offers to unmute while the app is silenced")
    func muteLabelWhenMuted() {
        #expect(
            AppRowAccessibility.muteLabel(appName: "Music", isMuted: true) == "Unmute Music"
        )
    }

    @Test("Mute label flips with the mute state so it tracks live changes")
    func muteLabelTracksState() {
        let unmuted = AppRowAccessibility.muteLabel(appName: "Safari", isMuted: false)
        let muted = AppRowAccessibility.muteLabel(appName: "Safari", isMuted: true)
        #expect(unmuted != muted)
        #expect(unmuted.hasPrefix("Mute"))
        #expect(muted.hasPrefix("Unmute"))
    }

    @Test("Mute label always names the app so rows stay distinguishable")
    func muteLabelNamesTheApp() {
        for isMuted in [true, false] {
            #expect(
                AppRowAccessibility.muteLabel(appName: "Podcasts", isMuted: isMuted)
                    .contains("Podcasts")
            )
        }
    }

    /// Guards the regression the issue describes: a bare "Mute"/"Unmute"
    /// announcement leaves a screen-reader user without row context.
    @Test("App-row mute wording is not the shared generic help text")
    func muteLabelIsNotGeneric() {
        #expect(AppRowAccessibility.muteLabel(appName: "Music", isMuted: false) != "Mute")
        #expect(AppRowAccessibility.muteLabel(appName: "Music", isMuted: true) != "Unmute")
    }
}
