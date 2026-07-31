// Semper/Views/Components/LiquidGlassSlider.swift
import SwiftUI

/// A slider using native SwiftUI Slider for Liquid Glass effect on macOS 26+
/// Styled to match the minimal track appearance of device sliders
struct LiquidGlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unityValue: Double?
    let usesBoostedFill: Bool
    let trackHeight: CGFloat
    let alwaysShowsThumb: Bool
    let onEditingChanged: ((Bool) -> Void)?

    @State private var isEditing = false
    @State private var isHovered = false

    /// Show thumb only when hovering or dragging
    private var showThumb: Bool {
        alwaysShowsThumb || isHovered || isEditing
    }

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        showUnityMarker: Bool = false,
        unityValue: Double? = nil,
        usesBoostedFill: Bool = false,
        trackHeight: CGFloat = 4,
        alwaysShowsThumb: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.unityValue = unityValue ?? (showUnityMarker
            ? range.lowerBound + ((range.upperBound - range.lowerBound) / 2)
            : nil)
        self.usesBoostedFill = usesBoostedFill
        self.trackHeight = trackHeight
        self.alwaysShowsThumb = alwaysShowsThumb
        self.onEditingChanged = onEditingChanged
    }

    private var normalizedValue: Double {
        max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    private var isBoosted: Bool {
        guard usesBoostedFill, let unityValue else { return false }
        return value > unityValue
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Custom track overlay (always visible, hides native track)
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(DesignTokens.Colors.sliderTrack)
                        .frame(height: trackHeight)

                    if isBoosted {
                        Capsule()
                            .fill(DesignTokens.Colors.boostedSliderFill)
                            .frame(width: fillWidth(in: geo.size.width), height: trackHeight)
                    } else {
                        Capsule()
                            .fill(DesignTokens.Colors.accentPrimary)
                            .frame(width: fillWidth(in: geo.size.width), height: trackHeight)
                    }
                }
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                if let unityValue {
                    let unityFraction = max(
                        0,
                        min(1, (unityValue - range.lowerBound) / (range.upperBound - range.lowerBound))
                    )
                    Rectangle()
                        .fill(DesignTokens.Colors.unityMarker)
                        .frame(width: 2, height: trackHeight + 2)
                        .offset(x: (geo.size.width * unityFraction) - 0.5)
                        .frame(maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                // Native SwiftUI Slider - gets Liquid Glass thumb on macOS 26+
                // Thumb only visible on hover/drag
                Slider(value: $value, in: range) { editing in
                    isEditing = editing
                    onEditingChanged?(editing)
                }
                .controlSize(.mini)
                .tint(.clear)  // Hide native track, we draw our own
                .opacity(showThumb ? 1 : 0.01)  // Nearly invisible when not hovered, but still interactive
            }
        }
        .frame(height: max(DesignTokens.Dimensions.sliderThumbHeight, trackHeight + 8))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        guard normalizedValue > 0 else { return 0 }
        return max(trackHeight, totalWidth * normalizedValue)
    }
}

// MARK: - Preview

#Preview("Liquid Glass Slider") {
    struct PreviewWrapper: View {
        @State private var value: Double = 0.5

        var body: some View {
            VStack(spacing: 30) {
                LiquidGlassSlider(value: $value, showUnityMarker: true)
                    .frame(width: 200)

                Text("\(Int(value * 200))%")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
