// Semper/Views/Settings/SettingsRootView.swift
import AppKit
import SwiftUI

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    let audioCommands: any AudioCommandDispatching
    @Bindable var callMode: CallModeCoordinator
    @Bindable var bluetoothHDGuard: BluetoothHDGuardCoordinator
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry
    @ObservedObject var updateManager: UpdateManager

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case general, audio, shortcuts, updates, about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .audio: "Audio"
            case .shortcuts: "Shortcuts"
            case .updates: "Updates"
            case .about: "About"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "Startup, appearance, and menu bar"
            case .audio: "Volume, processing, and device behavior"
            case .shortcuts: "Media keys, HUD, and global hotkeys"
            case .updates: "Version and automatic update settings"
            case .about: "Version, links, and project information"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .audio: "speaker.wave.2"
            case .shortcuts: "command"
            case .updates: "arrow.triangle.2.circlepath"
            case .about: "info.circle"
            }
        }
    }

    @AppStorage("settings.selectedSection") private var storedSelection = Section.general.rawValue

    private var selection: Section {
        Section(rawValue: storedSelection) ?? .general
    }

    private var selectionBinding: Binding<Section> {
        Binding(
            get: { selection },
            set: { storedSelection = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarVisibility(.hidden)
        .frame(width: 780, height: 560)
        .tint(DesignTokens.Colors.accentPrimary)
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
        .background(WindowTitleBridge(title: "Semper Settings"))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text("Semper")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Text("Settings")
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)

            Divider()

            List(selection: selectionBinding) {
                ForEach(Section.allCases) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 18)
                    }
                    .font(DesignTokens.Typography.rowName)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background {
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
        }
        .navigationSplitViewColumnWidth(min: 178, ideal: 190, max: 210)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            selectedPane
        }
        .popupGlassBackground()
    }

    private var paneHeader: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius, style: .continuous)
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.14))

                Image(systemName: selection.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
            }
            .frame(width: 38, height: 38)
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.2), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(selection.subtitle)
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.nextMasterBackground)
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selection {
        case .general:
            GeneralTab(
                settings: settings,
                onResetAll: {
                    callMode.shutdown()
                    bluetoothHDGuard.shutdown()
                    audioEngine.handleSettingsReset()
                    deviceVolumeMonitor.setSystemFollowDefault()
                }
            )
        case .audio:
            AudioTab(
                settings: settings,
                audioEngine: audioEngine,
                audioCommands: audioCommands,
                callMode: callMode,
                bluetoothHDGuard: bluetoothHDGuard,
                deviceVolumeMonitor: deviceVolumeMonitor
            )
        case .shortcuts:
            ShortcutsTab(
                settings: settings,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry
            )
        case .updates:
            UpdatesTab(updateManager: updateManager)
        case .about:
            AboutTab()
        }
    }
}
