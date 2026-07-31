// Semper/Views/Rows/AppRow.swift
import SwiftUI

/// A row displaying an app with volume controls and VU meter
/// Used in the Apps section
struct AppRow: View {
    let app: AudioApp
    let volume: Float  // Linear gain 0-1 (boost applied separately)
    let audioLevel: Float
    let devices: [AudioDevice]
    let deviceIconOverrides: [String: String]
    let selectedDeviceUID: String  // For single mode
    let selectedDeviceUIDs: Set<String>  // For multi mode
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let routeLifecycle: AppRouteLifecycle?
    let isMutedExternal: Bool  // Mute state from AudioEngine
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void  // Single mode
    let onDevicesSelected: (Set<String>) -> Void  // Multi mode
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

    @State private var isRowHovered = false
    @State private var localEQSettings: EQSettings

    init(
        app: AudioApp,
        volume: Float,
        audioLevel: Float = 0,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        selectedDeviceUID: String,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        routeLifecycle: AppRouteLifecycle? = nil,
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
        self.app = app
        self.volume = volume
        self.audioLevel = audioLevel
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.routeLifecycle = routeLifecycle
        self.isMutedExternal = isMuted
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
        // Initialize local EQ state for reactive UI updates
        self._localEQSettings = State(initialValue: eqSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded, isFocused: isFocused) {
            HStack(spacing: 9) {
                AppIdentityButton(
                    icon: app.icon,
                    name: app.name,
                    pid: app.id,
                    bundleID: app.bundleID,
                    usesFallbackIcon: app.usesFallbackIcon,
                    isProducingAudio: true,
                    onActivate: onAppActivate
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(app.name)
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                            .help(app.name)

                        if audioLevel > 0.015 && !isMutedExternal {
                            Circle()
                                .fill(DesignTokens.Colors.systemGreen)
                                .frame(width: 5, height: 5)
                        }

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
                        selectedDeviceUID: selectedDeviceUID,
                        selectedDeviceUIDs: selectedDeviceUIDs,
                        isFollowingDefault: isFollowingDefault,
                        defaultDeviceUID: defaultDeviceUID,
                        mode: deviceSelectionMode,
                        lifecycle: routeLifecycle
                    )
                    Text(
                        app.usesFallbackIcon
                            ? "PID \(app.id) · \(routingSubtitle ?? "Active audio")"
                            : (routingSubtitle ?? "Active audio")
                    )
                        .font(.system(size: 10))
                        .foregroundStyle(
                            app.usesFallbackIcon
                                ? DesignTokens.Colors.systemOrange
                                : DesignTokens.Colors.textSecondary
                        )
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                AppRowControls(
                    appName: app.name,
                    volume: volume,
                    isMuted: isMutedExternal,
                    devices: devices,
                    deviceIconOverrides: deviceIconOverrides,
                    selectedDeviceUID: selectedDeviceUID,
                    selectedDeviceUIDs: selectedDeviceUIDs,
                    isFollowingDefault: isFollowingDefault,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: deviceSelectionMode,
                    routeLifecycle: routeLifecycle,
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
        } expandedContent: {
            // EQ panel - shown when expanded
            // SwiftUI calculates natural height via conditional rendering
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

// MARK: - Previews

#Preview("App Row") {
    PreviewContainer {
        VStack(spacing: 4) {
            AppRow(
                app: MockData.sampleApps[0],
                volume: 1.0,
                audioLevel: 0.65,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[0].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )

            AppRow(
                app: MockData.sampleApps[1],
                volume: 0.5,
                audioLevel: 0.25,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[1].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )

            AppRow(
                app: MockData.sampleApps[2],
                volume: 1.5,
                audioLevel: 0.85,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[2].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )
        }
    }
}

#Preview("App Row - Multiple Apps") {
    PreviewContainer {
        VStack(spacing: 4) {
            ForEach(MockData.sampleApps) { app in
                AppRow(
                    app: app,
                    volume: Float.random(in: 0.5...1.5),
                    audioLevel: Float.random(in: 0...0.8),
                    devices: MockData.sampleDevices,
                    selectedDeviceUID: MockData.sampleDevices.randomElement()!.uid,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in }
                )
            }
        }
    }
}
