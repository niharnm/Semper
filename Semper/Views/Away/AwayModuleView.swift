import AppKit
import SwiftUI

enum AwayModeCopy {
    static let disclosure = "Away Mode covers every display with a privacy curtain. It is not the macOS Lock Screen and does not protect your account. It is not an OS security boundary. Force Quit, Semper failure, restart, administrator or Accessibility control, remote access, authorized capture software, and display-change timing can expose the desktop."
    static let exitPrompt = "Authenticate to exit Away Mode."
}

struct AwayPINSetupDraft: Equatable {
    private(set) var pin = ""
    private(set) var confirmation = ""

    var isValid: Bool {
        AwayPINCodec.isValidPIN(pin) && pin == confirmation
    }

    mutating func setPIN(_ value: String) {
        pin = Self.sanitize(value)
    }

    mutating func setConfirmation(_ value: String) {
        confirmation = Self.sanitize(value)
    }

    private static func sanitize(_ value: String) -> String {
        let digits = value.utf8.filter { (48...57).contains($0) }.prefix(4)
        return String(decoding: digits, as: UTF8.self)
    }
}

struct AwaySetupSubmission: Equatable {
    let authenticationMethod: AwayAuthenticationMethod
    let theme: AwayModeTheme
    let accent: AwayModeAccent
    let pin: String
    let confirmation: String
    private let removesExistingPIN: Bool
    private let keepsExistingPIN: Bool

    init(
        authenticationMethod: AwayAuthenticationMethod,
        theme: AwayModeTheme,
        accent: AwayModeAccent,
        pin: String,
        confirmation: String,
        existingAuthenticationMethod: AwayAuthenticationMethod,
        existingPINIsUsable: Bool = false
    ) {
        self.authenticationMethod = authenticationMethod
        self.theme = theme
        self.accent = accent
        self.pin = pin
        self.confirmation = confirmation
        self.removesExistingPIN = authenticationMethod == .system
            && existingAuthenticationMethod == .pin
        self.keepsExistingPIN = authenticationMethod == .pin
            && existingAuthenticationMethod == .pin
            && existingPINIsUsable
            && pin.isEmpty
            && confirmation.isEmpty
    }

    @MainActor
    func apply(to coordinator: AwayModeCoordinator) async -> Bool {
        let authenticated: Bool
        if keepsExistingPIN {
            authenticated = true
        } else if authenticationMethod == .pin {
            authenticated = await coordinator.configurePIN(pin, confirmation: confirmation)
        } else if removesExistingPIN {
            authenticated = await coordinator.removePIN()
        } else {
            authenticated = true
        }

        guard !Task.isCancelled, authenticated else { return false }
        return coordinator.finishSetup(
            authenticationMethod: authenticationMethod,
            theme: theme,
            accent: accent
        )
    }
}

@MainActor
struct AwayModuleView: View {
    @Bindable var coordinator: AwayModeCoordinator
    let onOpenSettings: () -> Void

    @State private var showingSetup = false
    @State private var previewPhoto: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader

            switch coordinator.state {
            case .countdown(let remainingSeconds):
                countdownView(remainingSeconds: remainingSeconds)
            case .arming, .disarming:
                progressView
            case .guarded, .authenticating, .degraded:
                activeView
            case .inactive:
                inactiveView
            }

            if let error = coordinator.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.systemOrange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Away Mode error")
                    .accessibilityValue(error)
            }

            Text(AwayModeCopy.disclosure)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Away Mode privacy notice")
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
        .sheet(isPresented: $showingSetup) {
            AwaySetupView(coordinator: coordinator)
        }
        .task(id: coordinator.preferences.managedPhotoFilename) {
            previewPhoto = await coordinator.managedPhotoImage()
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(DesignTokens.Colors.nextControlBackground)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(statusDetail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var inactiveView: some View {
        selectedCurtainPreview

        if coordinator.preferences.disclosureCompleted {
            Button {
                coordinator.startCountdown()
            } label: {
                Label("Start Away Mode", systemImage: "eye.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Begins a five second countdown")

            HStack(spacing: 8) {
                Button(coordinator.lastErrorMessage == nil ? "Review Setup" : "Repair Setup") {
                    showingSetup = true
                }
                .buttonStyle(.bordered)

                Button("Customize") {
                    onOpenSettings()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        } else {
            Button {
                showingSetup = true
            } label: {
                Label("Set Up Away Mode", systemImage: "eye.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Reviews privacy limits, permissions, authentication, and appearance")

            Button("Customize") {
                onOpenSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var selectedCurtainPreview: some View {
        ZStack(alignment: .bottomLeading) {
            AwayThemeThumbnail(
                theme: coordinator.preferences.theme,
                accent: coordinator.preferences.accent,
                photo: previewPhoto,
                photoFit: coordinator.preferences.photoFit
            )

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Curtain Preview")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(coordinator.preferences.theme.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DesignTokens.Colors.nextControlBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Curtain preview, \(coordinator.preferences.theme.title)")
    }

    private func countdownView(remainingSeconds: Int) -> some View {
        VStack(spacing: 12) {
            Text("Starting Away Mode")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            Text("\(remainingSeconds)")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .contentTransition(.numericText())
                .accessibilityLabel("\(remainingSeconds) seconds remaining")

            HStack(spacing: 8) {
                Button("Cancel") {
                    coordinator.cancelCountdown()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start Now") {
                    coordinator.startNow()
                }
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesignTokens.Colors.nextControlBackground)
        }
    }

    private var progressView: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(coordinator.state == .arming ? "Preparing every display" : "Ending Away Mode")
                .font(.system(size: 11.5, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = coordinator.powerWarning {
                Text(warning)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.systemOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.isAuthenticating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for authentication")
                        .font(.system(size: 11.5, weight: .medium))
                }
            } else {
                Button {
                    coordinator.requestAuthentication()
                } label: {
                    Label("Authenticate to Exit", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .inactive:
            coordinator.preferences.disclosureCompleted ? "Away Mode ready" : "Setup required"
        case .countdown: "Starting Away Mode"
        case .arming: "Preparing curtains"
        case .guarded: "Away Mode active"
        case .authenticating: "Authentication in progress"
        case .degraded: "Away Mode needs attention"
        case .disarming: "Ending Away Mode"
        }
    }

    private var statusDetail: String {
        switch coordinator.state {
        case .inactive:
            coordinator.preferences.disclosureCompleted
                ? "When active, Semper requests idle-sleep prevention. Keep Display Visible adds a display request; lid close, manual Sleep, and low-power limits still apply."
                : "Review the limits before the first use"
        case .countdown(let seconds): "Starts in \(seconds) seconds"
        case .arming: "Checking coverage and input filtering"
        case .guarded: "Every connected display is covered"
        case .authenticating: AwayModeCopy.exitPrompt
        case .degraded(let message): message
        case .disarming: "Restoring your desktop"
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .guarded, .authenticating: DesignTokens.Colors.systemGreen
        case .degraded: DesignTokens.Colors.systemOrange
        default: DesignTokens.Colors.systemBlue
        }
    }
}

@MainActor
private struct AwaySetupView: View {
    @Bindable var coordinator: AwayModeCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var hasEventAccess = false
    @State private var eventAccessChecked = false
    @State private var authenticationMethod: AwayAuthenticationMethod = .system
    @State private var pinDraft = AwayPINSetupDraft()
    @State private var theme: AwayModeTheme = .aurora
    @State private var accent: AwayModeAccent = .blue
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var loadedPreferences = false
    @State private var existingPINIsUsable = false

    private let stepTitles = [
        "Privacy Curtain",
        "Event Access",
        "Authentication",
        "Appearance",
    ]

    var body: some View {
        VStack(spacing: 0) {
            setupHeader
            Divider()

            ScrollView {
                Group {
                    switch step {
                    case 0: privacyStep
                    case 1: eventAccessStep
                    case 2: authenticationStep
                    default: appearanceStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.systemOrange)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .accessibilityLabel("Setup error")
                    .accessibilityValue(errorMessage)
            }

            Divider()
            setupFooter
        }
        .frame(width: 540, height: 520)
        .background(DesignTokens.Colors.nextMasterBackground)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard !loadedPreferences else { return }
            authenticationMethod = coordinator.preferences.authenticationMethod
            theme = coordinator.preferences.theme
            accent = coordinator.preferences.accent
            existingPINIsUsable = coordinator.hasUsablePIN()
            loadedPreferences = true
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            isSaving = false
        }
    }

    private var setupHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up Away Mode")
                    .font(.system(size: 17, weight: .semibold))
                Text("Step \(step + 1) of \(stepTitles.count): \(stepTitles[step])")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Know what Away Mode does")
                .font(.system(size: 22, weight: .semibold))
            Text(AwayModeCopy.disclosure)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            setupFact(
                icon: "play.circle",
                title: "Awake request",
                detail: "Semper asks macOS to prevent idle sleep. Lid close, manual Sleep, and forced low-power limits can sleep the Mac and pause work."
            )
            setupFact(
                icon: "exclamationmark.triangle",
                title: "App-level protection",
                detail: "Force Quit, restart, or an app failure can remove the curtain."
            )
            setupFact(
                icon: "person.badge.shield.checkmark",
                title: "Account protection",
                detail: "Use the macOS Lock Screen when you need account security."
            )
            setupFact(
                icon: "internaldrive",
                title: "Local status only",
                detail: "Away settings and the managed photo stay in local Application Support. The salted PIN verifier uses a non-syncing, device-only Keychain item. Away does not send this data, inspect process names, use agent hooks, or read remote status."
            )
        }
    }

    private var eventAccessStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Allow event access")
                .font(.system(size: 22, weight: .semibold))
            Text("Semper requires Accessibility access to filter input while the curtain is visible. If the event filter is still denied, macOS may also require Input Monitoring.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text(
                    eventAccessChecked
                        ? (hasEventAccess ? "Access confirmed" : "Access not confirmed")
                        : "Access has not been checked"
                )
            } icon: {
                Image(systemName: hasEventAccess ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(
                        hasEventAccess
                            ? DesignTokens.Colors.systemGreen
                            : DesignTokens.Colors.systemOrange
                    )
            }
            .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                Button("Request Access") {
                    coordinator.requestEventAccess()
                    checkEventAccess()
                }
                .buttonStyle(.borderedProminent)

                Button("Check Again") {
                    checkEventAccess()
                }
                .buttonStyle(.bordered)
            }

            Text("After allowing Semper in System Settings, return here and choose Check Again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if !eventAccessChecked {
                checkEventAccess()
            }
        }
    }

    private var authenticationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose how to exit")
                .font(.system(size: 22, weight: .semibold))
            Picker("Authentication", selection: $authenticationMethod) {
                ForEach(AwayAuthenticationMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)

            if authenticationMethod == .system {
                setupFact(
                    icon: "touchid",
                    title: "System Authentication",
                    detail: "Use Touch ID, Apple Watch when available, or your Mac login password."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if canKeepExistingPIN {
                        Text("Leave both fields empty to keep your current PIN, or enter a new PIN twice to replace it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
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
                    Text("Semper stores only a salted PIN verifier in Keychain. Mac authentication is required to save or change it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            }
        }
    }

    private var appearanceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview the curtain")
                .font(.system(size: 22, weight: .semibold))
            AwayThemePicker(
                selection: theme,
                accent: accent,
                customPhotoAvailable: coordinator.hasManagedPhotoFile
            ) {
                theme = $0
            }
            if !coordinator.hasManagedPhotoFile {
                Text("Add a Custom Photo later in Away settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            AwayAccentPicker(selection: accent) {
                accent = $0
            }
        }
    }

    private func setupFact(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent.color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var setupFooter: some View {
        HStack(spacing: 8) {
            Button("Cancel") {
                guard !isSaving else { return }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Spacer()

            if step > 0 {
                Button("Back") {
                    guard !isSaving else { return }
                    errorMessage = nil
                    step -= 1
                }
                .disabled(isSaving)
            }

            if step < stepTitles.count - 1 {
                Button("Continue") {
                    errorMessage = nil
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            } else {
                Button("Finish Setup") {
                    finishSetup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .controlSize(.small)
        .padding(16)
    }

    private var canContinue: Bool {
        switch step {
        case 1:
            hasEventAccess
        case 2:
            authenticationMethod == .system
                || pinDraft.isValid
                || (canKeepExistingPIN
                    && pinDraft.pin.isEmpty
                    && pinDraft.confirmation.isEmpty)
        default:
            true
        }
    }

    private func checkEventAccess() {
        hasEventAccess = coordinator.checkEventAccess()
        eventAccessChecked = true
    }

    private func finishSetup() {
        guard !isSaving else { return }
        let submission = AwaySetupSubmission(
            authenticationMethod: authenticationMethod,
            theme: theme,
            accent: accent,
            pin: pinDraft.pin,
            confirmation: pinDraft.confirmation,
            existingAuthenticationMethod: coordinator.preferences.authenticationMethod,
            existingPINIsUsable: existingPINIsUsable
        )
        isSaving = true
        errorMessage = nil
        saveTask = Task { @MainActor in
            let saved = await submission.apply(to: coordinator)

            guard !Task.isCancelled else {
                clearSaveTask()
                return
            }
            guard saved else {
                errorMessage = coordinator.pinConfigurationError
                    ?? "Authentication settings could not be saved."
                clearSaveTask()
                return
            }

            clearSaveTask()
            dismiss()
        }
    }

    private func clearSaveTask() {
        isSaving = false
        saveTask = nil
    }

    private var canKeepExistingPIN: Bool {
        coordinator.preferences.authenticationMethod == .pin && existingPINIsUsable
    }
}

@MainActor
struct AwayThemePicker: View {
    let selection: AwayModeTheme
    let accent: AwayModeAccent
    let customPhotoAvailable: Bool
    let onSelect: (AwayModeTheme) -> Void

    init(
        selection: AwayModeTheme,
        accent: AwayModeAccent,
        customPhotoAvailable: Bool = true,
        onSelect: @escaping (AwayModeTheme) -> Void
    ) {
        self.selection = selection
        self.accent = accent
        self.customPhotoAvailable = customPhotoAvailable
        self.onSelect = onSelect
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(AwayModeTheme.allCases) { theme in
                let isAvailable = theme != .customPhoto || customPhotoAvailable
                AwayThemePreview(
                    theme: theme,
                    accent: accent,
                    isSelected: selection == theme,
                    isEnabled: isAvailable,
                    onSelect: { onSelect(theme) }
                )
            }
        }
    }
}

@MainActor
private struct AwayThemePreview: View {
    let theme: AwayModeTheme
    let accent: AwayModeAccent
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    AwayThemeThumbnail(theme: theme, accent: accent)
                    Image(systemName: theme.systemImage)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .accessibilityHidden(true)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(7)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text(theme.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            }
            .padding(7)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DesignTokens.Colors.nextControlBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? accent.color
                            : DesignTokens.Colors.nextControlBorder,
                        lineWidth: isSelected || colorSchemeContrast == .increased ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.52)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(
            isEnabled
                ? "Selects this Away Mode curtain"
                : "Choose a photo in Away settings first"
        )
    }

}

@MainActor
private struct AwayThemeThumbnail: View {
    let theme: AwayModeTheme
    let accent: AwayModeAccent
    var photo: NSImage?
    var photoFit: AwayPhotoFit

    init(
        theme: AwayModeTheme,
        accent: AwayModeAccent,
        photo: NSImage? = nil,
        photoFit: AwayPhotoFit = .fill
    ) {
        self.theme = theme
        self.accent = accent
        self.photo = photo
        self.photoFit = photoFit
    }

    @ViewBuilder
    var body: some View {
        switch theme {
        case .stillGradient:
            LinearGradient(
                colors: [.black, accent.supportingColor, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .aurora:
            ZStack {
                Color(red: 0.02, green: 0.03, blue: 0.08)
                Circle()
                    .fill(accent.color.opacity(0.75))
                    .frame(width: 90, height: 90)
                    .blur(radius: 22)
                    .offset(x: -38, y: -20)
                Circle()
                    .fill(accent.supportingColor.opacity(0.65))
                    .frame(width: 80, height: 80)
                    .blur(radius: 25)
                    .offset(x: 50, y: 24)
            }
        case .quietOrbits:
            ZStack {
                Color(red: 0.02, green: 0.025, blue: 0.06)
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(accent.color.opacity(0.28), lineWidth: 1)
                        .frame(
                            width: CGFloat(42 + index * 26),
                            height: CGFloat(42 + index * 26)
                        )
                }
            }
        case .customPhoto:
            ZStack {
                Color.black
                if let photo {
                    Image(nsImage: photo)
                        .resizable()
                        .aspectRatio(contentMode: photoFit == .fill ? .fill : .fit)
                } else {
                    LinearGradient(
                        colors: [accent.supportingColor, Color.black, accent.color.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
    }
}

@MainActor
struct AwayAccentPicker: View {
    let selection: AwayModeAccent
    let onSelect: (AwayModeAccent) -> Void

    var body: some View {
        HStack(spacing: 9) {
            ForEach(AwayModeAccent.allCases) { accent in
                Button {
                    onSelect(accent)
                } label: {
                    ZStack {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 25, height: 25)
                        if selection == accent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accent.title)
                .accessibilityAddTraits(selection == accent ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accent")
    }
}
