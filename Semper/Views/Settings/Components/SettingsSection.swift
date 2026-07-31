// Semper/Views/Settings/Components/SettingsSection.swift
import SwiftUI

@MainActor
struct SettingsSection<Content: View>: View {
    private let title: String?
    @ViewBuilder private let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if let title {
                SectionHeader(title: title)
                    .padding(.horizontal, 4)
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
        }
    }
}
