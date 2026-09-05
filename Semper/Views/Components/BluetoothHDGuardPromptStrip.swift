import SwiftUI

struct BluetoothHDGuardPromptStrip: View {
    @Bindable var guardCoordinator: BluetoothHDGuardCoordinator

    var body: some View {
        if let prompt = guardCoordinator.pendingPrompt {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "wave.3.right")
                        .foregroundStyle(DesignTokens.Colors.systemBlue)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep \(prompt.headsetName) in HD?")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .lineLimit(1)
                        Text("Use another microphone before audio quality drops")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: DesignTokens.Spacing.xs)

                    Menu {
                        ForEach(prompt.microphones) { microphone in
                            Button {
                                guardCoordinator.selectMicrophone(microphone.uid)
                            } label: {
                                if microphone.uid == prompt.selectedMicrophoneUID {
                                    Label(microphone.name, systemImage: "checkmark")
                                } else {
                                    Text(microphone.name)
                                }
                            }
                        }
                    } label: {
                        Text(selectedMicrophoneName(prompt))
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 130)
                    .accessibilityLabel("Microphone for Bluetooth HD Guard")
                    .accessibilityValue(selectedMicrophoneName(prompt))
                    .accessibilityIdentifier("bluetooth-hd-guard-microphone")
                }

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Spacer()

                    Button("Protect Once") {
                        guardCoordinator.respond(.protectOnce)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .accessibilityLabel("Protect \(prompt.headsetName) audio once")
                    .accessibilityIdentifier("bluetooth-hd-guard-protect-once")

                    Button("Not Now") {
                        guardCoordinator.respond(.notNow)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel("Do not protect this headset microphone selection")
                    .accessibilityIdentifier("bluetooth-hd-guard-not-now")

                    Menu {
                        Button("Always Protect") {
                            guardCoordinator.respond(.always)
                        }
                        Button("Never Protect") {
                            guardCoordinator.respond(.never)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Remember HD Guard choice for \(prompt.headsetName)")
                    .accessibilityIdentifier("bluetooth-hd-guard-remember")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(DesignTokens.Colors.nextControlBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DesignTokens.Colors.nextSectionBorder)
                    .frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bluetooth-hd-guard-prompt")
        }
    }

    private func selectedMicrophoneName(_ prompt: BluetoothHDGuardPrompt) -> String {
        prompt.microphones.first(where: {
            $0.uid == prompt.selectedMicrophoneUID
        })?.name ?? "Choose Microphone"
    }
}
