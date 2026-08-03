// Semper/Audio/DDC/DDCDisplayMatcher.swift
// Pure display-to-CoreAudio matching for DDC routing

#if !APP_STORE

import Foundation

nonisolated struct DDCDisplayEDID: Hashable, Sendable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
}

nonisolated struct DDCDisplayCandidate: Equatable, Sendable {
    struct ID: Hashable, Comparable, Sendable {
        let rawValue: UInt64

        static func < (lhs: ID, rhs: ID) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: ID?
    let name: String
    let edid: DDCDisplayEDID?
}

nonisolated struct CoreAudioDisplayCandidate: Equatable, Sendable {
    struct ID: Hashable, Comparable, Sendable {
        let rawValue: String

        static func < (lhs: ID, rhs: ID) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: ID?
    let name: String
    let transport: TransportType
}

nonisolated enum DDCDisplayMatchMethod: Hashable, Sendable {
    case normalizedExactName
    case substringName
    case edidUIDPrefix(prefix: String)
    case transportFallback(TransportType)
}

nonisolated struct DDCDisplayMatch: Hashable, Sendable {
    let displayID: DDCDisplayCandidate.ID
    let coreAudioID: CoreAudioDisplayCandidate.ID
    let method: DDCDisplayMatchMethod
}

nonisolated enum DDCEvidenceStage: Hashable, Sendable {
    case normalizedExactName
    case substringName
    case edidUIDPrefix(prefix: String)
    case transportFallback
}

nonisolated struct DDCEvidenceAmbiguity: Hashable, Sendable {
    let stage: DDCEvidenceStage
    let displayIDs: [DDCDisplayCandidate.ID]
    let coreAudioIDs: [CoreAudioDisplayCandidate.ID]
}

nonisolated struct DDCNameEDIDConflict: Hashable, Sendable {
    let nameDisplayID: DDCDisplayCandidate.ID
    let nameCoreAudioID: CoreAudioDisplayCandidate.ID
    let edidDisplayID: DDCDisplayCandidate.ID
    let edidCoreAudioID: CoreAudioDisplayCandidate.ID
}

nonisolated enum DDCDisplayUnmatchedReason: Hashable, Sendable {
    case noCompatibleCoreAudioDevice
    case ambiguous(DDCEvidenceAmbiguity)
    case conflictingUniqueNameAndEDID(DDCNameEDIDConflict)
}

nonisolated enum CoreAudioUnmatchedReason: Hashable, Sendable {
    case noCompatibleDDCDisplay
    case ambiguous(DDCEvidenceAmbiguity)
    case conflictingUniqueNameAndEDID(DDCNameEDIDConflict)
    case ineligibleTransport(TransportType)
}

nonisolated struct DDCUnmatchedDisplay: Equatable, Sendable {
    let id: DDCDisplayCandidate.ID
    let reasons: [DDCDisplayUnmatchedReason]
}

nonisolated struct DDCUnmatchedCoreAudioDevice: Equatable, Sendable {
    let id: CoreAudioDisplayCandidate.ID
    let reasons: [CoreAudioUnmatchedReason]
}

nonisolated struct DDCUnavailableDisplayIdentity: Hashable, Sendable {
    let name: String
    let edid: DDCDisplayEDID?
}

nonisolated struct DDCUnavailableCoreAudioIdentity: Hashable, Sendable {
    let name: String
    let transport: TransportType
}

nonisolated enum DDCIdentityDiagnostic: Hashable, Sendable {
    case unavailableDisplay(DDCUnavailableDisplayIdentity)
    case duplicateDisplayID(DDCDisplayCandidate.ID)
    case unavailableCoreAudioDevice(DDCUnavailableCoreAudioIdentity)
    case duplicateCoreAudioDeviceID(CoreAudioDisplayCandidate.ID)
}

nonisolated struct DDCDisplayMatchResult: Equatable, Sendable {
    let matches: [DDCDisplayMatch]
    let unmatchedDisplays: [DDCUnmatchedDisplay]
    let unmatchedCoreAudioDevices: [DDCUnmatchedCoreAudioDevice]
    let identityDiagnostics: [DDCIdentityDiagnostic]
}

nonisolated enum DDCDisplayMatcher {
    private struct Edge: Hashable {
        let displayID: DDCDisplayCandidate.ID
        let coreAudioID: CoreAudioDisplayCandidate.ID
    }

    private struct EDIDAmbiguity {
        let prefix: String
        let displayIDs: Set<DDCDisplayCandidate.ID>
        let coreAudioIDs: Set<CoreAudioDisplayCandidate.ID>
    }

    private struct EDIDEvidence {
        let uniqueEdges: Set<Edge>
        let ambiguities: [EDIDAmbiguity]
    }

    private struct DisplayIDList: Comparable {
        let values: [DDCDisplayCandidate.ID]

        static func < (lhs: DisplayIDList, rhs: DisplayIDList) -> Bool {
            lhs.values.lexicographicallyPrecedes(rhs.values)
        }
    }

    private struct CoreAudioIDList: Comparable {
        let values: [CoreAudioDisplayCandidate.ID]

        static func < (lhs: CoreAudioIDList, rhs: CoreAudioIDList) -> Bool {
            lhs.values.lexicographicallyPrecedes(rhs.values)
        }
    }

    private enum MatchSortKey: Comparable {
        case exact(DDCDisplayCandidate.ID, CoreAudioDisplayCandidate.ID)
        case substring(DDCDisplayCandidate.ID, CoreAudioDisplayCandidate.ID)
        case edid(String, DDCDisplayCandidate.ID, CoreAudioDisplayCandidate.ID)
        case transport(Int, DDCDisplayCandidate.ID, CoreAudioDisplayCandidate.ID)
    }

    private enum EvidenceStageSortKey: Comparable {
        case exact
        case substring
        case edid(String)
        case transport
    }

    private enum UnmatchedReasonSortKey: Comparable {
        case noCompatible
        case ambiguous(EvidenceStageSortKey, DisplayIDList, CoreAudioIDList)
        case conflict(
            DDCDisplayCandidate.ID,
            CoreAudioDisplayCandidate.ID,
            DDCDisplayCandidate.ID,
            CoreAudioDisplayCandidate.ID
        )
        case ineligibleTransport(Int)
    }

    private enum EDIDSortKey: Comparable {
        case unavailable
        case available(UInt32, UInt32, UInt32)
    }

    private enum IdentityDiagnosticSortKey: Comparable {
        case unavailableDisplay(String, EDIDSortKey)
        case duplicateDisplay(DDCDisplayCandidate.ID)
        case unavailableCoreAudio(String, Int)
        case duplicateCoreAudio(CoreAudioDisplayCandidate.ID)
    }

    private static let displayTransports: Set<TransportType> = [.hdmi, .displayPort, .thunderbolt]

    static func match(
        displays: [DDCDisplayCandidate],
        coreAudioDevices: [CoreAudioDisplayCandidate]
    ) -> DDCDisplayMatchResult {
        var identityDiagnostics: [DDCIdentityDiagnostic] = []
        let validDisplays = validatedDisplays(displays, diagnostics: &identityDiagnostics)
        let validCoreAudio = validatedCoreAudioDevices(coreAudioDevices, diagnostics: &identityDiagnostics)

        let exactEdges = nameEdges(
            displays: Array(validDisplays.values),
            coreAudioDevices: Array(validCoreAudio.values),
            exact: true
        )
        let exactDisplayParticipants = Set(exactEdges.map(\.displayID))
        let exactCoreAudioParticipants = Set(exactEdges.map(\.coreAudioID))

        let substringEdges = nameEdges(
            displays: validDisplays.values.filter { candidate in
                guard let id = candidate.id else { return false }
                return !exactDisplayParticipants.contains(id)
            },
            coreAudioDevices: validCoreAudio.values.filter { candidate in
                guard let id = candidate.id else { return false }
                return !exactCoreAudioParticipants.contains(id)
            },
            exact: false
        )

        let edidEvidence = makeEDIDEvidence(
            displays: Array(validDisplays.values),
            coreAudioDevices: Array(validCoreAudio.values)
        )

        let uniqueNameEdges = mutuallyUniqueEdges(exactEdges)
            .union(mutuallyUniqueEdges(substringEdges))
        let uniqueEDIDEdges = mutuallyUniqueEdges(edidEvidence.uniqueEdges)
        let conflicts = nameEDIDConflicts(nameEdges: uniqueNameEdges, edidEdges: uniqueEDIDEdges)

        let blockedDisplayIDs = Set(conflicts.flatMap { [$0.nameDisplayID, $0.edidDisplayID] })
        let blockedCoreAudioIDs = Set(conflicts.flatMap { [$0.nameCoreAudioID, $0.edidCoreAudioID] })

        var matches: [DDCDisplayMatch] = []
        var matchedDisplayIDs = Set<DDCDisplayCandidate.ID>()
        var matchedCoreAudioIDs = Set<CoreAudioDisplayCandidate.ID>()
        var displayReasons: [DDCDisplayCandidate.ID: Set<DDCDisplayUnmatchedReason>] = [:]
        var coreAudioReasons: [CoreAudioDisplayCandidate.ID: Set<CoreAudioUnmatchedReason>] = [:]

        for conflict in conflicts {
            let displayIDs = Set([conflict.nameDisplayID, conflict.edidDisplayID])
            let coreAudioIDs = Set([conflict.nameCoreAudioID, conflict.edidCoreAudioID])
            for id in displayIDs {
                displayReasons[id, default: []].insert(.conflictingUniqueNameAndEDID(conflict))
            }
            for id in coreAudioIDs {
                coreAudioReasons[id, default: []].insert(.conflictingUniqueNameAndEDID(conflict))
            }
        }

        applyStage(
            edges: exactEdges,
            method: .normalizedExactName,
            evidenceStage: .normalizedExactName,
            blockedDisplayIDs: blockedDisplayIDs,
            blockedCoreAudioIDs: blockedCoreAudioIDs,
            matchedDisplayIDs: &matchedDisplayIDs,
            matchedCoreAudioIDs: &matchedCoreAudioIDs,
            matches: &matches,
            displayReasons: &displayReasons,
            coreAudioReasons: &coreAudioReasons
        )

        applyStage(
            edges: substringEdges,
            method: .substringName,
            evidenceStage: .substringName,
            blockedDisplayIDs: blockedDisplayIDs,
            blockedCoreAudioIDs: blockedCoreAudioIDs,
            matchedDisplayIDs: &matchedDisplayIDs,
            matchedCoreAudioIDs: &matchedCoreAudioIDs,
            matches: &matches,
            displayReasons: &displayReasons,
            coreAudioReasons: &coreAudioReasons
        )

        let ambiguousEDIDDisplayIDs = Set(edidEvidence.ambiguities.flatMap(\.displayIDs))
        let ambiguousEDIDCoreAudioIDs = Set(edidEvidence.ambiguities.flatMap(\.coreAudioIDs))

        for ambiguity in edidEvidence.ambiguities {
            let diagnostic = DDCEvidenceAmbiguity(
                stage: .edidUIDPrefix(prefix: ambiguity.prefix),
                displayIDs: ambiguity.displayIDs.sorted(),
                coreAudioIDs: ambiguity.coreAudioIDs.sorted()
            )
            for id in ambiguity.displayIDs where !matchedDisplayIDs.contains(id) {
                displayReasons[id, default: []].insert(.ambiguous(diagnostic))
            }
            for id in ambiguity.coreAudioIDs where !matchedCoreAudioIDs.contains(id) {
                coreAudioReasons[id, default: []].insert(.ambiguous(diagnostic))
            }
        }

        applyStage(
            edges: edidEvidence.uniqueEdges,
            methodForEdge: { edge in
                let prefix = validDisplays[edge.displayID]?.edid.map(edidUIDPrefix) ?? ""
                return .edidUIDPrefix(prefix: prefix)
            },
            evidenceStageForEdge: { edge in
                let prefix = validDisplays[edge.displayID]?.edid.map(edidUIDPrefix) ?? ""
                return .edidUIDPrefix(prefix: prefix)
            },
            blockedDisplayIDs: blockedDisplayIDs,
            blockedCoreAudioIDs: blockedCoreAudioIDs,
            matchedDisplayIDs: &matchedDisplayIDs,
            matchedCoreAudioIDs: &matchedCoreAudioIDs,
            matches: &matches,
            displayReasons: &displayReasons,
            coreAudioReasons: &coreAudioReasons
        )

        applyTransportFallback(
            displays: validDisplays,
            coreAudioDevices: validCoreAudio,
            blockedDisplayIDs: blockedDisplayIDs.union(ambiguousEDIDDisplayIDs),
            blockedCoreAudioIDs: blockedCoreAudioIDs.union(ambiguousEDIDCoreAudioIDs),
            matchedDisplayIDs: &matchedDisplayIDs,
            matchedCoreAudioIDs: &matchedCoreAudioIDs,
            matches: &matches,
            displayReasons: &displayReasons,
            coreAudioReasons: &coreAudioReasons
        )

        let unmatchedDisplays = validDisplays.keys
            .filter { !matchedDisplayIDs.contains($0) }
            .sorted()
            .map { id in
                let reasons = displayReasons[id, default: [.noCompatibleCoreAudioDevice]]
                    .sorted { displayReasonSortKey($0) < displayReasonSortKey($1) }
                return DDCUnmatchedDisplay(id: id, reasons: reasons)
            }

        let unmatchedCoreAudioDevices = validCoreAudio.keys
            .filter { !matchedCoreAudioIDs.contains($0) }
            .sorted()
            .map { id in
                var reasons = coreAudioReasons[id, default: []]
                if reasons.isEmpty, let candidate = validCoreAudio[id], !displayTransports.contains(candidate.transport) {
                    reasons.insert(.ineligibleTransport(candidate.transport))
                }
                if reasons.isEmpty {
                    reasons.insert(.noCompatibleDDCDisplay)
                }
                return DDCUnmatchedCoreAudioDevice(
                    id: id,
                    reasons: reasons.sorted { coreAudioReasonSortKey($0) < coreAudioReasonSortKey($1) }
                )
            }

        return DDCDisplayMatchResult(
            matches: matches.sorted { matchSortKey($0) < matchSortKey($1) },
            unmatchedDisplays: unmatchedDisplays,
            unmatchedCoreAudioDevices: unmatchedCoreAudioDevices,
            identityDiagnostics: identityDiagnostics.sorted {
                identityDiagnosticSortKey($0) < identityDiagnosticSortKey($1)
            }
        )
    }

    private static func validatedDisplays(
        _ displays: [DDCDisplayCandidate],
        diagnostics: inout [DDCIdentityDiagnostic]
    ) -> [DDCDisplayCandidate.ID: DDCDisplayCandidate] {
        var grouped: [DDCDisplayCandidate.ID: [DDCDisplayCandidate]] = [:]
        for candidate in displays {
            guard let id = candidate.id else {
                diagnostics.append(.unavailableDisplay(DDCUnavailableDisplayIdentity(
                    name: candidate.name,
                    edid: candidate.edid
                )))
                continue
            }
            grouped[id, default: []].append(candidate)
        }

        var result: [DDCDisplayCandidate.ID: DDCDisplayCandidate] = [:]
        for (id, candidates) in grouped {
            if candidates.count == 1 {
                result[id] = candidates[0]
            } else {
                diagnostics.append(.duplicateDisplayID(id))
            }
        }
        return result
    }

    private static func validatedCoreAudioDevices(
        _ coreAudioDevices: [CoreAudioDisplayCandidate],
        diagnostics: inout [DDCIdentityDiagnostic]
    ) -> [CoreAudioDisplayCandidate.ID: CoreAudioDisplayCandidate] {
        var grouped: [CoreAudioDisplayCandidate.ID: [CoreAudioDisplayCandidate]] = [:]
        for candidate in coreAudioDevices {
            guard let id = candidate.id,
                  !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                diagnostics.append(.unavailableCoreAudioDevice(DDCUnavailableCoreAudioIdentity(
                    name: candidate.name,
                    transport: candidate.transport
                )))
                continue
            }
            grouped[id, default: []].append(candidate)
        }

        var result: [CoreAudioDisplayCandidate.ID: CoreAudioDisplayCandidate] = [:]
        for (id, candidates) in grouped {
            if candidates.count == 1 {
                result[id] = candidates[0]
            } else {
                diagnostics.append(.duplicateCoreAudioDeviceID(id))
            }
        }
        return result
    }

    private static func normalizedName(_ name: String) -> String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func nameEdges<D: Collection, C: Collection>(
        displays: D,
        coreAudioDevices: C,
        exact: Bool
    ) -> Set<Edge> where D.Element == DDCDisplayCandidate, C.Element == CoreAudioDisplayCandidate {
        var edges = Set<Edge>()
        for display in displays {
            guard let displayID = display.id, let displayName = normalizedName(display.name) else { continue }
            for coreAudio in coreAudioDevices {
                guard let coreAudioID = coreAudio.id,
                      let coreAudioName = normalizedName(coreAudio.name) else { continue }
                let isMatch: Bool
                if exact {
                    isMatch = displayName == coreAudioName
                } else {
                    isMatch = displayName != coreAudioName
                        && (displayName.contains(coreAudioName) || coreAudioName.contains(displayName))
                }
                if isMatch {
                    edges.insert(Edge(displayID: displayID, coreAudioID: coreAudioID))
                }
            }
        }
        return edges
    }

    private static func edidUIDPrefix(_ edid: DDCDisplayEDID) -> String {
        let productSwapped = ((edid.productID & 0xFF) << 8) | ((edid.productID >> 8) & 0xFF)
        return String(format: "%04x%04x", edid.vendorID, productSwapped)
    }

    private static func makeEDIDEvidence(
        displays: [DDCDisplayCandidate],
        coreAudioDevices: [CoreAudioDisplayCandidate]
    ) -> EDIDEvidence {
        var displayGroups: [String: Set<DDCDisplayCandidate.ID>] = [:]
        for display in displays {
            guard let id = display.id, let edid = display.edid else { continue }
            displayGroups[edidUIDPrefix(edid), default: []].insert(id)
        }

        var uniqueEdges = Set<Edge>()
        var ambiguities: [EDIDAmbiguity] = []
        for (prefix, displayIDs) in displayGroups {
            let coreAudioIDs = Set(coreAudioDevices.compactMap { candidate -> CoreAudioDisplayCandidate.ID? in
                guard let id = candidate.id, id.rawValue.lowercased().hasPrefix(prefix) else { return nil }
                return id
            })
            if displayIDs.count == 1, coreAudioIDs.count == 1,
               let displayID = displayIDs.first, let coreAudioID = coreAudioIDs.first {
                uniqueEdges.insert(Edge(displayID: displayID, coreAudioID: coreAudioID))
            } else if displayIDs.count > 1 || coreAudioIDs.count > 1 {
                ambiguities.append(EDIDAmbiguity(
                    prefix: prefix,
                    displayIDs: displayIDs,
                    coreAudioIDs: coreAudioIDs
                ))
            }
        }
        return EDIDEvidence(uniqueEdges: uniqueEdges, ambiguities: ambiguities)
    }

    private static func mutuallyUniqueEdges(_ edges: Set<Edge>) -> Set<Edge> {
        let displayCounts = Dictionary(grouping: edges, by: \.displayID).mapValues(\.count)
        let coreAudioCounts = Dictionary(grouping: edges, by: \.coreAudioID).mapValues(\.count)
        return Set(edges.filter { edge in
            displayCounts[edge.displayID] == 1 && coreAudioCounts[edge.coreAudioID] == 1
        })
    }

    private static func nameEDIDConflicts(
        nameEdges: Set<Edge>,
        edidEdges: Set<Edge>
    ) -> Set<DDCNameEDIDConflict> {
        var conflicts = Set<DDCNameEDIDConflict>()
        for nameEdge in nameEdges {
            for edidEdge in edidEdges {
                let sameDisplayDifferentAudio = nameEdge.displayID == edidEdge.displayID
                    && nameEdge.coreAudioID != edidEdge.coreAudioID
                let sameAudioDifferentDisplay = nameEdge.coreAudioID == edidEdge.coreAudioID
                    && nameEdge.displayID != edidEdge.displayID
                if sameDisplayDifferentAudio || sameAudioDifferentDisplay {
                    conflicts.insert(DDCNameEDIDConflict(
                        nameDisplayID: nameEdge.displayID,
                        nameCoreAudioID: nameEdge.coreAudioID,
                        edidDisplayID: edidEdge.displayID,
                        edidCoreAudioID: edidEdge.coreAudioID
                    ))
                }
            }
        }
        return conflicts
    }

    private static func applyStage(
        edges: Set<Edge>,
        method: DDCDisplayMatchMethod,
        evidenceStage: DDCEvidenceStage,
        blockedDisplayIDs: Set<DDCDisplayCandidate.ID>,
        blockedCoreAudioIDs: Set<CoreAudioDisplayCandidate.ID>,
        matchedDisplayIDs: inout Set<DDCDisplayCandidate.ID>,
        matchedCoreAudioIDs: inout Set<CoreAudioDisplayCandidate.ID>,
        matches: inout [DDCDisplayMatch],
        displayReasons: inout [DDCDisplayCandidate.ID: Set<DDCDisplayUnmatchedReason>],
        coreAudioReasons: inout [CoreAudioDisplayCandidate.ID: Set<CoreAudioUnmatchedReason>]
    ) {
        applyStage(
            edges: edges,
            methodForEdge: { _ in method },
            evidenceStageForEdge: { _ in evidenceStage },
            blockedDisplayIDs: blockedDisplayIDs,
            blockedCoreAudioIDs: blockedCoreAudioIDs,
            matchedDisplayIDs: &matchedDisplayIDs,
            matchedCoreAudioIDs: &matchedCoreAudioIDs,
            matches: &matches,
            displayReasons: &displayReasons,
            coreAudioReasons: &coreAudioReasons
        )
    }

    private static func applyStage(
        edges: Set<Edge>,
        methodForEdge: (Edge) -> DDCDisplayMatchMethod,
        evidenceStageForEdge: (Edge) -> DDCEvidenceStage,
        blockedDisplayIDs: Set<DDCDisplayCandidate.ID>,
        blockedCoreAudioIDs: Set<CoreAudioDisplayCandidate.ID>,
        matchedDisplayIDs: inout Set<DDCDisplayCandidate.ID>,
        matchedCoreAudioIDs: inout Set<CoreAudioDisplayCandidate.ID>,
        matches: inout [DDCDisplayMatch],
        displayReasons: inout [DDCDisplayCandidate.ID: Set<DDCDisplayUnmatchedReason>],
        coreAudioReasons: inout [CoreAudioDisplayCandidate.ID: Set<CoreAudioUnmatchedReason>]
    ) {
        let eligibleEdges = Set(edges.filter { edge in
            !blockedDisplayIDs.contains(edge.displayID)
                && !blockedCoreAudioIDs.contains(edge.coreAudioID)
                && !matchedDisplayIDs.contains(edge.displayID)
                && !matchedCoreAudioIDs.contains(edge.coreAudioID)
        })
        let matchedEdges = mutuallyUniqueEdges(eligibleEdges)

        for edge in matchedEdges {
            matchedDisplayIDs.insert(edge.displayID)
            matchedCoreAudioIDs.insert(edge.coreAudioID)
            matches.append(DDCDisplayMatch(
                displayID: edge.displayID,
                coreAudioID: edge.coreAudioID,
                method: methodForEdge(edge)
            ))
        }

        let unmatchedEdges = eligibleEdges.subtracting(matchedEdges)
        let byDisplay = Dictionary(grouping: unmatchedEdges, by: \.displayID)
        for (displayID, displayEdges) in byDisplay where !matchedDisplayIDs.contains(displayID) {
            guard let first = displayEdges.first else { continue }
            let diagnostic = DDCEvidenceAmbiguity(
                stage: evidenceStageForEdge(first),
                displayIDs: [displayID],
                coreAudioIDs: Set(displayEdges.map(\.coreAudioID)).sorted()
            )
            displayReasons[displayID, default: []].insert(.ambiguous(diagnostic))
        }

        let byCoreAudio = Dictionary(grouping: unmatchedEdges, by: \.coreAudioID)
        for (coreAudioID, coreAudioEdges) in byCoreAudio where !matchedCoreAudioIDs.contains(coreAudioID) {
            guard let first = coreAudioEdges.first else { continue }
            let diagnostic = DDCEvidenceAmbiguity(
                stage: evidenceStageForEdge(first),
                displayIDs: Set(coreAudioEdges.map(\.displayID)).sorted(),
                coreAudioIDs: [coreAudioID]
            )
            coreAudioReasons[coreAudioID, default: []].insert(.ambiguous(diagnostic))
        }
    }

    private static func applyTransportFallback(
        displays: [DDCDisplayCandidate.ID: DDCDisplayCandidate],
        coreAudioDevices: [CoreAudioDisplayCandidate.ID: CoreAudioDisplayCandidate],
        blockedDisplayIDs: Set<DDCDisplayCandidate.ID>,
        blockedCoreAudioIDs: Set<CoreAudioDisplayCandidate.ID>,
        matchedDisplayIDs: inout Set<DDCDisplayCandidate.ID>,
        matchedCoreAudioIDs: inout Set<CoreAudioDisplayCandidate.ID>,
        matches: inout [DDCDisplayMatch],
        displayReasons: inout [DDCDisplayCandidate.ID: Set<DDCDisplayUnmatchedReason>],
        coreAudioReasons: inout [CoreAudioDisplayCandidate.ID: Set<CoreAudioUnmatchedReason>]
    ) {
        let unmatchedDisplayIDs = Set(displays.keys.filter { !matchedDisplayIDs.contains($0) })
        var unmatchedEligibleCoreAudioIDs = Set<CoreAudioDisplayCandidate.ID>()
        for (id, candidate) in coreAudioDevices
            where !matchedCoreAudioIDs.contains(id) && displayTransports.contains(candidate.transport) {
            unmatchedEligibleCoreAudioIDs.insert(id)
        }

        if unmatchedDisplayIDs.count == 1,
           unmatchedEligibleCoreAudioIDs.count == 1,
           let displayID = unmatchedDisplayIDs.first,
           let coreAudioID = unmatchedEligibleCoreAudioIDs.first,
           !blockedDisplayIDs.contains(displayID),
           !blockedCoreAudioIDs.contains(coreAudioID),
           let transport = coreAudioDevices[coreAudioID]?.transport {
            matchedDisplayIDs.insert(displayID)
            matchedCoreAudioIDs.insert(coreAudioID)
            matches.append(DDCDisplayMatch(
                displayID: displayID,
                coreAudioID: coreAudioID,
                method: .transportFallback(transport)
            ))
            return
        }

        guard !unmatchedDisplayIDs.isEmpty, !unmatchedEligibleCoreAudioIDs.isEmpty else { return }
        let diagnostic = DDCEvidenceAmbiguity(
            stage: .transportFallback,
            displayIDs: unmatchedDisplayIDs.sorted(),
            coreAudioIDs: unmatchedEligibleCoreAudioIDs.sorted()
        )
        for id in unmatchedDisplayIDs where !blockedDisplayIDs.contains(id) {
            displayReasons[id, default: []].insert(.ambiguous(diagnostic))
        }
        for id in unmatchedEligibleCoreAudioIDs where !blockedCoreAudioIDs.contains(id) {
            coreAudioReasons[id, default: []].insert(.ambiguous(diagnostic))
        }
    }

    private static func matchSortKey(_ match: DDCDisplayMatch) -> MatchSortKey {
        switch match.method {
        case .normalizedExactName:
            return .exact(match.displayID, match.coreAudioID)
        case .substringName:
            return .substring(match.displayID, match.coreAudioID)
        case .edidUIDPrefix(let prefix):
            return .edid(prefix, match.displayID, match.coreAudioID)
        case .transportFallback(let transport):
            return .transport(transportRank(transport), match.displayID, match.coreAudioID)
        }
    }

    private static func displayReasonSortKey(_ reason: DDCDisplayUnmatchedReason) -> UnmatchedReasonSortKey {
        switch reason {
        case .noCompatibleCoreAudioDevice:
            return .noCompatible
        case .ambiguous(let ambiguity):
            return .ambiguous(
                evidenceStageSortKey(ambiguity.stage),
                DisplayIDList(values: ambiguity.displayIDs),
                CoreAudioIDList(values: ambiguity.coreAudioIDs)
            )
        case .conflictingUniqueNameAndEDID(let conflict):
            return .conflict(
                conflict.nameDisplayID,
                conflict.nameCoreAudioID,
                conflict.edidDisplayID,
                conflict.edidCoreAudioID
            )
        }
    }

    private static func coreAudioReasonSortKey(_ reason: CoreAudioUnmatchedReason) -> UnmatchedReasonSortKey {
        switch reason {
        case .noCompatibleDDCDisplay:
            return .noCompatible
        case .ambiguous(let ambiguity):
            return .ambiguous(
                evidenceStageSortKey(ambiguity.stage),
                DisplayIDList(values: ambiguity.displayIDs),
                CoreAudioIDList(values: ambiguity.coreAudioIDs)
            )
        case .conflictingUniqueNameAndEDID(let conflict):
            return .conflict(
                conflict.nameDisplayID,
                conflict.nameCoreAudioID,
                conflict.edidDisplayID,
                conflict.edidCoreAudioID
            )
        case .ineligibleTransport(let transport):
            return .ineligibleTransport(transportRank(transport))
        }
    }

    private static func evidenceStageSortKey(_ stage: DDCEvidenceStage) -> EvidenceStageSortKey {
        switch stage {
        case .normalizedExactName: return .exact
        case .substringName: return .substring
        case .edidUIDPrefix(let prefix): return .edid(prefix)
        case .transportFallback: return .transport
        }
    }

    private static func identityDiagnosticSortKey(
        _ diagnostic: DDCIdentityDiagnostic
    ) -> IdentityDiagnosticSortKey {
        switch diagnostic {
        case .unavailableDisplay(let identity):
            let edidKey = identity.edid.map {
                EDIDSortKey.available($0.vendorID, $0.productID, $0.serialNumber)
            } ?? .unavailable
            return .unavailableDisplay(identity.name, edidKey)
        case .duplicateDisplayID(let id):
            return .duplicateDisplay(id)
        case .unavailableCoreAudioDevice(let identity):
            return .unavailableCoreAudio(identity.name, transportRank(identity.transport))
        case .duplicateCoreAudioDeviceID(let id):
            return .duplicateCoreAudio(id)
        }
    }

    private static func transportRank(_ transport: TransportType) -> Int {
        switch transport {
        case .builtIn: return 0
        case .usb: return 1
        case .bluetooth: return 2
        case .bluetoothLE: return 3
        case .airPlay: return 4
        case .virtual: return 5
        case .thunderbolt: return 6
        case .hdmi: return 7
        case .displayPort: return 8
        case .aggregate: return 9
        case .unknown: return 10
        }
    }
}

#endif
