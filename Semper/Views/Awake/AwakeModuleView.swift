import SwiftUI

struct AwakeModuleView: View {
    let awake: AwakeService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isReasonFocused: Bool
    @State private var reasonDraft = ""
    @State private var applications: [AwakeApplication] = []

    private let durationColumns = [
        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm)
    ]

    init(awake: AwakeService) {
        self.awake = awake
        _reasonDraft = State(initialValue: awake.sessionReason)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            statusRow
            if let session = awake.session {
                sessionDetails(session)
            }
            if let owners = AwakeSessionPresentation.leaseOwners(awake.leaseStates, manualSessionActive: awake.isActive) {
                Text(owners)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            durationGrid
            reasonField
            stopConditions
            displayToggleRow
            if let endReason = awake.lastSessionEndReason {
                Text(AwakeSessionPresentation.endReasonText(endReason))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failureText {
                Text(failureText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if awake.manualMutationRejected {
                Text("Manual Awake changes are unavailable while another mode has exclusive control.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .onAppear {
            reasonDraft = awake.sessionReason
            refreshApplications()
        }
        .onChange(of: isReasonFocused) { _, focused in
            if !focused { commitReason() }
        }
        .onChange(of: awake.sessionReason) { _, reason in
            if !isReasonFocused { reasonDraft = reason }
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
                .accessibilityHint("Ends this manual session. Other tools keep their own Awake requests.")
            }
        }
    }

    @ViewBuilder
    private func sessionDetails(_ session: AwakeSession) -> some View {
        let presentation = AwakeSessionPresentation(session: session, now: session.startedAt)
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.reason)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Session reason")
                .accessibilityValue(presentation.reason)

            Text("Started \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            if session.endsAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdownText(AwakeSessionPresentation(session: session, now: context.date))
                }
            } else {
                countdownText(AwakeSessionPresentation(session: session, now: session.startedAt))
            }
        }
    }

    private func countdownText(_ presentation: AwakeSessionPresentation) -> some View {
        Text(presentation.remainingText)
            .font(DesignTokens.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .accessibilityLabel("Time remaining")
            .accessibilityValue(presentation.remainingAccessibilityText)
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
            commitReason()
            isReasonFocused = false
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

    private var reasonField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Session reason (optional)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            TextField("Manual Awake session", text: $reasonDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($isReasonFocused)
                .onSubmit(commitReason)
                .onChange(of: reasonDraft) { _, reason in
                    if reason.count > 120 { reasonDraft = String(reason.prefix(120)) }
                }
                .accessibilityLabel("Session reason, optional")
                .accessibilityHint("Up to 120 characters. Press Return to apply.")
        }
    }

    private var stopConditions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            applicationMenu
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("Battery cutoff")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer(minLength: 0)
                Picker("Battery cutoff", selection: Binding(
                    get: { awake.conditions.batteryThreshold },
                    set: { threshold in
                        var conditions = awake.conditions
                        conditions.batteryThreshold = threshold
                        awake.setConditions(conditions)
                    }
                )) {
                    Text("Off").tag(AwakeBatteryThreshold?.none)
                    ForEach(AwakeBatteryThreshold.allCases) { threshold in
                        Text("\(threshold.rawValue)%").tag(Optional(threshold))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityHint("Ends this manual session only, at or below the selected charge while on battery.")
            }
            if awake.conditions.batteryThreshold != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stops at or below the cutoff on battery. Plugged in, the cutoff is ignored.")
                    if awake.lastSessionEndReason != .batteryStateUnavailable {
                        Text(AwakeSessionPresentation.batteryStatus(awake.conditionSnapshot))
                    }
                }
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var applicationMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stop when this app quits")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Menu {
                Button {
                    selectApplication(nil)
                } label: {
                    if awake.conditions.application == nil {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
                if let selected = awake.conditions.application,
                   !applications.contains(where: { $0.id == selected.id }) {
                    Text("\(selected.name) (not in refreshed list)")
                }
                ForEach(applications) { application in
                    let hasAnotherInstance = applications.contains {
                        $0.name == application.name && $0.id != application.id
                    }
                    let label = hasAnotherInstance
                        ? "\(application.name) (PID \(application.id.processIdentifier))"
                        : application.name
                    Button {
                        selectApplication(application)
                    } label: {
                        if awake.conditions.application?.id == application.id {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
                Divider()
                Button("Refresh apps", action: refreshApplications)
            } label: {
                Text(awake.conditions.application?.name ?? "None")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .accessibilityLabel("Stop when this app quits")
            .accessibilityValue(awake.conditions.application?.name ?? "None")
            .accessibilityHint("Applies to this running copy of the selected app. Use Refresh apps to update the list.")
            .help(awake.conditions.application?.name ?? "Choose an app that is currently running")
        }
    }

    private func commitReason() {
        awake.setSessionReason(reasonDraft)
        reasonDraft = awake.sessionReason
    }

    private func refreshApplications() {
        applications = awake.availableApplications()
    }

    private func selectApplication(_ application: AwakeApplication?) {
        var conditions = awake.conditions
        conditions.application = application
        awake.setConditions(conditions)
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
