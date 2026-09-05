import Foundation

enum CallModePreference: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case ask
    case always
    case never

    var id: Self { self }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

struct VerifiedCallApplication: Identifiable, Equatable, Sendable {
    let identifier: String
    let displayName: String

    var id: String { identifier }

    static let supported: [VerifiedCallApplication] = [
        VerifiedCallApplication(identifier: "us.zoom.xos", displayName: "Zoom"),
        VerifiedCallApplication(identifier: "com.apple.FaceTime", displayName: "FaceTime"),
        VerifiedCallApplication(identifier: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        VerifiedCallApplication(identifier: "com.microsoft.teams", displayName: "Microsoft Teams Classic"),
    ]

    static func matching(_ identifier: String?) -> VerifiedCallApplication? {
        guard let identifier else { return nil }
        return supported.first { $0.identifier == identifier }
    }
}

struct CallModeAppActivity: Equatable, Sendable {
    let identifier: String
    let displayName: String
    let isUsingInput: Bool
}

struct CallModePrompt: Equatable, Sendable {
    let applicationIdentifier: String
    let displayName: String
}

struct CallModeSession: Equatable, Sendable {
    let applicationIdentifier: String
    let displayName: String
    let inputDeviceUID: String?
    let startedAt: Date
}

enum CallModePromptResponse: Equatable, Sendable {
    case startOnce
    case always
    case notNow
    case never
}

@Observable
@MainActor
final class CallModeCoordinator {
    private static let owner = AudioAutomationOwner(rawValue: "call-mode")
    private static let otherAppGain: Float = 0.25
    private static let quietAlertVolume: Float = 0.25

    private let settings: SettingsManager
    private let overlayStore: AudioModeOverlayStore
    private let activityStore: AudioActivityStore
    private let currentInputDeviceUID: () -> String?
    private let claimInputDevice: (String) -> Bool
    private let releaseInputDevice: () -> Void
    private let readAlertVolume: () -> Float
    private let writeAlertVolume: (Float) -> Void
    private let endDelay: TimeInterval
    private let now: () -> Date

    private(set) var pendingPrompt: CallModePrompt?
    private(set) var activeSession: CallModeSession?

    private var latestActivities: [CallModeAppActivity] = []
    private var suppressedUntilInputStops: Set<String> = []
    private var endTask: Task<Void, Never>?
    private var alertVolumeClaim: (original: Float, applied: Float)?

    init(
        settings: SettingsManager,
        overlayStore: AudioModeOverlayStore,
        activityStore: AudioActivityStore,
        currentInputDeviceUID: @escaping () -> String?,
        claimInputDevice: @escaping (String) -> Bool,
        releaseInputDevice: @escaping () -> Void,
        readAlertVolume: @escaping () -> Float,
        writeAlertVolume: @escaping (Float) -> Void,
        endDelay: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.overlayStore = overlayStore
        self.activityStore = activityStore
        self.currentInputDeviceUID = currentInputDeviceUID
        self.claimInputDevice = claimInputDevice
        self.releaseInputDevice = releaseInputDevice
        self.readAlertVolume = readAlertVolume
        self.writeAlertVolume = writeAlertVolume
        self.endDelay = max(0, endDelay)
        self.now = now
    }

    var isActive: Bool {
        activeSession != nil
    }

    func handleActivities(_ activities: [CallModeAppActivity]) {
        latestActivities = activities
        let activeInputIdentifiers = Set(
            activities.lazy.filter(\.isUsingInput).map(\.identifier)
        )
        suppressedUntilInputStops.formIntersection(activeInputIdentifiers)

        if let prompt = pendingPrompt,
           !activeInputIdentifiers.contains(prompt.applicationIdentifier) {
            pendingPrompt = nil
        }

        if let session = activeSession {
            updateOverlays(for: session)
            if activeInputIdentifiers.contains(session.applicationIdentifier) {
                endTask?.cancel()
                endTask = nil
            } else {
                scheduleAutomaticEnd(for: session.applicationIdentifier)
            }
            return
        }

        guard settings.appSettings.callModeEnabled, pendingPrompt == nil else { return }
        guard let candidate = activities
            .filter({ $0.isUsingInput })
            .sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
            .first(where: {
                VerifiedCallApplication.matching($0.identifier) != nil
                    && !suppressedUntilInputStops.contains($0.identifier)
            }) else {
            return
        }

        switch settings.callModePreference(for: candidate.identifier) {
        case .ask:
            pendingPrompt = CallModePrompt(
                applicationIdentifier: candidate.identifier,
                displayName: candidate.displayName
            )
        case .always:
            start(
                applicationIdentifier: candidate.identifier,
                displayName: candidate.displayName
            )
        case .never:
            suppressedUntilInputStops.insert(candidate.identifier)
        }
    }

    func respond(_ response: CallModePromptResponse) {
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil

        switch response {
        case .startOnce:
            start(
                applicationIdentifier: prompt.applicationIdentifier,
                displayName: prompt.displayName
            )
        case .always:
            settings.setCallModePreference(.always, for: prompt.applicationIdentifier)
            start(
                applicationIdentifier: prompt.applicationIdentifier,
                displayName: prompt.displayName
            )
        case .notNow:
            suppressedUntilInputStops.insert(prompt.applicationIdentifier)
        case .never:
            settings.setCallModePreference(.never, for: prompt.applicationIdentifier)
            suppressedUntilInputStops.insert(prompt.applicationIdentifier)
        }
    }

    func start(applicationIdentifier: String, displayName: String) {
        guard settings.appSettings.callModeEnabled else { return }
        if activeSession?.applicationIdentifier == applicationIdentifier {
            return
        }
        if activeSession != nil {
            end(recordActivity: false)
        }

        endTask?.cancel()
        endTask = nil
        let inputUID = currentInputDeviceUID()
        if let inputUID {
            _ = claimInputDevice(inputUID)
        }
        beginQuietAlertsIfNeeded()

        let session = CallModeSession(
            applicationIdentifier: applicationIdentifier,
            displayName: displayName,
            inputDeviceUID: inputUID,
            startedAt: now()
        )
        activeSession = session
        updateOverlays(for: session)
        recordActiveActivity(for: session)
    }

    func end() {
        end(recordActivity: true)
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            pendingPrompt = nil
            suppressedUntilInputStops.removeAll()
            end(recordActivity: activeSession != nil)
        } else {
            handleActivities(latestActivities)
        }
    }

    func setQuietAlertsEnabled(_ enabled: Bool) {
        guard activeSession != nil else { return }
        if enabled {
            beginQuietAlertsIfNeeded()
        } else {
            restoreAlertVolumeIfOwned()
        }
    }

    func shutdown() {
        pendingPrompt = nil
        suppressedUntilInputStops.removeAll()
        end(recordActivity: false)
    }

    private func updateOverlays(for session: CallModeSession) {
        let targetIdentifiers = Set(
            latestActivities.lazy
                .map(\.identifier)
                .filter { $0 != session.applicationIdentifier }
        )
        _ = overlayStore.replaceGains(
            Dictionary(uniqueKeysWithValues: targetIdentifiers.map {
                ($0, Self.otherAppGain)
            }),
            for: Self.owner
        )
    }

    private func scheduleAutomaticEnd(for applicationIdentifier: String) {
        guard endTask == nil else { return }
        endTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if endDelay > 0 {
                try? await Task.sleep(for: .seconds(endDelay))
            }
            guard !Task.isCancelled,
                  activeSession?.applicationIdentifier == applicationIdentifier,
                  !latestActivities.contains(where: {
                      $0.identifier == applicationIdentifier && $0.isUsingInput
                  }) else {
                return
            }
            end(recordActivity: true)
        }
    }

    private func end(recordActivity: Bool) {
        endTask?.cancel()
        endTask = nil
        guard let session = activeSession else { return }

        overlayStore.removeAll(for: Self.owner)
        releaseInputDevice()
        restoreAlertVolumeIfOwned()
        suppressedUntilInputStops.insert(session.applicationIdentifier)
        activeSession = nil

        if recordActivity {
            activityStore.record(
                presentation: AudioActivityPresentation(
                    message: "Call Mode ended for \(session.displayName)",
                    systemImage: "phone.down"
                ),
                source: .automation,
                reason: .callMode
            )
        }

        handleActivities(latestActivities)
    }

    private func beginQuietAlertsIfNeeded() {
        guard alertVolumeClaim == nil,
              settings.appSettings.callModeQuietAlerts else { return }
        let original = readAlertVolume()
        guard original.isFinite, original > Self.quietAlertVolume else { return }
        writeAlertVolume(Self.quietAlertVolume)
        alertVolumeClaim = (original: original, applied: Self.quietAlertVolume)
    }

    private func restoreAlertVolumeIfOwned() {
        guard let claim = alertVolumeClaim else { return }
        alertVolumeClaim = nil
        guard abs(readAlertVolume() - claim.applied) <= 0.01 else { return }
        writeAlertVolume(claim.original)
    }

    private func recordActiveActivity(for session: CallModeSession) {
        activityStore.record(
            presentation: AudioActivityPresentation(
                message: "Call Mode lowered other apps to 25% for \(session.displayName)",
                systemImage: "phone",
                actionTitle: "End"
            ),
            source: .automation,
            reason: .callMode,
            action: { [weak self] in self?.end() }
        )
    }
}
