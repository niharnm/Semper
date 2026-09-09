import Foundation

extension DisplayDiagnosticsReport {
    static func make(
        for item: DisplayInventoryItem,
        generatedAt: Date,
        applicationVersion: Version?,
        operatingSystemVersion: Version,
        distribution: Distribution
    ) -> Self {
        var issues: [Issue] = []
        let controls = [
            diagnosticControl(.brightness, availability: item.controls.brightness, issues: &issues),
            diagnosticControl(.contrast, availability: item.controls.contrast, issues: &issues),
            diagnosticControl(.volume, availability: item.controls.volume, issues: &issues),
            diagnosticControl(.inputSelection, availability: item.controls.input, issues: &issues),
        ]
        if case .unavailable(let reason) = item.systemDisplay,
           let issue = diagnosticIssue(for: reason),
           !issues.contains(issue) {
            issues.append(issue)
        }
        if !item.unverifiedWrites.isEmpty,
           !issues.contains(.controlWriteUnverified) {
            issues.append(.controlWriteUnverified)
        }

        return Self(
            generatedAt: generatedAt,
            applicationVersion: applicationVersion,
            operatingSystemVersion: operatingSystemVersion,
            distribution: distribution,
            displays: [
                Display(
                    connection: .external,
                    backend: item.backend == .ddcCI ? .ddcCI : .macOSSettings,
                    screenMapping: diagnosticScreenMapping(item.systemDisplay),
                    controls: controls,
                    issues: issues
                )
            ]
        )
    }

    private static func diagnosticControl<Value: Equatable & Sendable>(
        _ kind: Control.Kind,
        availability: DisplayControlAvailability<Value>,
        issues: inout [Issue]
    ) -> Control {
        switch availability {
        case .available:
            return Control(kind: kind, state: .available)
        case .unavailable(let reason):
            if let issue = diagnosticIssue(for: reason), !issues.contains(issue) {
                issues.append(issue)
            }
            return Control(kind: kind, state: diagnosticState(for: reason))
        }
    }

    private static func diagnosticState(
        for reason: DisplayControlUnavailableReason
    ) -> Control.State {
        switch reason {
        case .notAdvertised,
             .missingCapabilitiesVersion,
             .unsupportedCapabilitiesVersion,
             .inputValuesMissing,
             .inputValuesEmpty,
             .unsupportedInputTable:
            return .unsupported
        case .liveReadFailed, .invalidLiveValue:
            return .readFailed
        default:
            return .unavailable
        }
    }

    private static func diagnosticIssue(
        for reason: DisplayControlUnavailableReason
    ) -> Issue? {
        switch reason {
        case .missingStableIdentity:
            return .missingStableIdentity
        case .duplicateStableIdentity:
            return .duplicateStableIdentity
        case .capabilitiesReadFailed:
            return .capabilitiesUnavailable
        case .capabilitiesInvalid:
            return .capabilitiesInvalid
        case .notAdvertised:
            return .controlNotAdvertised
        case .missingCapabilitiesVersion:
            return .missingProtocolVersion
        case .unsupportedCapabilitiesVersion:
            return .protocolVersionUnsupported
        case .inputValuesMissing:
            return .inputValuesMissing
        case .inputValuesEmpty:
            return .inputValuesEmpty
        case .unsupportedInputTable:
            return .inputTableUnsupported
        case .liveReadFailed:
            return .controlReadFailed
        case .invalidLiveValue:
            return .invalidControlValue
        case .systemDisplayNotFound:
            return .noScreenMatch
        case .ambiguousSystemDisplayMatch:
            return .ambiguousScreenMatch
        case .appStoreBuild:
            return .appStoreRestriction
        case .missingRegistryEndpoint:
            return .missingRegistryEndpoint
        case .duplicateRegistryEndpoint:
            return .duplicateRegistryEndpoint
        case .serviceStopped:
            return .serviceStopped
        }
    }

    private static func diagnosticScreenMapping(
        _ match: DisplaySystemDisplayMatch
    ) -> ScreenMapping {
        switch match {
        case .matched:
            return .matched
        case .unavailable(.ambiguousSystemDisplayMatch):
            return .ambiguous
        case .unavailable(.systemDisplayNotFound):
            return .unmatched
        case .unavailable:
            return .notAttempted
        }
    }
}
