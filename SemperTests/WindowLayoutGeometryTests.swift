import AppKit
import CoreGraphics
import Testing

@testable import Semper

@Suite("Window Layout geometry and eligibility")
struct WindowLayoutGeometryTests {
    let original = CGRect(x: 70, y: 100, width: 400, height: 300)
    let display = WorkspaceDisplay(
        id: "main", name: "Display", visibleFrame: CGRect(x: 0, y: 25, width: 1001, height: 675),
        fullScreenFrame: CGRect(x: 0, y: 0, width: 1001, height: 750))

    static let placements: [WindowLayoutAction] = WindowLayoutAction.allCases.filter { $0 != .restore }
    static let fullHeightPlacements: [WindowLayoutAction] = [.leftHalf, .rightHalf, .maximize]
    static let halfHeightPlacements: [WindowLayoutAction] = [.topHalf, .bottomHalf] + WindowLayoutAction.quarters
    static let corners: [(quarter: WindowLayoutAction, vertical: WindowLayoutAction, horizontal: WindowLayoutAction)] =
        [
            (.topLeftQuarter, .topHalf, .leftHalf), (.topRightQuarter, .topHalf, .rightHalf),
            (.bottomLeftQuarter, .bottomHalf, .leftHalf), (.bottomRightQuarter, .bottomHalf, .rightHalf),
        ]

    private func target(
        _ action: WindowLayoutAction, on display: WorkspaceDisplay? = nil, frame: CGRect? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> CGRect {
        try #require(
            WindowLayoutGeometry.target(action, frame: frame ?? original, display: display ?? self.display),
            sourceLocation: sourceLocation)
    }

    private func expectTiling(
        _ tiles: [CGRect], cover bounds: CGRect, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(tiles.reduce(CGRect.null) { $0.union($1) } == bounds, sourceLocation: sourceLocation)
        for tile in tiles {
            #expect(WorkspaceGeometry.valid(tile), sourceLocation: sourceLocation)
            #expect(bounds.contains(tile), "\(tile) leaves \(bounds)", sourceLocation: sourceLocation)
        }
        for (index, tile) in tiles.enumerated() {
            for other in tiles[(index + 1)...] {
                #expect(tile.intersection(other).isEmpty, "\(tile) overlaps \(other)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("Halves partition odd usable widths without rounding beyond the display")
    func halves() throws {
        let left = try target(.leftHalf)
        let right = try target(.rightHalf)
        #expect(left == CGRect(x: 0, y: 25, width: 500.5, height: 675))
        #expect(left.maxX == right.minX)
        #expect(right.maxX == display.visibleFrame.maxX)
        #expect(left.union(right) == display.visibleFrame)
        #expect(display.visibleFrame.contains(left))
        #expect(display.visibleFrame.contains(right))
        expectTiling([left, right], cover: display.visibleFrame)
    }

    @Test("Vertical halves partition odd usable heights from the top edge without rounding")
    func verticalHalves() throws {
        let top = try target(.topHalf)
        let bottom = try target(.bottomHalf)
        #expect(top == CGRect(x: 0, y: 25, width: 1001, height: 337.5))
        #expect(bottom == CGRect(x: 0, y: 362.5, width: 1001, height: 337.5))
        #expect(top.minY == display.visibleFrame.minY)
        #expect(top.maxY == bottom.minY)
        #expect(bottom.maxY == display.visibleFrame.maxY)
        #expect(top.width == display.visibleFrame.width && bottom.width == display.visibleFrame.width)
        expectTiling([top, bottom], cover: display.visibleFrame)
    }

    @Test("Quarters tile the usable area and agree with the halves they belong to")
    func quarters() throws {
        var tiles: [CGRect] = []
        for corner in Self.corners {
            let quarter = try target(corner.quarter)
            let vertical = try target(corner.vertical)
            let horizontal = try target(corner.horizontal)
            #expect(quarter == vertical.intersection(horizontal))
            #expect(quarter.size == CGSize(width: 500.5, height: 337.5))
            tiles.append(quarter)
        }
        expectTiling(tiles, cover: display.visibleFrame)
        #expect(tiles[0].origin == display.visibleFrame.origin)
        #expect(tiles[3].maxX == display.visibleFrame.maxX && tiles[3].maxY == display.visibleFrame.maxY)
        #expect(tiles[0].union(tiles[1]) == (try target(.topHalf)))
        #expect(tiles[2].union(tiles[3]) == (try target(.bottomHalf)))
        #expect(tiles[0].union(tiles[2]) == (try target(.leftHalf)))
        #expect(tiles[1].union(tiles[3]) == (try target(.rightHalf)))
    }

    @Test("Fractional display origins remain inside usable bounds")
    func fractionalBounds() throws {
        let display = WorkspaceDisplay(
            id: "fractional", name: "Display", visibleFrame: CGRect(x: -999.75, y: 24.25, width: 999.5, height: 675.5),
            fullScreenFrame: CGRect(x: -999.75, y: 0, width: 999.5, height: 750))
        for action in Self.placements {
            let target = try target(action, on: display)
            #expect(display.visibleFrame.contains(target))
        }
        let left = try target(.leftHalf, on: display)
        let right = try target(.rightHalf, on: display)
        #expect(left.maxX == right.minX)
        #expect(left.union(right) == display.visibleFrame)
        expectTiling(
            [try target(.topHalf, on: display), try target(.bottomHalf, on: display)], cover: display.visibleFrame)
        expectTiling(try WindowLayoutAction.quarters.map { try target($0, on: display) }, cover: display.visibleFrame)
    }

    @Test("Negative-origin displays with odd sizes keep every placement inside the usable area")
    func negativeOriginOddSizes() throws {
        let display = WorkspaceDisplay(
            id: "above-left", name: "Display", visibleFrame: CGRect(x: -1601, y: -1077, width: 1601, height: 1023),
            fullScreenFrame: CGRect(x: -1601, y: -1100, width: 1601, height: 1100))
        let bounds = display.visibleFrame
        for action in Self.placements {
            let target = try target(action, on: display)
            #expect(bounds.contains(target), "\(action.title) produced \(target)")
            #expect(!WorkspaceGeometry.excludedByDisplayBounds(target, on: [display]))
        }
        #expect(try target(.topHalf, on: display) == CGRect(x: -1601, y: -1077, width: 1601, height: 511.5))
        #expect(try target(.bottomHalf, on: display) == CGRect(x: -1601, y: -565.5, width: 1601, height: 511.5))
        #expect(try target(.topLeftQuarter, on: display) == CGRect(x: -1601, y: -1077, width: 800.5, height: 511.5))
        #expect(
            try target(.bottomRightQuarter, on: display) == CGRect(x: -800.5, y: -565.5, width: 800.5, height: 511.5))
        #expect(try target(.center, on: display) == CGRect(x: -1000.5, y: -715.5, width: 400, height: 300))
        expectTiling([try target(.leftHalf, on: display), try target(.rightHalf, on: display)], cover: bounds)
        expectTiling([try target(.topHalf, on: display), try target(.bottomHalf, on: display)], cover: bounds)
        expectTiling(try WindowLayoutAction.quarters.map { try target($0, on: display) }, cover: bounds)
        for corner in Self.corners {
            #expect(
                try target(corner.quarter, on: display)
                    == (try target(corner.vertical, on: display)).intersection(
                        try target(corner.horizontal, on: display)))
        }
    }

    @Test("Usable areas that leave the reported display bounds refuse every placement")
    func usableAreaOutsideDisplay() {
        let displays = [
            WorkspaceDisplay(
                id: "shifted", name: "Display", visibleFrame: CGRect(x: -1601, y: -1077, width: 1601, height: 1023),
                fullScreenFrame: CGRect(x: -1601, y: -1000, width: 1601, height: 1000)),
            WorkspaceDisplay(
                id: "wider", name: "Display", visibleFrame: CGRect(x: 0, y: 25, width: 1002, height: 675),
                fullScreenFrame: CGRect(x: 0, y: 0, width: 1001, height: 750)),
        ]
        for display in displays {
            for action in WindowLayoutAction.allCases {
                #expect(WindowLayoutGeometry.target(action, frame: original, display: display) == nil)
            }
            #expect(
                WindowLayoutWindowRules.issue(
                    standard: true, minimized: false, frame: original, displays: [display],
                    movable: true, resizable: true) == .unknownState)
        }
    }

    @Test("Auto-hidden system bars refuse full-height targets while half-height placements stay available")
    func autoHiddenBarsKeepHalfHeightPlacements() throws {
        let autoHide = WorkspaceDisplay(
            id: "auto-hide", name: "Display", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            fullScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        for action in Self.fullHeightPlacements {
            #expect(WindowLayoutGeometry.target(action, frame: original, display: autoHide) == nil)
        }
        for action in Self.halfHeightPlacements {
            let target = try target(action, on: autoHide)
            #expect(target.height == 350)
            #expect(autoHide.visibleFrame.contains(target))
            #expect(!WorkspaceGeometry.excludedByDisplayBounds(target, on: [autoHide]))
            #expect(
                WindowLayoutWindowRules.issue(
                    standard: true, minimized: false, frame: target, displays: [autoHide],
                    movable: true, resizable: true) == nil)
        }
        let stacked = try target(.topHalf, on: autoHide).union(try target(.bottomHalf, on: autoHide))
        #expect(WorkspaceGeometry.excludedByDisplayBounds(stacked, on: [autoHide]))
    }

    @Test("Maximize uses the usable display instead of fullscreen bounds")
    func maximize() {
        #expect(WindowLayoutGeometry.target(.maximize, frame: original, display: display) == display.visibleFrame)
        #expect(WindowLayoutGeometry.target(.maximize, frame: original, display: display) != display.fullScreenFrame)
    }

    @Test("Center preserves window dimensions on a display left of the primary display")
    func center() throws {
        let display = WorkspaceDisplay(
            id: "left", name: "Display", visibleFrame: CGRect(x: -1500, y: -200, width: 1200, height: 900),
            fullScreenFrame: CGRect(x: -1500, y: -225, width: 1200, height: 1000))
        let centered = try target(.center, on: display)
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

    @Test("Existing placements keep their identifiers, titles, symbols and targets")
    func existingPlacementsPreserved() {
        let expectations: [(WindowLayoutAction, String, String, String, CGRect?)] = [
            (
                .leftHalf, "window-layout.left-half", "Left Half", "rectangle.lefthalf.filled",
                CGRect(x: 0, y: 25, width: 500.5, height: 675)
            ),
            (
                .rightHalf, "window-layout.right-half", "Right Half", "rectangle.righthalf.filled",
                CGRect(x: 500.5, y: 25, width: 500.5, height: 675)
            ),
            (
                .maximize, "window-layout.maximize", "Maximize", "arrow.up.left.and.arrow.down.right",
                display.visibleFrame
            ),
            (
                .center, "window-layout.center", "Center", "rectangle.center.inset.filled",
                CGRect(x: 300.5, y: 212.5, width: 400, height: 300)
            ),
            (.restore, "window-layout.restore", "Restore Previous Placement", "arrow.uturn.backward", nil),
        ]
        for (action, rawValue, title, symbol, target) in expectations {
            #expect(action.rawValue == rawValue)
            #expect(action.id == rawValue)
            #expect(action.title == title)
            #expect(action.symbolName == symbol)
            #expect(WindowLayoutGeometry.target(action, frame: original, display: display) == target)
        }
    }

    @Test("Placement catalog has stable unique identifiers, distinct titles and available symbols")
    func placementCatalog() {
        let actions = WindowLayoutAction.allCases
        #expect(actions.count == 11)
        #expect(Set(actions.map(\.rawValue)).count == actions.count)
        #expect(actions.allSatisfy { $0.rawValue.hasPrefix("window-layout.") })
        #expect(Set(actions.map(\.title)).count == actions.count)
        #expect(Set(actions.map(\.symbolName)).count == actions.count)
        let grouped = WindowLayoutAction.halves + WindowLayoutAction.quarters
        #expect(grouped.count == 8 && Set(grouped).count == grouped.count)
        #expect(actions.filter { !grouped.contains($0) } == [.maximize, .center, .restore])
        for action in actions {
            #expect(
                NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil,
                "\(action.symbolName) is not an available SF Symbol")
        }
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
                #expect(
                    WindowLayoutGeometry.target(
                        action, frame: original,
                        display: WorkspaceDisplay(
                            id: "invalid-full", name: "Display", visibleFrame: display.visibleFrame,
                            fullScreenFrame: frame)) == nil)
            }
        }
    }

    @Test("Restore has no calculated target and requires the recorded previous placement")
    func restoreNeedsHistory() {
        #expect(WindowLayoutGeometry.target(.restore, frame: original, display: display) == nil)
    }

    @Test("Usable-area layouts remain eligible while full-height targets are conservatively refused")
    func repeatedLayoutsRetainEligibility() throws {
        let autoHideDisplay = WorkspaceDisplay(
            id: "auto-hide", name: "Display", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            fullScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        for action in Self.placements where action != .center {
            let arranged = try target(action)
            let centered = try target(.center, frame: arranged)
            for frame in [arranged, centered, original] {
                #expect(
                    WindowLayoutWindowRules.issue(
                        standard: true, minimized: false, frame: frame, displays: [display],
                        movable: true, resizable: true) == nil)
            }
            #expect(
                WorkspaceWindowRules.issue(
                    standard: true, minimized: false, frame: arranged, displays: [display],
                    movable: true, resizable: true) == nil)
            if Self.fullHeightPlacements.contains(action) {
                #expect(WindowLayoutGeometry.target(action, frame: original, display: autoHideDisplay) == nil)
            } else {
                #expect(WindowLayoutGeometry.target(action, frame: original, display: autoHideDisplay) != nil)
            }
        }
        #expect(WindowLayoutGeometry.target(.center, frame: original, display: autoHideDisplay) != nil)
    }

    @Test("Full-height windows retain the existing conservative exclusion regardless of width")
    func refusedFullHeight() throws {
        let fullBounds = try #require(display.fullScreenFrame)
        for frame in [fullBounds, CGRect(x: 0, y: 0, width: 400, height: fullBounds.height)] {
            #expect(
                WindowLayoutWindowRules.issue(
                    standard: true, minimized: false, frame: frame, displays: [display],
                    movable: true, resizable: true) == .manualAdjustmentRequired)
        }
    }

    @Test("Layout retains unsupported and minimized Workspace boundaries")
    func unsupportedStates() {
        #expect(
            WindowLayoutWindowRules.issue(
                standard: false, minimized: false, frame: original, displays: [display],
                movable: true, resizable: true) == .unsupported)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: true, frame: original, displays: [display],
                movable: true, resizable: true) == .minimized)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: false, resizable: true) == .unsupported)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: true, resizable: false) == .unsupported)
    }

    @Test("Missing role, minimized, frame, display and capability reads remain unknown")
    func unknownStates() {
        #expect(
            WindowLayoutWindowRules.issue(
                standard: nil, minimized: false, frame: original, displays: [display],
                movable: true, resizable: true) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: nil, frame: original, displays: [display],
                movable: true, resizable: true) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: nil, displays: [display],
                movable: true, resizable: true) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [],
                movable: true, resizable: true) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: nil, resizable: true) == .unknownState)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [display],
                movable: true, resizable: nil) == .unknownState)
        let unknownDisplay = WorkspaceDisplay(id: "unknown", name: "Display", visibleFrame: display.visibleFrame)
        #expect(
            WindowLayoutWindowRules.issue(
                standard: true, minimized: false, frame: original, displays: [unknownDisplay],
                movable: true, resizable: true) == .unknownState)
        for action in WindowLayoutAction.allCases {
            #expect(WindowLayoutGeometry.target(action, frame: original, display: unknownDisplay) == nil)
        }
    }
}
