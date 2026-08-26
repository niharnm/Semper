import SwiftUI

struct CallModePromptStrip: View {
    @Bindable var callMode: CallModeCoordinator

    var body: some View {
        if let prompt = callMode.pendingPrompt {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "phone")
                    .foregroundStyle(DesignTokens.Colors.systemBlue)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Call detected in \(prompt.displayName)")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                    Text("Lower other apps to 25%?")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.Spacing.xs)

                Button("Start Once") {
                    callMode.respond(.startOnce)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .accessibilityLabel("Start Call Mode once for \(prompt.displayName)")
                .accessibilityIdentifier("call-mode-start-once")

                Button("Not Now") {
                    callMode.respond(.notNow)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Do not start Call Mode for this \(prompt.displayName) call")
                .accessibilityIdentifier("call-mode-not-now")

                Menu {
                    Button("Always") { callMode.respond(.always) }
                    Button("Never") { callMode.respond(.never) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Remember Call Mode choice for \(prompt.displayName)")
                .accessibilityIdentifier("call-mode-remember")
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
            .accessibilityIdentifier("call-mode-prompt")
        }
    }
}
