// SemperTests/MenuBarPopupSizeTests.swift
import Testing
import Foundation
@testable import Semper

@Suite("MenuBarPopupSize — Codable round-trip")
struct MenuBarPopupSizeCodableTests {

    @Test("All cases round-trip through JSON as their raw String value")
    func roundTripAllCases() throws {
        for size in MenuBarPopupSize.allCases {
            let data = try JSONEncoder().encode(size)
            let decoded = try JSONDecoder().decode(MenuBarPopupSize.self, from: data)
            #expect(decoded == size)
        }
    }

    @Test("compact encodes as \"compact\"")
    func compactRawEncoding() throws {
        let data = try JSONEncoder().encode(MenuBarPopupSize.compact)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"compact\"")
    }

    @Test("comfortable encodes as \"comfortable\"")
    func comfortableRawEncoding() throws {
        let data = try JSONEncoder().encode(MenuBarPopupSize.comfortable)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"comfortable\"")
    }

    @Test("spacious encodes as \"spacious\"")
    func spaciousRawEncoding() throws {
        let data = try JSONEncoder().encode(MenuBarPopupSize.spacious)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"spacious\"")
    }

    @Test("AppSettings.popupSize defaults to .comfortable when key is missing")
    func defaultMissingKey() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.popupSize == .comfortable)
    }

    @Test("AppSettings.popupSize round-trips through full JSON")
    func roundTripThroughAppSettings() throws {
        var settings = AppSettings()
        settings.popupSize = .spacious

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.popupSize == .spacious)
    }
}

@Suite("MenuBarPopupSize — Dimensions resolution")
struct MenuBarPopupSizeDimensionsTests {

    @Test("compact resolves to the narrow / tight preset")
    func compactDimensions() {
        let d = MenuBarPopupSize.compact.dimensions
        #expect(d.width == 260)
        #expect(d.contentPadding == 8)
        #expect(d.maxContentHeight == 560)
    }

    @Test("comfortable resolves to the middle preset")
    func comfortableDimensions() {
        let d = MenuBarPopupSize.comfortable.dimensions
        #expect(d.width == 280)
        #expect(d.contentPadding == 10)
        #expect(d.maxContentHeight == 660)
    }

    @Test("spacious resolves to the wider / roomier preset")
    func spaciousDimensions() {
        let d = MenuBarPopupSize.spacious.dimensions
        #expect(d.width == 320)
        #expect(d.contentPadding == 12)
        #expect(d.maxContentHeight == 760)
    }

    @Test("widths are strictly increasing across the three cases")
    func widthsMonotonic() {
        let widths = MenuBarPopupSize.allCases.map { $0.dimensions.width }
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
    }

    @Test("maxContentHeight is strictly increasing across the three cases")
    func maxContentHeightMonotonic() {
        let heights = MenuBarPopupSize.allCases.map { $0.dimensions.maxContentHeight }
        #expect(heights == heights.sorted())
        #expect(Set(heights).count == heights.count)
    }

    @Test("maxContentHeight fits inside a 13\" MacBook usable height (~860pt)")
    func maxContentHeightFitsSmallestScreen() {
        for size in MenuBarPopupSize.allCases {
            #expect(size.dimensions.maxContentHeight <= 800)
        }
    }
}
