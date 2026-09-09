import Foundation

struct AwakeSessionPresentation: Equatable {
    let reason: String
    let remainingText: String
    let remainingAccessibilityText: String

    init(session: AwakeSession, now: Date) {
        reason = session.reason.isEmpty ? "Manual Awake session" : session.reason
        guard let endsAt = session.endsAt else {
            remainingText = "No time limit"
            remainingAccessibilityText = "No time limit. Ends when you turn it off or a stop condition is met."
            return
        }

        let seconds = Int(max(0, ceil(endsAt.timeIntervalSince(now))))
        guard seconds > 0 else {
            remainingText = "Time elapsed"
            remainingAccessibilityText = "The session time has elapsed."
            return
        }

        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        remainingText = hours > 0
            ? String(format: "%d:%02d:%02d remaining", hours, minutes, remainder)
            : String(format: "%d:%02d remaining", minutes, remainder)

        let components = [(hours, "hour"), (minutes, "minute"), (remainder, "second")]
            .filter { $0.0 > 0 }
            .map { value, unit in "\(value) \(unit)\(value == 1 ? "" : "s")" }
        remainingAccessibilityText = components.joined(separator: ", ") + " remaining"
    }

    static func batteryStatus(_ snapshot: AwakeConditionSnapshot?) -> String {
        guard let snapshot else {
            return "Battery state is checked when the session starts."
        }
        switch snapshot.battery {
        case .unknown:
            return "Battery state unknown. Awake needs a reading to use the cutoff."
        case .noBattery:
            return "No battery detected; cutoff does not apply."
        case .externalPower(let percentage):
            if let percentage {
                return "Plugged in, battery \(percentage)%. Cutoff is ignored."
            }
            return "Plugged in. Battery percentage unknown; cutoff is ignored."
        case .battery(let percentage):
            return "On battery, \(percentage)%."
        }
    }

    static func endReasonText(_ reason: AwakeSessionEndReason) -> String {
        switch reason {
        case .selectedApplicationExited(let name):
            return "\(name) is no longer running. Manual session ended."
        case .batteryThresholdReached(let percentage):
            return "Battery is at or below \(percentage)%. Manual session ended."
        case .batteryStateUnavailable:
            return "Battery state is unavailable. Manual Awake needs a reading for this cutoff."
        case .conditionMonitoringUnavailable:
            return "Awake could not watch the selected stop conditions."
        case .expired:
            return "The timed Awake session ended."
        }
    }

    static func leaseOwners(
        _ states: [AwakeLeaseOwner: AwakeLeaseState], manualSessionActive: Bool
    ) -> String? {
        let owners: [(AwakeLeaseOwner, String)] = [
            (.awayMode, "Away"), (.scene, "Scenes"), (.presentation, "Presentation")
        ]
        let names = owners.filter { states[$0.0] != nil }.map(\.1)
        guard !names.isEmpty else { return nil }
        let prefix = manualSessionActive ? "Also kept awake by " : "Kept awake by "
        return prefix + names.joined(separator: ", ") + "."
    }
}
