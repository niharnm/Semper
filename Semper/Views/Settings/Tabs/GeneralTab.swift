// Semper/Views/Settings/Tabs/GeneralTab.swift
import SwiftUI
import UserNotifications

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let onResetAll: () -> Void

    @State private var showResetConfirmation = false
    @State private var notificationMessage: String?

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
                Toggle("", isOn: Binding(
                    get: { settings.appSettings.showDeviceDisconnectAlerts },
                    set: { enabled in
                        settings.appSettings.showDeviceDisconnectAlerts = enabled
                        guard enabled else { notificationMessage = nil; return }
                        Task {
                            do {
                                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                                notificationMessage = granted ? nil : "Notifications are denied. Allow Semper notifications in System Settings to receive device alerts."
                            } catch {
                                notificationMessage = "Notification access could not be requested: \(error.localizedDescription)"
                            }
                        }
                    }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if let notificationMessage {
                Text(notificationMessage).font(.caption).foregroundStyle(.secondary)
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

    // MARK: - Reset

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
