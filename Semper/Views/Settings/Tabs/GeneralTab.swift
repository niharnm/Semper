// Semper/Views/Settings/Tabs/GeneralTab.swift
import SwiftUI

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let onResetAll: () -> Void

    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                behaviorSection
                interfaceSection
                dataSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { onResetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        SettingsSection("Behavior", subtitle: "When Semper runs") {
            SettingsRow(
                "Launch at Login",
                description: "Keep the mixer ready after you sign in"
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Device Disconnect Alerts",
                description: "Notify you when an active output disappears"
            ) {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Interface

    private var interfaceSection: some View {
        SettingsSection("Interface", subtitle: "How Semper shows up") {
            SettingsRow(
                "Appearance",
                description: "Follow macOS or choose a fixed look"
            ) {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
            SettingsRowDivider()
            SettingsRow(
                "Menu Bar Symbol",
                description: "Pick a mark you can recognize at a glance"
            ) {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(
                "Mixer Footprint",
                description: "Set how much room the popup gives each control"
            ) {
                PopupSizeTilePicker(selection: $settings.appSettings.popupSize)
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection("Reset", subtitle: "Back to defaults") {
            SettingsRow(
                "Reset Semper",
                description: "Clear saved volumes, EQ, and device routes"
            ) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }
}
