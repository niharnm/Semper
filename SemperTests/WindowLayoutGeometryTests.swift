import ApplicationServices
import CoreGraphics
import Testing

@testable import Semper

@Suite("Window Layout geometry and eligibility")
struct WindowLayoutGeometryTests {
    let original = CGRect(x: 70, y: 100, width: 400, height: 300)
    let display = WorkspaceDisplay(
        id: "main", name: "Display", visibleFrame: CGRect(x: 0, y: 25, width: 1001, height: 675),
        fullScreenFrame: CGRect(x: 0, y: 0, width: 1001, height: 750))

    @Test("Halves partition odd usable widths without rounding beyond the display")
    func halves() throws {
        let left = try #require(WindowLayoutGeometry.target(.leftHalf, frame: original, display: display))
        let right = try #require(WindowLayoutGeometry.target(.rightHalf, frame: original, display: display))
        #expect(left == CGRect(x: 0, y: 25, width: 500.5, height: 675))
        #expect(left.maxX == right.minX)
        #expect(right.maxX == display.visibleFrame.maxX)
        #expect(left.union(right) == display.visibleFrame)
        #expect(display.visibleFrame.contains(left))
        #expect(display.visibleFrame.contains(right))
    }

    @Test("Fractional display origins remain inside usable bounds")
    func fractionalBounds() throws {
        let display = WorkspaceDisplay(
            id: "fractional", name: "Display", visibleFrame: CGRect(x: -999.75, y: 24.25, width: 999.5, height: 675.5))
        for action in [WindowLayoutAction.leftHalf, .rightHalf, .maximize, .center] {
            let target = try #require(WindowLayoutGeometry.target(action, frame: original, display: display))
            #expect(display.visibleFrame.contains(target))
        }
        let left = try #require(WindowLayoutGeometry.target(.leftHalf, frame: original, display: display))
        let right = try #require(WindowLayoutGeometry.target(.rightHalf, frame: original, display: display))
        #expect(left.maxX == right.minX)
        #expect(left.union(right) == display.visibleFrame)
    }

    @Test("Maximize uses the usable display instead of fullscreen bounds")
    func maximize() {
        #expect(WindowLayoutGeometry.target(.maximize, frame: original, display: display) == display.visibleFrame)
        #expect(WindowLayoutGeometry.target(.maximize, frame: original, display: display) != display.fullScreenFrame)
    }

    @Test("Center preserves window dimensions on a display left of the primary display")
    func center() throws {
        let display = WorkspaceDisplay(
            id: "left", name: "Display", visibleFrame: CGRect(x: -1500, y: -200, width: 1200, height: 900))
        let centered = try #require(WindowLayoutGeometry.target(.center, frame: original, display: display))
        #expect(centered.size == original.size)
        #expect(centered.midX == display.visibleFrame.midX)
        #expect(centered.midY == display.visibleFrame.midY)
    }

    @Test("Center refuses an oversized window without resizing it")
    func oversizedCenter() {
        for frame in [
            CGRect(x: 0, y: 0, width: 1002, height: 300),
            CGRect(x: 0, y: 0, width: 400, height: 676),
        ] {
            #expect(WindowLayoutGeometry.target(.center, frame: frame, display: display) == nil)
        }
        #expect(
            WindowLayoutGeometry.target(.center, frame: display.visibleFrame, display: display) == display.visibleFrame)
    }

    @Test("Invalid frames or displays never produce a movement target")
    func invalidGeometry() {
        let invalidFrames = [
            CGRect.zero, CGRect.null, CGRect.infinite,
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
            CGRect(x: 0, y: 0, width: 100_000, height: 100),
        ]
        for frame in invalidFrames {
            for action in WindowLayoutAction.allCases {
                #expect(WindowLayoutGeometry.target(action, frame: frame, display: display) == nil)
                #expect(
                    WindowLayoutGeometry.target(
                        action, frame: original,
                        display: WorkspaceDisplay(id: "invalid", name: "Display", visibleFrame: frame)) == nil)
            }
        }
    }

    @Test("Restore has no calculated target and requires the recorded previous placement")
    func restoreNeedsHistory() {
        #expect(WindowLayoutGeometry.target(.restore, frame: original, display: display) == nil)
    }

    @Test("Only recognized fullscreen button subroles establish fullscreen state")
    func fullscreenButtonState() {
        #expect(WindowLayoutWindowRules.fullscreenState(buttonSubrole: kAXFullScreenButtonSubrole) == false)
        #expect(WindowLayoutWindowRules.fullscreenState(buttonSubrole: kAXZoomButtonSubrole) == true)
        #expect(WindowLayoutWindowRules.fullscreenState(buttonSubrole: nil) == nil)
        #expect(WindowLayoutWindowRules.fullscreenState(buttonSubrole: kAXCloseButtonSubrole) == nil)
        #expect(WindowLayoutWindowRules.fullscreenState(buttonSubrole: "vendor-button") == nil)
    }

    @Test("Verified windowed full-height layouts remain eligible for center and restoration")
    func repeatedLayoutsRetainEligibility() throws {
        let display = WorkspaceDisplay(
            id: "auto-hide", name: "Display", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            fullScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        for action in [WindowLayoutAction.leftHalf, .rightHalf, .maximize] {
            let arranged = try #require(WindowLayoutGeometry.target(action, frame: original, display: display))
            let centered = try #require(WindowLayoutGeometry.target(.center, frame: arranged, display: display))
            for frame in [arranged, centered, original] {
                #expect(
                    WindowLayoutWindowRules.issue(
                        standard: true, minimized: false, frame: frame, displays: [display],
                        movable: true, resizable: true, fullscreen: false) == nil)
            }
            #expect(
                WorkspaceWindowRules.issue(
                    standard: true, minimized: false, frame: arranged, displays: [display],
                    movable: true, resizable: true) == .manualAdjustmentRequired)
        }
        #expect(display.fullScreenFrame == display.visibleFrame)
    }

    @Test("True and unknown fullscreen states are refused for ordinary and full-height frames")
    func refusedFullscreen() {
        for frame in [original, display.visibleFrame] {
            #expect(
                WindowLayoutWindowRules.issue(
                    standard: true, minimized: false, frame: frame, displays: [display],
                    movable: true, resizable: true, fullscreen: true) == .unsupported)
            #expect(
                WindowLayoutWindowRules.issue(
                    standard: true, minimized: false, frame: frame, displays: [display],
                    movable: true, resizable: true, fullscreen: nil) == .unknownState)
        }
    }

    @Test("Layout retains unsupported and minimized Workspace boundaries")
    func unsupportedStates() {
        #expect(
            WindowLayoutWindowRules.issue(
                standard: false, minimized: false, frame: original, displays: [display],
                movable: true, resizable: true, fullscreen: false) == .unsupported)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: true, frame: original, displays: [display],
                movable: true, resizable: true, fullscreen: false) == .minimized)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: false, resizable: true, fullscreen: false) == .unsupported)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: true, resizable: false, fullscreen: false) == .unsupported)
    }

    @Test("Missing role, minimized, frame, display and capability reads remain unknown")
    func unknownStates() {
        #expect(
            WindowLayoutWindowRules.issue(
                standard: nil, minimized: false, frame: original, displays: [display],
                movable: true, resizable: true, fullscreen: false) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: nil, frame: original, displays: [display],
                movable: true, resizable: true, fullscreen: false) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: nil, displays: [display],
                movable: true, resizable: true, fullscreen: false) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [],
                movable: true, resizable: true, fullscreen: false) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: nil, resizable: true, fullscreen: false) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: true, resizable: nil, fullscreen: false) == .unknownState)
    }
}
