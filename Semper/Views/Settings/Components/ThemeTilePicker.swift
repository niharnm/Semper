// Semper/Views/Settings/Components/ThemeTilePicker.swift
import SwiftUI

@MainActor
struct ThemeTilePicker: View {
    @Binding var selection: AppearancePreference

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppearancePreference.allCases) { preference in
                AppearanceOption(
                    preference: preference,
                    isSelected: selection == preference,
                    onTap: { selection = preference }
                )
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

private struct AppearanceOption: View {
    let preference: AppearancePreference
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(preference.description)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(
                isSelected
                    ? DesignTokens.Colors.accentPrimary
                    : DesignTokens.Colors.textSecondary
            )
            .padding(.horizontal, 10)
            .frame(height: 30)
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
                    .strokeBorder(
                        isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.28) : Color.clear,
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : DesignTokens.Animation.hover) {
                isHovered = hovering
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(preference.description))
        .accessibilityHint("Changes Semper's appearance")
    }

    private var iconName: String {
        switch preference {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.stars.fill"
        }
    }
}

// MARK: - Popup size tile picker

@MainActor
struct PopupSizeTilePicker: View {
    @Binding var selection: MenuBarPopupSize

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuBarPopupSize.allCases) { size in
                PopupFootprintOption(
                    size: size,
                    isSelected: selection == size,
                    onTap: { selection = size }
                )
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

private struct PopupFootprintOption: View {
    let size: MenuBarPopupSize
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Capsule()
                        .fill(
                            isSelected
                                ? DesignTokens.Colors.accentPrimary
                                : DesignTokens.Colors.textTertiary
                        )
                        .frame(width: indicatorWidth, height: 3)

                    Text(size.description)
                        .font(.system(size: 10, weight: .semibold))
                }

                Text("\(Int(size.dimensions.width)) pt")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .foregroundStyle(
                isSelected
                    ? DesignTokens.Colors.accentPrimary
                    : DesignTokens.Colors.textSecondary
            )
            .padding(.horizontal, 9)
            .frame(width: 104, height: 38, alignment: .leading)
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
                    .strokeBorder(
                        isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.28) : Color.clear,
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : DesignTokens.Animation.hover) {
                isHovered = hovering
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(size.description))
        .accessibilityHint("Changes the menu bar popup size")
    }

    private var indicatorWidth: CGFloat {
        switch size {
        case .compact:
            return 12
        case .comfortable:
            return 18
        case .spacious:
            return 24
        }
    }
}

#Preview("Popup Size Tiles") {
    @Previewable @State var size: MenuBarPopupSize = .comfortable
    VStack(alignment: .leading, spacing: 16) {
        ThemeTilePicker(selection: .constant(.system))
        PopupSizeTilePicker(selection: $size)
    }
    .padding(20)
    .darkGlassBackground()
}
