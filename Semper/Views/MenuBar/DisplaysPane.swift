import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if !APP_STORE
@MainActor
struct DisplaysPane: View {
    @Bindable var displayService: DisplayControlService
    let isSceneOperationInProgress: Bool
    private let sceneOperationIsInProgress: @MainActor () -> Bool

    init(
        displayService: DisplayControlService,
        isSceneOperationInProgress: Bool,
        sceneOperationIsInProgress: @escaping @MainActor () -> Bool
    ) {
        self.displayService = displayService
        self.isSceneOperationInProgress = isSceneOperationInProgress
        self.sceneOperationIsInProgress = sceneOperationIsInProgress
    }

    private struct ControlKey: Hashable {
        let displayID: DisplayIdentity
        let feature: DisplayFeature
    }

    private struct InputRequest: Identifiable {
        let id = UUID()
        let displayID: DisplayIdentity
        let displayName: String
        let value: UInt8
    }

    private struct UnavailableControl: Identifiable {
        let kind: DisplayControlKind
        let reason: DisplayControlUnavailableReason

        var id: DisplayControlKind { kind }
    }

    @State private var values: [ControlKey: Double] = [:]
    @State private var volumeValues: [DisplayIdentity: Double] = [:]
    @State private var editingFeatureKeys = Set<ControlKey>()
    @State private var editingVolumeIDs = Set<DisplayIdentity>()
    @State private var pendingWrites = Set<ControlKey>()
    @State private var pendingVolumeWrites = Set<DisplayIdentity>()
    @State private var pendingInputWrites = Set<DisplayIdentity>()
    @State private var changesSlidersTogether = false
    @State private var isRefreshing = false
    @State private var inputRequest: InputRequest?
    @State private var statusMessage: String?
    @State private var identificationController = DisplayIdentificationController()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if displayService.displays.count > 1 {
                groupControl
            }

            if displayService.inventory.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(displayService.inventory) { item in
                        displaySection(item)
                        if item.id != displayService.inventory.last?.id {
                            Divider()
                        }
                    }
                }
            }

            supportActions

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
            await refreshDisplays()
        }
        .onChange(of: displayService.displays) { _, _ in
            syncValues()
        }
        .onChange(of: isSceneOperationInProgress) { _, isInProgress in
            guard isInProgress else { return }
            inputRequest = nil
            editingFeatureKeys.removeAll()
            editingVolumeIDs.removeAll()
            syncValues()
        }
        .onDisappear {
            identificationController.clear()
        }
        .confirmationDialog(
            "Switch monitor input?",
            isPresented: Binding(
                get: { inputRequest != nil },
                set: { if !$0 { inputRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: inputRequest
        ) { request in
            Button("Switch to \(inputLabel(request.value))") {
                inputRequest = nil
                writeInput(request)
            }
            .disabled(sceneOperationIsInProgress())
            Button("Cancel", role: .cancel) {
                inputRequest = nil
            }
        } message: { request in
            Text(
                "Semper will send one input switch to \(request.displayName). It will not retry or switch back if the monitor stops responding."
            )
        }
    }

    private var header: some View {
        HStack {
            SectionHeader(title: "External Displays")

            Spacer()

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Refreshing displays")
            }

            Button {
                Task { await refreshDisplays() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background {
                        Circle().fill(DesignTokens.Colors.nextControlBackground)
                    }
            }
            .buttonStyle(.plain)
            .disabled(isSceneOperationInProgress || isRefreshing)
            .help("Refresh displays")
            .accessibilityLabel("Refresh displays")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private var groupControl: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            Text("Change supported sliders together")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            Spacer()

            Toggle("", isOn: $changesSlidersTogether)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(hasPendingWrites || hasActiveEditing || isSceneOperationInProgress)
                .accessibilityLabel("Change supported display sliders together")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Text("No external display found")
                .font(DesignTokens.Typography.rowName)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text("Connect a DDC/CI display, then refresh. macOS display controls remain available in System Settings.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.xxl)
    }

    private func displaySection(_ item: DisplayInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            displayHeader(item)

            if let display = device(for: item) {
                ForEach(DisplayFeature.allCases, id: \.self) { feature in
                    if display.features[feature] != nil {
                        featureRow(feature, display: display)
                    }
                }

                if case .available(let volume) = display.volume {
                    volumeRow(volume, display: display)
                }

                if case .available(let input) = display.input {
                    inputRow(input, display: display)
                }
            }

            ForEach(unavailableControls(for: item)) { control in
                unavailableRow(control)
            }

            if case .unavailable(let reason) = item.systemDisplay,
               item.identity != nil {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .frame(width: 16)
                    Text("Identify: \(reason.message)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private func displayHeader(_ item: DisplayInventoryItem) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "display")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accentPrimary)

            Text(item.name)
                .font(DesignTokens.Typography.rowNameBold)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)

            Text(item.backendLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(DesignTokens.Colors.nextControlBackground))
                .accessibilityLabel("Control backend \(item.backendLabel)")

            Spacer(minLength: DesignTokens.Spacing.xs)

            if let displayID = item.systemDisplay.displayID {
                Button {
                    identify(displayID: displayID)
                } label: {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Identify \(item.name)")
                .accessibilityLabel("Identify \(item.name)")
            }

            Button {
                exportDiagnostics(for: item)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Export local diagnostics for \(item.name)")
            .accessibilityLabel("Export local diagnostics for \(item.name)")
        }
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
                    updateFeatureEditing(
                        isEditing,
                        for: key,
                        displayName: display.name
                    )
                }
            )
            .disabled(!isAvailable || pendingWrites.contains(key))
            .accessibilityLabel("\(feature.title) for \(display.name)")
            .accessibilityValue(
                "\(Int((value(for: key, display: display) * 100).rounded())) percent"
            )

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

    private func volumeRow(_ reading: DisplayVolumeReading, display: DisplayDevice) -> some View {
        let isPending = pendingVolumeWrites.contains(display.id)
        let isAvailable = !isSceneOperationInProgress

        return HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 16)

            Text("Volume")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 58, alignment: .leading)

            LiquidGlassSlider(
                value: volumeBinding(for: display),
                alwaysShowsThumb: true,
                onEditingChanged: { isEditing in
                    updateVolumeEditing(isEditing, for: display)
                }
            )
            .disabled(!isAvailable || isPending)
            .accessibilityLabel("Volume for \(display.name)")
            .accessibilityValue(volumeLabel(reading, display: display))

            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: DesignTokens.Dimensions.percentageWidth)
                    .accessibilityLabel("Saving volume")
            } else {
                Text(volumeLabel(reading, display: display))
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .monospacedDigit()
                    .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
            }
        }
        .opacity(isAvailable ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private func inputRow(_ reading: DisplayInputReading, display: DisplayDevice) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "cable.connector")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 16)

            Text("Input")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 58, alignment: .leading)

            Menu {
                ForEach(reading.advertisedValues, id: \.self) { value in
                    Button {
                        guard value != reading.current else { return }
                        inputRequest = InputRequest(
                            displayID: display.id,
                            displayName: display.name,
                            value: value
                        )
                    } label: {
                        if value == reading.current {
                            Label(inputLabel(value), systemImage: "checkmark")
                        } else {
                            Text(inputLabel(value))
                        }
                    }
                }
            } label: {
                Text(inputLabel(reading.current))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .disabled(isSceneOperationInProgress || pendingInputWrites.contains(display.id))
            .accessibilityLabel("Input for \(display.name)")
            .accessibilityValue(inputLabel(reading.current))

            if pendingInputWrites.contains(display.id) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: DesignTokens.Dimensions.percentageWidth)
                    .accessibilityLabel("Confirming input")
            }
        }
    }

    private func unavailableRow(_ control: UnavailableControl) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "minus.circle")
                .frame(width: 16)
            Text("\(control.kind.title): \(control.reason.message)")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(DesignTokens.Colors.textTertiary)
        .accessibilityElement(children: .combine)
    }

    private var supportActions: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                identifyAll()
            } label: {
                Label("Identify All", systemImage: "rectangle.3.group")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                openDisplaySettings()
            } label: {
                Label("Display Settings", systemImage: "gear")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private var hasPendingWrites: Bool {
        !pendingWrites.isEmpty || !pendingVolumeWrites.isEmpty || !pendingInputWrites.isEmpty
    }

    private var hasActiveEditing: Bool {
        !editingFeatureKeys.isEmpty || !editingVolumeIDs.isEmpty
    }

    private func device(for item: DisplayInventoryItem) -> DisplayDevice? {
        guard let identity = item.identity else { return nil }
        return displayService.displays.first(where: { $0.id == identity })
    }

    private func valueBinding(for key: ControlKey, display: DisplayDevice) -> Binding<Double> {
        Binding(
            get: { value(for: key, display: display) },
            set: { newValue in
                values[key] = newValue
                guard changesSlidersTogether else { return }
                for member in featureGroupMembers(key.feature) {
                    values[ControlKey(displayID: member, feature: key.feature)] = newValue
                }
            }
        )
    }

    private func value(for key: ControlKey, display: DisplayDevice) -> Double {
        values[key] ?? display.features[key.feature]?.normalized ?? 0
    }

    private func volumeBinding(for display: DisplayDevice) -> Binding<Double> {
        Binding(
            get: { volumeValues[display.id] ?? display.volume.value?.normalized ?? 0 },
            set: { newValue in
                volumeValues[display.id] = newValue
                guard changesSlidersTogether else { return }
                for member in volumeGroupMembers() {
                    volumeValues[member] = newValue
                }
            }
        )
    }

    private func updateFeatureEditing(
        _ isEditing: Bool,
        for key: ControlKey,
        displayName: String
    ) {
        if isEditing {
            editingFeatureKeys.insert(key)
            return
        }
        editingFeatureKeys.remove(key)
        guard !sceneOperationIsInProgress() else {
            syncValues()
            return
        }
        writeValue(for: key, displayName: displayName)
    }

    private func updateVolumeEditing(_ isEditing: Bool, for display: DisplayDevice) {
        if isEditing {
            editingVolumeIDs.insert(display.id)
            return
        }
        editingVolumeIDs.remove(display.id)
        guard !sceneOperationIsInProgress() else {
            syncValues()
            return
        }
        writeVolume(for: display)
    }

    private func writeValue(for key: ControlKey, displayName: String) {
        guard DisplayManualControlDispatchPolicy.allowsDispatch(
            sceneOperationIsInProgress: sceneOperationIsInProgress,
            isPending: pendingWrites.contains(key)
        ), let requested = values[key] else {
            return
        }
        let members = changesSlidersTogether ? featureGroupMembers(key.feature) : [key.displayID]
        let keys = Set(members.map { ControlKey(displayID: $0, feature: key.feature) })
        let displayNames = capturedDisplayNames(for: members)
        pendingWrites.formUnion(keys)
        statusMessage = nil

        Task {
            guard !sceneOperationIsInProgress() else {
                pendingWrites.subtract(keys)
                syncValues()
                return
            }
            do {
                if members.count > 1 {
                    let group = DisplayControlGroup(name: "Linked Displays", members: members)
                    let report = try await displayService.apply(
                        .feature(key.feature, normalized: requested),
                        to: group
                    )
                    statusMessage = DisplayGroupStatusFormatter.message(
                        controlName: key.feature.title,
                        report: report,
                        displayNames: displayNames
                    )
                } else {
                    let result = try await displayService.set(
                        requested,
                        feature: key.feature,
                        for: key.displayID
                    )
                    statusMessage = featureStatus(
                        result,
                        feature: key.feature,
                        displayName: displayName
                    )
                }
            } catch is CancellationError {
            } catch {
                statusMessage = "Display changes are temporarily unavailable."
            }
            pendingWrites.subtract(keys)
            syncValues()
        }
    }

    private func writeVolume(for display: DisplayDevice) {
        guard DisplayManualControlDispatchPolicy.allowsDispatch(
            sceneOperationIsInProgress: sceneOperationIsInProgress,
            isPending: pendingVolumeWrites.contains(display.id)
        ), let requested = volumeValues[display.id] else {
            return
        }
        let members = changesSlidersTogether ? volumeGroupMembers() : [display.id]
        let displayNames = capturedDisplayNames(for: members)
        pendingVolumeWrites.formUnion(members)
        statusMessage = nil

        Task {
            guard !sceneOperationIsInProgress() else {
                pendingVolumeWrites.subtract(members)
                syncValues()
                return
            }
            do {
                if members.count > 1 {
                    let group = DisplayControlGroup(name: "Linked Displays", members: members)
                    let report = try await displayService.apply(
                        .volume(normalized: requested),
                        to: group
                    )
                    statusMessage = DisplayGroupStatusFormatter.message(
                        controlName: "Volume",
                        report: report,
                        displayNames: displayNames
                    )
                } else {
                    let result = try await displayService.setVolume(requested, for: display.id)
                    statusMessage = volumeStatus(result, displayName: display.name)
                }
            } catch is CancellationError {
            } catch {
                statusMessage = "Display volume is temporarily unavailable."
            }
            pendingVolumeWrites.subtract(members)
            syncValues()
        }
    }

    private func writeInput(_ request: InputRequest) {
        guard DisplayManualControlDispatchPolicy.allowsDispatch(
            sceneOperationIsInProgress: sceneOperationIsInProgress,
            isPending: pendingInputWrites.contains(request.displayID)
        ) else {
            return
        }
        pendingInputWrites.insert(request.displayID)
        statusMessage = nil

        Task {
            guard !sceneOperationIsInProgress() else {
                pendingInputWrites.remove(request.displayID)
                return
            }
            do {
                let result = try await displayService.setInput(
                    request.value,
                    for: request.displayID
                )
                switch result {
                case .applied:
                    statusMessage = "\(request.displayName) confirmed \(inputLabel(request.value))."
                case .unavailable(let reason):
                    statusMessage = "Input is unavailable on \(request.displayName): \(reason.message)"
                case .invalidTarget:
                    statusMessage = "That input was not advertised by \(request.displayName)."
                case .unconfirmed:
                    statusMessage = "The input switch was attempted once, but \(request.displayName) did not confirm it. Semper will not retry or switch back."
                }
            } catch is CancellationError {
            } catch {
                statusMessage = "The input request could not be completed."
            }
            pendingInputWrites.remove(request.displayID)
        }
    }

    private func featureGroupMembers(_ feature: DisplayFeature) -> [DisplayIdentity] {
        displayService.displays.compactMap { display in
            display.features[feature] == nil ? nil : display.id
        }
    }

    private func volumeGroupMembers() -> [DisplayIdentity] {
        displayService.displays.compactMap { display in
            display.volume.value == nil ? nil : display.id
        }
    }

    private func capturedDisplayNames(
        for members: [DisplayIdentity]
    ) -> [DisplayIdentity: String] {
        Dictionary(uniqueKeysWithValues: members.map { identity in
            let name = displayService.displays.first(where: { $0.id == identity })?.name
                ?? displayService.inventory.first(where: { $0.identity == identity })?.name
                ?? "Disconnected display"
            return (identity, name)
        })
    }

    private func featureStatus(
        _ result: DisplayWriteResult,
        feature: DisplayFeature,
        displayName: String
    ) -> String? {
        switch result {
        case .applied:
            nil
        case .unavailable:
            "\(feature.title) is unavailable on \(displayName)."
        case .invalidTarget:
            "That \(feature.title.lowercased()) value is not valid."
        case .failed:
            "\(displayName) did not confirm the \(feature.title.lowercased()) change."
        }
    }

    private func volumeStatus(
        _ result: DisplayVolumeWriteResult,
        displayName: String
    ) -> String? {
        switch result {
        case .applied:
            nil
        case .unavailable(let reason):
            "Volume is unavailable on \(displayName): \(reason.message)"
        case .invalidTarget:
            "That volume value is not valid."
        case .failed:
            "\(displayName) did not confirm the volume change."
        }
    }

    private func volumeLabel(_ reading: DisplayVolumeReading, display: DisplayDevice) -> String {
        DisplayVolumeLabel.text(
            reading: reading,
            draft: volumeValues[display.id]
        )
    }

    private func inputLabel(_ value: UInt8) -> String {
        DisplayInputLabel.text(for: value)
    }

    private func unavailableControls(for item: DisplayInventoryItem) -> [UnavailableControl] {
        var controls: [UnavailableControl] = []
        if case .unavailable(let reason) = item.controls.brightness {
            controls.append(UnavailableControl(kind: .brightness, reason: reason))
        }
        if case .unavailable(let reason) = item.controls.contrast {
            controls.append(UnavailableControl(kind: .contrast, reason: reason))
        }
        if case .unavailable(let reason) = item.controls.volume {
            controls.append(UnavailableControl(kind: .volume, reason: reason))
        }
        if case .unavailable(let reason) = item.controls.input {
            controls.append(UnavailableControl(kind: .input, reason: reason))
        }
        return controls
    }

    private func refreshDisplays() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await displayService.probe()
        syncValues()
    }

    private func syncValues() {
        var updatedValues: [ControlKey: Double] = [:]
        var updatedVolumeValues: [DisplayIdentity: Double] = [:]
        for display in displayService.displays {
            for (feature, reading) in display.features {
                let key = ControlKey(displayID: display.id, feature: feature)
                let preservesLinkedDraft = changesSlidersTogether
                    && editingFeatureKeys.contains(where: { $0.feature == feature })
                let preservesDraft = DisplaySliderDraftPolicy.preservesDraft(
                    isPending: pendingWrites.contains(key),
                    isEditing: editingFeatureKeys.contains(key),
                    isLinkedToActiveEdit: preservesLinkedDraft
                )
                updatedValues[key] = preservesDraft ? values[key] : reading.normalized
            }
            if let reading = display.volume.value {
                let preservesDraft = DisplaySliderDraftPolicy.preservesDraft(
                    isPending: pendingVolumeWrites.contains(display.id),
                    isEditing: editingVolumeIDs.contains(display.id),
                    isLinkedToActiveEdit: changesSlidersTogether && !editingVolumeIDs.isEmpty
                )
                if let synchronized = DisplaySliderDraftPolicy.synchronizedValue(
                    published: reading.normalized,
                    draft: volumeValues[display.id],
                    preservesDraft: preservesDraft
                ) {
                    updatedVolumeValues[display.id] = synchronized
                }
            }
        }
        values = updatedValues
        volumeValues = updatedVolumeValues
    }

    private func identify(displayID: UInt32) {
        switch identificationController.identify(displayID: displayID) {
        case .success:
            statusMessage = nil
        case .failure:
            statusMessage = "That display could not be identified. Refresh the display list and try again."
        }
    }

    private func identifyAll() {
        switch identificationController.identifyAll() {
        case .success:
            statusMessage = nil
        case .failure:
            statusMessage = "No active macOS displays could be identified."
        }
    }

    private func openDisplaySettings() {
        if !DisplaySystemSettingsOpener().open() {
            statusMessage = "macOS Display Settings could not be opened."
        }
    }

    private func exportDiagnostics(for item: DisplayInventoryItem) {
        let report = diagnosticReport(for: item)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Semper-Display-Diagnostic.json"
        panel.message = "This local report omits monitor names and identifiers."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try DisplayDiagnosticsExporter().export(report, to: destination)
            statusMessage = "Display diagnostics were saved locally."
        } catch {
            statusMessage = "Display diagnostics could not be saved."
        }
    }

    private func diagnosticReport(for item: DisplayInventoryItem) -> DisplayDiagnosticsReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DisplayDiagnosticsReport.make(
            for: item,
            generatedAt: Date(),
            applicationVersion: applicationVersion,
            operatingSystemVersion: .init(
                major: UInt(max(version.majorVersion, 0)),
                minor: UInt(max(version.minorVersion, 0)),
                patch: UInt(max(version.patchVersion, 0))
            ),
            distribution: .direct
        )
    }

    private var applicationVersion: DisplayDiagnosticsReport.Version? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count) else { return nil }
        let values = components.compactMap { UInt($0) }
        guard values.count == components.count else { return nil }
        return .init(major: values[0], minor: values[1], patch: values.count > 2 ? values[2] : 0)
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

private extension DisplayControlKind {
    var title: String {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .volume: "Volume"
        case .input: "Input"
        }
    }
}
#else
@MainActor
struct DisplaysPane: View {
    @State private var identificationController = DisplayIdentificationController()
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SectionHeader(title: "Displays")

            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "display")
                    .font(.system(size: 22))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text("macOS Settings")
                        .font(DesignTokens.Typography.rowNameBold)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Text("Direct monitor controls are not included in this build.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Identify All", systemImage: "rectangle.3.group") {
                    identifyAll()
                }
                .frame(maxWidth: .infinity)

                Button("Display Settings", systemImage: "gear") {
                    if !DisplaySystemSettingsOpener().open() {
                        statusMessage = "macOS Display Settings could not be opened."
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let statusMessage {
                Text(statusMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .onDisappear {
            identificationController.clear()
        }
    }

    private func identifyAll() {
        switch identificationController.identifyAll() {
        case .success:
            statusMessage = nil
        case .failure:
            statusMessage = "No active macOS displays could be identified."
        }
    }
}
#endif
