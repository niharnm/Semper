// Semper/Views/Settings/Tabs/UpdatesTab.swift
import SwiftUI

@MainActor
struct UpdatesTab: View {
    @ObservedObject var updateManager: UpdateManager

    private var lastCheckDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let date = updateManager.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Version \(version) · \(formatter.localizedString(for: date, relativeTo: .now))"
        }
        return "Version \(version) · Never checked"
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticUpdatesEnabled },
            set: { updateManager.setAutomaticUpdatesEnabled($0) }
        )
    }

    private var channelDescription: String {
        guard updateManager.isConfigured else {
            return "Not configured for this build"
        }
        switch updateManager.updateChannel {
        case .stable:
            return "Tested releases recommended for most people"
        case .canary:
            return "Pre-release builds that may contain unfinished changes"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Software Updates") {
                    SettingsRow(
                        "Update channel",
                        description: channelDescription
                    ) {
                        Picker("", selection: $updateManager.updateChannel) {
                            ForEach(UpdateChannel.allCases) { channel in
                                Text(channel.title).tag(channel)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(!updateManager.isConfigured)
                    }
                    SettingsRowDivider()
                    SettingsRow(
                        "Automatic updates",
                        description: "Check for and download new versions automatically"
                    ) {
                        Toggle("", isOn: automaticUpdatesBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(!updateManager.isConfigured)
                    }
                    SettingsRowDivider()
                    SettingsRow(
                        "Last checked",
                        description: lastCheckDescription
                    ) {
                        Button("Check Now") {
                            updateManager.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!updateManager.canCheckForUpdates)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}
