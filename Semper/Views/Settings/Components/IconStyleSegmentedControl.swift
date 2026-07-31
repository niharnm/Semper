// Semper/Views/Settings/Components/IconStyleSegmentedControl.swift
import SwiftUI

/// Labeled symbol selector for `MenuBarIconStyle`.
@MainActor
struct IconStyleSegmentedControl: View {
    @Binding var selection: MenuBarIconStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuBarIconStyle.allCases) { style in
                IconOption(style: style, isSelected: selection == style) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        selection = style
                    }
                }
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DesignTokens.Colors.nextControlBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DesignTokens.Colors.nextControlBorder, lineWidth: 0.5)
        }
    }
}

private struct IconOption: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                Group {
                    if style.isSystemSymbol {
                        Image(systemName: style.iconName)
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Image(style.iconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 13, height: 13)
                    }
                }

                Text(style.displayName)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
            .frame(width: 52, height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? DesignTokens.Colors.accentPrimary.opacity(0.14)
                            : isHovered ? DesignTokens.Colors.nextControlHover : Color.clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isSelected
                            ? DesignTokens.Colors.accentPrimary.opacity(0.28)
                            : isHovered ? DesignTokens.Colors.nextControlBorder : Color.clear,
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : DesignTokens.Animation.hover) {
                isHovered = hovering
            }
        }
        .help(style.displayName)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Previews

#Preview("Icon Style Segmented Control") {
    VStack(spacing: 16) {
        IconStyleSegmentedControl(selection: .constant(.default))
        IconStyleSegmentedControl(selection: .constant(.speaker))
        IconStyleSegmentedControl(selection: .constant(.equalizer))
    }
    .padding()
    .frame(width: 300)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
