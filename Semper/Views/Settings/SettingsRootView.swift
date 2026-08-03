// Semper/Views/Settings/SettingsRootView.swift
import AppKit
import SwiftUI

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
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
            case .general: "Choose how Semper starts, looks, and lives in your menu bar"
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
        VStack(spacing: 0) {
            navigationBar

            Divider()

            detail
        }
        .toolbarVisibility(.hidden)
        .frame(width: 860, height: 610)
        .tint(DesignTokens.Colors.accentPrimary)
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .popupGlassBackground()
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
        .background(WindowTitleBridge(title: "\(selection.title) · Semper"))
    }

    private var navigationBar: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Semper")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Text("SETTINGS")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Section.allCases) { section in
                    SettingsNavigationButton(
                        section: section,
                        isSelected: selection == section,
                        onSelect: { selectionBinding.wrappedValue = section }
                    )
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(height: 66)
        .background(DesignTokens.Colors.nextMasterBackground)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            selectedPane
        }
    }

    private var paneHeader: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))

                Image(systemName: selection.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
            }
            .frame(width: 44, height: 44)
            .overlay {
                Circle()
                    .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.2), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(selection.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(selection.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer(minLength: 0)

            Text(panePosition)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
        .padding(.horizontal, DesignTokens.Spacing.xxl)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.md)
    }

    private var panePosition: String {
        let index = (Section.allCases.firstIndex(of: selection) ?? 0) + 1
        return String(format: "%02d / %02d", index, Section.allCases.count)
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selection {
        case .general:
            GeneralTab(
                settings: settings,
                onResetAll: {
                    audioEngine.handleSettingsReset()
                    deviceVolumeMonitor.setSystemFollowDefault()
                }
            )
        case .audio:
            AudioTab(
                settings: settings,
                audioEngine: audioEngine,
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

private struct SettingsNavigationButton: View {
    let section: SettingsRootView.Section
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(
                isSelected
                    ? DesignTokens.Colors.accentPrimary
                    : DesignTokens.Colors.textSecondary
            )
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? DesignTokens.Colors.accentPrimary.opacity(0.13)
                            : isHovered ? DesignTokens.Colors.nextControlHover : Color.clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? DesignTokens.Colors.accentPrimary.opacity(0.3)
                            : Color.clear,
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : DesignTokens.Animation.hover) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
