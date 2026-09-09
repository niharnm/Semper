import SwiftUI

struct AwakeModuleView: View {
    let awake: AwakeService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let durationColumns = [
        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            statusRow
            durationGrid
            displayToggleRow
            if let failureText {
                Text(failureText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.systemOrange)
            }
            Text("Closing the lid or choosing Sleep still works.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Colors.nextMasterBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.Colors.nextSectionBorder)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.Colors.nextSectionBorder)
                .frame(height: 1)
        }
    }

    // MARK: - Status

    private var statusText: String {
        guard let session = awake.session else { return "Choose a duration" }
        if let endsAt = session.endsAt {
            return "Until \(endsAt.formatted(date: .omitted, time: .shortened))"
        }
        return "Until you turn it off"
    }

    private var failureText: String? {
        switch awake.failure {
        case .couldNotStart:
            "Could not start Awake. Try again."
        case .couldNotRelease:
            "A power assertion could not be released. Quit Semper if the Mac still stays awake."
        case nil:
            nil
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: awake.isActive ? "sun.max.fill" : "sun.max")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    awake.isActive
                        ? DesignTokens.Colors.systemBlue
                        : DesignTokens.Colors.textSecondary
                )
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(DesignTokens.Colors.nextControlBackground)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(awake.isActive ? "Mac stays awake" : "Keep this Mac awake")
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(statusText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(awake.isActive ? "Mac stays awake" : "Keep this Mac awake")
            .accessibilityValue(statusText)

            Spacer(minLength: 0)

            if awake.isActive {
                Button {
                    awake.stop()
                } label: {
                    Text("End Awake")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(DesignTokens.Colors.nextControlBackground)
                        }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .help("End Awake")
                .accessibilityLabel("End Awake")
                .accessibilityHint("Allows automatic idle sleep again")
            }
        }
    }

    // MARK: - Durations

    private var durationGrid: some View {
        LazyVGrid(columns: durationColumns, spacing: DesignTokens.Spacing.sm) {
            ForEach(AwakeDuration.allCases) { duration in
                durationButton(duration)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep awake duration")
    }

    @ViewBuilder
    private func durationButton(_ duration: AwakeDuration) -> some View {
        let isCurrent = awake.session?.duration == duration
        Button {
            withAnimation(reduceMotion ? nil : DesignTokens.Animation.quick) {
                awake.start(duration)
            }
        } label: {
            HStack(spacing: 4) {
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(duration.label)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isCurrent ? Color.white : DesignTokens.Colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 1)
                    .fill(
                        isCurrent
                            ? DesignTokens.Colors.systemBlue
                            : DesignTokens.Colors.nextControlBackground
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 1)
                            .strokeBorder(DesignTokens.Colors.nextControlBorder, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Keep this Mac awake \(duration.accessibilityPhrase)")
        .accessibilityLabel("Keep this Mac awake \(duration.accessibilityPhrase)")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    // MARK: - Display scope

    private var displayToggleRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep display on")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text("Also prevents idle display sleep.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer(minLength: 0)

            Toggle("Keep display on", isOn: Binding(
                get: { awake.keepDisplayAwake },
                set: { awake.setKeepDisplayAwake($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityHint("Also prevents idle display sleep while Awake is active")
        }
    }
}
