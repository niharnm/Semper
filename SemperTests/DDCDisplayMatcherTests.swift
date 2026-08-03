// SemperTests/DDCDisplayMatcherTests.swift

import Foundation
import Testing
@testable import Semper

@Suite("DDC display matching")
struct DDCDisplayMatcherTests {
    @Test("Empty candidate collections return an empty result")
    func emptyCandidates() {
        let result = DDCDisplayMatcher.match(displays: [], coreAudioDevices: [])

        #expect(result.matches.isEmpty)
        #expect(result.unmatchedDisplays.isEmpty)
        #expect(result.unmatchedCoreAudioDevices.isEmpty)
        #expect(result.identityDiagnostics.isEmpty)
    }

    @Test("Exact names ignore case and surrounding whitespace")
    func normalizedExactName() {
        let result = DDCDisplayMatcher.match(
            displays: [display(1, name: "  LG UltraFine  ")],
            coreAudioDevices: [audio("lg", name: "lg ultrafine")]
        )

        #expect(result.matches == [match(1, "lg", .normalizedExactName)])
    }

    @Test("Exact name wins over a substring candidate regardless of order")
    func exactPrecedesSubstring() {
        let short = display(1, name: "UltraFine")
        let exact = display(2, name: "LG UltraFine")
        let device = audio("lg", name: "LG UltraFine", transport: .usb)
        let expected = match(2, "lg", .normalizedExactName)

        let first = DDCDisplayMatcher.match(
            displays: [short, exact],
            coreAudioDevices: [device]
        )
        let second = DDCDisplayMatcher.match(
            displays: [exact, short],
            coreAudioDevices: [device]
        )

        #expect(first.matches == [expected])
        #expect(second.matches == [expected])
    }

    @Test("Unique substring names match in either containment direction")
    func uniqueSubstringNames() {
        let longerCoreAudioName = DDCDisplayMatcher.match(
            displays: [display(1, name: "UltraFine")],
            coreAudioDevices: [audio("a", name: "LG UltraFine", transport: .usb)]
        )
        let longerDisplayName = DDCDisplayMatcher.match(
            displays: [display(2, name: "Dell U2723QE Display")],
            coreAudioDevices: [audio("b", name: "U2723QE", transport: .usb)]
        )

        #expect(longerCoreAudioName.matches == [match(1, "a", .substringName)])
        #expect(longerDisplayName.matches == [match(2, "b", .substringName)])
    }

    @Test("Empty and whitespace-only names create no name edge")
    func emptyNamesCreateNoEdges() {
        let emptyDisplay = DDCDisplayMatcher.match(
            displays: [display(1, name: "   ")],
            coreAudioDevices: [audio("a", name: "Display", transport: .usb)]
        )
        let emptyCoreAudio = DDCDisplayMatcher.match(
            displays: [display(2, name: "Display")],
            coreAudioDevices: [audio("b", name: "\t\n", transport: .usb)]
        )

        #expect(emptyDisplay.matches.isEmpty)
        #expect(emptyCoreAudio.matches.isEmpty)
    }

    @Test("Duplicate exact names remain unmatched")
    func duplicateExactNames() {
        let displays = [
            display(1, name: "External Display"),
            display(2, name: "External Display"),
        ]
        let coreAudioDevices = [
            audio("a", name: "External Display", transport: .usb),
            audio("b", name: "External Display", transport: .usb),
        ]
        let result = DDCDisplayMatcher.match(
            displays: displays,
            coreAudioDevices: coreAudioDevices
        )
        let reordered = DDCDisplayMatcher.match(
            displays: Array(displays.reversed()),
            coreAudioDevices: Array(coreAudioDevices.reversed())
        )

        #expect(result.matches.isEmpty)
        #expect(reordered == result)
        #expect(result.unmatchedDisplays.count == 2)
        #expect(result.unmatchedCoreAudioDevices.count == 2)
        #expect(result.unmatchedDisplays.allSatisfy { unmatched in
            unmatched.reasons.contains { reason in
                guard case .ambiguous(let ambiguity) = reason else { return false }
                return ambiguity.stage == .normalizedExactName
            }
        })
    }

    @Test("An exact-name ambiguity does not fall through to substring matching")
    func exactAmbiguitySkipsSubstring() {
        let result = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Panel"),
                display(2, name: "Panel"),
            ],
            coreAudioDevices: [
                audio("a", name: "Panel", transport: .usb),
                audio("b", name: "Panel Pro", transport: .usb),
            ]
        )

        #expect(result.matches.isEmpty)
    }

    @Test("Overlapping substring names remain unmatched")
    func ambiguousSubstringNames() {
        let result = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Dell"),
                display(2, name: "Dell UltraSharp"),
            ],
            coreAudioDevices: [
                audio("a", name: "Dell U2723QE", transport: .usb),
                audio("b", name: "Dell U3223QE", transport: .usb),
            ]
        )

        #expect(result.matches.isEmpty)
        #expect(result.unmatchedDisplays.contains { unmatched in
            unmatched.reasons.contains { reason in
                guard case .ambiguous(let ambiguity) = reason else { return false }
                return ambiguity.stage == .substringName
            }
        })
    }

    @Test("EDID matching byte-swaps the product and ignores UID prefix case")
    func edidByteSwapAndCase() {
        let value = edid(vendor: 0x1E6D, product: 0x7750, serial: 42)
        let result = DDCDisplayMatcher.match(
            displays: [display(1, name: "Quartz", edid: value)],
            coreAudioDevices: [audio("1E6D5077-0000-0000", name: "Nimbus", transport: .usb)]
        )

        #expect(result.matches == [
            match(1, "1E6D5077-0000-0000", .edidUIDPrefix(prefix: "1e6d5077")),
        ])
    }

    @Test("Ambiguous exact names may be resolved by unique EDID prefixes")
    func ambiguousNamesContinueToEDID() {
        let firstEDID = edid(vendor: 0x1001, product: 0x0100)
        let secondEDID = edid(vendor: 0x1002, product: 0x0200)
        let result = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Twin", edid: firstEDID),
                display(2, name: "Twin", edid: secondEDID),
            ],
            coreAudioDevices: [
                audio(uid(for: firstEDID, suffix: "-a"), name: "Twin"),
                audio(uid(for: secondEDID, suffix: "-b"), name: "Twin"),
            ]
        )

        #expect(result.matches == [
            match(1, uid(for: firstEDID, suffix: "-a"), .edidUIDPrefix(prefix: prefix(for: firstEDID))),
            match(2, uid(for: secondEDID, suffix: "-b"), .edidUIDPrefix(prefix: prefix(for: secondEDID))),
        ])
    }

    @Test("Duplicate EDID prefixes remain unmatched after a name match")
    func duplicateEDIDPrefixesRemainUnmatched() {
        let firstEDID = edid(vendor: 0x2222, product: 0x3300, serial: 1)
        let secondEDID = edid(vendor: 0x2222, product: 0x3300, serial: 2)
        let firstUID = uid(for: firstEDID, suffix: "-first")
        let secondUID = uid(for: secondEDID, suffix: "-second")
        let result = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Named Panel", edid: firstEDID),
                display(2, name: "Quartz", edid: secondEDID),
            ],
            coreAudioDevices: [
                audio(firstUID, name: "Named Panel", transport: .hdmi),
                audio(secondUID, name: "Nimbus", transport: .hdmi),
            ]
        )

        #expect(result.matches == [match(1, firstUID, .normalizedExactName)])
        #expect(result.unmatchedDisplays.map(\.id) == [displayID(2)])
        #expect(result.unmatchedCoreAudioDevices.map(\.id) == [coreAudioID(secondUID)])
        #expect(result.unmatchedDisplays[0].reasons.contains { reason in
            guard case .ambiguous(let ambiguity) = reason else { return false }
            guard case .edidUIDPrefix = ambiguity.stage else { return false }
            return true
        })
    }

    @Test("Duplicate display EDID prefixes block transport without a matching UID prefix")
    func duplicateDisplayEDIDPrefixesBlockTransportWithoutUIDMatch() {
        let firstEDID = edid(vendor: 0x2233, product: 0x4400, serial: 1)
        let secondEDID = edid(vendor: 0x2233, product: 0x4400, serial: 2)
        let result = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Named Panel", edid: firstEDID),
                display(2, name: "Quartz", edid: secondEDID),
            ],
            coreAudioDevices: [
                audio("name-target", name: "Named Panel", transport: .hdmi),
                audio("unrelated-hdmi", name: "Nimbus", transport: .hdmi),
            ]
        )

        #expect(result.matches == [match(1, "name-target", .normalizedExactName)])
        #expect(result.unmatchedDisplays.map(\.id) == [displayID(2)])
        #expect(result.unmatchedCoreAudioDevices.map(\.id) == [coreAudioID("unrelated-hdmi")])
        #expect(result.unmatchedDisplays[0].reasons.contains { reason in
            guard case .ambiguous(let ambiguity) = reason else { return false }
            guard case .edidUIDPrefix = ambiguity.stage else { return false }
            return ambiguity.coreAudioIDs.isEmpty
        })
    }

    @Test("A unique name that conflicts with unique EDID fails closed")
    func nameEDIDConflictByDisplay() {
        let conflictingEDID = edid(vendor: 0x3001, product: 0x4400)
        let edidUID = uid(for: conflictingEDID, suffix: "-edid")
        let result = DDCDisplayMatcher.match(
            displays: [display(1, name: "Named Panel", edid: conflictingEDID)],
            coreAudioDevices: [
                audio("name-target", name: "Named Panel", transport: .hdmi),
                audio(edidUID, name: "Other Device", transport: .hdmi),
            ]
        )

        #expect(result.matches.isEmpty)
        #expect(result.unmatchedDisplays[0].reasons.contains { reason in
            if case .conflictingUniqueNameAndEDID = reason { return true }
            return false
        })
    }

    @Test("Unique name and EDID pairs sharing a Core Audio device fail closed")
    func nameEDIDConflictByCoreAudioDevice() {
        let value = edid(vendor: 0x3002, product: 0x5500)
        let targetUID = uid(for: value, suffix: "-shared")
        let result = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Named Panel"),
                display(2, name: "Other Display", edid: value),
            ],
            coreAudioDevices: [audio(targetUID, name: "Named Panel", transport: .hdmi)]
        )

        #expect(result.matches.isEmpty)
        #expect(result.unmatchedDisplays.count == 2)
        #expect(result.unmatchedCoreAudioDevices.count == 1)
    }

    @Test("Transport fallback accepts each supported transport only for one remaining pair")
    func uniqueTransportFallback() {
        for (index, transport) in [TransportType.hdmi, .displayPort, .thunderbolt].enumerated() {
            let rawID = UInt64(index + 1)
            let uid = "transport-\(index)"
            let result = DDCDisplayMatcher.match(
                displays: [display(rawID, name: "Display \(index)")],
                coreAudioDevices: [audio(uid, name: "Audio \(index)", transport: transport)]
            )

            #expect(result.matches == [match(rawID, uid, .transportFallback(transport))])
        }
    }

    @Test("Transport fallback rejects non-display transports")
    func ineligibleTransportFallback() {
        for (index, transport) in [
            TransportType.builtIn,
            .usb,
            .bluetooth,
            .bluetoothLE,
            .airPlay,
            .virtual,
            .aggregate,
            .unknown,
        ].enumerated() {
            let result = DDCDisplayMatcher.match(
                displays: [display(UInt64(index + 1), name: "Quartz")],
                coreAudioDevices: [audio("uid-\(index)", name: "Nimbus", transport: transport)]
            )

            #expect(result.matches.isEmpty)
        }
    }

    @Test("Transport fallback rejects one-to-many, many-to-one, and many-to-many sets")
    func ambiguousTransportFallback() {
        let oneToMany = DDCDisplayMatcher.match(
            displays: [display(1, name: "Quartz")],
            coreAudioDevices: [
                audio("a", name: "Nimbus", transport: .hdmi),
                audio("b", name: "Cobalt", transport: .displayPort),
            ]
        )
        let manyToOne = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Quartz"),
                display(2, name: "Saffron"),
            ],
            coreAudioDevices: [audio("a", name: "Nimbus", transport: .hdmi)]
        )
        let manyToMany = DDCDisplayMatcher.match(
            displays: [
                display(1, name: "Quartz"),
                display(2, name: "Saffron"),
            ],
            coreAudioDevices: [
                audio("a", name: "Nimbus", transport: .hdmi),
                audio("b", name: "Cobalt", transport: .thunderbolt),
            ]
        )

        #expect(oneToMany.matches.isEmpty)
        #expect(manyToOne.matches.isEmpty)
        #expect(manyToMany.matches.isEmpty)
    }

    @Test("Each display and Core Audio device is assigned at most once")
    func oneToOneAssignment() {
        let result = mixedThreeByThreeResult(
            displays: mixedThreeByThreeDisplays(),
            coreAudioDevices: mixedThreeByThreeCoreAudio()
        )

        #expect(Set(result.matches.map(\.displayID)).count == result.matches.count)
        #expect(Set(result.matches.map(\.coreAudioID)).count == result.matches.count)
    }

    @Test("Matches use evidence precedence before stable identities in canonical output")
    func canonicalMatchOrdering() {
        let value = edid(vendor: 0x4141, product: 0x4200)
        let displays = [
            display(10, name: "Fallback Display"),
            display(20, name: "Quartz", edid: value),
            display(30, name: "UltraFine"),
            display(40, name: "Exact Panel"),
        ]
        let coreAudioDevices = [
            audio("fallback", name: "Route Endpoint", transport: .hdmi),
            audio(uid(for: value, suffix: "-edid"), name: "Nimbus", transport: .usb),
            audio("substring", name: "LG UltraFine", transport: .usb),
            audio("exact", name: " exact panel ", transport: .usb),
        ]
        let expectedMatches = [
            match(40, "exact", .normalizedExactName),
            match(30, "substring", .substringName),
            match(20, uid(for: value, suffix: "-edid"), .edidUIDPrefix(prefix: prefix(for: value))),
            match(10, "fallback", .transportFallback(.hdmi)),
        ]

        let result = DDCDisplayMatcher.match(
            displays: displays,
            coreAudioDevices: coreAudioDevices
        )
        let reversed = DDCDisplayMatcher.match(
            displays: Array(displays.reversed()),
            coreAudioDevices: Array(coreAudioDevices.reversed())
        )

        #expect(result.matches == expectedMatches)
        #expect(reversed == result)
    }

    @Test("Mixed three-by-three result is identical for all 36 input permutations")
    func allThreeByThreePermutations() {
        let displays = mixedThreeByThreeDisplays()
        let coreAudioDevices = mixedThreeByThreeCoreAudio()
        let expected = mixedThreeByThreeResult(displays: displays, coreAudioDevices: coreAudioDevices)

        #expect(expected.matches == [
            match(1, "exact", .normalizedExactName),
            match(2, "20020002-edid", .edidUIDPrefix(prefix: "20020002")),
            match(3, "fallback", .transportFallback(.hdmi)),
        ])

        var count = 0
        for displayOrder in permutations(displays) {
            for coreAudioOrder in permutations(coreAudioDevices) {
                let result = mixedThreeByThreeResult(
                    displays: displayOrder,
                    coreAudioDevices: coreAudioOrder
                )
                #expect(result == expected)
                count += 1
            }
        }
        #expect(count == 36)
    }

    @Test("Unavailable and duplicate identities are diagnosed and excluded")
    func invalidIdentities() {
        let displays = [
            display(nil, name: "Missing ID"),
            display(1, name: "Duplicate A"),
            display(1, name: "Duplicate B"),
            display(2, name: "Valid"),
        ]
        let coreAudioDevices = [
            audio(nil, name: "Missing UID", transport: .usb),
            audio(" \n", name: "Whitespace UID", transport: .usb),
            audio("duplicate", name: "Duplicate A", transport: .usb),
            audio("duplicate", name: "Duplicate B", transport: .usb),
            audio("valid", name: "Valid", transport: .usb),
        ]
        let result = DDCDisplayMatcher.match(
            displays: displays,
            coreAudioDevices: coreAudioDevices
        )
        let reversed = DDCDisplayMatcher.match(
            displays: Array(displays.reversed()),
            coreAudioDevices: Array(coreAudioDevices.reversed())
        )

        #expect(result.matches == [match(2, "valid", .normalizedExactName)])
        #expect(result.identityDiagnostics == [
            .unavailableDisplay(DDCUnavailableDisplayIdentity(name: "Missing ID", edid: nil)),
            .duplicateDisplayID(displayID(1)),
            .unavailableCoreAudioDevice(DDCUnavailableCoreAudioIdentity(
                name: "Missing UID",
                transport: .usb
            )),
            .unavailableCoreAudioDevice(DDCUnavailableCoreAudioIdentity(
                name: "Whitespace UID",
                transport: .usb
            )),
            .duplicateCoreAudioDeviceID(coreAudioID("duplicate")),
        ])
        #expect(reversed == result)
    }

    @Test("Unmatched candidates return typed reasons")
    func typedUnmatchedReasons() {
        let result = DDCDisplayMatcher.match(
            displays: [display(1, name: "Quartz")],
            coreAudioDevices: [audio("usb", name: "Nimbus", transport: .usb)]
        )

        #expect(result.unmatchedDisplays == [
            DDCUnmatchedDisplay(id: displayID(1), reasons: [.noCompatibleCoreAudioDevice]),
        ])
        #expect(result.unmatchedCoreAudioDevices == [
            DDCUnmatchedCoreAudioDevice(id: coreAudioID("usb"), reasons: [.ineligibleTransport(.usb)]),
        ])
    }

    @Test("Multiple unmatched reasons use evidence and identity ordering")
    func canonicalUnmatchedReasonOrdering() {
        let firstEDID = edid(vendor: 0x5151, product: 0x5200, serial: 1)
        let secondEDID = edid(vendor: 0x5151, product: 0x5200, serial: 2)
        let firstUID = uid(for: firstEDID, suffix: "-a")
        let secondUID = uid(for: secondEDID, suffix: "-b")
        let displays = [
            display(2, name: "Twin", edid: secondEDID),
            display(1, name: "Twin", edid: firstEDID),
        ]
        let coreAudioDevices = [
            audio(secondUID, name: "Twin", transport: .hdmi),
            audio(firstUID, name: "Twin", transport: .hdmi),
        ]
        let edidAmbiguity = DDCEvidenceAmbiguity(
            stage: .edidUIDPrefix(prefix: prefix(for: firstEDID)),
            displayIDs: [displayID(1), displayID(2)],
            coreAudioIDs: [coreAudioID(firstUID), coreAudioID(secondUID)]
        )
        let result = DDCDisplayMatcher.match(
            displays: displays,
            coreAudioDevices: coreAudioDevices
        )
        let reversed = DDCDisplayMatcher.match(
            displays: Array(displays.reversed()),
            coreAudioDevices: Array(coreAudioDevices.reversed())
        )

        #expect(result.unmatchedDisplays == [
            DDCUnmatchedDisplay(id: displayID(1), reasons: [
                .ambiguous(DDCEvidenceAmbiguity(
                    stage: .normalizedExactName,
                    displayIDs: [displayID(1)],
                    coreAudioIDs: [coreAudioID(firstUID), coreAudioID(secondUID)]
                )),
                .ambiguous(edidAmbiguity),
            ]),
            DDCUnmatchedDisplay(id: displayID(2), reasons: [
                .ambiguous(DDCEvidenceAmbiguity(
                    stage: .normalizedExactName,
                    displayIDs: [displayID(2)],
                    coreAudioIDs: [coreAudioID(firstUID), coreAudioID(secondUID)]
                )),
                .ambiguous(edidAmbiguity),
            ]),
        ])
        #expect(result.unmatchedCoreAudioDevices == [
            DDCUnmatchedCoreAudioDevice(id: coreAudioID(firstUID), reasons: [
                .ambiguous(DDCEvidenceAmbiguity(
                    stage: .normalizedExactName,
                    displayIDs: [displayID(1), displayID(2)],
                    coreAudioIDs: [coreAudioID(firstUID)]
                )),
                .ambiguous(edidAmbiguity),
            ]),
            DDCUnmatchedCoreAudioDevice(id: coreAudioID(secondUID), reasons: [
                .ambiguous(DDCEvidenceAmbiguity(
                    stage: .normalizedExactName,
                    displayIDs: [displayID(1), displayID(2)],
                    coreAudioIDs: [coreAudioID(secondUID)]
                )),
                .ambiguous(edidAmbiguity),
            ]),
        ])
        #expect(reversed == result)
    }

    @Test("Larger mixed fixture is identical across 100 fixed-seed shuffles")
    func fixedSeedShuffles() {
        let fixture = largerFixture()
        let expected = DDCDisplayMatcher.match(
            displays: fixture.displays,
            coreAudioDevices: fixture.coreAudioDevices
        )

        #expect(expected == DDCDisplayMatchResult(
            matches: [
                match(1, "one", .normalizedExactName),
                match(2, "two", .normalizedExactName),
                match(9, "nine", .normalizedExactName),
                match(3, "three", .substringName),
                match(4, "four", .substringName),
                match(5, "50050005-five", .edidUIDPrefix(prefix: "50050005")),
                match(6, "60060006-six", .edidUIDPrefix(prefix: "60060006")),
                match(7, "70070007-seven", .edidUIDPrefix(prefix: "70070007")),
                match(8, "80080008-eight", .edidUIDPrefix(prefix: "80080008")),
                match(10, "ten", .transportFallback(.displayPort)),
            ],
            unmatchedDisplays: [],
            unmatchedCoreAudioDevices: [
                DDCUnmatchedCoreAudioDevice(
                    id: coreAudioID("unrelated"),
                    reasons: [.ineligibleTransport(.usb)]
                ),
            ],
            identityDiagnostics: [
                .unavailableDisplay(DDCUnavailableDisplayIdentity(
                    name: "Unavailable Identity",
                    edid: nil
                )),
                .duplicateCoreAudioDeviceID(coreAudioID("duplicate")),
            ]
        ))

        for iteration in 0..<100 {
            var generator = FixedSeedGenerator(seed: UInt64(iteration + 1))
            let displays = fixture.displays.shuffled(using: &generator)
            let coreAudioDevices = fixture.coreAudioDevices.shuffled(using: &generator)
            let result = DDCDisplayMatcher.match(
                displays: displays,
                coreAudioDevices: coreAudioDevices
            )

            #expect(result == expected)
            #expect(Set(result.matches.map(\.displayID)).count == result.matches.count)
            #expect(Set(result.matches.map(\.coreAudioID)).count == result.matches.count)
        }
    }
}

private func display(
    _ rawID: UInt64?,
    name: String,
    edid: DDCDisplayEDID? = nil
) -> DDCDisplayCandidate {
    DDCDisplayCandidate(
        id: rawID.map(displayID),
        name: name,
        edid: edid
    )
}

private func audio(
    _ rawID: String?,
    name: String,
    transport: TransportType = .hdmi
) -> CoreAudioDisplayCandidate {
    CoreAudioDisplayCandidate(
        id: rawID.map(coreAudioID),
        name: name,
        transport: transport
    )
}

private func displayID(_ rawValue: UInt64) -> DDCDisplayCandidate.ID {
    DDCDisplayCandidate.ID(rawValue: rawValue)
}

private func coreAudioID(_ rawValue: String) -> CoreAudioDisplayCandidate.ID {
    CoreAudioDisplayCandidate.ID(rawValue: rawValue)
}

private func edid(
    vendor: UInt32,
    product: UInt32,
    serial: UInt32 = 0
) -> DDCDisplayEDID {
    DDCDisplayEDID(vendorID: vendor, productID: product, serialNumber: serial)
}

private func prefix(for value: DDCDisplayEDID) -> String {
    let productSwapped = ((value.productID & 0xFF) << 8) | ((value.productID >> 8) & 0xFF)
    return String(format: "%04x%04x", value.vendorID, productSwapped)
}

private func uid(for value: DDCDisplayEDID, suffix: String) -> String {
    prefix(for: value) + suffix
}

private func match(
    _ displayRawID: UInt64,
    _ coreAudioRawID: String,
    _ method: DDCDisplayMatchMethod
) -> DDCDisplayMatch {
    DDCDisplayMatch(
        displayID: displayID(displayRawID),
        coreAudioID: coreAudioID(coreAudioRawID),
        method: method
    )
}

private func permutations<T>(_ values: [T]) -> [[T]] {
    guard values.count > 1 else { return [values] }
    var result: [[T]] = []
    for index in values.indices {
        var remainder = values
        let value = remainder.remove(at: index)
        for suffix in permutations(remainder) {
            result.append([value] + suffix)
        }
    }
    return result
}

private func mixedThreeByThreeDisplays() -> [DDCDisplayCandidate] {
    [
        display(1, name: "Exact"),
        display(2, name: "Quartz", edid: edid(vendor: 0x2002, product: 0x0200)),
        display(3, name: "Fallback Display"),
    ]
}

private func mixedThreeByThreeCoreAudio() -> [CoreAudioDisplayCandidate] {
    [
        audio("exact", name: " exact ", transport: .usb),
        audio("20020002-edid", name: "Nimbus", transport: .usb),
        audio("fallback", name: "Route Endpoint", transport: .hdmi),
    ]
}

private func mixedThreeByThreeResult(
    displays: [DDCDisplayCandidate],
    coreAudioDevices: [CoreAudioDisplayCandidate]
) -> DDCDisplayMatchResult {
    DDCDisplayMatcher.match(displays: displays, coreAudioDevices: coreAudioDevices)
}

private func largerFixture() -> (
    displays: [DDCDisplayCandidate],
    coreAudioDevices: [CoreAudioDisplayCandidate]
) {
    let fifth = edid(vendor: 0x5005, product: 0x0500)
    let sixth = edid(vendor: 0x6006, product: 0x0600)
    let seventh = edid(vendor: 0x7007, product: 0x0700)
    let eighth = edid(vendor: 0x8008, product: 0x0800)

    let displays = [
        display(1, name: "Exact One"),
        display(2, name: "  Exact Two  "),
        display(3, name: "UltraFine"),
        display(4, name: "Dell U2723QE Display"),
        display(5, name: "Quartz", edid: fifth),
        display(6, name: "Twin", edid: sixth),
        display(7, name: "Twin", edid: seventh),
        display(8, name: "Cobalt", edid: eighth),
        display(9, name: "Exact Nine"),
        display(10, name: "Fallback Display"),
        display(nil, name: "Unavailable Identity"),
    ]

    let coreAudioDevices = [
        audio("one", name: "Exact One", transport: .usb),
        audio("two", name: "exact two", transport: .usb),
        audio("three", name: "LG UltraFine", transport: .usb),
        audio("four", name: "U2723QE", transport: .usb),
        audio(uid(for: fifth, suffix: "-five"), name: "Nimbus", transport: .usb),
        audio(uid(for: sixth, suffix: "-six"), name: "Twin", transport: .usb),
        audio(uid(for: seventh, suffix: "-seven"), name: "Twin", transport: .usb),
        audio(uid(for: eighth, suffix: "-eight"), name: "Saffron", transport: .usb),
        audio("nine", name: "Exact Nine", transport: .usb),
        audio("ten", name: "Route Endpoint", transport: .displayPort),
        audio("unrelated", name: "Unrelated USB", transport: .usb),
        audio("duplicate", name: "Duplicate One", transport: .usb),
        audio("duplicate", name: "Duplicate Two", transport: .usb),
    ]
    return (displays, coreAudioDevices)
}

private struct FixedSeedGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
