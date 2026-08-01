// Semper/Views/Settings/Components/AboutLinkChip.swift
import AppKit
import SwiftUI

/// Pill-shaped link button used on the About tab.
///
/// Two variants:
/// - Default (outlined): icon swaps to filled `hoverIcon` in `hoverColor` on hover.
/// - `isPrimary`: icon is always filled in `hoverColor` and the capsule has a tinted
///   fill so the chip reads as the page's primary action.
@MainActor
struct AboutLinkChip: View {
    let label: String
    let icon: String
    let hoverIcon: String
    let hoverColor: Color
    let url: URL
    var isPrimary: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var resolvedIcon: String {
        isPrimary || isHovered ? hoverIcon : icon
    }

    private var resolvedIconColor: Color {
        isPrimary || isHovered ? hoverColor : DesignTokens.Colors.textSecondary
    }

    private var resolvedTextColor: Color {
        isPrimary || isHovered ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
    }

    private var resolvedFill: Color {
        if isPrimary {
            return hoverColor.opacity(isHovered ? 0.18 : 0.12)
        }
        return isHovered ? Color.white.opacity(0.06) : Color.clear
    }

    private var resolvedBorder: Color {
        if isPrimary {
            return hoverColor.opacity(isHovered ? 0.55 : 0.35)
        }
        return isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: resolvedIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(resolvedIconColor)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(resolvedTextColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(resolvedFill)
            )
            .overlay(
                Capsule().strokeBorder(resolvedBorder, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Previews

#Preview("About Link Chip") {
    HStack(spacing: 8) {
        AboutLinkChip(
            label: "Website",
            icon: "globe",
            hoverIcon: "globe",
            hoverColor: .blue,
            url: DesignTokens.Links.website,
            isPrimary: true
        )
        AboutLinkChip(
            label: "Apache-2.0",
            icon: "doc.text",
            hoverIcon: "doc.text.fill",
            hoverColor: .orange,
            url: DesignTokens.Links.license
        )
    }
    .padding(24)
    .frame(width: 520, height: 80)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
