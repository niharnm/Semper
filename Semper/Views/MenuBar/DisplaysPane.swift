import SwiftUI

#if !APP_STORE
@MainActor
struct DisplaysPane: View {
    @Bindable var displayService: DisplayControlService
    let isSceneOperationInProgress: Bool

    private struct ControlKey: Hashable {
        let displayID: DisplayIdentity
        let feature: DisplayFeature
    }

    @State private var values: [ControlKey: Double] = [:]
    @State private var pendingWrites = Set<ControlKey>()
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if displayService.displays.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(displayService.displays) { display in
                        displaySection(display)
                        if display.id != displayService.displays.last?.id {
                            Divider()
                        }
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.md)
                    .accessibilityLabel(statusMessage)
            }
        }
        .task(id: isSceneOperationInProgress) {
            guard !isSceneOperationInProgress else { return }
            await displayService.probe()
            syncValues()
        }
        .onChange(of: displayService.displays) { _, _ in
            syncValues()
        }
    }

    private var header: some View {
        HStack {
            SectionHeader(title: "External Displays")

            Spacer()

            Button {
                Task {
                    await displayService.probe()
                    syncValues()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background {
                        Circle()
                            .fill(DesignTokens.Colors.nextControlBackground)
                    }
            }
            .buttonStyle(.plain)
            .disabled(isSceneOperationInProgress)
            .help("Refresh displays")
            .accessibilityLabel("Refresh displays")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Text("No supported display found")
                .font(DesignTokens.Typography.rowName)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text("Connect a DDC compatible external display, then refresh.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.xxl)
    }

    private func displaySection(_ display: DisplayDevice) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "display")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)

                Text(display.name)
                    .font(DesignTokens.Typography.rowNameBold)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()
            }

            ForEach(DisplayFeature.allCases, id: \.self) { feature in
                if display.features[feature] != nil {
                    featureRow(feature, display: display)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private func featureRow(_ feature: DisplayFeature, display: DisplayDevice) -> some View {
        let key = ControlKey(displayID: display.id, feature: feature)
        let isAvailable = display.features[feature] != nil && !isSceneOperationInProgress

        return HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 16)

            Text(feature.title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 58, alignment: .leading)

            LiquidGlassSlider(
                value: valueBinding(for: key, display: display),
                alwaysShowsThumb: true,
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    writeValue(for: key, displayName: display.name)
                }
            )
            .disabled(!isAvailable || pendingWrites.contains(key))

            if pendingWrites.contains(key) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: DesignTokens.Dimensions.percentageWidth)
                    .accessibilityLabel("Saving \(feature.title.lowercased())")
            } else {
                Text("\(Int((value(for: key, display: display) * 100).rounded()))%")
                    .percentageStyle()
            }
        }
        .opacity(isAvailable ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private func valueBinding(for key: ControlKey, display: DisplayDevice) -> Binding<Double> {
        Binding(
            get: { value(for: key, display: display) },
            set: { values[key] = $0 }
        )
    }

    private func value(for key: ControlKey, display: DisplayDevice) -> Double {
        values[key] ?? display.features[key.feature]?.normalized ?? 0
    }

    private func writeValue(for key: ControlKey, displayName: String) {
        guard !pendingWrites.contains(key), let value = values[key] else { return }
        pendingWrites.insert(key)
        statusMessage = nil

        Task {
            let result: DisplayWriteResult
            do {
                result = try await displayService.set(
                    value,
                    feature: key.feature,
                    for: key.displayID
                )
            } catch is CancellationError {
                pendingWrites.remove(key)
                syncValues()
                return
            } catch {
                pendingWrites.remove(key)
                statusMessage = "Display changes are temporarily unavailable."
                syncValues()
                return
            }
            pendingWrites.remove(key)
            let confirmed = displayService.displays
                .first(where: { $0.id == key.displayID })?
                .features[key.feature]?
                .normalized
            values[key] = DisplayFeatureIO.resolvedSliderValue(
                requested: value,
                result: result,
                confirmed: confirmed
            )

            switch result {
            case .applied:
                statusMessage = nil
            case .unavailable:
                statusMessage = "\(key.feature.title) is unavailable on \(displayName)."
            case .invalidTarget:
                statusMessage = "That \(key.feature.title.lowercased()) value is not valid."
            case .failed:
                statusMessage = "\(displayName) did not confirm the \(key.feature.title.lowercased()) change."
            }
            if case .applied = result {
                return
            }
            syncValues()
        }
    }

    private func syncValues() {
        var updated: [ControlKey: Double] = [:]
        for display in displayService.displays {
            for (feature, reading) in display.features {
                let key = ControlKey(displayID: display.id, feature: feature)
                updated[key] = pendingWrites.contains(key) ? values[key] : reading.normalized
            }
        }
        values = updated
    }
}

private extension DisplayFeature {
    var title: String {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        }
    }

    var systemImage: String {
        switch self {
        case .brightness: "sun.max.fill"
        case .contrast: "circle.lefthalf.filled"
        }
    }
}
#else
@MainActor
struct DisplaysPane: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "display")
                .font(.system(size: 22))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text("Display controls are not included in this build.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.xxl)
    }
}
#endif
