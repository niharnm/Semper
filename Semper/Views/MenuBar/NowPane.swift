import SwiftUI

@MainActor
struct NowPane: View {
    @Bindable var sceneManager: SceneManager
    @State private var showsKeepCurrentConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sceneSection
            statusSection
        }
        .confirmationDialog(
            "Keep the current setup?",
            isPresented: $showsKeepCurrentConfirmation,
            titleVisibility: .visible
        ) {
            Button("Keep Current", role: .destructive) {
                sceneManager.keepCurrentSetup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Semper will remove the saved restore point. Current settings will not change.")
        }
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                SectionHeader(title: "Scenes")

                Spacer()

                if sceneManager.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Applying scene")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.md)

            if sceneManager.scenes.isEmpty {
                emptyScenes
            } else {
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    ForEach(sceneManager.scenes) { scene in
                        Button {
                            sceneManager.apply(scene: scene)
                        } label: {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                Image(systemName: "circle.grid.2x2.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                    Text(scene.name)
                                        .font(DesignTokens.Typography.rowName)
                                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                                        .lineLimit(1)

                                    Text(actionSummary(for: scene))
                                        .font(DesignTokens.Typography.caption)
                                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: DesignTokens.Spacing.sm)

                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverableRow()
                        .disabled(sceneManager.isBusy)
                        .accessibilityLabel("Apply \(scene.name) scene")
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.sm)
            }

            if sceneManager.hasPendingRestore {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        sceneManager.restore()
                    } label: {
                        Label("Restore Previous Setup", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sceneManager.isBusy)
                    .accessibilityHint("Restores settings changed by the active scene when they have not drifted")

                    Button {
                        showsKeepCurrentConfirmation = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sceneManager.isBusy)
                    .accessibilityLabel("Keep current setup")
                    .accessibilityHint("Removes the saved restore point without changing settings")
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.md)
            }
        }
    }

    private var emptyScenes: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("No saved scenes")
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text("Create one in Settings to recall a complete setup.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    @ViewBuilder
    private var statusSection: some View {
        if let message = sceneManager.statusMessage {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "info.circle")
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.md)
            .accessibilityElement(children: .combine)
        }
    }

    private func actionSummary(for scene: SemperScene) -> String {
        let count = scene.actions.count
        return count == 1 ? "1 setting" : "\(count) settings"
    }
}
