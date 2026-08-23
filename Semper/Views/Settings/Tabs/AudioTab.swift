// Semper/Views/Settings/Tabs/AudioTab.swift
import AppKit
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    let audioCommands: any AudioCommandDispatching
    @Bindable var callMode: CallModeCoordinator
    @Bindable var bluetoothHDGuard: BluetoothHDGuardCoordinator
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
                bluetoothHDGuardSection
                callModeSection
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
            } else if oldValue && !newValue {
                audioEngine.handleInputLockDisabled()
            }
        }
        .onChange(of: settings.appSettings.callModeEnabled) { _, newValue in
            callMode.setEnabled(newValue)
        }
        .onChange(of: settings.appSettings.callModeQuietAlerts) { _, newValue in
            callMode.setQuietAlertsEnabled(newValue)
        }
        .onChange(of: settings.appSettings.bluetoothHDGuardEnabled) { _, newValue in
            bluetoothHDGuard.setEnabled(newValue)
        }
        .onChange(of: settings.appSettings.monoAudioEnabled) { _, newValue in
            audioEngine.setMonoAudioEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
    }

    // MARK: - Bluetooth Audio

    private var bluetoothHDGuardSection: some View {
        SettingsSection("Bluetooth Audio") {
            SettingsRow(
                "HD Guard",
                description: "Offer another microphone before a headset drops to call quality"
            ) {
                Toggle("", isOn: $settings.appSettings.bluetoothHDGuardEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Bluetooth HD Guard")
            }

            if let session = bluetoothHDGuard.activeSession {
                SettingsRowDivider()
                SettingsRow(
                    "Protecting \(session.headsetName)",
                    description: "Using \(session.protectedInputName) for microphone input"
                ) {
                    Button("Use Headset Mic") {
                        bluetoothHDGuard.stopProtection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Stop HD Guard and use the headset microphone")
                }
            }

            ForEach(settings.bluetoothHDGuardPreferences) { preference in
                SettingsRowDivider()
                SettingsRow(
                    preference.headsetName,
                    description: "Choose what happens when this headset microphone is selected"
                ) {
                    Picker(
                        "",
                        selection: bluetoothBehaviorBinding(for: preference)
                    ) {
                        ForEach(BluetoothHDGuardBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    .disabled(!settings.appSettings.bluetoothHDGuardEnabled)
                    .accessibilityLabel("\(preference.headsetName) HD Guard behavior")
                    .accessibilityValue(preference.behavior.title)
                }

                if preference.behavior != .never {
                    SettingsRowDivider()
                    SettingsRow(
                        "Microphone for \(preference.headsetName)",
                        description: "Non-Bluetooth input used to preserve headset audio quality"
                    ) {
                        Picker(
                            "",
                            selection: bluetoothMicrophoneBinding(for: preference)
                        ) {
                            if let uid = preference.microphoneUID,
                               !bluetoothHDGuard.availableMicrophones.contains(where: {
                                   $0.uid == uid
                               }) {
                                Text("\(preference.microphoneName ?? "Saved microphone") (Disconnected)")
                                    .tag(uid)
                            }
                            ForEach(bluetoothHDGuard.availableMicrophones) { microphone in
                                Text(microphone.name).tag(microphone.uid)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .disabled(
                            !settings.appSettings.bluetoothHDGuardEnabled
                                || bluetoothHDGuard.availableMicrophones.isEmpty
                        )
                        .accessibilityLabel("Microphone used for \(preference.headsetName)")
                        .accessibilityValue(
                            preference.microphoneName ?? "Automatic"
                        )
                    }
                }
            }
        }
    }

    private func bluetoothBehaviorBinding(
        for preference: BluetoothHDGuardPreference
    ) -> Binding<BluetoothHDGuardBehavior> {
        Binding(
            get: { preference.behavior },
            set: { behavior in
                var updated = preference
                updated.behavior = behavior
                settings.setBluetoothHDGuardPreference(updated)
                bluetoothHDGuard.preferencesDidChange()
            }
        )
    }

    private func bluetoothMicrophoneBinding(
        for preference: BluetoothHDGuardPreference
    ) -> Binding<String> {
        Binding(
            get: {
                preference.microphoneUID
                    ?? bluetoothHDGuard.availableMicrophones.first?.uid
                    ?? ""
            },
            set: { microphoneUID in
                guard let microphone = bluetoothHDGuard.availableMicrophones.first(where: {
                    $0.uid == microphoneUID
                }) else {
                    return
                }
                var updated = preference
                updated.microphoneUID = microphone.uid
                updated.microphoneName = microphone.name
                settings.setBluetoothHDGuardPreference(updated)
                bluetoothHDGuard.preferencesDidChange()
            }
        )
    }

    // MARK: - Call Mode

    private var callModeSection: some View {
        SettingsSection("Call Mode") {
            SettingsRow(
                "Call Detection",
                description: "Offer to lower other apps when a verified call starts"
            ) {
                Toggle("", isOn: $settings.appSettings.callModeEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Call Mode detection")
            }

            SettingsRowDivider()

            SettingsRow(
                "Quiet Alerts",
                description: "Limit notification sounds to 25% during Call Mode"
            ) {
                Toggle("", isOn: $settings.appSettings.callModeQuietAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!settings.appSettings.callModeEnabled)
                    .accessibilityLabel("Quiet alerts during Call Mode")
            }

            ForEach(VerifiedCallApplication.supported) { application in
                SettingsRowDivider()
                SettingsRow(
                    application.displayName,
                    description: "Choose what happens when this app uses the microphone"
                ) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.callModePreference(for: application.identifier) },
                            set: { settings.setCallModePreference($0, for: application.identifier) }
                        )
                    ) {
                        ForEach(CallModePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    .disabled(!settings.appSettings.callModeEnabled)
                    .accessibilityLabel("\(application.displayName) Call Mode behavior")
                    .accessibilityValue(
                        settings.callModePreference(for: application.identifier).title
                    )
                }
            }

            if let session = callMode.activeSession {
                SettingsRowDivider()
                SettingsRow(
                    "Active for \(session.displayName)",
                    description: "Other apps are temporarily limited to 25%"
                ) {
                    Button("End") { callMode.end() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("End Call Mode for \(session.displayName)")
                }
            }
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
                    width: DesignTokens.Dimensions.settingsSliderWidth,
                    accessibilityLabel: "Default volume for new apps"
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Mono Audio",
                description: "Combine left and right channels for managed apps"
            ) {
                Toggle("", isOn: $settings.appSettings.monoAudioEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Mono audio")
                    .accessibilityValue(settings.appSettings.monoAudioEnabled ? "On" : "Off")
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
                    width: DesignTokens.Dimensions.settingsSliderWidth,
                    accessibilityLabel: "Alert volume"
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
