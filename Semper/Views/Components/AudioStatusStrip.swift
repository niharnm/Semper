import SwiftUI

struct AudioStatusStrip: View {
    @Bindable var store: AudioActivityStore

    var body: some View {
        if let activity = store.visibleActivity {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: activity.presentation.systemImage)
                    .foregroundStyle(DesignTokens.Colors.systemBlue)
                    .accessibilityHidden(true)

                Text(activity.presentation.message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: DesignTokens.Spacing.xs)

                if let actionTitle = activity.presentation.actionTitle {
                    Button(actionTitle) {
                        store.performVisibleAction()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.systemBlue)
                }

                Button {
                    store.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityLabel("Dismiss audio status")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(DesignTokens.Colors.nextControlBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DesignTokens.Colors.nextSectionBorder)
                    .frame(height: 1)
            }
            .accessibilityElement(children: .contain)
        }
    }
}
