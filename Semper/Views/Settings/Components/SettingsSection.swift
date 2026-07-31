// Semper/Views/Settings/Components/SettingsSection.swift
import SwiftUI

@MainActor
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let subtitle: String?
    @ViewBuilder private let content: () -> Content

    init(
        _ title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            if let title {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(DesignTokens.Colors.accentPrimary)
                        .frame(width: 24, height: 3)

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, DesignTokens.Spacing.sm)
                .frame(width: 92, alignment: .leading)
            }

            VStack(spacing: 0) {
                content()
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DesignTokens.Dimensions.rowRadius,
                    style: .continuous
                )
            )
            .eqCardBackground()
            .frame(maxWidth: .infinity)
        }
    }
}
