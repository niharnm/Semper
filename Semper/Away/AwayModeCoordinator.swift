import AppKit
import Foundation
import Observation
import os

enum AwayModeState: Equatable, Sendable {
    case inactive
    case countdown(remainingSeconds: Int)
    case arming
    case guarded
    case authenticating(attemptID: UUID)
    case degraded(message: String)
    case disarming
}

enum AwayModeActivationError: Error, Equatable, Sendable {
    case disclosureRequired
    case systemAuthenticationUnavailable
    case pinMissingOrUnreadable
    case eventAccessRequired
    case powerAssertionFailed
    case panelPreparationFailed
    case inputFilterFailed
    case presentationFailed
    case coverageFailed
    case mutationInProgress
    case cleanupPending

    var message: String {
        switch self {
        case .disclosureRequired:
            "Finish Away Mode setup before starting."
        case .systemAuthenticationUnavailable:
            "Mac authentication is not available."
        case .pinMissingOrUnreadable:
            "The Away Mode PIN is missing or unreadable. Repair it with Mac authentication."
        case .eventAccessRequired:
            "Allow Semper in Accessibility. macOS may also require Input Monitoring."
        case .powerAssertionFailed:
            "macOS did not accept the awake request. Away Mode was not started."
        case .panelPreparationFailed:
            "Semper could not prepare a curtain for every display."
        case .inputFilterFailed:
            "Semper could not block ordinary input. Away Mode was not started."
        case .presentationFailed:
            "Semper could not prepare the full-screen presentation."
        case .coverageFailed:
            "Semper could not verify full display coverage."
        case .mutationInProgress:
            "Wait for the current scene operation to finish, then try again."
        case .cleanupPending:
            "Away Mode cleanup is still pending. Try again after macOS releases the awake request."
        }
    }
}

enum AwayModeDataResetStep: Hashable, Sendable {
    case pin
    case managedPhoto
    case unusedPhotos
    case settings
}

enum AwayModeDataError: Error, Equatable, Sendable {
    case mutationUnavailable
    case authenticationFailed
    case persistenceFailed
    case persistenceAndCleanupFailed
    case deletionFailed(
        completed: Set<AwayModeDataResetStep>,
        failed: Set<AwayModeDataResetStep>
    )

    var message: String {
        switch self {
        case .mutationUnavailable:
            return "Away Mode data cannot be reset right now. No data or settings were changed."
        case .authenticationFailed:
            return "Mac authentication was canceled or failed. No data or settings were changed."
        case .persistenceFailed:
            return "Away Mode settings could not be saved. The previous photo remains selected."
        case .persistenceAndCleanupFailed:
            return "Away Mode settings could not be saved. The previous photo remains selected, and the unused photo copy could not be deleted."
        case let .deletionFailed(completed, failed):
            let failedText = Self.stepNames(failed)
            guard !completed.isEmpty else {
                return "Away Mode data could not be deleted. Failed: \(failedText). No other settings were reset."
            }
            return "Reset partially finished. Completed: \(Self.stepNames(completed)). Failed: \(failedText). No other settings were reset."
        }
    }

    private static func stepNames(_ steps: Set<AwayModeDataResetStep>) -> String {
        [
            steps.contains(.pin) ? "Away PIN data" : nil,
            steps.contains(.managedPhoto) ? "the managed Away photo" : nil,
            steps.contains(.unusedPhotos) ? "unused Away photos" : nil,
            steps.contains(.settings) ? "Away settings" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private enum AwayPINVerificationResult: Sendable {
    case accepted
    case rejected
    case unreadable
}

@MainActor
protocol AwayWindowManaging: AnyObject {
    var isPresented: Bool { get }
    var onDegraded: ((AwayWindowFailure) -> Void)? { get set }
    var onRestored: (() -> Void)? { get set }

    func prepare(
        contentBuilder: @escaping @MainActor (AwayScreenSnapshot, Bool) throws -> NSView
    ) -> AwayWindowPreparationResult
    func presentPrepared() -> AwayWindowPresentationResult
    func reorderPanels()
    func dismiss()
}

extension AwayWindowController: AwayWindowManaging {}

@MainActor
protocol AwayInputGuarding: AnyObject {
    var isActive: Bool { get }
    var isFilteringOperational: Bool { get }
    var hasEventAccess: Bool { get }
    var onActivity: (() -> Void)? { get set }
    var onAuthenticationRequested: (() -> Void)? { get set }
    var onQuitRequested: (() -> Void)? { get set }
    var onFailure: ((AwayInputGuardFailure) -> Void)? { get set }
    var onRestored: (() -> Void)? { get set }

    func preflight() -> Bool
    func requestEventAccess()
    func start(policy: AwayInputPolicy) -> Bool
    func setPolicy(_ policy: AwayInputPolicy)
    func setAuthenticationShortcut(_ shortcut: ShortcutCodable?)
    func handleTapDisabled()
    func stop()
}

extension AwayInputGuard: AwayInputGuarding {}

@MainActor
@Observable
final class AwayModeCoordinator: AwayShortcutHandling {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias CurtainContentBuilder = @MainActor (AwayScreenSnapshot, Bool) throws -> NSView

    private static let countdownLength = 5
    private static let authenticationReason = "Exit Semper Away Mode."
    private static let coverageFailureMessage =
        "Display coverage could not be restored. Existing curtains remain visible."
    private static let inputFailureMessage =
        "Input filtering stopped. Use Mac authentication or Force Quit."
    private static let activityRescheduleInterval: TimeInterval = 1
    private static let logger = Logger(
        subsystem: "systems.semper.Semper",
        category: "AwayMode"
    )

    private let settings: SettingsManager
    private let awakeService: AwakeService
    private let mutationAdmission: MutationAdmissionGate
    private let windows: any AwayWindowManaging
    private let inputGuard: any AwayInputGuarding
    private let authenticator: any AwaySystemAuthenticating
    private let pinStore: any AwayPINStoring
    private let photoStore: any AwayPhotoStoring
    private let photoImageCache = AwayPhotoImageCache()
    private let presentation: any AwayApplicationPresenting
    private let powerPolicy: AwayPowerPolicy
    private let now: () -> Date
    private let sleep: Sleep
    private let workspaceNotificationCenter: NotificationCenter

    private(set) var state: AwayModeState = .inactive
    private(set) var lastErrorMessage: String?
    private(set) var powerWarning: String?
    private(set) var sessionStartedAt: Date?
    private(set) var isBlackedOut = false
    private(set) var pinEntry = ""
    private(set) var pinCooldown = AwayPINCooldown()
    private(set) var pinConfigurationError: String?
    private(set) var displaysAreActive = true
    private(set) var activeAuthenticationMethod: AwayAuthenticationMethod?
    private(set) var isVerifyingPIN = false
    private(set) var isManagingPIN = false

    @ObservationIgnored var makeCurtainContent: CurtainContentBuilder?
    @ObservationIgnored var onWillGuard: (() -> Void)?
    @ObservationIgnored var onDidDisarm: (() -> Void)?
    @ObservationIgnored var onAuthenticatedQuit: (() -> Void)?

    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var dimTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationTask: Task<Void, Never>?
    @ObservationIgnored private var pinVerificationTask: Task<Void, Never>?
    @ObservationIgnored private var disarmTask: Task<Void, Never>?
    @ObservationIgnored private var pinVerificationID: UUID?
    @ObservationIgnored private var pinManagementID: UUID?
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var awakeLease: AwakeLeaseToken?
    @ObservationIgnored private var mutationPermit: MutationAdmissionPermit?
    @ObservationIgnored private var lastDimScheduleAt: Date?
    @ObservationIgnored private var quitAfterAuthentication = false
    @ObservationIgnored private var returnToPINAfterSystemAuthentication = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var didShutDown = false
    @ObservationIgnored private var hasCoverageFailure = false
    @ObservationIgnored private var hasInputFailure = false

    init(
        settings: SettingsManager,
        awakeService: AwakeService,
        mutationAdmission: MutationAdmissionGate = MutationAdmissionGate(),
        windows: any AwayWindowManaging = AwayWindowController(),
        inputGuard: any AwayInputGuarding = AwayInputGuard(),
        authenticator: any AwaySystemAuthenticating = LocalAwaySystemAuthenticator(),
        pinStore: any AwayPINStoring = KeychainAwayPINStore(),
        photoStore: any AwayPhotoStoring = AwayPhotoStore(),
        presentation: any AwayApplicationPresenting = AwayApplicationPresentationController(),
        powerPolicy: AwayPowerPolicy = AwayPowerPolicy(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.settings = settings
        self.awakeService = awakeService
        self.mutationAdmission = mutationAdmission
        self.windows = windows
        self.inputGuard = inputGuard
        self.authenticator = authenticator
        self.pinStore = pinStore
        self.photoStore = photoStore
        self.presentation = presentation
        self.powerPolicy = powerPolicy
        self.now = now
        self.sleep = sleep
        self.workspaceNotificationCenter = workspaceNotificationCenter

        windows.onDegraded = { [weak self] _ in
            self?.markCoverageFailed()
        }
        windows.onRestored = { [weak self] in
            self?.handleCoverageRestored()
        }
        inputGuard.onActivity = { [weak self] in
            self?.registerActivity()
        }
        inputGuard.onAuthenticationRequested = { [weak self] in
            self?.requestAuthentication()
        }
        inputGuard.onQuitRequested = { [weak self] in
            self?.requestQuit()
        }
        inputGuard.onFailure = { [weak self] _ in
            self?.markInputFailed()
        }
        inputGuard.onRestored = { [weak self] in
            self?.handleInputRestored()
        }
        powerPolicy.onChange = { [weak self] _ in
            self?.reconcilePowerPolicy()
        }
        observeWorkspace(NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.displaysAreActive = false
        }
        observeWorkspace(NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.displaysAreActive = true
        }
        observeWorkspace(NSWorkspace.didWakeNotification) { [weak self] in
            self?.displaysAreActive = true
        }
        do {
            try photoStore.removeUnreferencedPhotos(
                keeping: settings.appSettings.awayModePreferences.managedPhotoFilename
            )
        } catch {
            Self.logger.error("Away photo cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var preferences: AwayModePreferences {
        settings.appSettings.awayModePreferences
    }

    var powerSnapshot: AwayPowerPolicySnapshot {
        powerPolicy.snapshot
    }

    var hasEventAccess: Bool {
        inputGuard.hasEventAccess
    }

    var isGuarding: Bool {
        switch state {
        case .arming, .guarded, .authenticating, .degraded, .disarming:
            true
        case .inactive, .countdown:
            false
        }
    }

    var blocksOrdinaryShortcuts: Bool {
        isGuarding
    }

    var isAuthenticating: Bool {
        if case .authenticating = state { return true }
        return false
    }

    var elapsedText: String {
        guard let sessionStartedAt else { return "0 min" }
        let seconds = max(0, Int(now().timeIntervalSince(sessionStartedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
    }

    var batteryText: String {
        let reading = powerSnapshot.reading
        let level = reading.batteryPercentage.map { "\($0)%" } ?? "Battery unavailable"
        if reading.isOnACPower == true {
            return reading.isCharging == true ? "\(level), charging" : "\(level), power connected"
        }
        return level
    }

    var cooldownRemaining: TimeInterval {
        pinCooldown.remainingTime(at: now())
    }

    func handleAwayShortcut() {
        switch state {
        case .inactive:
            startCountdown()
        case .countdown, .arming, .disarming:
            break
        case .guarded, .authenticating, .degraded:
            requestAuthentication()
        }
    }

    func startCountdown() {
        guard !didShutDown, state == .inactive, !isManagingPIN else { return }
        inputGuard.setAuthenticationShortcut(
            settings.appSettings.customShortcuts[ShortcutAction.toggleAwayMode.rawValue]
        )
        guard prepareMutationAdmissionForEntry() else {
            failBeforeActivation(.cleanupPending)
            return
        }
        guard let makeCurtainContent else {
            failBeforeActivation(.panelPreparationFailed)
            return
        }
        guard preflightCapabilities(), self.makeCurtainContent != nil else { return }

        lastErrorMessage = nil
        state = .countdown(remainingSeconds: Self.countdownLength)
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self, makeCurtainContent] in
            guard let self else { return }
            for remaining in stride(from: Self.countdownLength, through: 1, by: -1) {
                do {
                    try await self.sleep(.seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      state == .countdown(remainingSeconds: remaining) else {
                    return
                }
                if remaining == 1 {
                    arm(contentBuilder: makeCurtainContent)
                } else {
                    state = .countdown(remainingSeconds: remaining - 1)
                }
            }
        }
    }

    func cancelCountdown() {
        guard case .countdown = state else { return }
        countdownTask?.cancel()
        countdownTask = nil
        state = .inactive
    }

    func startNow() {
        guard case .countdown = state, let makeCurtainContent else { return }
        countdownTask?.cancel()
        countdownTask = nil
        arm(contentBuilder: makeCurtainContent)
    }

    func requestAuthentication() {
        switch state {
        case .guarded, .degraded:
            break
        case .inactive, .countdown, .arming, .authenticating, .disarming:
            return
        }
        if preferences.authenticationMethod == .system {
            beginSystemAuthentication()
        } else {
            inputGuard.setPolicy(.pinEntry)
            inputGuard.handleTapDisabled()
            guard inputGuard.isFilteringOperational else {
                hasInputFailure = true
                activeAuthenticationMethod = nil
                let message = protectionDegradationMessage ?? Self.inputFailureMessage
                state = .degraded(message: message)
                return
            }
            hasInputFailure = false
            let attemptID = UUID()
            pinEntry = ""
            lastErrorMessage = nil
            activeAuthenticationMethod = .pin
            state = .authenticating(attemptID: attemptID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func beginSystemAuthentication() {
        switch state {
        case .guarded, .degraded:
            break
        case .authenticating where activeAuthenticationMethod == .pin:
            break
        case .inactive, .countdown, .arming, .authenticating, .disarming:
            return
        }
        cancelPINVerification()
        returnToPINAfterSystemAuthentication = preferences.authenticationMethod == .pin
        let attemptID = UUID()
        pinEntry = ""
        lastErrorMessage = nil
        activeAuthenticationMethod = .system
        state = .authenticating(attemptID: attemptID)
        inputGuard.setPolicy(.systemAuthentication)
        NSApp.activate(ignoringOtherApps: true)

        authenticationTask?.cancel()
        authenticationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded: Bool
            do {
                try await authenticator.authenticate(reason: Self.authenticationReason)
                succeeded = true
            } catch {
                succeeded = false
            }

            if completeSystemAuthentication(succeeded: succeeded, attemptID: attemptID) {
                authenticationTask = nil
            }
        }
    }

    @discardableResult
    func completeSystemAuthentication(succeeded: Bool, attemptID: UUID) -> Bool {
        guard case .authenticating(let currentAttemptID) = state,
              currentAttemptID == attemptID,
              activeAuthenticationMethod == .system else {
            return false
        }
        inputGuard.setPolicy(.fullFiltering)
        inputGuard.handleTapDisabled()
        if inputGuard.isFilteringOperational {
            hasInputFailure = false
        }

        if succeeded {
            pinCooldown.recordSuccess()
            returnToPINAfterSystemAuthentication = false
            disarmAfterAuthentication()
        } else {
            quitAfterAuthentication = false
            lastErrorMessage = "Authentication was cancelled or failed."
            if let protectionDegradationMessage {
                activeAuthenticationMethod = nil
                state = .degraded(message: protectionDegradationMessage)
            } else if returnToPINAfterSystemAuthentication,
                      inputGuard.isFilteringOperational {
                inputGuard.setPolicy(.pinEntry)
                activeAuthenticationMethod = .pin
                state = .authenticating(attemptID: UUID())
            } else if inputGuard.isFilteringOperational {
                activeAuthenticationMethod = nil
                state = .guarded
            } else {
                activeAuthenticationMethod = nil
                hasInputFailure = true
                let message = protectionDegradationMessage ?? Self.inputFailureMessage
                state = .degraded(message: message)
            }
            returnToPINAfterSystemAuthentication = false
        }
        return true
    }

    func updatePINEntry(_ value: String) {
        guard !pinCooldown.isCoolingDown(at: now()), !isVerifyingPIN else { return }
        let digits = value.utf8.filter { (48...57).contains($0) }.prefix(4)
        pinEntry = String(decoding: digits, as: UTF8.self)
        lastErrorMessage = nil
    }

    func appendPINDigit(_ digit: Int) {
        guard !pinCooldown.isCoolingDown(at: now()),
              !isVerifyingPIN,
              (0...9).contains(digit),
              pinEntry.utf8.count < 4 else { return }
        pinEntry.append(String(digit))
    }

    func deleteLastPINDigit() {
        guard !pinCooldown.isCoolingDown(at: now()),
              !isVerifyingPIN,
              !pinEntry.isEmpty else { return }
        pinEntry.removeLast()
    }

    func submitPIN() {
        guard case .authenticating(let attemptID) = state,
              activeAuthenticationMethod == .pin,
              !isVerifyingPIN else { return }
        guard !pinCooldown.isCoolingDown(at: now()) else {
            lastErrorMessage = "PIN entry is temporarily unavailable. Use Mac authentication."
            return
        }
        guard AwayPINCodec.isValidPIN(pinEntry) else {
            lastErrorMessage = "Enter exactly four digits."
            return
        }

        let candidate = pinEntry
        pinEntry = ""
        isVerifyingPIN = true
        let verificationID = UUID()
        pinVerificationID = verificationID
        let store = pinStore
        pinVerificationTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> AwayPINVerificationResult in
                do {
                    return try store.verifyPIN(candidate) ? .accepted : .rejected
                } catch {
                    return AwayPINVerificationResult.unreadable
                }
            }.value

            guard let self, pinVerificationID == verificationID else { return }
            pinVerificationTask = nil
            pinVerificationID = nil
            isVerifyingPIN = false
            guard case .authenticating(let currentAttemptID) = state,
                  currentAttemptID == attemptID,
                  activeAuthenticationMethod == .pin else { return }

            switch result {
            case .accepted:
                break
            case .rejected:
                recordPINFailure(attemptID: attemptID)
                return
            case .unreadable:
                lastErrorMessage = "The Away Mode PIN could not be read. Use Mac authentication to repair it."
                return
            }
            pinCooldown.recordSuccess()
            returnToPINAfterSystemAuthentication = false
            disarmAfterAuthentication()
        }
    }

    func requestQuit() {
        switch state {
        case .guarded, .degraded:
            quitAfterAuthentication = true
            requestAuthentication()
        case .arming, .authenticating, .disarming:
            quitAfterAuthentication = true
        case .inactive, .countdown:
            return
        }
    }

    func registerActivity() {
        switch state {
        case .guarded, .authenticating, .degraded:
            break
        case .inactive, .countdown, .arming, .disarming:
            return
        }
        let activityDate = now()
        if isBlackedOut {
            isBlackedOut = false
            scheduleDim()
            return
        }
        guard preferences.keepsDisplayAwake,
              preferences.dimDelay.timeInterval != nil else {
            return
        }
        if let lastDimScheduleAt,
           activityDate.timeIntervalSince(lastDimScheduleAt) < Self.activityRescheduleInterval {
            return
        }
        scheduleDim()
    }

    func refreshPreferences() {
        guard isGuarding else { return }
        reconcilePowerPolicy()
        scheduleDim()
    }

    func updatePreferences(_ update: (inout AwayModePreferences) -> Void) {
        var appSettings = settings.appSettings
        update(&appSettings.awayModePreferences)
        settings.appSettings = appSettings
        refreshPreferences()
    }

    func requestEventAccess() {
        inputGuard.requestEventAccess()
    }

    func checkEventAccess() -> Bool {
        guard !isGuarding else { return inputGuard.hasEventAccess }
        return inputGuard.preflight()
    }

    func hasUsablePIN() -> Bool {
        guard !didShutDown else { return false }
        return (try? pinStore.hasPIN()) == true
    }

    @discardableResult
    func configurePIN(_ pin: String, confirmation: String) async -> Bool {
        guard !didShutDown, state == .inactive, !isManagingPIN else { return false }
        guard pin == confirmation else {
            pinConfigurationError = "PIN entries do not match."
            return false
        }
        guard AwayPINCodec.isValidPIN(pin) else {
            pinConfigurationError = "Use exactly four ASCII digits."
            return false
        }

        let managementID = UUID()
        pinManagementID = managementID
        isManagingPIN = true
        defer {
            if pinManagementID == managementID {
                pinManagementID = nil
                isManagingPIN = false
            }
        }
        do {
            try await authenticator.authenticate(reason: "Change the Semper Away Mode PIN.")
            guard !Task.isCancelled,
                  !didShutDown,
                  pinManagementID == managementID,
                  state == .inactive else { return false }
            let store = pinStore
            let preparedPIN = try await Task.detached(priority: .userInitiated) {
                try store.preparePIN(pin)
            }.value
            guard !Task.isCancelled,
                  !didShutDown,
                  pinManagementID == managementID,
                  state == .inactive else {
                pinConfigurationError = "Mac authentication or PIN storage failed."
                return false
            }
            let priorAppSettings = settings.appSettings
            try store.commitPIN(preparedPIN)
            var appSettings = priorAppSettings
            appSettings.awayModePreferences.authenticationMethod = .pin
            settings.appSettings = appSettings
            guard settings.flushSync() else {
                settings.appSettings = priorAppSettings
                _ = settings.flushSync()
                pinConfigurationError = "The PIN was stored, but Away Mode settings could not be saved. Review setup before starting."
                return false
            }
            pinConfigurationError = nil
            return true
        } catch {
            pinConfigurationError = "Mac authentication or PIN storage failed."
            return false
        }
    }

    @discardableResult
    func removePIN() async -> Bool {
        guard !didShutDown, state == .inactive, !isManagingPIN else { return false }
        let managementID = UUID()
        pinManagementID = managementID
        isManagingPIN = true
        defer {
            if pinManagementID == managementID {
                pinManagementID = nil
                isManagingPIN = false
            }
        }
        do {
            try await authenticator.authenticate(reason: "Remove the Semper Away Mode PIN.")
            guard !Task.isCancelled,
                  !didShutDown,
                  pinManagementID == managementID,
                  state == .inactive else { return false }
            try pinStore.removePIN()
            var appSettings = settings.appSettings
            appSettings.awayModePreferences.authenticationMethod = .system
            settings.appSettings = appSettings
            guard settings.flushSync() else {
                pinConfigurationError = "The PIN was removed, but Away Mode settings could not be saved. Repair setup after relaunch."
                return false
            }
            pinConfigurationError = nil
            return true
        } catch {
            pinConfigurationError = "Mac authentication or PIN removal failed."
            return false
        }
    }

    func finishSetup(
        authenticationMethod: AwayAuthenticationMethod,
        theme: AwayModeTheme,
        accent: AwayModeAccent
    ) -> Bool {
        guard !didShutDown, state == .inactive, !isManagingPIN else {
            pinConfigurationError = "Away Mode setup can no longer be saved."
            return false
        }
        if authenticationMethod == .pin {
            do {
                guard try pinStore.hasPIN() else {
                    pinConfigurationError = "The existing PIN is missing. Create a new PIN."
                    return false
                }
            } catch {
                pinConfigurationError = "The existing PIN could not be read. Create a new PIN."
                return false
            }
        }

        let priorAppSettings = settings.appSettings
        var appSettings = priorAppSettings
        appSettings.awayModePreferences.authenticationMethod = authenticationMethod
        appSettings.awayModePreferences.theme = theme
        appSettings.awayModePreferences.accent = accent
        appSettings.awayModePreferences.disclosureCompleted = true
        settings.appSettings = appSettings
        guard settings.flushSync() else {
            settings.appSettings = priorAppSettings
            _ = settings.flushSync()
            pinConfigurationError = "Away Mode setup could not be saved."
            return false
        }
        pinConfigurationError = nil
        return true
    }

    @discardableResult
    func importPhoto(from url: URL) throws -> AwayManagedPhoto {
        guard !didShutDown, state == .inactive, !isManagingPIN else {
            throw AwayModeDataError.mutationUnavailable
        }
        let imported = try photoStore.importPhoto(from: url)
        let priorAppSettings = settings.appSettings
        let priorFilename = preferences.managedPhotoFilename
        var appSettings = priorAppSettings
        appSettings.awayModePreferences.managedPhotoFilename = imported.filename
        appSettings.awayModePreferences.theme = .customPhoto
        settings.appSettings = appSettings
        guard settings.flushSync() else {
            settings.appSettings = priorAppSettings
            _ = settings.flushSync()
            do {
                try photoStore.removePhoto(named: imported.filename)
            } catch {
                throw AwayModeDataError.persistenceAndCleanupFailed
            }
            throw AwayModeDataError.persistenceFailed
        }
        photoImageCache.clear()
        if let priorFilename, priorFilename != imported.filename {
            do {
                try photoStore.removePhoto(named: priorFilename)
            } catch {
                Self.logger.error(
                    "Previous Away photo cleanup failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return imported
    }

    func managedPhotoURL() -> URL? {
        guard let filename = preferences.managedPhotoFilename else { return nil }
        do {
            return try photoStore.managedPhotoURL(for: filename)
        } catch {
            Self.logger.error("Away photo URL failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var hasManagedPhotoFile: Bool {
        guard let url = managedPhotoURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func managedPhotoImage() async -> NSImage? {
        guard let url = managedPhotoURL() else { return nil }
        do {
            return try await photoImageCache.image(at: url)
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.error("Away photo loading failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func resetAwayData() async throws {
        guard !didShutDown, state == .inactive, !isManagingPIN else {
            throw AwayModeDataError.mutationUnavailable
        }

        let managementID = UUID()
        pinManagementID = managementID
        isManagingPIN = true
        defer {
            if pinManagementID == managementID {
                pinManagementID = nil
                isManagingPIN = false
            }
        }

        guard authenticator.isAvailable() else {
            throw AwayModeDataError.authenticationFailed
        }
        do {
            try await authenticator.authenticate(reason: "Reset Semper settings and delete Away Mode data.")
        } catch {
            throw AwayModeDataError.authenticationFailed
        }
        guard !didShutDown,
              pinManagementID == managementID,
              state == .inactive else {
            throw AwayModeDataError.mutationUnavailable
        }

        var completed: Set<AwayModeDataResetStep> = []
        var failed: Set<AwayModeDataResetStep> = []
        do {
            try pinStore.removePIN()
            var appSettings = settings.appSettings
            appSettings.awayModePreferences.authenticationMethod = .system
            settings.appSettings = appSettings
            completed.insert(.pin)
        } catch {
            failed.insert(.pin)
        }

        if let filename = preferences.managedPhotoFilename {
            do {
                try photoStore.removePhoto(named: filename)
                var appSettings = settings.appSettings
                appSettings.awayModePreferences.managedPhotoFilename = nil
                if appSettings.awayModePreferences.theme == .customPhoto {
                    appSettings.awayModePreferences.theme = .aurora
                }
                settings.appSettings = appSettings
                photoImageCache.clear()
                completed.insert(.managedPhoto)
            } catch {
                failed.insert(.managedPhoto)
            }
        }

        do {
            try photoStore.removeUnreferencedPhotos(keeping: preferences.managedPhotoFilename)
            completed.insert(.unusedPhotos)
        } catch {
            failed.insert(.unusedPhotos)
        }

        if !settings.flushSync() {
            failed.insert(.settings)
        }

        if !failed.isEmpty {
            throw AwayModeDataError.deletionFailed(completed: completed, failed: failed)
        }
    }

    func shutdown() {
        guard !didShutDown else { return }
        didShutDown = true
        countdownTask?.cancel()
        dimTask?.cancel()
        authenticationTask?.cancel()
        cancelPINVerification()
        disarmTask?.cancel()
        countdownTask = nil
        dimTask = nil
        authenticationTask = nil
        disarmTask = nil
        activeSessionID = nil
        lastDimScheduleAt = nil
        pinManagementID = nil
        returnToPINAfterSystemAuthentication = false
        activeAuthenticationMethod = nil
        quitAfterAuthentication = false
        pinEntry = ""
        pinCooldown.recordSuccess()
        isManagingPIN = false
        hasCoverageFailure = false
        hasInputFailure = false
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        windows.dismiss()
        presentation.restore()
        inputGuard.stop()
        if releaseAwayLease() {
            releaseMutationPermit()
        }
        powerPolicy.shutdown()
        photoImageCache.clear()
        sessionStartedAt = nil
        isBlackedOut = false
        lastErrorMessage = nil
        powerWarning = nil
        state = .inactive
    }

    private func preflightCapabilities() -> Bool {
        guard preferences.disclosureCompleted else {
            failBeforeActivation(.disclosureRequired)
            return false
        }
        guard authenticator.isAvailable() else {
            failBeforeActivation(.systemAuthenticationUnavailable)
            return false
        }
        if preferences.authenticationMethod == .pin {
            do {
                guard try pinStore.hasPIN() else {
                    failBeforeActivation(.pinMissingOrUnreadable)
                    return false
                }
            } catch {
                failBeforeActivation(.pinMissingOrUnreadable)
                return false
            }
        }
        guard inputGuard.preflight() else {
            failBeforeActivation(.eventAccessRequired)
            return false
        }
        return true
    }

    private func arm(contentBuilder: @escaping CurtainContentBuilder) {
        guard case .countdown = state else { return }
        guard preflightCapabilities() else { return }

        do {
            mutationPermit = try mutationAdmission.acquire(owner: .awayMode, mode: .exclusive)
        } catch {
            failBeforeActivation(.mutationInProgress)
            return
        }

        state = .arming
        lastErrorMessage = nil
        powerWarning = warning(for: powerSnapshot.awakeRestriction)
        hasCoverageFailure = false
        hasInputFailure = false
        onWillGuard?()

        do {
            if powerSnapshot.allowsAwakeAssertions {
                do {
                    awakeLease = try awakeService.acquireLease(
                        owner: .awayMode,
                        keepsDisplayAwake: preferences.keepsDisplayAwake
                    )
                } catch {
                    awakeLease = awakeService.pendingCleanupToken(for: .awayMode)
                    throw AwayModeActivationError.powerAssertionFailed
                }
            }

            guard case .prepared = windows.prepare(contentBuilder: contentBuilder) else {
                throw AwayModeActivationError.panelPreparationFailed
            }
            guard inputGuard.start(policy: .fullFiltering),
                  inputGuard.isFilteringOperational else {
                throw AwayModeActivationError.inputFilterFailed
            }
            do {
                try presentation.begin()
            } catch {
                throw AwayModeActivationError.presentationFailed
            }
            guard case .presented = windows.presentPrepared() else {
                throw AwayModeActivationError.coverageFailed
            }
            guard state == .arming,
                  inputGuard.isFilteringOperational else {
                throw AwayModeActivationError.inputFilterFailed
            }

            NSApp.activate(ignoringOtherApps: true)
            sessionStartedAt = now()
            activeSessionID = UUID()
            isBlackedOut = false
            state = .guarded
            scheduleDim()
            if quitAfterAuthentication {
                requestAuthentication()
            }
        } catch let error as AwayModeActivationError {
            rollbackActivation(error)
        } catch {
            rollbackActivation(.powerAssertionFailed)
        }
    }

    private func rollbackActivation(_ error: AwayModeActivationError) {
        windows.dismiss()
        presentation.restore()
        inputGuard.stop()
        let releasedAwakeLease = releaseAwayLease()
        if releasedAwakeLease {
            releaseMutationPermit()
        }
        sessionStartedAt = nil
        activeSessionID = nil
        lastDimScheduleAt = nil
        hasCoverageFailure = false
        hasInputFailure = false
        isBlackedOut = false
        state = .inactive
        lastErrorMessage = releasedAwakeLease
            ? error.message
            : "\(error.message) The macOS awake request cleanup is still pending."
        onDidDisarm?()
    }

    private func recordPINFailure(attemptID: UUID) {
        guard case .authenticating(let currentAttemptID) = state,
              currentAttemptID == attemptID else { return }
        let delay = pinCooldown.recordFailure(at: now())
        if let delay {
            lastErrorMessage = "Wrong PIN. PIN entry is unavailable for \(Int(delay)) seconds."
        } else {
            lastErrorMessage = "Wrong PIN."
        }
    }

    private func disarmAfterAuthentication() {
        guard isGuarding, let sessionID = activeSessionID else { return }
        cancelPINVerification()
        state = .disarming
        activeAuthenticationMethod = nil
        dimTask?.cancel()
        dimTask = nil
        isBlackedOut = false

        disarmTask?.cancel()
        disarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(.milliseconds(160))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  state == .disarming,
                  activeSessionID == sessionID else { return }
            windows.dismiss()
            presentation.restore()
            inputGuard.stop()
            let releasedAwakeLease = releaseAwayLease()
            if releasedAwakeLease {
                releaseMutationPermit()
            }
            sessionStartedAt = nil
            activeSessionID = nil
            lastDimScheduleAt = nil
            hasCoverageFailure = false
            hasInputFailure = false
            pinEntry = ""
            lastErrorMessage = releasedAwakeLease
                ? nil
                : "Away Mode ended, but the macOS awake request cleanup is still pending."
            powerWarning = nil
            state = .inactive
            disarmTask = nil
            onDidDisarm?()

            if quitAfterAuthentication {
                quitAfterAuthentication = false
                onAuthenticatedQuit?()
            }
        }
    }

    private func scheduleDim() {
        dimTask?.cancel()
        dimTask = nil
        lastDimScheduleAt = nil
        guard isGuarding,
              preferences.keepsDisplayAwake,
              let delay = preferences.dimDelay.timeInterval else { return }
        lastDimScheduleAt = now()
        dimTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(.seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, self.isGuarding else { return }
            self.isBlackedOut = true
            self.dimTask = nil
        }
    }

    private func reconcilePowerPolicy() {
        guard isGuarding else { return }
        powerWarning = warning(for: powerSnapshot.awakeRestriction)

        if !powerSnapshot.allowsAwakeAssertions {
            if !releaseAwayLease() {
                powerWarning = "The macOS awake request cleanup is pending."
            }
            return
        }

        do {
            if let awakeLease {
                try awakeService.updateLease(
                    awakeLease,
                    keepsDisplayAwake: preferences.keepsDisplayAwake
                )
            } else {
                awakeLease = try awakeService.acquireLease(
                    owner: .awayMode,
                    keepsDisplayAwake: preferences.keepsDisplayAwake
                )
            }
        } catch {
            if awakeLease == nil {
                awakeLease = awakeService.pendingCleanupToken(for: .awayMode)
            }
            let didRelease = releaseAwayLease()
            powerWarning = didRelease
                ? "The macOS awake request failed. macOS may sleep."
                : "The macOS awake request failed and cleanup is pending."
        }
    }

    private func warning(for restriction: AwayAwakeRestriction?) -> String? {
        switch restriction {
        case .criticalThermalPressure:
            "Thermal pressure is critical. Semper is not requesting that macOS stay awake, and macOS may sleep."
        case .lowBattery:
            "Battery is at 10% or lower. Semper is not requesting that macOS stay awake, and macOS may sleep."
        case .awaitingSafePower:
            "Connect power or charge to 15% before the awake request resumes. macOS may sleep."
        case .powerStatusUnavailable:
            "Power status is unavailable. Semper is not requesting that macOS stay awake, and macOS may sleep."
        case nil:
            nil
        }
    }

    @discardableResult
    private func releaseAwayLease() -> Bool {
        guard let awakeLease else { return true }
        guard awakeService.releaseLease(awakeLease) else {
            Self.logger.error("Away power lease cleanup is pending")
            return false
        }
        self.awakeLease = nil
        return true
    }

    private func prepareMutationAdmissionForEntry() -> Bool {
        guard mutationPermit != nil else { return true }
        guard releaseAwayLease() else { return false }
        releaseMutationPermit()
        return mutationPermit == nil
    }

    private func releaseMutationPermit() {
        guard let mutationPermit else { return }
        guard mutationAdmission.release(mutationPermit) else {
            Self.logger.error("Away mutation permit cleanup is pending")
            return
        }
        self.mutationPermit = nil
    }

    private func cancelPINVerification() {
        pinVerificationTask?.cancel()
        pinVerificationTask = nil
        pinVerificationID = nil
        isVerifyingPIN = false
    }

    private var protectionDegradationMessage: String? {
        switch (hasCoverageFailure, hasInputFailure) {
        case (true, true):
            "Display coverage could not be restored and input filtering stopped. Existing curtains remain visible. Use Mac authentication or Force Quit."
        case (true, false):
            Self.coverageFailureMessage
        case (false, true):
            Self.inputFailureMessage
        case (false, false):
            nil
        }
    }

    private func markCoverageFailed() {
        guard isGuarding else { return }
        hasCoverageFailure = true
        refreshProtectionState()
    }

    private func markInputFailed() {
        guard isGuarding else { return }
        hasInputFailure = true
        refreshProtectionState()
    }

    private func handleCoverageRestored() {
        hasCoverageFailure = false
        refreshProtectionState()
    }

    private func handleInputRestored() {
        hasInputFailure = false
        refreshProtectionState()
    }

    private func refreshProtectionState() {
        guard isGuarding, windows.isPresented, !isAuthenticating else { return }
        guard state != .arming, state != .disarming else { return }
        if let protectionDegradationMessage {
            state = .degraded(message: protectionDegradationMessage)
        } else if case .degraded = state {
            lastErrorMessage = nil
            state = .guarded
        }
    }

    private func observeWorkspace(
        _ name: Notification.Name,
        handler: @escaping @MainActor () -> Void
    ) {
        let observer = workspaceNotificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        workspaceObservers.append(observer)
    }

    private func failBeforeActivation(_ error: AwayModeActivationError) {
        countdownTask?.cancel()
        countdownTask = nil
        state = .inactive
        activeAuthenticationMethod = nil
        lastErrorMessage = error.message
    }
}
