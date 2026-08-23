import Foundation

struct AppShortcutApplicationDescriptor: Equatable, Sendable {
    let identifier: String
    let displayName: String
    let isActive: Bool
}

struct AppShortcutOutputDescriptor: Equatable, Sendable {
    let uid: String
    let displayName: String
}

struct AppShortcutExecution: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case applied
        case accepted
        case unchanged
    }

    let status: Status
    let message: String
}

enum AppShortcutExecutionError: LocalizedError, Equatable {
    case unavailable
    case invalidValue(String)
    case appUnavailable(String)
    case deviceUnavailable(String)
    case permissionDenied
    case unsupportedRoute(String)
    case writeFailed
    case callModeDisabled
    case callAppUnavailable(String)
    case undoUnavailable
    case undoStale
    case undoFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Open Semper once, then run this shortcut again."
        case .invalidValue(let message):
            message
        case .appUnavailable(let identifier):
            "The app with identifier \(identifier) is no longer available in Semper."
        case .deviceUnavailable(let uid):
            "The output with UID \(uid) is disconnected."
        case .permissionDenied:
            "Allow System Audio Recording for Semper, then run this shortcut again."
        case .unsupportedRoute(let message):
            message
        case .writeFailed:
            "Semper could not apply the audio change."
        case .callModeDisabled:
            "Call Mode is disabled in Semper Settings."
        case .callAppUnavailable(let name):
            "\(name) is not running."
        case .undoUnavailable:
            "There is no recent Semper audio change to undo."
        case .undoStale:
            "The audio setting changed again, so Semper did not undo it."
        case .undoFailed:
            "Semper could not restore every audio setting."
        }
    }
}

@MainActor
final class AppShortcutController {
    private let activeApplications: () -> [AudioApp]
    private let pinnedApplications: () -> [PinnedAppInfo]
    private let outputDevices: () -> [AudioDevice]
    private let dispatchCommand: (AudioCommand, AudioCommandContext) -> AudioCommandResult
    private let undoCommand: (AudioCommandSource) -> AudioUndoResult
    private let callModeEnabled: () -> Bool
    private let activeCallSession: () -> CallModeSession?
    private let startCallMode: (String, String) -> Void
    private let endCallMode: () -> Void

    init(
        activeApplications: @escaping () -> [AudioApp],
        pinnedApplications: @escaping () -> [PinnedAppInfo],
        outputDevices: @escaping () -> [AudioDevice],
        dispatchCommand: @escaping (AudioCommand, AudioCommandContext) -> AudioCommandResult,
        undoCommand: @escaping (AudioCommandSource) -> AudioUndoResult,
        callModeEnabled: @escaping () -> Bool,
        activeCallSession: @escaping () -> CallModeSession?,
        startCallMode: @escaping (String, String) -> Void,
        endCallMode: @escaping () -> Void
    ) {
        self.activeApplications = activeApplications
        self.pinnedApplications = pinnedApplications
        self.outputDevices = outputDevices
        self.dispatchCommand = dispatchCommand
        self.undoCommand = undoCommand
        self.callModeEnabled = callModeEnabled
        self.activeCallSession = activeCallSession
        self.startCallMode = startCallMode
        self.endCallMode = endCallMode
    }

    convenience init(
        engine: AudioEngine,
        commands: any AudioCommandDispatching,
        callMode: CallModeCoordinator
    ) {
        self.init(
            activeApplications: { [weak engine] in engine?.apps ?? [] },
            pinnedApplications: { [weak engine] in
                engine?.settingsManager.getPinnedAppInfo() ?? []
            },
            outputDevices: { [weak engine] in engine?.outputDevices ?? [] },
            dispatchCommand: { command, context in
                commands.dispatch(command, context: context)
            },
            undoCommand: { source in commands.undoLastChange(source: source) },
            callModeEnabled: { [weak engine] in
                engine?.settingsManager.appSettings.callModeEnabled ?? false
            },
            activeCallSession: { [weak callMode] in callMode?.activeSession },
            startCallMode: { [weak callMode] identifier, name in
                callMode?.start(applicationIdentifier: identifier, displayName: name)
            },
            endCallMode: { [weak callMode] in callMode?.end() }
        )
    }

    func applications() -> [AppShortcutApplicationDescriptor] {
        var applicationsByID = Dictionary(
            uniqueKeysWithValues: pinnedApplications().map {
                ($0.persistenceIdentifier, AppShortcutApplicationDescriptor(
                    identifier: $0.persistenceIdentifier,
                    displayName: $0.displayName,
                    isActive: false
                ))
            }
        )
        for app in activeApplications() {
            applicationsByID[app.persistenceIdentifier] = AppShortcutApplicationDescriptor(
                identifier: app.persistenceIdentifier,
                displayName: app.name,
                isActive: true
            )
        }
        return applicationsByID.values.sorted(by: Self.sortApplications)
    }

    func outputs() -> [AppShortcutOutputDescriptor] {
        outputDevices().map {
            AppShortcutOutputDescriptor(uid: $0.uid, displayName: $0.name)
        }.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.uid < $1.uid : comparison == .orderedAscending
        }
    }

    func setVolume(
        applicationIdentifier: String,
        percent: Double
    ) throws -> AppShortcutExecution {
        guard percent.isFinite, (0...100).contains(percent) else {
            throw AppShortcutExecutionError.invalidValue("Volume must be between 0 and 100 percent.")
        }
        let application = try requireApplication(applicationIdentifier)
        return try execute(
            .setAppVolume(
                target: .persisted(application.identifier),
                volume: Float(percent / 100)
            ),
            appliedMessage: "Set \(application.displayName) volume to \(Int(percent.rounded()))%."
        )
    }

    func setMute(
        applicationIdentifier: String,
        muted: Bool
    ) throws -> AppShortcutExecution {
        let application = try requireApplication(applicationIdentifier)
        return try execute(
            .setAppMute(target: .persisted(application.identifier), muted: muted),
            appliedMessage: muted ? "Muted \(application.displayName)." : "Unmuted \(application.displayName)."
        )
    }

    func route(
        applicationIdentifier: String,
        outputUID: String
    ) throws -> AppShortcutExecution {
        let application = try requireApplication(applicationIdentifier)
        let output = try requireOutput(outputUID)
        return try execute(
            .setAppDevice(target: .persisted(application.identifier), deviceUID: output.uid),
            appliedMessage: "Routed \(application.displayName) to \(output.displayName)."
        )
    }

    func followDefaultOutput(
        applicationIdentifier: String
    ) throws -> AppShortcutExecution {
        let application = try requireApplication(applicationIdentifier)
        return try execute(
            .setAppDevice(target: .persisted(application.identifier), deviceUID: nil),
            appliedMessage: "Set \(application.displayName) to follow the default output."
        )
    }

    func switchDefaultOutput(outputUID: String) throws -> AppShortcutExecution {
        let output = try requireOutput(outputUID)
        return try execute(
            .setDefaultOutput(deviceUID: output.uid),
            appliedMessage: "Switched the default output to \(output.displayName)."
        )
    }

    func setAudioProcessingMode(_ mode: AudioProcessingMode) throws -> AppShortcutExecution {
        let message = mode == .bypassed
            ? "Bypassed Semper audio processing."
            : "Requested Semper audio processing."
        return try execute(.setAudioProcessingMode(mode), appliedMessage: message)
    }

    func startCallMode(applicationIdentifier: String) throws -> AppShortcutExecution {
        guard callModeEnabled() else {
            throw AppShortcutExecutionError.callModeDisabled
        }
        guard let verified = VerifiedCallApplication.matching(applicationIdentifier) else {
            throw AppShortcutExecutionError.appUnavailable(applicationIdentifier)
        }
        guard activeApplications().contains(where: {
            $0.persistenceIdentifier == applicationIdentifier
        }) else {
            throw AppShortcutExecutionError.callAppUnavailable(verified.displayName)
        }
        if activeCallSession()?.applicationIdentifier == applicationIdentifier {
            return AppShortcutExecution(
                status: .unchanged,
                message: "Call Mode is already active for \(verified.displayName)."
            )
        }
        startCallMode(verified.identifier, verified.displayName)
        return AppShortcutExecution(
            status: .applied,
            message: "Started Call Mode for \(verified.displayName)."
        )
    }

    func endCallModeSession() -> AppShortcutExecution {
        guard let session = activeCallSession() else {
            return AppShortcutExecution(
                status: .unchanged,
                message: "Call Mode is not active."
            )
        }
        endCallMode()
        return AppShortcutExecution(
            status: .applied,
            message: "Ended Call Mode for \(session.displayName)."
        )
    }

    func undoLastChange() throws -> AppShortcutExecution {
        switch undoCommand(.appIntent) {
        case .restored:
            AppShortcutExecution(
                status: .applied,
                message: "Restored the previous audio settings."
            )
        case .unavailable:
            throw AppShortcutExecutionError.undoUnavailable
        case .stale:
            throw AppShortcutExecutionError.undoStale
        case .failed:
            throw AppShortcutExecutionError.undoFailed
        }
    }

    private func execute(
        _ command: AudioCommand,
        appliedMessage: String
    ) throws -> AppShortcutExecution {
        let result = dispatchCommand(
            command,
            AudioCommandContext(source: .appIntent, reason: .shortcut)
        )
        switch result {
        case .applied:
            return AppShortcutExecution(status: .applied, message: appliedMessage)
        case .accepted:
            return AppShortcutExecution(
                status: .accepted,
                message: "Semper accepted the audio change request."
            )
        case .unchanged:
            return AppShortcutExecution(
                status: .unchanged,
                message: "That audio setting is already in place."
            )
        case .rejected(let rejection):
            throw Self.error(for: rejection)
        }
    }

    private func requireApplication(_ identifier: String) throws -> AppShortcutApplicationDescriptor {
        guard let application = applications().first(where: { $0.identifier == identifier }) else {
            throw AppShortcutExecutionError.appUnavailable(identifier)
        }
        return application
    }

    private func requireOutput(_ uid: String) throws -> AppShortcutOutputDescriptor {
        guard let output = outputs().first(where: { $0.uid == uid }) else {
            throw AppShortcutExecutionError.deviceUnavailable(uid)
        }
        return output
    }

    private static func error(for rejection: AudioCommandRejection) -> AppShortcutExecutionError {
        switch rejection {
        case .invalidValue:
            .invalidValue("The shortcut contains an invalid value.")
        case .appUnavailable(let identifier):
            .appUnavailable(identifier)
        case .deviceUnavailable(let uid):
            .deviceUnavailable(uid)
        case .permissionDenied:
            .permissionDenied
        case .unsupportedRoute(let message):
            .unsupportedRoute(message)
        case .writeFailed:
            .writeFailed
        }
    }

    private static func sortApplications(
        _ lhs: AppShortcutApplicationDescriptor,
        _ rhs: AppShortcutApplicationDescriptor
    ) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        return comparison == .orderedSame
            ? lhs.identifier < rhs.identifier
            : comparison == .orderedAscending
    }
}
