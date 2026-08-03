// Semper/Views/Settings/Tabs/AudioTab.swift
import AppKit
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    let audioCommands: any AudioCommandDispatching
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []
    @State private var reportCopied = false

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                devicesSection
                audioRecoverySection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: DesignTokens.Dimensions.settingsSliderWidth
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Loudness Compensation",
                description: "Boost low frequencies at low volume"
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection("Devices") {
            SettingsRow(
                "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "System Sounds",
                description: "Where alerts and effects play"
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Alert Volume",
                description: "Volume for alerts and notifications"
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: DesignTokens.Dimensions.settingsSliderWidth
                )
            }
            .task {
                // No CoreAudio listener for alert volume — must poll via AppleScript.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
    }

    // MARK: - Audio Recovery

    private var audioRecoverySection: some View {
        SettingsSection("Audio Recovery") {
            SettingsRow(
                "Audio Processing",
                description: audioProcessingDescription
            ) {
                audioProcessingAction
            }
            SettingsRowDivider()
            SettingsRow(
                "Diagnostics",
                description: "Copy a privacy-filtered audio report"
            ) {
                Button(reportCopied ? "Copied" : "Copy Report") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(audioEngine.audioRecoveryReport, forType: .string)
                    reportCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        reportCopied = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Copy audio recovery report")
            }
        }
    }

    private var audioProcessingDescription: String {
        switch audioEngine.audioProcessingState {
        case .active: "Per-app volume and routing are active"
        case .bypassing: "Releasing audio processing resources"
        case .bypassed: "Apps use their normal system audio path"
        case .waitingForPermission: "Audio recording access is required to resume"
        case .resuming: "Restoring saved app audio settings"
        case .failed: "Audio resources could not be fully recovered"
        }
    }

    @ViewBuilder
    private var audioProcessingAction: some View {
        switch audioEngine.audioProcessingState {
        case .active:
            recoveryButton("Bypass", accessibilityLabel: "Bypass audio processing") {
                dispatchAudioProcessing(.bypassed)
            }
        case .bypassed:
            recoveryButton("Resume", accessibilityLabel: "Resume audio processing") {
                dispatchAudioProcessing(.active)
            }
        case .waitingForPermission:
            if audioEngine.permission.status == .denied {
                recoveryButton("Open System Settings", accessibilityLabel: "Open audio recording settings") {
                    audioEngine.permission.openSystemSettings()
                }
            } else {
                recoveryButton("Grant Access", accessibilityLabel: "Grant audio recording access") {
                    audioEngine.permission.request()
                }
            }
        case .failed:
            recoveryButton("Try Again", accessibilityLabel: "Retry audio recovery") {
                audioEngine.retryAudioProcessingRecovery()
            }
        case .bypassing, .resuming:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(audioEngine.audioProcessingState.accessibilityValue)
        }
    }

    private func recoveryButton(
        _ title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(audioEngine.audioProcessingState.accessibilityValue)
    }

    private func dispatchAudioProcessing(_ mode: AudioProcessingMode) {
        audioCommands.dispatch(
            .setAudioProcessingMode(mode),
            context: AudioCommandContext(
                source: .popup,
                reason: .bypass
            )
        )
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}
