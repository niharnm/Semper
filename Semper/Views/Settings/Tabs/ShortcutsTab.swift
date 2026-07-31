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
            Picker("", selection: $settings.appSettings.volumeHotkeyStep) {
                ForEach(VolumeHotkeyStep.allCases) { step in
                    Text(step.description).tag(step)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            if settings.appSettings.volumeHotkeyStep == .custom {
                TextField(
                    "Percent",
                    value: customVolumePercentBinding,
                    format: .number.precision(.fractionLength(0...2))
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 48)

                Text("%")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                Stepper(
                    "",
                    value: customVolumePercentBinding,
                    in: VolumeHotkeyStep.customPercentRange,
                    step: 0.25
                )
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("Media Keys") {
            SettingsRow(
                "Media Keys Control",
                description: "Use F11/F12 (or volume keys) to control Semper"
            ) {
                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if !accessibility.isTrustedCached {
                SettingsRowDivider()
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if mediaKeyStatus.isOffline {
                SettingsRowDivider()
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
        SettingsSection("Hotkeys") {
            SettingsRow(
                "App Shortcut Target",
                description: "Choose which app the volume and mute hotkeys control."
            ) {
                targetAppControl
            }
            SettingsRowDivider()

            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(
                    action.displayName,
                    description: description(for: action)
                ) {
                    VStack(alignment: .trailing, spacing: 4) {
                        KeyboardShortcuts.Recorder(
                            for: shortcutsRegistry.name(for: action),
                            onChange: shortcutsRegistry.recordCallback(for: action)
                        )

                        if let conflictingAction = shortcutsRegistry.conflictingAction(for: action) {
                            Label(
                                "Already used by \(conflictingAction.displayName)",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(DesignTokens.Typography.rowDescription)
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }

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

    private var targetAppControl: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("", selection: $settings.appSettings.shortcutTargetMode) {
                ForEach(ShortcutTargetMode.allCases) { mode in
                    Text(mode.description).tag(mode)
                        .disabled(mode == .selectedApp && shortcutsRegistry.targetAppOptions().isEmpty)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            if settings.appSettings.shortcutTargetMode == .selectedApp {
                let options = shortcutsRegistry.targetAppOptions()
                Picker("", selection: selectedTargetBundleIDBinding) {
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
            }
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
        case .targetAppVolumeUp: "Raise volume for the app playing audio"
        case .targetAppVolumeDown: "Lower volume for the app playing audio"
        case .targetAppMuteToggle: "Mute or unmute the app playing audio"
        }
    }
}
