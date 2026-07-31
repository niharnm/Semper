// Semper/Views/Settings/Components/SettingsRow.swift
import SwiftUI

@MainActor
struct SettingsRow<Trailing: View>: View {
    private let title: String
    private let description: String?
    @ViewBuilder private let trailing: () -> Trailing

    init(
        _ title: String,
        description: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .font(DesignTokens.Typography.rowNameBold)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                if let description {
                    Text(description)
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.lg)
            trailing()
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// Hairline divider sized to fit between `SettingsRow`s inside a
/// `SettingsSection`. Inset from the leading edge so it doesn't touch the
/// container border.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, DesignTokens.Spacing.lg)
    }
}
