// SemperTests/MenuBarIconImageSizeTests.swift
// Size invariance for menu bar icons — the status item is variable-length,
// so icons of differing sizes resize it and shift neighboring items.

import AppKit
import Testing
@testable import Semper

@Suite("MenuBarIconImage — size invariance")
@MainActor
struct MenuBarIconImageSizeTests {

    /// Every image the coordinator can put on the status bar button.
    private var reachableImages: [MenuBarIconImage] {
        var images: [MenuBarIconImage] = [MenuBarIconState.speakerMuted.image]
        images += [VolumeBucket.zero, .low, .mid, .high].map { .systemSymbol($0.symbolName) }
        images += MenuBarIconStyle.allCases.map {
            MenuBarIconState.baseline(style: $0, volume: 0.5, muted: false).image
        }
        images += DeviceIconCatalog.categories.flatMap(\.entries).map { .systemSymbol($0.symbol) }
        // Resolver fallbacks not in the catalog (AudioDeviceID.iconSymbol / TransportType.defaultIconSymbol).
        images += [
            "macstudio.fill", "macmini.fill", "macbook", "desktopcomputer", "display",
            "appletv", "homepod", "homepodmini", "airplayaudio", "bolt.horizontal",
            "tv", "speaker.wave.2", "hifispeaker",
        ].map { .systemSymbol($0) }
        return images
    }

    @Test("every reachable icon renders at one shared size")
    func allIconsShareOneSize() throws {
        let canonical = try #require(MenuBarIconState.speakerVolume(.high).image.nsImage()).size
        for image in reachableImages {
            let rendered = try #require(image.nsImage(), "\(image) produced no NSImage")
            #expect(rendered.size == canonical, "\(image) is \(rendered.size), canonical is \(canonical)")
        }
    }

    @Test("shared size never downscales the widest speaker symbol")
    func sharedSizeCoversNaturalSymbolSize() throws {
        let shared = try #require(MenuBarIconState.speakerVolume(.high).image.nsImage()).size
        let natural = try #require(NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)).size
        #expect(shared.width >= natural.width)
        #expect(shared.height >= natural.height)
    }

    @Test("template rendering and accessibility description survive")
    func templateAndAccessibilitySurvive() throws {
        for image in [
            MenuBarIconImage.systemSymbol("speaker.fill"),
            .systemSymbol("waveform.path")
        ] {
            let rendered = try #require(image.nsImage())
            #expect(rendered.isTemplate, "\(image) lost template rendering")
            #expect(rendered.accessibilityDescription == "Semper", "\(image) lost accessibility description")
        }
    }
}
