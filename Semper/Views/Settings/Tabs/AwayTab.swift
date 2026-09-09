import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AwayTab: View {
    @Bindable var coordinator: AwayModeCoordinator

    @State private var hasEventAccess = false
    @State private var eventAccessChecked = false
    @State private var authenticationMethod: AwayAuthenticationMethod = .system
    @State private var pinDraft = AwayPINSetupDraft()
    @State private var authenticationInProgress = false
    @State private var authenticationTask: Task<Void, Never>?
    @State private var authenticationOperationID: UUID?
    @State private var authenticationStatusMessage: String?
    @State private var photoStatusMessage: String?
    @State private var loadedPreferences = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                authenticationSection
                permissionSection
                appearanceSection
                widgetsSection
                displaySection
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear {
            guard !loadedPreferences else { return }
            authenticationMethod = coordinator.preferences.authenticationMethod
            checkEventAccess()
            loadedPreferences = true
        }
        .onDisappear {
            authenticationTask?.cancel()
            authenticationTask = nil
            authenticationOperationID = nil
            authenticationInProgress = false
        }
    }

    private var authenticationSection: some View {
        SettingsSection("Authentication", subtitle: "How you leave the curtain") {
            SettingsRow(
                "Exit Method",
                description: "Use Mac authentication or a separate four digit PIN"
            ) {
                Picker("Exit Method", selection: $authenticationMethod) {
                    ForEach(AwayAuthenticationMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)
                .disabled(authenticationInProgress)
                .onChange(of: authenticationMethod) { oldValue, newValue in
                    authenticationMethodChanged(from: oldValue, to: newValue)
                }
            }

            if authenticationMethod == .pin {
                SettingsRowDivider()
                SettingsRow(
                    "Set PIN",
                    description: "Saving a PIN requires Mac authentication"
                ) {
                    HStack(spacing: 8) {
                        SecureField(
                            "4-digit PIN",
                            text: Binding(
                                get: { pinDraft.pin },
                                set: { pinDraft.setPIN($0) }
                            )
                        )
                        SecureField(
                            "Confirm PIN",
                            text: Binding(
                                get: { pinDraft.confirmation },
                                set: { pinDraft.setConfirmation($0) }
                            )
                        )
                        Button("Set PIN") {
                            savePIN()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!pinDraft.isValid || authenticationInProgress)
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 410)
                }
            }

            if let message = authenticationStatusMessage ?? coordinator.pinConfigurationError {
                SettingsRowDivider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Colors.systemOrange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                .padding(DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Authentication status")
                .accessibilityValue(message)
            }
        }
    }

    private var permissionSection: some View {
        SettingsSection("Event Access", subtitle: "Required for input filtering") {
            SettingsRow(
                eventAccessChecked
                    ? (hasEventAccess ? "Access Confirmed" : "Access Needed")
                    : "Not Checked",
                description: "Semper checks access only when you ask or open this pane"
            ) {
                HStack(spacing: 8) {
                    Image(systemName: hasEventAccess ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(
                            hasEventAccess
                                ? DesignTokens.Colors.systemGreen
                                : DesignTokens.Colors.systemOrange
                        )
                        .accessibilityHidden(true)

                    Button("Request Access") {
                        coordinator.requestEventAccess()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Check Again") {
                        checkEventAccess()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSection("Appearance", subtitle: "What covers each display") {
            SettingsRow(
                "Curtain Theme",
                description: "Preview and choose one of four curtain styles"
            ) {
                AwayThemePicker(
                    selection: coordinator.preferences.theme,
                    accent: coordinator.preferences.accent,
                    customPhotoAvailable: coordinator.hasManagedPhotoFile
                ) { theme in
                    update(\.theme, to: theme)
                }
                .frame(width: 410)
            }

            SettingsRowDivider()
            SettingsRow("Accent", description: "Tint for motion and controls") {
                AwayAccentPicker(selection: coordinator.preferences.accent) { accent in
                    update(\.accent, to: accent)
                }
            }

            SettingsRowDivider()
            SettingsRow(
                "Custom Photo",
                description: photoDescription
            ) {
                Button("Choose Photo") {
                    choosePhoto()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            SettingsRowDivider()
            SettingsRow("Photo Sizing", description: "Fill crops edges; Fit keeps the full image") {
                Picker("Photo Sizing", selection: binding(\.photoFit)) {
                    ForEach(AwayPhotoFit.allCases) { fit in
                        Text(fit.title).tag(fit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            SettingsRowDivider()
            SettingsRow("Ambient Motion", description: "Motion pauses for power and accessibility") {
                Picker("Ambient Motion", selection: binding(\.motionLevel)) {
                    ForEach(AwayMotionLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
        }
    }

    private var widgetsSection: some View {
        SettingsSection("Widgets", subtitle: "Local details on the primary display") {
            SettingsRow("Message", description: "Plain text, up to 140 characters") {
                VStack(alignment: .trailing, spacing: 3) {
                    TextField("Optional away message", text: binding(\.customMessage), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...3)
                        .frame(width: 360)
                    Text("\(coordinator.preferences.customMessage.count) / 140")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }

            SettingsRowDivider()
            SettingsRow("Position", description: "Place the local widget group") {
                AwayWidgetPlacementPicker(
                    selection: coordinator.preferences.widgetPlacement
                ) { placement in
                    update(\.widgetPlacement, to: placement)
                }
            }

            SettingsRowDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Visible Items")
                    .font(DesignTokens.Typography.rowNameBold)
                HStack(spacing: 18) {
                    Toggle("Local Time", isOn: binding(\.showsClock))
                    Toggle("Elapsed Time", isOn: binding(\.showsElapsedTime))
                    Toggle("Battery", isOn: binding(\.showsBattery))
                    Toggle("Awake Request", isOn: binding(\.showsAwakeState))
                }
                .toggleStyle(.checkbox)
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displaySection: some View {
        SettingsSection("Power and Display", subtitle: "Visibility and idle dimming") {
            SettingsRow(
                "Keep Display Visible",
                description: "Off by default. The Mac may turn displays off normally."
            ) {
                Toggle("Keep Display Visible", isOn: binding(\.keepsDisplayAwake))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            SettingsRowDivider()
            SettingsRow(
                "Dim to Black",
                description: "Applies only while Keep Display Visible is on"
            ) {
                Picker("Dim to Black", selection: binding(\.dimDelay)) {
                    ForEach(AwayDimDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 290)
                .disabled(!coordinator.preferences.keepsDisplayAwake)
            }
        }
    }

    private var photoDescription: String {
        if let message = photoStatusMessage {
            return message
        }
        guard coordinator.preferences.managedPhotoFilename != nil else {
            return "PNG, JPEG, or HEIC up to 50 MB"
        }
        return coordinator.hasManagedPhotoFile
            ? "A managed local copy is selected"
            : "The managed photo is missing. Choose a replacement."
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AwayModePreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { coordinator.preferences[keyPath: keyPath] },
            set: { update(keyPath, to: $0) }
        )
    }

    private func update<Value>(
        _ keyPath: WritableKeyPath<AwayModePreferences, Value>,
        to value: Value
    ) {
        coordinator.updatePreferences { preferences in
            preferences[keyPath: keyPath] = value
        }
    }

    private func checkEventAccess() {
        hasEventAccess = coordinator.checkEventAccess()
        eventAccessChecked = true
    }

    private func authenticationMethodChanged(
        from oldValue: AwayAuthenticationMethod,
        to newValue: AwayAuthenticationMethod
    ) {
        authenticationStatusMessage = nil
        guard oldValue != newValue else { return }
        if newValue == .system, coordinator.preferences.authenticationMethod == .pin {
            authenticationTask?.cancel()
            let operationID = UUID()
            authenticationOperationID = operationID
            authenticationInProgress = true
            authenticationTask = Task { @MainActor in
                let removed = await coordinator.removePIN()
                guard !Task.isCancelled,
                      authenticationOperationID == operationID else { return }
                authenticationTask = nil
                authenticationOperationID = nil
                authenticationInProgress = false
                guard authenticationMethod == .system else { return }
                if !removed {
                    authenticationMethod = coordinator.preferences.authenticationMethod
                    authenticationStatusMessage = coordinator.pinConfigurationError
                }
            }
        }
    }

    private func savePIN() {
        authenticationTask?.cancel()
        let operationID = UUID()
        authenticationOperationID = operationID
        authenticationInProgress = true
        authenticationStatusMessage = nil
        authenticationTask = Task { @MainActor in
            let saved = await coordinator.configurePIN(
                pinDraft.pin,
                confirmation: pinDraft.confirmation
            )
            guard !Task.isCancelled,
                  authenticationOperationID == operationID else { return }
            authenticationTask = nil
            authenticationOperationID = nil
            authenticationInProgress = false
            guard authenticationMethod == .pin else { return }
            if saved {
                pinDraft = AwayPINSetupDraft()
                authenticationStatusMessage = "PIN saved."
            } else {
                authenticationStatusMessage = coordinator.pinConfigurationError
            }
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.prompt = "Choose Photo"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let photo = try coordinator.importPhoto(from: url)
            photoStatusMessage = "Photo imported, \(photo.pixelWidth) by \(photo.pixelHeight) pixels."
        } catch let error as AwayModeDataError {
            photoStatusMessage = error.message
        } catch {
            photoStatusMessage = "That photo could not be imported. Choose a supported file under 50 MB."
        }
    }
}

@MainActor
private struct AwayWidgetPlacementPicker: View {
    let selection: AwayWidgetPlacement
    let onSelect: (AwayWidgetPlacement) -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let columns = [
        GridItem(.fixed(56), spacing: 6),
        GridItem(.fixed(56), spacing: 6),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(AwayWidgetPlacement.allCases) { placement in
                Button {
                    onSelect(placement)
                } label: {
                    ZStack(alignment: placement.alignment) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DesignTokens.Colors.nextControlBackground)
                        Circle()
                            .fill(
                                selection == placement
                                    ? DesignTokens.Colors.accentPrimary
                                    : DesignTokens.Colors.textTertiary
                            )
                            .frame(width: 9, height: 9)
                            .padding(6)
                        if selection == placement {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 56, height: 34)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                selection == placement
                                    ? DesignTokens.Colors.accentPrimary
                                    : DesignTokens.Colors.nextControlBorder,
                                lineWidth: selection == placement
                                    || colorSchemeContrast == .increased ? 2 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(placement.title)
                .accessibilityAddTraits(selection == placement ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Widget Position")
    }
}
