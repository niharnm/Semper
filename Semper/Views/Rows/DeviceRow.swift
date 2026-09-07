// Semper/Views/Rows/DeviceRow.swift
import SwiftUI

/// A row displaying a device with volume controls.
/// Used in the Output Devices section.
///
/// Volume mapping depends on the device's `volumeBackend`:
/// - **Hardware**: Identity mapping (slider == HAL scalar). CoreAudio's VirtualMainVolume
///   scalar is already audio-tapered by the driver — IOAudioLevelControl applies a dB curve
///   by default (see `setLinearScale()` in IOAudioLevelControl.h). Empirically confirmed:
///   scalar 0.50 → −50 dB, scalar 0.10 → −90 dB (100 dB range, linear-in-dB).
/// - **DDC**: Identity mapping (slider == DDC 0–100 / 100). DDC writes VCP 0x62 (Audio
///   Speaker Volume) as an integer 0–100 directly to the monitor via I2C, bypassing the HAL
///   entirely. The monitor's firmware handles perceptual mapping internally. Identity matches
///   the OSD values users see on the physical display. MonitorControl uses the same approach.
/// - **Software**: VolumeMapping x² curve. Software gain is a linear PCM amplitude multiplier
///   that needs perceptual scaling (dr-lex.be, Discord perceptual).
///
/// See: IOAudioLevelControl.h, MCCS VCP 0x62, empirical ScalarToDecibels measurement.
struct DeviceRow: View {
    let device: AudioDevice
    let isDefault: Bool
    let volume: Float
    let observedVolume: Float?
    let isMuted: Bool
    /// The device's volume backend. Determines which slider ↔ value mapping to use.
    let volumeBackend: VolumeControlTier
    let capabilities: OutputDeviceCapabilities
    let maximumSelectableGain: Float
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let balance: Float
    let onBalanceChange: (Float) -> Void
    let getStereoAudioLevel: () -> StereoAudioLevel
    let isLevelMeterActive: Bool
    let attenuationNotice: String?

    // AutoEQ (all optional — existing call sites work without them)
    let autoEQProfileName: String?
    let autoEQEnabled: Bool
    let onAutoEQToggle: ((Bool) -> Void)?
    let autoEQProfileManager: AutoEQProfileManager?
    let autoEQSelection: AutoEQSelection?
    let autoEQFavoriteIDs: Set<String>
    let onAutoEQSelect: ((AutoEQProfile?) -> Void)?
    let onAutoEQImport: (() -> Void)?
    let onAutoEQToggleFavorite: ((String) -> Void)?
    let autoEQImportError: String?
    let autoEQPreampEnabled: Bool
    let onAutoEQPreampToggle: (() -> Void)?
    let isFocused: Bool
    let iconOverrideSymbol: String?

    @State private var sliderValue: Double
    @State private var balanceValue: Double
    @State private var isEditing = false
    @State private var suppressSliderAutoUnmute = false
    /// Prevents a programmatic slider synchronization from writing back as a user command.
    /// Breaks the quantization feedback loop on USB DACs with discrete dB steps.
    @State private var suppressNextSliderWrite = false

    /// The displayed percentage value, matching EditablePercentage's formula.
    /// Used for icon and unmute logic so visual state stays consistent with the label.
    private var displayedPercentage: Int {
        if isObservedAboveMaximum && !isEditing, let observedPercentage {
            return observedPercentage
        }
        return Int(round(sliderValue * Double(controlMaximumGain) * 100))
    }

    private var observedPercentage: Int? {
        observedVolume.map { Self.outputPercentage(for: $0, backend: volumeBackend) }
    }

    private var isObservedAboveMaximum: Bool {
        Self.isObservedAboveMaximum(
            observedVolume,
            maximumSelectableGain: controlMaximumGain
        )
    }

    private var controlMaximumGain: Float {
        Self.controlMaximumGain(
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        )
    }

    /// Show muted icon when system muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because SwiftUI Slider
    /// and volume clamping can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    /// Default slider position to restore when unmuting from 0 (50%).
    private var defaultUnmuteSliderValue: Double {
        Self.volumeToSlider(
            0.5,
            backend: volumeBackend,
            maximumGain: controlMaximumGain
        )
    }

    private var displayIcon: NSImage? {
        DeviceIconResolver.displayIcon(
            overrideSymbol: iconOverrideSymbol,
            automatic: device.icon,
            deviceName: device.name
        )
    }

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        observedVolume: Float?,
        isMuted: Bool,
        volumeBackend: VolumeControlTier = .hardware,
        capabilities: OutputDeviceCapabilities,
        maximumSelectableGain: Float,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        balance: Float = 0,
        onBalanceChange: @escaping (Float) -> Void = { _ in },
        getStereoAudioLevel: @escaping () -> StereoAudioLevel = { .zero },
        isLevelMeterActive: Bool = true,
        attenuationNotice: String? = nil,
        autoEQProfileName: String? = nil,
        autoEQEnabled: Bool = false,
        onAutoEQToggle: ((Bool) -> Void)? = nil,
        autoEQProfileManager: AutoEQProfileManager? = nil,
        autoEQSelection: AutoEQSelection? = nil,
        autoEQFavoriteIDs: Set<String> = [],
        onAutoEQSelect: ((AutoEQProfile?) -> Void)? = nil,
        onAutoEQImport: (() -> Void)? = nil,
        onAutoEQToggleFavorite: ((String) -> Void)? = nil,
        autoEQImportError: String? = nil,
        autoEQPreampEnabled: Bool = true,
        onAutoEQPreampToggle: (() -> Void)? = nil,
        isFocused: Bool = false,
        iconOverrideSymbol: String? = nil
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.observedVolume = observedVolume
        self.isMuted = isMuted
        self.volumeBackend = volumeBackend
        self.capabilities = capabilities
        self.maximumSelectableGain = maximumSelectableGain
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.balance = balance
        self.onBalanceChange = onBalanceChange
        self.getStereoAudioLevel = getStereoAudioLevel
        self.isLevelMeterActive = isLevelMeterActive
        self.attenuationNotice = attenuationNotice
        self.autoEQProfileName = autoEQProfileName
        self.autoEQEnabled = autoEQEnabled
        self.onAutoEQToggle = onAutoEQToggle
        self.autoEQProfileManager = autoEQProfileManager
        self.autoEQSelection = autoEQSelection
        self.autoEQFavoriteIDs = autoEQFavoriteIDs
        self.onAutoEQSelect = onAutoEQSelect
        self.onAutoEQImport = onAutoEQImport
        self.onAutoEQToggleFavorite = onAutoEQToggleFavorite
        self.autoEQImportError = autoEQImportError
        self.autoEQPreampEnabled = autoEQPreampEnabled
        self.onAutoEQPreampToggle = onAutoEQPreampToggle
        self.isFocused = isFocused
        self.iconOverrideSymbol = iconOverrideSymbol
        self._sliderValue = State(
            initialValue: Self.volumeToSlider(
                volume,
                backend: volumeBackend,
                maximumGain: Self.controlMaximumGain(
                    capabilities: capabilities,
                    maximumSelectableGain: maximumSelectableGain
                )
            )
        )
        self._balanceValue = State(initialValue: Double(balance))
    }

    var body: some View {
        VStack(spacing: 7) {
            masterTopRow
            masterSlider
            if capabilities.supportsBalance {
                balanceControl
            }
            StereoOutputMeter(
                getLevel: getStereoAudioLevel,
                isActive: isLevelMeterActive && !showMutedIcon
            )
        }
        .frame(
            minHeight: capabilities.supportsBalance
                ? DesignTokens.Dimensions.outputDeviceRowContentHeight
                : DesignTokens.Dimensions.outputDeviceRowCompactContentHeight
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isDefault {
                onSetDefault()
            }
        }
        .onChange(of: volume) { _, newValue in
            guard !isEditing else { return }
            let newSlider = Self.volumeToSlider(
                newValue,
                backend: volumeBackend,
                maximumGain: controlMaximumGain
            )
            guard newSlider != sliderValue else { return }
            suppressNextSliderWrite = true
            sliderValue = newSlider
        }
        .onChange(of: controlMaximumGain) { _, newMaximum in
            let newSlider = Self.volumeToSlider(
                volume,
                backend: volumeBackend,
                maximumGain: newMaximum
            )
            guard newSlider != sliderValue else { return }
            suppressNextSliderWrite = true
            sliderValue = newSlider
        }
        .onChange(of: balance) { _, newValue in
            let clamped = max(-1, min(1, Double(newValue)))
            if balanceValue != clamped {
                balanceValue = clamped
            }
        }
    }

    private var masterTopRow: some View {
        HStack(spacing: 10) {
            DeviceBadge(icon: displayIcon, isSelected: isDefault)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .help(device.name)

                Text(masterStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(
                        isBoosted || isObservedAboveMaximum || attenuationNotice != nil
                            ? DesignTokens.Colors.systemOrange
                            : DesignTokens.Colors.textSecondary
                    )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if device.supportsAutoEQ,
               let profileManager = autoEQProfileManager,
               let onSelect = onAutoEQSelect,
               let onImport = onAutoEQImport {
                AutoEQPicker(
                    profileManager: profileManager,
                    profileName: autoEQProfileName,
                    selection: autoEQSelection,
                    favoriteIDs: autoEQFavoriteIDs,
                    onSelect: onSelect,
                    onImport: onImport,
                    onToggleFavorite: { id in onAutoEQToggleFavorite?(id) },
                    importError: autoEQImportError,
                    isCorrectionEnabled: autoEQEnabled,
                    onCorrectionToggle: onAutoEQToggle,
                    preampEnabled: autoEQPreampEnabled,
                    onPreampToggle: onAutoEQPreampToggle
                )
            }

            MuteButton(
                isMuted: showMutedIcon,
                levelFraction: sliderValue,
                foregroundColor: .white
            ) {
                if showMutedIcon {
                    if displayedPercentage == 0 {
                        suppressSliderAutoUnmute = isMuted
                        sliderValue = defaultUnmuteSliderValue
                    }
                    if isMuted {
                        onMuteToggle()
                    }
                } else {
                    onMuteToggle()
                }
            }
            .frame(width: 26, height: 26)
            .background {
                Circle()
                    .fill(
                        showMutedIcon
                            ? DesignTokens.Colors.systemRed
                            : DesignTokens.Colors.nextControlBackground
                    )
            }

            EditablePercentage(
                percentage: Binding(
                    get: { displayedPercentage },
                    set: commitPercentage
                ),
                range: 0...Int((controlMaximumGain * 100).rounded()),
                normalTextColor: isBoosted || isObservedAboveMaximum
                    ? DesignTokens.Colors.systemOrange
                    : nil,
                isRowFocused: isFocused,
                accessibilityName: "Master volume percentage for \(device.name)"
            )
        }
    }

    private var masterSlider: some View {
        LiquidGlassSlider(
            value: $sliderValue,
            unityValue: VolumeMapping.unityMasterSliderFraction(
                maximumGain: controlMaximumGain
            ),
            usesBoostedFill: Self.supportsBoost(
                capabilities: capabilities,
                maximumSelectableGain: maximumSelectableGain
            ),
            trackHeight: 8,
            alwaysShowsThumb: true,
            onEditingChanged: { editing in
                isEditing = editing
            }
        )
        .opacity(showMutedIcon ? 0.5 : 1.0)
        .onChange(of: sliderValue) { _, newValue in
            if suppressNextSliderWrite {
                suppressNextSliderWrite = false
                return
            }
            commitUserVolume(
                Self.sliderToVolume(
                    newValue,
                    backend: volumeBackend,
                    maximumGain: controlMaximumGain
                ),
                sliderFraction: newValue
            )
        }
        .scrollWheelStep($sliderValue, in: 0.0...1.0)
        .help(Self.masterVolumeHelp(
            deviceName: device.name,
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        ))
        .accessibilityLabel("Master volume for \(device.name)")
        .accessibilityValue("\(displayedPercentage) percent")
    }

    func commitPercentage(_ percentage: Int) {
        let commit = Self.percentageCommit(
            percentage,
            backend: volumeBackend,
            maximumGain: controlMaximumGain
        )
        if commit.sliderFraction != sliderValue {
            suppressNextSliderWrite = true
            sliderValue = commit.sliderFraction
        }
        commitUserVolume(commit.volume, sliderFraction: commit.sliderFraction)
    }

    private func commitUserVolume(_ volume: Float, sliderFraction: Double) {
        onVolumeChange(volume)
        if suppressSliderAutoUnmute {
            suppressSliderAutoUnmute = false
            return
        }
        if isMuted && sliderFraction > 0 {
            onMuteToggle()
        }
    }

    private var balanceControl: some View {
        HStack(spacing: 8) {
            Text("L")
            SemperBalanceSlider(value: $balanceValue)
                .accessibilityLabel("Balance for \(device.name)")
                .accessibilityValue(balanceAccessibilityValue)
                .accessibilityHint("Adjusts balance in five percent steps")
                .onChange(of: balanceValue) { _, newValue in
                    onBalanceChange(Float(max(-1, min(1, newValue))))
                }
            Text("R")

            Button("Center") {
                balanceValue = 0
            }
            .buttonStyle(.plain)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Colors.nextControlBackground)
            }
            .accessibilityLabel("Reset balance to center")
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(DesignTokens.Colors.textTertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignTokens.Colors.nextControlBackground.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DesignTokens.Colors.nextControlBorder, lineWidth: 1)
                }
        }
    }

    private var isBoosted: Bool {
        displayedPercentage > 100
    }

    private var masterStatusText: String {
        if isObservedAboveMaximum, let observedPercentage {
            let maximum = Self.maximumSelectablePercentage(
                capabilities: capabilities,
                maximumSelectableGain: maximumSelectableGain
            )
            return "\(observedPercentage)% current · \(maximum)% volume limit"
        }
        if let attenuationNotice {
            return attenuationNotice
        }
        if isBoosted {
            return "\(displayedPercentage)% software gain · -1 dB limiter"
        }
        return Self.idleMasterStatus(
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        )
    }

    private var balanceAccessibilityValue: String {
        if abs(balanceValue) < 0.01 {
            return "Center"
        }
        let side = balanceValue < 0 ? "left" : "right"
        return "\(Int(round(abs(balanceValue) * 100))) percent \(side)"
    }
}

private struct SemperBalanceSlider: View {
    @Binding var value: Double

    private var normalizedValue: CGFloat {
        CGFloat((max(-1, min(1, value)) + 1) / 2)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 5)

                RoundedRectangle(cornerRadius: 2)
                    .fill(DesignTokens.Colors.systemBlue)
                    .frame(
                        width: geometry.size.width * abs(normalizedValue - 0.5),
                        height: 5
                    )
                    .offset(x: geometry.size.width * min(normalizedValue, 0.5))

                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 2, height: 5)
                    .offset(x: (geometry.size.width * 0.5) - 1)

                Slider(value: $value, in: -1...1)
                    .controlSize(.mini)
                    .tint(.clear)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            value = AudioAccessibility.adjustedValue(
                value,
                direction: direction,
                step: 0.05,
                range: -1...1
            )
        }
    }
}

private struct StereoOutputMeter: View {
    let getLevel: () -> StereoAudioLevel
    let isActive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: DesignTokens.Timing.vuMeterUpdateInterval)) { _ in
            let level = isActive ? getLevel() : .zero

            VStack(spacing: 3) {
                channel(label: "L", level: level.left)
                channel(label: "R", level: level.right)
            }
        }
    }

    private func channel(label: String, level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(width: 8)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))

                    Capsule()
                        .fill(DesignTokens.Colors.stereoMeterFill)
                        .frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(height: 3)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

extension DeviceRow {
    // MARK: - Boost Presentation

    static func percentageCommit(
        _ percentage: Int,
        backend: VolumeControlTier,
        maximumGain: Float
    ) -> (sliderFraction: Double, volume: Float) {
        let maximumGain = normalizedMaximumGain(maximumGain)
        let sliderFraction = max(
            0,
            min(1, Double(percentage) / (Double(maximumGain) * 100))
        )
        return (
            sliderFraction,
            sliderToVolume(
                sliderFraction,
                backend: backend,
                maximumGain: maximumGain
            )
        )
    }

    static func isObservedAboveMaximum(
        _ volume: Float?,
        maximumSelectableGain: Float
    ) -> Bool {
        guard let volume, volume.isFinite else { return false }
        return volume > normalizedMaximumGain(maximumSelectableGain)
            + SafeOutputSwitchState.volumeTolerance
    }

    static func outputPercentage(
        for volume: Float,
        backend: VolumeControlTier
    ) -> Int {
        guard volume.isFinite else { return 0 }
        let fraction = volumeToSlider(
            volume,
            backend: backend,
            maximumGain: VolumeMapping.maximumMasterGain
        )
        return Int((fraction * Double(VolumeMapping.maximumMasterGain) * 100).rounded())
    }

    static func supportsBoost(
        capabilities: OutputDeviceCapabilities,
        maximumSelectableGain: Float
    ) -> Bool {
        capabilities.supportsBoost
            && selectableMaximumGain(
                capabilities: capabilities,
                maximumSelectableGain: maximumSelectableGain
            ) > 1
    }

    static func controlMaximumGain(
        capabilities: OutputDeviceCapabilities,
        maximumSelectableGain: Float
    ) -> Float {
        let maximum = selectableMaximumGain(
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        )
        return capabilities.supportsBoost ? maximum : min(1, maximum)
    }

    static func maximumSelectablePercentage(
        capabilities: OutputDeviceCapabilities,
        maximumSelectableGain: Float
    ) -> Int {
        let maximum = controlMaximumGain(
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        )
        return Int((maximum * 100).rounded())
    }

    static func masterVolumeHelp(
        deviceName: String,
        capabilities: OutputDeviceCapabilities,
        maximumSelectableGain: Float
    ) -> String {
        let maximum = maximumSelectablePercentage(
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        )
        return "Master volume for \(deviceName), maximum \(maximum) percent"
    }

    static func idleMasterStatus(
        capabilities: OutputDeviceCapabilities,
        maximumSelectableGain: Float
    ) -> String {
        let maximum = maximumSelectablePercentage(
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        )
        if supportsBoost(
            capabilities: capabilities,
            maximumSelectableGain: maximumSelectableGain
        ) {
            return "Software gain up to \(maximum)% · -1 dB limiter"
        }
        if maximum < 100 {
            return "\(maximum)% volume limit · boost unavailable"
        }
        return capabilities.unavailableReason ?? "100% max · boost unavailable"
    }

    private static func selectableMaximumGain(
        capabilities: OutputDeviceCapabilities,
        maximumSelectableGain: Float
    ) -> Float {
        let capabilityMaximum = normalizedMaximumGain(capabilities.maximumGain)
        return min(capabilityMaximum, normalizedMaximumGain(maximumSelectableGain))
    }

    private static func normalizedMaximumGain(_ maximumGain: Float) -> Float {
        guard maximumGain.isFinite, maximumGain > 0 else { return 1 }
        return min(maximumGain, VolumeMapping.maximumMasterGain)
    }

    // MARK: - Volume Mapping

    static func volumeToSlider(
        _ volume: Float,
        backend: VolumeControlTier,
        maximumGain: Float = VolumeMapping.maximumMasterGain
    ) -> Double {
        VolumeMapping.masterSliderFraction(
            forGain: volume,
            tier: backend,
            maximumGain: maximumGain
        )
    }

    static func sliderToVolume(
        _ slider: Double,
        backend: VolumeControlTier,
        maximumGain: Float = VolumeMapping.maximumMasterGain
    ) -> Float {
        VolumeMapping.masterGain(
            forSliderFraction: slider,
            tier: backend,
            maximumGain: maximumGain
        )
    }

    // MARK: - Subtitle

    static func autoEQSubtitle(profileName: String?, isEnabled: Bool) -> String? {
        guard let profileName else { return nil }
        return isEnabled ? profileName : "\(profileName) (off)"
    }
}

// MARK: - Previews

#Preview("Device Row - Default") {
    PreviewContainer {
        VStack(spacing: 0) {
            DeviceRow(
                device: MockData.sampleDevices[0],
                isDefault: true,
                volume: 0.75,
                observedVolume: 0.75,
                isMuted: false,
                capabilities: OutputDeviceCapabilities(
                    maximumGain: 3,
                    supportsBalance: true,
                    channelCount: 2,
                    isRouteVerified: true,
                    unavailableReason: nil
                ),
                maximumSelectableGain: 3,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[1],
                isDefault: false,
                volume: 1.0,
                observedVolume: 1.0,
                isMuted: false,
                capabilities: .unavailable(
                    channelCount: MockData.sampleDevices[1].outputTopology.channelCount,
                    reason: "Route an app here to verify boost"
                ),
                maximumSelectableGain: 1,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[2],
                isDefault: false,
                volume: 0.5,
                observedVolume: 0.5,
                isMuted: true,
                capabilities: .unavailable(
                    channelCount: MockData.sampleDevices[2].outputTopology.channelCount,
                    reason: "Route an app here to verify boost"
                ),
                maximumSelectableGain: 1,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )
        }
    }
}
