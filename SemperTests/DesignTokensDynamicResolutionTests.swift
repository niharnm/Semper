// SemperTests/DesignTokensDynamicResolutionTests.swift
// Verifies each dynamic DesignTokens.Colors token resolves to the expected
// NSColor for both `.aqua` (light) and `.darkAqua` (dark) appearances.
//
// This test catches three regressions:
//  1. A token's light or dark RGBA being changed inadvertently.
//  2. Two tokens accidentally sharing an NSColor.Name, which silently
//     merges them under NSColor's name cache.
//  3. The dynamicColor helper resolving the wrong branch for an appearance.

import Testing
import SwiftUI
import AppKit
@testable import Semper

@Suite("DesignTokens — Dynamic color resolution")
@MainActor
struct DesignTokensDynamicResolutionTests {

    // MARK: Helpers

    /// Resolves a SwiftUI Color (backed by an NSColor dynamic provider) to its
    /// concrete NSColor for the specified appearance, by entering that appearance
    /// as the drawing context.
    private func resolve(_ color: Color, appearance: NSAppearance) -> NSColor {
        var resolved: NSColor = .clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return resolved
    }

    /// Asserts a SwiftUI Color's resolved RGBA matches the expected NSColor's RGBA
    /// in the specified appearance, within a tolerance for floating-point drift.
    private func expectColor(
        _ token: Color,
        equals expected: NSColor,
        in appearance: NSAppearance,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = resolve(token, appearance: appearance)
        let actualSRGB = actual.usingColorSpace(.sRGB) ?? actual
        let expectedSRGB = expected.usingColorSpace(.sRGB) ?? expected
        let tol: CGFloat = 0.005
        #expect(
            abs(actualSRGB.redComponent - expectedSRGB.redComponent) < tol &&
            abs(actualSRGB.greenComponent - expectedSRGB.greenComponent) < tol &&
            abs(actualSRGB.blueComponent - expectedSRGB.blueComponent) < tol &&
            abs(actualSRGB.alphaComponent - expectedSRGB.alphaComponent) < tol,
            "Token in \(appearance.name.rawValue) resolved to RGBA(\(actualSRGB.redComponent), \(actualSRGB.greenComponent), \(actualSRGB.blueComponent), \(actualSRGB.alphaComponent)) but expected RGBA(\(expectedSRGB.redComponent), \(expectedSRGB.greenComponent), \(expectedSRGB.blueComponent), \(expectedSRGB.alphaComponent))",
            sourceLocation: sourceLocation
        )
    }

    private static let aqua = NSAppearance(named: .aqua)!
    private static let darkAqua = NSAppearance(named: .darkAqua)!

    // MARK: Per-token resolution

    @Test("popupOverlay resolves correctly in light and dark")
    func popupOverlay() {
        // Light bumped from 0.10 → 0.50: lifts the popup from muddy gray
        // to crisp white-tilted glass over the .popover material.
        expectColor(DesignTokens.Colors.popupOverlay,
                    equals: NSColor.white.withAlphaComponent(0.50),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.popupOverlay,
                    equals: NSColor(
                        calibratedRed: 28.0 / 255.0,
                        green: 28.0 / 255.0,
                        blue: 32.0 / 255.0,
                        alpha: 0.84
                    ),
                    in: Self.darkAqua)
    }

    @Test("recessedBackground resolves correctly in light and dark")
    func recessedBackground() {
        expectColor(DesignTokens.Colors.recessedBackground,
                    equals: NSColor.black.withAlphaComponent(0.04),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.recessedBackground,
                    equals: NSColor.black.withAlphaComponent(0.3),
                    in: Self.darkAqua)
    }

    @Test("menuBorder resolves correctly in light and dark")
    func menuBorder() {
        expectColor(DesignTokens.Colors.menuBorder,
                    equals: NSColor.black.withAlphaComponent(0.18),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.menuBorder,
                    equals: NSColor.white.withAlphaComponent(0.12),
                    in: Self.darkAqua)
    }

    @Test("menuBorderHover resolves correctly in light and dark")
    func menuBorderHover() {
        expectColor(DesignTokens.Colors.menuBorderHover,
                    equals: NSColor.black.withAlphaComponent(0.32),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.menuBorderHover,
                    equals: NSColor.white.withAlphaComponent(0.25),
                    in: Self.darkAqua)
    }

    @Test("autoEQEmptyBorder resolves correctly in light and dark")
    func autoEQEmptyBorder() {
        expectColor(DesignTokens.Colors.autoEQEmptyBorder,
                    equals: NSColor.black.withAlphaComponent(0.22),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.autoEQEmptyBorder,
                    equals: NSColor.white.withAlphaComponent(0.1),
                    in: Self.darkAqua)
    }

    @Test("autoEQEmptyIcon resolves correctly in light and dark")
    func autoEQEmptyIcon() {
        expectColor(DesignTokens.Colors.autoEQEmptyIcon,
                    equals: NSColor(white: 0.45, alpha: 1.0),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.autoEQEmptyIcon,
                    equals: NSColor(white: 0.267, alpha: 1.0),
                    in: Self.darkAqua)
    }

    @Test("autoEQToggleLabel resolves correctly in light and dark")
    func autoEQToggleLabel() {
        expectColor(DesignTokens.Colors.autoEQToggleLabel,
                    equals: NSColor.black.withAlphaComponent(0.65),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.autoEQToggleLabel,
                    equals: NSColor.white.withAlphaComponent(0.5),
                    in: Self.darkAqua)
    }

    // MARK: Shared tokens added in Task 5

    @Test("hoverSurface resolves correctly in light and dark")
    func hoverSurface() {
        // Light bumped from 0.08 → 0.115: clearly visible row hover wash
        // on the new whiter glass without competing with the selected row.
        expectColor(DesignTokens.Colors.hoverSurface,
                    equals: NSColor.black.withAlphaComponent(0.115),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.hoverSurface,
                    equals: NSColor.white.withAlphaComponent(0.07),
                    in: Self.darkAqua)
    }

    @Test("glassFill is transparent at rest in both appearances (flat-row design)")
    func glassFill() {
        expectColor(DesignTokens.Colors.glassFill, equals: NSColor.clear, in: Self.aqua)
        expectColor(DesignTokens.Colors.glassFill, equals: NSColor.clear, in: Self.darkAqua)
    }

    @Test("glassFillStrong resolves correctly in light and dark")
    func glassFillStrong() {
        expectColor(DesignTokens.Colors.glassFillStrong,
                    equals: NSColor.white.withAlphaComponent(0.85),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.glassFillStrong,
                    equals: NSColor.white.withAlphaComponent(0.1),
                    in: Self.darkAqua)
    }

    @Test("glassRowBorder is transparent at rest in both appearances (flat-row design)")
    func glassRowBorder() {
        expectColor(DesignTokens.Colors.glassRowBorder, equals: NSColor.clear, in: Self.aqua)
        expectColor(DesignTokens.Colors.glassRowBorder, equals: NSColor.clear, in: Self.darkAqua)
    }

    @Test("glassRowBorderHover resolves correctly in light and dark")
    func glassRowBorderHover() {
        expectColor(DesignTokens.Colors.glassRowBorderHover,
                    equals: NSColor.black.withAlphaComponent(0.10),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.glassRowBorderHover,
                    equals: NSColor.white.withAlphaComponent(0.15),
                    in: Self.darkAqua)
    }

    @Test("hudBorder resolves correctly in light and dark")
    func hudBorder() {
        expectColor(DesignTokens.Colors.hudBorder,
                    equals: NSColor.black.withAlphaComponent(0.15),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.hudBorder,
                    equals: NSColor.white.withAlphaComponent(0.08),
                    in: Self.darkAqua)
    }

    @Test("sectionHeaderText resolves correctly in light and dark")
    func sectionHeaderText() {
        // Light bumped from 0.55 → 0.65: stronger section anchor on
        // whiter glass without changing tracking or weight.
        expectColor(DesignTokens.Colors.sectionHeaderText,
                    equals: NSColor.black.withAlphaComponent(0.65),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.sectionHeaderText,
                    equals: NSColor.white.withAlphaComponent(0.40),
                    in: Self.darkAqua)
    }

    // MARK: Card & badge tokens (light-mode polish)

    @Test("eqCardBackground resolves correctly in light and dark")
    func eqCardBackground() {
        expectColor(DesignTokens.Colors.eqCardBackground,
                    equals: NSColor.white.withAlphaComponent(0.78),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.eqCardBackground,
                    equals: NSColor.white.withAlphaComponent(0.07),
                    in: Self.darkAqua)
    }

    @Test("eqCardBorder resolves correctly in light and dark")
    func eqCardBorder() {
        expectColor(DesignTokens.Colors.eqCardBorder,
                    equals: NSColor.black.withAlphaComponent(0.06),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.eqCardBorder,
                    equals: NSColor.white.withAlphaComponent(0.10),
                    in: Self.darkAqua)
    }

    @Test("deviceBadgeMonoFill resolves correctly in light and dark")
    func deviceBadgeMonoFill() {
        expectColor(DesignTokens.Colors.deviceBadgeMonoFill,
                    equals: NSColor.black.withAlphaComponent(0.10),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.deviceBadgeMonoFill,
                    equals: NSColor.white.withAlphaComponent(0.10),
                    in: Self.darkAqua)
    }

    @Test("deviceBadgeMonoForeground resolves correctly in light and dark")
    func deviceBadgeMonoForeground() {
        expectColor(DesignTokens.Colors.deviceBadgeMonoForeground,
                    equals: NSColor.black.withAlphaComponent(0.65),
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.deviceBadgeMonoForeground,
                    equals: NSColor.white.withAlphaComponent(0.70),
                    in: Self.darkAqua)
    }
}
