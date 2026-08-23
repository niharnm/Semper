// Semper/Views/Rows/AppRowControls.swift
import SwiftUI

/// Shared controls for app rows: mute button, volume slider, percentage, VU meter, device picker, EQ button.
/// Used by both AppRow (active apps) and InactiveAppRow (pinned inactive apps).
struct AppRowControls: View {
    let appName: String
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    var deviceIconOverrides: [String: String] = [:]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let routeLifecycle: AppRouteLifecycle?
    let boost: BoostLevel
    let isEQExpanded: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onBoostChange: (BoostLevel) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onEQToggle: () -> Void
    var isRowFocused: Bool = false
    var showsOptions: Bool = false

    @State private var dragOverrideValue: Double?

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.gainToSlider(volume)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: { newValue in
                dragOverrideValue = newValue
                let gain = VolumeMapping.sliderToGain(newValue)
                onVolumeChange(gain)
                if isMuted {
                    onMuteChange(false)
                }
            }
        )
    }

    /// The displayed percentage value, matching EditablePercentage's formula.
    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    /// Show muted icon when muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because the x² volume
    /// mapping round-trip can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    private var routeDevice: AudioDevice? {
        let uid: String?
        switch routeLifecycle {
        case .active(let deviceUIDs), .preparing(let deviceUIDs):
            uid = deviceUIDs.first
        case .failed(let previousDeviceUIDs, _):
            uid = previousDeviceUIDs.first
        case .unavailable, .none:
            if deviceSelectionMode == .multi {
                uid = selectedDeviceUIDs.sorted().first
            } else {
                uid = isFollowingDefault ? defaultDeviceUID : selectedDeviceUID
            }
        }
        guard let uid else { return nil }
        return devices.first(where: { $0.uid == uid })
    }

    private var routeDescription: String {
        DevicePicker.routingSubtitle(
            devices: devices,
            selectedDeviceUID: selectedDeviceUID,
            selectedDeviceUIDs: selectedDeviceUIDs,
            isFollowingDefault: isFollowingDefault,
            defaultDeviceUID: defaultDeviceUID,
            mode: deviceSelectionMode,
            lifecycle: routeLifecycle
        ) ?? "Output unavailable"
    }

    var body: some View {
        HStack(spacing: 5) {
            LiquidGlassSlider(
                value: sliderBinding,
                showUnityMarker: false,
                trackHeight: 8,
                alwaysShowsThumb: true,
                onEditingChanged: { editing in
                    if !editing {
                        dragOverrideValue = nil
                    }
                }
            )
            .frame(width: DesignTokens.Dimensions.sliderWidth)
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .scrollWheelStep(sliderBinding, in: 0.0...1.0)
            .accessibilityLabel("Volume for \(appName)")
            .accessibilityValue("\(displayedPercentage) percent")

            MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                if showMutedIcon {
                    if displayedPercentage == 0 {
                        onVolumeChange(1.0)
                    }
                    onMuteChange(false)
                } else {
                    onMuteChange(true)
                }
            }
            .frame(width: 22, height: 22)

            EditablePercentage(
                percentage: Binding(
                    get: {
                        Int(round(sliderValue * 100))
                    },
                    set: { newPercentage in
                        let sliderPos = Double(newPercentage) / 100.0
                        let gain = VolumeMapping.sliderToGain(sliderPos)
                        onVolumeChange(gain)
                    }
                ),
                range: 0...100,
                isRowFocused: isRowFocused,
                accessibilityName: "Volume percentage for \(appName)"
            )

            Menu {
                if deviceSelectionMode == .single {
                    Button(
                        systemOutputMenuTitle,
                        systemImage: isFollowingDefault ? "checkmark" : "globe"
                    ) {
                        onSelectFollowDefault()
                    }

                    ForEach(devices) { device in
                        Button {
                            onDeviceSelected(device.uid)
                        } label: {
                            if !isFollowingDefault && selectedDeviceUID == device.uid {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } else {
                    ForEach(devices) { device in
                        Button {
                            var updated = selectedDeviceUIDs
                            if updated.contains(device.uid) {
                                updated.remove(device.uid)
                            } else {
                                updated.insert(device.uid)
                            }
                            onDevicesSelected(updated)
                        } label: {
                            if selectedDeviceUIDs.contains(device.uid) {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                }

                Divider()

                Button(
                    deviceSelectionMode == .single ? "Use Multiple Outputs" : "Use One Output",
                    systemImage: deviceSelectionMode == .single ? "hifispeaker.2.fill" : "hifispeaker.fill"
                ) {
                    onDeviceModeChange(deviceSelectionMode == .single ? .multi : .single)
                }

                Divider()

                Button("Boost: \(boost.next.label)", systemImage: "bolt.fill") {
                    onBoostChange(boost.next)
                }

                Button(
                    isEQExpanded ? "Close Equalizer" : "Open Equalizer",
                    systemImage: "slider.vertical.3"
                ) {
                    onEQToggle()
                }
            } label: {
                routeMenuIcon
                    .frame(width: 22, height: 22)
                    .background {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                showsOptions || isEQExpanded
                                    ? Color.white.opacity(0.08)
                                    : Color.clear
                            )
                    }
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Output for \(appName): \(routeDescription)")
            .accessibilityLabel("Output for \(appName)")
            .accessibilityValue(routeDescription)
        }
        .fixedSize()
    }

    private var systemOutputMenuTitle: String {
        guard let defaultDeviceUID,
              let device = devices.first(where: { $0.uid == defaultDeviceUID }) else {
            return "Follow System Output"
        }
        return "Follow System Output · \(device.name)"
    }

    @ViewBuilder
    private var routeMenuIcon: some View {
        if let icon = routeDevice.flatMap({
            DeviceIconResolver.displayIcon(
                overrideSymbol: deviceIconOverrides[$0.uid],
                automatic: $0.icon,
                deviceName: $0.name
            )
        }) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else if case .failed = routeLifecycle {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.systemOrange)
        } else {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }
}
