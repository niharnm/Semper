// Semper/Views/Settings/Components/VolumeSlider.swift
import SwiftUI

/// Trailing-slot volume slider for `CardRow`. Pairs a SwiftUI `Slider` with
/// the existing `EditablePercentage` field so users can either drag or type.
@MainActor
struct VolumeSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let width: CGFloat

    init(_ value: Binding<Float>, range: ClosedRange<Float> = 0...1, width: CGFloat = 160) {
        self._value = value
        self.range = range
        self.width = width
    }

    private var percentageRange: ClosedRange<Int> {
        Int(round(range.lowerBound * 100))...Int(round(range.upperBound * 100))
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .frame(width: width)

            EditablePercentage(
                percentage: Binding(
                    get: { Int(round(value * 100)) },
                    set: { value = Float($0) / 100.0 }
                ),
                range: percentageRange
            )
            .frame(width: DesignTokens.Dimensions.settingsPercentageWidth, alignment: .trailing)
        }
    }
}

// MARK: - Previews

#Preview("Volume Slider") {
    VStack(spacing: 16) {
        VolumeSlider(.constant(0.5))
        VolumeSlider(.constant(0.8), range: 0.1...1.0, width: 200)
    }
    .padding()
    .frame(width: 400)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
