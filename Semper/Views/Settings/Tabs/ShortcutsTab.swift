// Semper/Views/Settings/Tabs/ShortcutsTab.swift
import SwiftUI
import KeyboardShortcuts

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                mediaKeysSection
                hotkeysSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Volume Step",
                description: "How much each keypress changes the volume. Applies to media keys, configured hotkeys, and arrow-key nav in the popup."
            ) {
                Picker("", selection: $settings.appSettings.volumeHotkeyStep) {
                    ForEach(VolumeHotkeyStep.allCases) { step in
                        Text(step.description).tag(step)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("Media Keys") {
            HStack(spacing: DesignTokens.Spacing.md) {
                settingsIcon("speaker.wave.2.fill")

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text("Mac Volume Keys")
                        .font(DesignTokens.Typography.rowNameBold)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    Text("Use F10, F11, and F12 for the default output device")
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Spacing.md)

                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            .frame(minHeight: 64)

            if !accessibility.isTrustedCached {
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.bottom, DesignTokens.Spacing.md)
            }

            if mediaKeyStatus.isOffline {
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.md)
            }

            if settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                SettingsRowDivider()
                SettingsRow(
                    "HUD Style",
                    description: "How the volume indicator appears"
                ) {
                    HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Hotkeys")

                Spacer(minLength: DesignTokens.Spacing.sm)

                Label("Click a field to record", systemImage: "keyboard")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
                    GridItem(.flexible(), spacing: DesignTokens.Spacing.sm)
                ],
                spacing: DesignTokens.Spacing.sm
            ) {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                            settingsIcon(systemImage(for: action))

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                Text(action.displayName)
                                    .font(DesignTokens.Typography.rowName)
                                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                                Text(description(for: action))
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer(minLength: 0)

                        HStack {
                            Spacer(minLength: 0)

                            KeyboardShortcuts.Recorder(
                                for: shortcutsRegistry.name(for: action),
                                onChange: shortcutsRegistry.recordCallback(for: action)
                            )
                            .controlSize(.small)
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .eqCardBackground()
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func settingsIcon(_ systemImage: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))

            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.accentPrimary)
        }
        .frame(width: 32, height: 32)
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func systemImage(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "macwindow.on.rectangle"
        case .targetAppVolumeUp: "speaker.wave.3.fill"
        case .targetAppVolumeDown: "speaker.wave.1.fill"
        case .targetAppMuteToggle: "speaker.slash.fill"
        }
    }

    private func description(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "Show or hide the menu bar popup"
        case .targetAppVolumeUp: "Raise volume for the app playing audio"
        case .targetAppVolumeDown: "Lower volume for the app playing audio"
        case .targetAppMuteToggle: "Mute or unmute the app playing audio"
        }
    }
}
