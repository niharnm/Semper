import Foundation
import Testing
@testable import Semper

@Suite("Away appearance and accessibility")
struct AwayAppearanceTests {
    @Test("Required privacy and exit copy remains exact")
    func requiredCopy() {
        #expect(
            AwayModeCopy.disclosure
                == "Away Mode covers every display with a privacy curtain. It is not the macOS Lock Screen and does not protect your account. It is not an OS security boundary. Force Quit, Semper failure, restart, administrator or Accessibility control, remote access, authorized capture software, and display-change timing can expose the desktop."
        )
        #expect(AwayModeCopy.exitPrompt == "Authenticate to exit Away Mode.")
    }

    @Test("All approved themes have distinct labels and non lock symbols")
    func themeCatalog() {
        #expect(AwayModeTheme.allCases.map(\.title) == [
            "Still Gradient",
            "Aurora",
            "Quiet Orbits",
            "Custom Photo",
        ])
        #expect(Set(AwayModeTheme.allCases.map(\.systemImage)).count == 4)
        #expect(AwayModeTheme.allCases.allSatisfy { !$0.systemImage.contains("lock") })
    }

    @Test("Accent placement motion and dim choices match settings")
    func settingsChoices() {
        #expect(AwayModeAccent.allCases.map(\.title) == ["Blue", "Violet", "Teal", "Amber"])
        #expect(AwayWidgetPlacement.allCases.map(\.title) == [
            "Top Left",
            "Center",
            "Bottom Left",
            "Bottom Right",
        ])
        #expect(AwayMotionLevel.allCases.map(\.title) == ["Off", "Subtle", "Standard"])
        #expect(AwayDimDelay.allCases.map(\.title) == [
            "Never",
            "1 Minute",
            "5 Minutes",
            "15 Minutes",
        ])
    }

    @Test("PIN setup accepts matching four digit values only")
    func pinSetupDraft() {
        var draft = AwayPINSetupDraft()
        draft.setPIN("1a2-345")
        draft.setConfirmation("1234")
        #expect(draft.pin == "1234")
        #expect(draft.confirmation == "1234")
        #expect(draft.isValid)

        draft.setConfirmation("123")
        #expect(!draft.isValid)
    }

    @Test("Ambient updates never exceed twenty frames each second")
    func frameRateCap() {
        #expect(AwayCurtainPresentation.maximumFramesPerSecond == 20)
        #expect(AwayCurtainPresentation.animationInterval == 0.05)
    }

    @Test("Ambient motion stops for every required pause state")
    func ambientMotionPauseStates() {
        #expect(!AwayCurtainPresentation.shouldAnimate(
            motionLevel: .off,
            isDimmed: false,
            powerAllowsMotion: true,
            reduceMotion: false
        ))
        #expect(!AwayCurtainPresentation.shouldAnimate(
            motionLevel: .standard,
            isDimmed: true,
            powerAllowsMotion: true,
            reduceMotion: false
        ))
        #expect(!AwayCurtainPresentation.shouldAnimate(
            motionLevel: .standard,
            isDimmed: false,
            powerAllowsMotion: false,
            reduceMotion: false
        ))
        #expect(!AwayCurtainPresentation.shouldAnimate(
            motionLevel: .standard,
            isDimmed: false,
            powerAllowsMotion: true,
            reduceMotion: true
        ))
        #expect(AwayCurtainPresentation.shouldAnimate(
            motionLevel: .subtle,
            isDimmed: false,
            powerAllowsMotion: true,
            reduceMotion: false
        ))
    }

    @Test("Only the primary curtain exposes content")
    func primaryCurtainContent() {
        #expect(AwayCurtainPresentation.showsPrimaryContent(isPrimary: true))
        #expect(!AwayCurtainPresentation.showsPrimaryContent(isPrimary: false))
    }

    @Test("Blackout reveals authentication and degraded recovery")
    func blackedOutRecoveryContent() {
        #expect(AwayCurtainPresentation.shouldRevealRecoveryContent(
            isBlackedOut: true,
            state: .authenticating(attemptID: UUID())
        ))
        #expect(AwayCurtainPresentation.shouldRevealRecoveryContent(
            isBlackedOut: true,
            state: .degraded(message: "Input filtering stopped")
        ))
        #expect(!AwayCurtainPresentation.shouldRevealRecoveryContent(
            isBlackedOut: true,
            state: .guarded
        ))
        #expect(!AwayCurtainPresentation.shouldRevealRecoveryContent(
            isBlackedOut: false,
            state: .degraded(message: "Input filtering stopped")
        ))
    }

    @Test("Accessibility contrast settings use solid panels and full strength text")
    func accessibleContrastPresentation() {
        #expect(!AwayCurtainPresentation.usesSolidPanelFill(
            reduceTransparency: false,
            increasedContrast: false
        ))
        #expect(AwayCurtainPresentation.usesSolidPanelFill(
            reduceTransparency: true,
            increasedContrast: false
        ))
        #expect(AwayCurtainPresentation.usesSolidPanelFill(
            reduceTransparency: false,
            increasedContrast: true
        ))
        #expect(
            AwayCurtainPresentation.readableTextOpacity(
                defaultOpacity: 0.72,
                increasedContrast: false
            ) == 0.72
        )
        #expect(
            AwayCurtainPresentation.readableTextOpacity(
                defaultOpacity: 0.72,
                increasedContrast: true
            ) == 1
        )
    }

    @Test("Primary timeline runs only while display visuals are active")
    func primaryTimelineActivity() {
        #expect(AwayCurtainPresentation.shouldRunPrimaryTimeline(
            displaysAreActive: true,
            isBlackedOut: false
        ))
        #expect(!AwayCurtainPresentation.shouldRunPrimaryTimeline(
            displaysAreActive: false,
            isBlackedOut: false
        ))
        #expect(!AwayCurtainPresentation.shouldRunPrimaryTimeline(
            displaysAreActive: true,
            isBlackedOut: true
        ))
    }

    @Test("Awake request wording states requests and sleep risk")
    func awakeRequestWording() {
        #expect(AwayCurtainPresentation.awakeStateText(
            allowsAwakeAssertions: true,
            keepsDisplayAwake: false,
            warning: nil
        ) == "macOS awake request active")
        #expect(AwayCurtainPresentation.awakeStateText(
            allowsAwakeAssertions: true,
            keepsDisplayAwake: true,
            warning: nil
        ) == "macOS awake and display requests active")
        #expect(AwayCurtainPresentation.awakeStateText(
            allowsAwakeAssertions: false,
            keepsDisplayAwake: false,
            warning: nil
        ) == "No macOS awake request. macOS may sleep.")
    }
}
