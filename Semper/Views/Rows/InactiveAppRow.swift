// Semper/Views/Rows/InactiveAppRow.swift
import SwiftUI

/// A row displaying a pinned but inactive app (not currently producing audio).
/// Similar to AppRow but:
/// - Uses PinnedAppInfo instead of AudioApp
/// - VU meter always shows 0 (no audio level polling)
/// - Slightly dimmed appearance to indicate inactive state
/// - All settings (volume/mute/EQ/device) work normally and are persisted
struct InactiveAppRow: View {
    let appInfo: PinnedAppInfo
    let icon: NSImage
    let usesFallbackIcon: Bool
    let volume: Float  // Linear gain 0-1 (boost applied separately)
    let devices: [AudioDevice]
    let deviceIconOverrides: [String: String]
    let selectedDeviceUID: String?
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let isMuted: Bool
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onAppActivate: () -> Bool
    let eqSettings: EQSettings
    let userPresets: [UserEQPreset]
    let onEQChange: (EQSettings) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let isFocused: Bool

    @State private var localEQSettings: EQSettings
    @State private var isRowHovered = false

    init(
        appInfo: PinnedAppInfo,
        icon: NSImage,
        usesFallbackIcon: Bool = false,
        volume: Float,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        selectedDeviceUID: String?,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        isMuted: Bool = false,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onAppActivate: @escaping () -> Bool = { false },
        eqSettings: EQSettings = EQSettings(),
        userPresets: [UserEQPreset] = [],
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        onUserPresetSelected: @escaping (UserEQPreset) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        isFocused: Bool = false
    ) {
        self.appInfo = appInfo
        self.icon = icon
        self.usesFallbackIcon = usesFallbackIcon
        self.volume = volume
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.isMuted = isMuted
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onAppActivate = onAppActivate
        self.eqSettings = eqSettings
        self.userPresets = userPresets
        self.onEQChange = onEQChange
        self.onUserPresetSelected = onUserPresetSelected
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.isFocused = isFocused
        self._localEQSettings = State(initialValue: eqSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded, isFocused: isFocused) {
            HStack(spacing: 9) {
                AppIdentityButton(
                    icon: icon,
                    name: appInfo.displayName,
                    pid: nil,
                    bundleID: appInfo.bundleID,
                    usesFallbackIcon: usesFallbackIcon,
                    isProducingAudio: false,
                    onActivate: onAppActivate
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(appInfo.displayName)
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                            .help(appInfo.displayName)
                            .foregroundStyle(DesignTokens.Colors.textPrimary)

                        if boost.isBoosted {
                            Text("\(Int(boost.rawValue * 100))% Boost")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(DesignTokens.Colors.systemOrange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(DesignTokens.Colors.systemOrange.opacity(0.18))
                                }
                        }
                    }

                    let routingSubtitle = DevicePicker.routingSubtitle(
                        devices: devices,
                        selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
                        selectedDeviceUIDs: selectedDeviceUIDs,
                        isFollowingDefault: isFollowingDefault,
                        defaultDeviceUID: defaultDeviceUID,
                        mode: deviceSelectionMode
                    )
                    Text(routingSubtitle ?? "Pinned · Not playing")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                AppRowControls(
                    appName: appInfo.displayName,
                    volume: volume,
                    isMuted: isMuted,
                    devices: devices,
                    deviceIconOverrides: deviceIconOverrides,
                    selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
                    selectedDeviceUIDs: selectedDeviceUIDs,
                    isFollowingDefault: isFollowingDefault,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: deviceSelectionMode,
                    routeLifecycle: nil,
                    boost: boost,
                    isEQExpanded: isEQExpanded,
                    onVolumeChange: onVolumeChange,
                    onMuteChange: onMuteChange,
                    onBoostChange: onBoostChange,
                    onDeviceSelected: onDeviceSelected,
                    onDevicesSelected: onDevicesSelected,
                    onDeviceModeChange: onDeviceModeChange,
                    onSelectFollowDefault: onSelectFollowDefault,
                    onEQToggle: onEQToggle,
                    isRowFocused: isFocused,
                    showsOptions: isRowHovered
                )
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
            .opacity(0.6)
        } expandedContent: {
            // EQ panel
            EQPanelView(
                settings: $localEQSettings,
                userPresets: userPresets,
                onPresetSelected: { preset in
                    localEQSettings = preset.settings
                    onEQChange(preset.settings)
                },
                onUserPresetSelected: { userPreset in
                    localEQSettings = userPreset.settings
                    onUserPresetSelected(userPreset)
                },
                onSettingsChanged: { settings in
                    onEQChange(settings)
                },
                onSavePreset: onSavePreset,
                onDeleteUserPreset: onDeleteUserPreset,
                onRenameUserPreset: onRenameUserPreset
            )
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .onChange(of: eqSettings) { _, newValue in
            localEQSettings = newValue
        }
        .onHover { isRowHovered = $0 }
    }
}
