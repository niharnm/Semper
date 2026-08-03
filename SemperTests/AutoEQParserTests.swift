import Testing
@testable import Semper

@Suite("AutoEQ parser")
struct AutoEQParserTests {
    @Test("Clamps preamp values and accepts irregular whitespace")
    func clampsPreamp() {
        let cases: [(String, Float)] = [
            ("Preamp:   -42 dB", -30),
            ("Preamp:\t12.5 dB", 12.5),
            ("Preamp: 42 dB", 30),
        ]

        for (line, expected) in cases {
            let profile = parse("""
                \(line)
                Filter 1: ON PK Fc 100 Hz Gain -2 dB Q 1
                """)

            #expect(profile?.preampDB == expected, "Unexpected preamp for \(line)")
        }
    }

    @Test("Skips disabled filters")
    func skipsDisabledFilters() {
        let profile = parse("""
            Filter 1: OFF PK Fc 100 Hz Gain -2 dB Q 1
            Filter 2: ON PK Fc 200 Hz Gain -3 dB Q 1
            """)

        #expect(profile?.filters.map(\.frequency) == [200])
    }

    @Test("Skips malformed and unsupported filters")
    func skipsMalformedAndUnsupportedFilters() {
        let profile = parse("""
            Filter 1: ON PK Fc 100 Hz Gain -2 dB
            Filter 2: ON XYZ Fc 200 Hz Gain -2 dB Q 1
            Filter 3: ON PK Fc 300 Hz Gain -2 dB Q 1
            """)

        #expect(profile?.filters.map(\.frequency) == [300])
    }

    @Test("Skips filters outside supported numeric ranges")
    func skipsOutOfRangeFilters() {
        let profile = parse("""
            Filter 1: ON PK Fc 0 Hz Gain -2 dB Q 1
            Filter 2: ON PK Fc 100 Hz Gain 31 dB Q 1
            Filter 3: ON PK Fc 200 Hz Gain -2 dB Q 0
            Filter 4: ON PK Fc 300 Hz Gain -2 dB Q 1
            """)

        #expect(profile?.filters.map(\.frequency) == [300])
    }

    @Test("Accepts all documented filter type aliases")
    func acceptsFilterTypeAliases() {
        let aliases: [(String, AutoEQFilter.FilterType)] = [
            ("PK", .peaking),
            ("PEQ", .peaking),
            ("LS", .lowShelf),
            ("LSC", .lowShelf),
            ("HS", .highShelf),
            ("HSC", .highShelf),
        ]

        for (alias, expectedType) in aliases {
            let profile = parse("Filter 1: ON \(alias) Fc 100 Hz Gain -2 dB Q 1")

            #expect(profile?.filters.map(\.type) == [expectedType], "Unexpected type for \(alias)")
        }
    }

    @Test("Limits parsed filters to the profile maximum")
    func limitsParsedFilters() {
        let text = (1...12).map { index in
            "Filter \(index): ON PK Fc \(index * 100) Hz Gain -2 dB Q 1"
        }.joined(separator: "\n")

        let profile = parse(text)

        #expect(profile?.filters.count == AutoEQProfile.maxFilters)
        #expect(profile?.filters.last?.frequency == Double(AutoEQProfile.maxFilters * 100))
    }

    @Test("Uses explicit IDs and stable slugs for bundled and fetched profiles")
    func usesExplicitAndStableIDs() {
        let bundled = parse("Filter 1: ON PK Fc 100 Hz Gain -2 dB Q 1", source: .bundled)
        let fetched = parse("Filter 1: ON PK Fc 100 Hz Gain -2 dB Q 1", source: .fetched)
        let explicit = parse(
            "Filter 1: ON PK Fc 100 Hz Gain -2 dB Q 1",
            source: .imported,
            id: "explicit-profile"
        )

        #expect(bundled?.id == "test-profile")
        #expect(fetched?.id == "test-profile")
        #expect(explicit?.id == "explicit-profile")
    }

    @Test("Parses catalog paths, deduplicates models, prioritizes sources, and sorts names")
    @MainActor
    func parsesCatalogIndex() {
        let entries = AutoEQFetcher.parseIndexMarkdown("""
            - [Zeta](./crinacle/over-ear/Zeta) by crinacle
            - [alpha (m15 Apex module)](./crinacle/over-ear/Alpha%20(m15%20Apex%20module)) by crinacle
            - [Alpha (m15 Apex module)](./oratory1990/over-ear/Alpha%20(m15%20Apex%20module)) by oratory1990
            - [Beta](./Rtings/over-ear/Beta) by Rtings on Rig A
            """)

        #expect(entries.count == 3)
        #expect(entries.map(\.name) == ["Alpha (m15 Apex module)", "Beta", "Zeta"])

        let alpha = entries.first { $0.name == "Alpha (m15 Apex module)" }
        #expect(alpha?.measuredBy == "oratory1990")
        #expect(alpha?.relativePath == "oratory1990/over-ear/Alpha (m15 Apex module)")

        let beta = entries.first { $0.name == "Beta" }
        #expect(beta?.measuredBy == "Rtings")
    }

    private func parse(
        _ text: String,
        name: String = "Test Profile",
        source: AutoEQSource = .fetched,
        id: String? = nil
    ) -> AutoEQProfile? {
        AutoEQParser.parse(text: text, name: name, source: source, id: id)
    }
}
