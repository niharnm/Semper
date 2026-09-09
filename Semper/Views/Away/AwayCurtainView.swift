import AppKit
import SwiftUI

enum AwayCurtainPresentation {
    static let maximumFramesPerSecond = 20.0
    static let animationInterval = 1.0 / maximumFramesPerSecond

    static func shouldAnimate(
        motionLevel: AwayMotionLevel,
        isDimmed: Bool,
        powerAllowsMotion: Bool,
        reduceMotion: Bool
    ) -> Bool {
        motionLevel != .off
            && !isDimmed
            && powerAllowsMotion
            && !reduceMotion
    }

    static func showsPrimaryContent(isPrimary: Bool) -> Bool {
        isPrimary
    }

    static func shouldRevealRecoveryContent(
        isBlackedOut: Bool,
        state: AwayModeState
    ) -> Bool {
        guard isBlackedOut else { return false }
        switch state {
        case .authenticating, .degraded:
            return true
        case .inactive, .countdown, .arming, .guarded, .disarming:
            return false
        }
    }

    static func usesSolidPanelFill(
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Bool {
        reduceTransparency || increasedContrast
    }

    static func readableTextOpacity(
        defaultOpacity: Double,
        increasedContrast: Bool
    ) -> Double {
        increasedContrast ? 1 : defaultOpacity
    }

    static func shouldRunPrimaryTimeline(
        displaysAreActive: Bool,
        isBlackedOut: Bool
    ) -> Bool {
        displaysAreActive && !isBlackedOut
    }

    static func awakeStateText(
        allowsAwakeAssertions: Bool,
        keepsDisplayAwake: Bool,
        warning: String?
    ) -> String {
        if let warning {
            return warning
        }
        guard allowsAwakeAssertions else {
            return "No macOS awake request. macOS may sleep."
        }
        return keepsDisplayAwake
            ? "macOS awake and display requests active"
            : "macOS awake request active"
    }
}

extension AwayAuthenticationMethod {
    var title: String {
        switch self {
        case .system: "System Authentication"
        case .pin: "4-Digit PIN"
        }
    }
}

extension AwayModeTheme {
    var title: String {
        switch self {
        case .stillGradient: "Still Gradient"
        case .aurora: "Aurora"
        case .quietOrbits: "Quiet Orbits"
        case .customPhoto: "Custom Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .stillGradient: "square.fill"
        case .aurora: "wind"
        case .quietOrbits: "circle.dotted"
        case .customPhoto: "photo"
        }
    }
}

extension AwayModeAccent {
    var title: String {
        switch self {
        case .blue: "Blue"
        case .violet: "Violet"
        case .teal: "Teal"
        case .amber: "Amber"
        }
    }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.18, green: 0.48, blue: 0.98)
        case .violet: Color(red: 0.56, green: 0.33, blue: 0.96)
        case .teal: Color(red: 0.10, green: 0.68, blue: 0.66)
        case .amber: Color(red: 0.94, green: 0.56, blue: 0.16)
        }
    }

    var supportingColor: Color {
        switch self {
        case .blue: Color(red: 0.23, green: 0.20, blue: 0.72)
        case .violet: Color(red: 0.20, green: 0.34, blue: 0.78)
        case .teal: Color(red: 0.10, green: 0.32, blue: 0.62)
        case .amber: Color(red: 0.66, green: 0.18, blue: 0.28)
        }
    }
}

extension AwayWidgetPlacement {
    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .center: "Center"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .center: .center
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

extension AwayPhotoFit {
    var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        }
    }
}

extension AwayMotionLevel {
    var title: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .standard: "Standard"
        }
    }
}

extension AwayDimDelay {
    var title: String {
        switch self {
        case .never: "Never"
        case .oneMinute: "1 Minute"
        case .fiveMinutes: "5 Minutes"
        case .fifteenMinutes: "15 Minutes"
        }
    }
}

@MainActor
struct AwayCurtainView: View {
    @Bindable var coordinator: AwayModeCoordinator
    let screen: AwayScreenSnapshot
    let isPrimary: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var photo: NSImage?
    @FocusState private var isPINFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black

            AwayThemeBackground(
                theme: coordinator.preferences.theme,
                accent: coordinator.preferences.accent,
                motionLevel: coordinator.preferences.motionLevel,
                shouldAnimate: shouldAnimate,
                photo: photo,
                photoFit: coordinator.preferences.photoFit
            )
            .opacity(isDisarming ? 0 : 1)
            .animation(.easeOut(duration: 0.16), value: isDisarming)

            if coordinator.isBlackedOut {
                Color.black
                    .accessibilityHidden(true)
            }

            if AwayCurtainPresentation.showsPrimaryContent(isPrimary: isPrimary) {
                if !coordinator.isBlackedOut {
                    primaryContent
                } else if AwayCurtainPresentation.shouldRevealRecoveryContent(
                    isBlackedOut: coordinator.isBlackedOut,
                    state: coordinator.state
                ) {
                    positionedAuthenticationPanel
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(
            width: max(1, screen.frame.width),
            height: max(1, screen.frame.height)
        )
        .background(Color.black)
        .clipped()
        .ignoresSafeArea()
        .accessibilityHidden(!isPrimary)
        .task(id: coordinator.preferences.managedPhotoFilename) {
            photo = await coordinator.managedPhotoImage()
        }
    }

    private var shouldAnimate: Bool {
        AwayCurtainPresentation.shouldAnimate(
            motionLevel: coordinator.preferences.motionLevel,
            isDimmed: coordinator.isBlackedOut,
            powerAllowsMotion: coordinator.powerSnapshot.allowsMotion
                && coordinator.displaysAreActive,
            reduceMotion: reduceMotion
        )
    }

    private var isDisarming: Bool {
        coordinator.state == .disarming
    }

    private var primaryContent: some View {
        ZStack {
            if hasWidgetContent {
                widgetPanel
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: coordinator.preferences.widgetPlacement.alignment
                    )
                    .padding(48)
            }

            positionedAuthenticationPanel
        }
        .foregroundStyle(.white)
    }

    private var positionedAuthenticationPanel: some View {
        authenticationPanel
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )
            .padding(48)
    }

    private var hasWidgetContent: Bool {
        let preferences = coordinator.preferences
        return preferences.showsClock
            || preferences.showsElapsedTime
            || preferences.showsBattery
            || preferences.showsAwakeState
            || !preferences.customMessage.isEmpty
    }

    @ViewBuilder
    private var widgetPanel: some View {
        if AwayCurtainPresentation.shouldRunPrimaryTimeline(
            displaysAreActive: coordinator.displaysAreActive,
            isBlackedOut: coordinator.isBlackedOut
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                widgetPanelContent(date: timeline.date)
            }
        } else {
            widgetPanelContent(date: .now)
        }
    }

    private func widgetPanelContent(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.preferences.showsClock {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 46, weight: .medium, design: .rounded))
                        .tracking(-1.2)
                    Text(date, format: .dateTime.weekday(.wide).month().day())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(readableCurtainText(defaultOpacity: 0.72))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Local time")
                .accessibilityValue(
                    date.formatted(
                        .dateTime.weekday(.wide).month().day().hour().minute()
                    )
                )
            }

            if !coordinator.preferences.customMessage.isEmpty {
                Text(coordinator.preferences.customMessage)
                    .font(.system(size: 17, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Away message")
                    .accessibilityValue(coordinator.preferences.customMessage)
            }

            VStack(alignment: .leading, spacing: 8) {
                if coordinator.preferences.showsElapsedTime {
                    statusLine(
                        icon: "timer",
                        title: "Away for \(coordinator.elapsedText)"
                    )
                }
                if coordinator.preferences.showsBattery {
                    statusLine(
                        icon: batterySystemImage,
                        title: coordinator.batteryText
                    )
                }
                if coordinator.preferences.showsAwakeState {
                    statusLine(
                        icon: "moon.zzz",
                        title: AwayCurtainPresentation.awakeStateText(
                            allowsAwakeAssertions: coordinator.powerSnapshot
                                .allowsAwakeAssertions,
                            keepsDisplayAwake: coordinator.preferences.keepsDisplayAwake,
                            warning: coordinator.powerWarning
                        )
                    )
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(22)
        .awayCurtainPanel(
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private func statusLine(icon: String, title: String) -> some View {
        Label {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .frame(width: 16)
                .accessibilityHidden(true)
        }
        .foregroundStyle(readableCurtainText(defaultOpacity: 0.78))
    }

    private var batterySystemImage: String {
        if coordinator.powerSnapshot.reading.isCharging == true {
            return "battery.100percent.bolt"
        }
        guard let percentage = coordinator.powerSnapshot.reading.batteryPercentage else {
            return "battery.0percent"
        }
        switch percentage {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 11...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var authenticationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Away Mode")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text(AwayModeCopy.exitPrompt)
                .font(.system(size: 12))
                .foregroundStyle(readableCurtainText(defaultOpacity: 0.74))

            if let warning = coordinator.powerWarning {
                Label(warning, systemImage: "moon.zzz")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Away Mode power warning")
                    .accessibilityValue(warning)
            }

            if case .degraded(let message) = coordinator.state {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            authenticationControls

            if let error = coordinator.lastErrorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Authentication error")
                    .accessibilityValue(error)
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(18)
        .awayCurtainPanel(
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var authenticationControls: some View {
        switch coordinator.state {
        case .authenticating where coordinator.activeAuthenticationMethod == .pin:
            pinControls
        case .authenticating:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Mac authentication")
                    .font(.system(size: 12, weight: .medium))
            }
            .accessibilityElement(children: .combine)
        case .arming:
            progressLabel("Starting Away Mode")
        case .disarming:
            progressLabel("Finishing Away Mode")
        case .degraded:
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    coordinator.requestAuthentication()
                } label: {
                    Label("Authenticate to Exit", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(coordinator.preferences.accent.color)

                Button("Use Mac Authentication") {
                    coordinator.beginSystemAuthentication()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        case .inactive, .countdown, .guarded:
            Button {
                coordinator.requestAuthentication()
            } label: {
                Label("Authenticate to Exit", systemImage: "eye.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.preferences.accent.color)
            .controlSize(.large)
            .accessibilityHint("Opens the selected Away Mode authentication method")
        }
    }

    private var pinControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(
                "4-digit PIN",
                text: Binding(
                    get: { coordinator.pinEntry },
                    set: { coordinator.updatePINEntry($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($isPINFieldFocused)
            .disabled(coordinator.cooldownRemaining > 0 || coordinator.isVerifyingPIN)
            .onSubmit {
                coordinator.submitPIN()
            }
            .task {
                isPINFieldFocused = true
            }
            .onChange(of: coordinator.isVerifyingPIN) { _, isVerifying in
                if !isVerifying, coordinator.cooldownRemaining == 0 {
                    isPINFieldFocused = true
                }
            }
            .accessibilityHint("Enter the four digit Away Mode PIN")

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if coordinator.isVerifyingPIN {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking PIN")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(readableCurtainText(defaultOpacity: 0.7))
                } else if coordinator.cooldownRemaining > 0 {
                    Text(
                        "Try again in \(Int(ceil(coordinator.cooldownRemaining))) seconds"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(readableCurtainText(defaultOpacity: 0.7))
                }
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 7),
                    count: 3
                ),
                spacing: 7
            ) {
                ForEach(0..<12, id: \.self) { index in
                    keypadButton(at: index)
                }
            }

            HStack(spacing: 8) {
                Button("Exit") {
                    coordinator.submitPIN()
                }
                .buttonStyle(.borderedProminent)
                .tint(coordinator.preferences.accent.color)
                .disabled(pinSubmissionDisabled)

                Button("Use Mac Authentication") {
                    coordinator.beginSystemAuthentication()
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isVerifyingPIN)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func keypadButton(at index: Int) -> some View {
        if index == 9 {
            Color.clear
                .frame(height: 32)
                .accessibilityHidden(true)
        } else if index == 11 {
            Button {
                coordinator.deleteLastPINDigit()
            } label: {
                Image(systemName: "delete.left")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Delete")
            .disabled(
                coordinator.pinEntry.isEmpty
                    || coordinator.cooldownRemaining > 0
                    || coordinator.isVerifyingPIN
            )
        } else {
            let digit = index == 10 ? 0 : index + 1
            Button {
                coordinator.appendPINDigit(digit)
            } label: {
                Text("\(digit)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Digit \(digit)")
            .disabled(
                coordinator.pinEntry.utf8.count >= 4
                    || coordinator.cooldownRemaining > 0
                    || coordinator.isVerifyingPIN
            )
        }
    }

    private var pinSubmissionDisabled: Bool {
        coordinator.pinEntry.utf8.count != 4
            || coordinator.cooldownRemaining > 0
            || coordinator.isVerifyingPIN
    }

    private func readableCurtainText(defaultOpacity: Double) -> Color {
        .white.opacity(
            AwayCurtainPresentation.readableTextOpacity(
                defaultOpacity: defaultOpacity,
                increasedContrast: colorSchemeContrast == .increased
            )
        )
    }

    private func progressLabel(_ text: String) -> some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AwayThemeBackground: View {
    let theme: AwayModeTheme
    let accent: AwayModeAccent
    let motionLevel: AwayMotionLevel
    let shouldAnimate: Bool
    let photo: NSImage?
    let photoFit: AwayPhotoFit

    var body: some View {
        switch theme {
        case .stillGradient:
            AwayStillGradient(accent: accent)
        case .aurora:
            animatedOrStatic { phase in
                AwayAuroraBackground(
                    accent: accent,
                    phase: phase,
                    amplitude: motionAmplitude
                )
            }
        case .quietOrbits:
            animatedOrStatic { phase in
                AwayOrbitBackground(
                    accent: accent,
                    phase: phase,
                    amplitude: motionAmplitude
                )
            }
        case .customPhoto:
            AwayPhotoBackground(image: photo, fit: photoFit, accent: accent)
        }
    }

    private var motionAmplitude: Double {
        motionLevel == .standard ? 1 : 0.45
    }

    @ViewBuilder
    private func animatedOrStatic<Content: View>(
        @ViewBuilder content: @escaping (TimeInterval) -> Content
    ) -> some View {
        if shouldAnimate {
            TimelineView(
                .periodic(from: .now, by: AwayCurtainPresentation.animationInterval)
            ) { timeline in
                content(timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(0)
        }
    }
}

private struct AwayStillGradient: View {
    let accent: AwayModeAccent

    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.025, green: 0.035, blue: 0.075),
                accent.supportingColor.opacity(0.88),
                Color(red: 0.015, green: 0.02, blue: 0.045),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct AwayAuroraBackground: View {
    let accent: AwayModeAccent
    let phase: TimeInterval
    let amplitude: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let xTravel = sin(phase * 0.18) * size.width * 0.09 * amplitude
            let yTravel = cos(phase * 0.13) * size.height * 0.07 * amplitude

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.015, green: 0.025, blue: 0.06),
                        Color(red: 0.035, green: 0.055, blue: 0.12),
                        Color(red: 0.012, green: 0.016, blue: 0.04),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.color.opacity(0.82), accent.color.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.34
                        )
                    )
                    .frame(width: size.width * 0.72, height: size.width * 0.72)
                    .blur(radius: 70)
                    .offset(x: -size.width * 0.2 + xTravel, y: -size.height * 0.12 + yTravel)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                accent.supportingColor.opacity(0.68),
                                accent.supportingColor.opacity(0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.3
                        )
                    )
                    .frame(width: size.width * 0.62, height: size.width * 0.62)
                    .blur(radius: 90)
                    .offset(x: size.width * 0.28 - xTravel, y: size.height * 0.17 - yTravel)
            }
        }
    }
}

private struct AwayOrbitBackground: View {
    let accent: AwayModeAccent
    let phase: TimeInterval
    let amplitude: Double

    var body: some View {
        GeometryReader { geometry in
            let shortestSide = min(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.025, blue: 0.05),
                        accent.supportingColor.opacity(0.46),
                        Color(red: 0.01, green: 0.012, blue: 0.028),
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )

                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .trim(from: 0.08, to: 0.84)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    .clear,
                                    accent.color.opacity(0.16 + Double(index) * 0.035),
                                    .white.opacity(0.18),
                                    .clear,
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(
                                lineWidth: 1 + CGFloat(index) * 0.45,
                                lineCap: .round
                            )
                        )
                        .frame(
                            width: shortestSide * (0.48 + CGFloat(index) * 0.22),
                            height: shortestSide * (0.48 + CGFloat(index) * 0.22)
                        )
                        .rotationEffect(
                            .degrees(
                                Double(index * 37)
                                    + phase * (1.3 + Double(index) * 0.35) * amplitude
                            )
                        )
                }

                Circle()
                    .fill(accent.color.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.color, radius: 12)
            }
        }
    }
}

private struct AwayPhotoBackground: View {
    let image: NSImage?
    let fit: AwayPhotoFit
    let accent: AwayModeAccent

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: fit == .fill ? .fill : .fit)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .clipped()
                        .accessibilityHidden(true)

                    LinearGradient(
                        colors: [.black.opacity(0.12), .black.opacity(0.42)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    AwayStillGradient(accent: accent)
                }
            }
        }
    }
}

private struct AwayCurtainPanelModifier: ViewModifier {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if AwayCurtainPresentation.usesSolidPanelFill(
                    reduceTransparency: reduceTransparency,
                    increasedContrast: increasedContrast
                ) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            increasedContrast
                                ? Color(red: 0.015, green: 0.02, blue: 0.035)
                                : Color(red: 0.045, green: 0.05, blue: 0.07)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        .white.opacity(increasedContrast ? 0.85 : 0.17),
                        lineWidth: increasedContrast ? 2 : 1
                    )
            }
            .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
    }
}

private extension View {
    func awayCurtainPanel(
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> some View {
        modifier(
            AwayCurtainPanelModifier(
                reduceTransparency: reduceTransparency,
                increasedContrast: increasedContrast
            )
        )
    }
}
