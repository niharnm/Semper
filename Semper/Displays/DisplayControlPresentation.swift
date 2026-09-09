import Foundation

nonisolated enum DisplayManualControlDispatchPolicy {
    @MainActor
    static func allowsDispatch(
        sceneOperationIsInProgress: @MainActor () -> Bool,
        isPending: Bool
    ) -> Bool {
        !sceneOperationIsInProgress() && !isPending
    }
}

nonisolated enum DisplaySliderDraftPolicy {
    static func preservesDraft(
        isPending: Bool,
        isEditing: Bool,
        isLinkedToActiveEdit: Bool
    ) -> Bool {
        isPending || isEditing || isLinkedToActiveEdit
    }

    static func synchronizedValue(
        published: Double?,
        draft: Double?,
        preservesDraft: Bool
    ) -> Double? {
        if preservesDraft, let draft {
            return draft
        }
        return published
    }
}

nonisolated enum DisplayVolumeLabel {
    static func text(reading: DisplayVolumeReading, draft: Double?) -> String {
        if let draft {
            return "\(Int((draft * 100).rounded()))%"
        }
        if reading.encoding == .continuousSubrange {
            if reading.current == 0 { return "Default" }
            if reading.current == 0xFF { return "Muted" }
        }
        return "\(Int(((reading.normalized ?? 0) * 100).rounded()))%"
    }
}

nonisolated enum DisplayInputLabel {
    static func text(for value: UInt8) -> String {
        switch value {
        case 0x01: return "VGA 1"
        case 0x02: return "VGA 2"
        case 0x03: return "DVI 1"
        case 0x04: return "DVI 2"
        case 0x05: return "Composite 1"
        case 0x06: return "Composite 2"
        case 0x07: return "S-Video 1"
        case 0x08: return "S-Video 2"
        case 0x09: return "Tuner 1"
        case 0x0A: return "Tuner 2"
        case 0x0B: return "Tuner 3"
        case 0x0C: return "Component 1"
        case 0x0D: return "Component 2"
        case 0x0E: return "Component 3"
        case 0x0F: return "DisplayPort 1"
        case 0x10: return "DisplayPort 2"
        case 0x11: return "HDMI 1"
        case 0x12: return "HDMI 2"
        default: return "Input 0x\(String(format: "%02X", value))"
        }
    }
}

nonisolated enum DisplayGroupStatusFormatter {
    static func message(
        controlName: String,
        report: DisplayGroupWriteReport,
        displayNames: [DisplayIdentity: String]
    ) -> String {
        let outcomes = report.outcomes.map { outcome in
            let name = displayNames[outcome.identity] ?? "Disconnected display"
            return "\(name): \(status(for: outcome.result))"
        }
        return "\(controlName): \(outcomes.joined(separator: "; "))."
    }

    private static func status(for result: DisplayGroupTargetResult) -> String {
        switch result {
        case .feature(.applied), .volume(.applied), .input(.applied):
            return "confirmed"
        case .feature(.unavailable):
            return "unavailable"
        case .volume(.unavailable(let reason)), .input(.unavailable(let reason)):
            return "unavailable, \(reason.message)"
        case .feature(.invalidTarget), .volume(.invalidTarget), .input(.invalidTarget):
            return "invalid value"
        case .feature(.failed), .volume(.failed):
            return "not confirmed"
        case .input(.unconfirmed):
            return "attempted once, not confirmed"
        case .cancelled:
            return "cancelled"
        case .failed:
            return "failed"
        case .notAttempted:
            return "not attempted"
        }
    }
}
