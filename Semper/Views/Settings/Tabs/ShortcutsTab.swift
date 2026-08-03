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

    @State private var showClearAllConfirmation = false
    @State private var showingAccessibilityGrantedFeedback = false
    @State private var accessibilityGrantedFeedbackTask: Task<Void, Never>?

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
        .onChange(of: settings.appSettings.shortcutTargetMode) { _, mode in
            guard mode == .selectedApp,
                  settings.appSettings.selectedShortcutTargetBundleID == nil,
                  let firstOption = shortcutsRegistry.targetAppOptions().first
            else { return }
            settings.appSettings.selectedShortcutTargetBundleID = firstOption.bundleID
        }
        .onChange(of: accessibility.isTrustedCached) { oldValue, newValue in
            guard !oldValue, newValue else { return }
            showAccessibilityGrantedFeedback()
        }
        .onDisappear {
            accessibilityGrantedFeedbackTask?.cancel()
            accessibilityGrantedFeedbackTask = nil
        }
        .confirmationDialog(
            "Clear all keyboard shortcuts?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                shortcutsRegistry.clearAllShortcuts()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every Semper hotkey assignment.")
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Volume Step",
                description: "How much each keypress changes the volume. Applies to media keys, configured hotkeys, and arrow-key nav in the popup."
            ) {
                volumeStepControl
            }
        }
    }

    private var volumeStepControl: some View {
        HStack(spacing: 8) {
            Picker("Volume step", selection: $settings.appSettings.volumeHotkeyStep) {
                ForEach(VolumeHotkeyStep.allCases) { step in
                    Text(step.description).tag(step)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Volume step")

            if settings.appSettings.volumeHotkeyStep == .custom {
                TextField(
                    "Percent",
                    value: customVolumePercentBinding,
                    format: .number.precision(.fractionLength(0...2))
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .accessibilityLabel("Custom volume percentage")

                Text("%")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .accessibilityHidden(true)

                Stepper(
                    "Adjust custom volume percentage",
                    value: customVolumePercentBinding,
                    in: VolumeHotkeyStep.customPercentRange,
                    step: 0.25
                )
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Adjust custom volume percentage")
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

                Toggle("Mac Volume Keys", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Mac Volume Keys")
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            .frame(minHeight: 64)

            if !accessibility.isTrustedCached || showingAccessibilityGrantedFeedback {
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
        SettingsSection("Hotkeys", subtitle: "App targets and global assignments") {
            SettingsRow(
                "App Shortcut Target",
                description: "Choose which app the volume and mute hotkeys control."
            ) {
                targetAppControl
            }

            SettingsRowDivider()

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Label("Click a field to record", systemImage: "keyboard")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
                        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm)
                    ],
                    spacing: DesignTokens.Spacing.sm
                ) {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        shortcutCard(for: action)
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)

            SettingsRowDivider()
            SettingsRow(
                "Clear All Shortcuts",
                description: "Remove every custom hotkey assignment."
            ) {
                Button("Clear All", role: .destructive) {
                    showClearAllConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!shortcutsRegistry.hasAssignedShortcuts)
            }
        }
    }

    private func shortcutCard(for action: ShortcutAction) -> some View {
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

            VStack(alignment: .trailing, spacing: 4) {
                KeyboardShortcuts.Recorder(
                    for: shortcutsRegistry.name(for: action),
                    onChange: shortcutsRegistry.recordCallback(for: action)
                )
                .controlSize(.small)

                if let conflictingAction = shortcutsRegistry.conflictingAction(for: action) {
                    Label(
                        "Already used by \(conflictingAction.displayName)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .eqCardBackground()
        .accessibilityElement(children: .contain)
    }

    private var targetAppControl: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let hasActiveAudioApps = !shortcutsRegistry.targetAppOptions().isEmpty
            Picker("Shortcut target mode", selection: $settings.appSettings.shortcutTargetMode) {
                ForEach(ShortcutTargetMode.allCases) { mode in
                    Text(mode.description).tag(mode)
                        .disabled(mode == .selectedApp && !hasActiveAudioApps)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Shortcut target mode")

            if settings.appSettings.shortcutTargetMode == .selectedApp {
                let options = shortcutsRegistry.targetAppOptions()
                Picker("Target app", selection: selectedTargetBundleIDBinding) {
                    if options.isEmpty {
                        Text("No active audio apps").tag("")
                    } else {
                        ForEach(options) { option in
                            Text(option.displayName).tag(option.bundleID)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(options.isEmpty)
                .accessibilityLabel("Target app")
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

    private var customVolumePercentBinding: Binding<Double> {
        Binding(
            get: { settings.appSettings.customVolumeHotkeyStepPercent },
            set: {
                settings.appSettings.customVolumeHotkeyStepPercent =
                    VolumeHotkeyStep.clampedCustomPercent($0)
            }
        )
    }

    private var selectedTargetBundleIDBinding: Binding<String> {
        Binding(
            get: { settings.appSettings.selectedShortcutTargetBundleID ?? "" },
            set: { settings.appSettings.selectedShortcutTargetBundleID = $0.isEmpty ? nil : $0 }
        )
    }

    private func description(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "Show or hide the menu bar popup"
        case .targetAppVolumeUp: "Raise the selected target app's volume"
        case .targetAppVolumeDown: "Lower the selected target app's volume"
        case .targetAppMuteToggle: "Mute or unmute the selected target app"
        }
    }

    private func showAccessibilityGrantedFeedback() {
        accessibilityGrantedFeedbackTask?.cancel()
        showingAccessibilityGrantedFeedback = true
        accessibilityGrantedFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            showingAccessibilityGrantedFeedback = false
            accessibilityGrantedFeedbackTask = nil
        }
    }
}
