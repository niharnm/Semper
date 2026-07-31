// SemperTests/DeviceIconCatalogTests.swift

import Testing
import AppKit
import AudioToolbox
@testable import Semper

@Suite("DeviceIconCatalog")
struct DeviceIconCatalogTests {

    @Test("No duplicate symbols across the catalog")
    func noDuplicates() {
        let symbols = DeviceIconCatalog.allEntries.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("Every catalog symbol resolves to a real SF Symbol")
    func allSymbolsResolve() {
        for entry in DeviceIconCatalog.allEntries {
            #expect(
                NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil,
                "unresolvable symbol: \(entry.symbol)"
            )
        }
    }

    @Test("Every entry carries at least one keyword")
    func keywordsPresent() {
        for entry in DeviceIconCatalog.allEntries {
            #expect(!entry.keywords.isEmpty, "no keywords: \(entry.symbol)")
        }
    }

    @Test("entry(for:) round-trips every catalog symbol and misses cleanly")
    func entryLookupRoundTrips() {
        for entry in DeviceIconCatalog.allEntries {
            #expect(DeviceIconCatalog.entry(for: entry.symbol) == entry)
        }
        #expect(DeviceIconCatalog.entry(for: "not.a.catalog.symbol") == nil)
    }

    @Test("Search matches symbol names and keywords, case-insensitively")
    func searchMatching() {
        let byName = DeviceIconCatalog.matching("AIRPODS").map(\.symbol)
        #expect(byName.contains("airpodspro"))

        let byKeyword = DeviceIconCatalog.matching("cans").map(\.symbol)
        #expect(byKeyword.contains("headphones"))

        let byMultiWordKeyword = DeviceIconCatalog.matching("apple tv").map(\.symbol)
        #expect(byMultiWordKeyword.contains("appletv.fill"))

        #expect(DeviceIconCatalog.matching("zzzz-no-match").isEmpty)
    }

    @Test("Empty and whitespace-only queries return the full catalog")
    func emptyQueryReturnsAll() {
        #expect(DeviceIconCatalog.matching("").count == DeviceIconCatalog.allEntries.count)
        #expect(DeviceIconCatalog.matching("   ").count == DeviceIconCatalog.allEntries.count)
    }

    @Test("Suggestions lead with the automatic guess and never duplicate",
          arguments: [TransportType.builtIn, .usb, .bluetooth, .bluetoothLE, .airPlay,
                      .virtual, .thunderbolt, .hdmi, .displayPort, .aggregate, .unknown])
    func suggestionsPerTransport(transport: TransportType) {
        let suggested = DeviceIconCatalog.suggested(forName: "Some Device", transport: transport)
        #expect(!suggested.isEmpty)
        #expect(suggested.first == AudioDeviceID.iconSymbol(forName: "Some Device", transport: transport))
        #expect(Set(suggested).count == suggested.count)
        for symbol in suggested {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "unresolvable suggestion: \(symbol)")
        }
    }

    // iconSymbol() can lead with symbols absent from the catalog (e.g. "homepod",
    // "appletv"), so these name/transport pairs pin that those still resolve.
    @Test("Suggestions for recognized device names lead with the automatic guess and resolve",
          arguments: [("HomePod mini", TransportType.airPlay),
                      ("Apple TV 4K", .airPlay),
                      ("Mac Studio Speakers", .builtIn),
                      ("Beats Studio Pro", .bluetooth),
                      ("MacBook Pro Speakers", .builtIn)])
    func suggestionsPerName(name: String, transport: TransportType) {
        let suggested = DeviceIconCatalog.suggested(forName: name, transport: transport)
        #expect(!suggested.isEmpty)
        #expect(suggested.first == AudioDeviceID.iconSymbol(forName: name, transport: transport))
        #expect(Set(suggested).count == suggested.count)
        for symbol in suggested {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "unresolvable suggestion: \(symbol)")
        }
    }

    @Test("Name-derived suggestion wins over transport family")
    func nameDerivedSuggestion() {
        let suggested = DeviceIconCatalog.suggested(forName: "AirPods Pro", transport: .bluetooth)
        #expect(suggested.first == "airpodspro")
    }
}
