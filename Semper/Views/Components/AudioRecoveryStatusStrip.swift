import SwiftUI

struct AudioRecoveryStatusStrip: View {
    @Bindable var audioEngine: AudioEngine
    let onResume: () -> Void

    var body: some View {
        if audioEngine.audioProcessingState != .active {
            HStack(spacing: DesignTokens.Spacing.sm) {
                statusIcon
                    .accessibilityHidden(true)

                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: DesignTokens.Spacing.xs)

                action
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
            .accessibilityValue(audioEngine.audioProcessingState.accessibilityValue)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch audioEngine.audioProcessingState {
        case .bypassing, .resuming:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.systemOrange)
        case .waitingForPermission:
            Image(systemName: "lock.fill")
                .foregroundStyle(DesignTokens.Colors.systemOrange)
        case .bypassed:
            Image(systemName: "waveform.slash")
                .foregroundStyle(DesignTokens.Colors.systemBlue)
        case .active:
            EmptyView()
        }
    }

    private var message: String {
        switch audioEngine.audioProcessingState {
        case .active: "Audio processing active"
        case .bypassing: "Bypassing audio processing"
        case .bypassed: "Audio processing bypassed"
        case .waitingForPermission: "Permission needed to resume"
        case .resuming: "Resuming audio processing"
        case .failed: "Audio recovery needs attention"
        }
    }

    @ViewBuilder
    private var action: some View {
        switch audioEngine.audioProcessingState {
        case .bypassed:
            statusButton("Resume", action: onResume)
        case .waitingForPermission:
            if audioEngine.permission.status == .denied {
                statusButton("Open Settings") {
                    audioEngine.permission.openSystemSettings()
                }
            } else {
                statusButton("Grant Access") {
                    audioEngine.permission.request()
                }
            }
        case .failed:
            statusButton("Try Again") {
                audioEngine.retryAudioProcessingRecovery()
            }
        case .active, .bypassing, .resuming:
            EmptyView()
        }
    }

    private func statusButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.systemBlue)
    }
}
