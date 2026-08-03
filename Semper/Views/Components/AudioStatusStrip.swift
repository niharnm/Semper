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
                    .help(activity.presentation.message)
                    .accessibilityIdentifier("audio-status-message")

                Spacer(minLength: DesignTokens.Spacing.xs)

                if let actionTitle = activity.presentation.actionTitle {
                    actionButton(actionTitle)
                }

                Button {
                    store.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityLabel(
                    activity.presentation.actionTitle == "Undo"
                        ? "Dismiss undo"
                        : "Dismiss audio status"
                )
                .accessibilityHint(
                    activity.presentation.actionTitle == "Undo"
                        ? "Discards the visible undo action."
                        : "Hides this audio status."
                )
                .accessibilityIdentifier("audio-status-dismiss")
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
            .accessibilityIdentifier("audio-status-strip")
        }
    }

    @ViewBuilder
    private func actionButton(_ actionTitle: String) -> some View {
        let button = Button(actionTitle) {
            store.performVisibleAction()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(DesignTokens.Colors.systemBlue)
        .accessibilityLabel(
            actionTitle == "Undo" ? "Undo last audio change" : "End Call Mode"
        )
        .accessibilityHint(
            actionTitle == "Undo"
                ? "Restores the previous audio setting. Available for 30 seconds."
                : "Restores the audio settings from before Call Mode."
        )
        .accessibilityIdentifier(
            actionTitle == "Undo" ? "audio-undo-button" : "call-mode-end"
        )

        if actionTitle == "Undo" {
            button.keyboardShortcut("z", modifiers: .command)
        } else {
            button
        }
    }
}
