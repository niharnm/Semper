import SwiftUI

nonisolated enum AudioAccessibility {
    static func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) percent"
    }

    static func adjustedValue(
        _ value: Double,
        direction: AccessibilityAdjustmentDirection,
        step: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let candidate: Double
        switch direction {
        case .increment:
            candidate = value + step
        case .decrement:
            candidate = value - step
        @unknown default:
            candidate = value
        }
        return max(range.lowerBound, min(range.upperBound, candidate))
    }
}
