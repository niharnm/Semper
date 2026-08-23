import AppIntents
import Foundation

protocol SemperForegroundAppIntent: AppIntent {}

extension SemperForegroundAppIntent {
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
}

struct SemperApplicationEntity: AppEntity, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Application")
    static let defaultQuery = SemperApplicationQuery()

    let id: String
    let displayName: String
    let isActive: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(id)"
        )
    }
}

struct SemperApplicationQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [SemperApplicationEntity] {
        let available = await SemperAppIntentRuntime.applications()
        let applicationsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return identifiers.map {
            applicationsByID[$0] ?? SemperApplicationEntity(
                id: $0,
                displayName: $0,
                isActive: false
            )
        }
    }

    func suggestedEntities() async throws -> [SemperApplicationEntity] {
        await SemperAppIntentRuntime.applications()
    }

    func entities(matching string: String) async throws -> [SemperApplicationEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return await SemperAppIntentRuntime.applications() }
        return await SemperAppIntentRuntime.applications().filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
}

struct SemperOutputDeviceEntity: AppEntity, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audio Output")
    static let defaultQuery = SemperOutputDeviceQuery()

    let id: String
    let displayName: String
    let isConnected: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(id)"
        )
    }
}

struct SemperOutputDeviceQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [SemperOutputDeviceEntity] {
        let available = await SemperAppIntentRuntime.outputs()
        let outputsByUID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return identifiers.map {
            outputsByUID[$0] ?? SemperOutputDeviceEntity(
                id: $0,
                displayName: "Disconnected Output",
                isConnected: false
            )
        }
    }

    func suggestedEntities() async throws -> [SemperOutputDeviceEntity] {
        await SemperAppIntentRuntime.outputs()
    }

    func entities(matching string: String) async throws -> [SemperOutputDeviceEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return await SemperAppIntentRuntime.outputs() }
        return await SemperAppIntentRuntime.outputs().filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
}

struct SemperCallApplicationEntity: AppEntity, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Call Application")
    static let defaultQuery = SemperCallApplicationQuery()

    let id: String
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(id)"
        )
    }
}

struct SemperCallApplicationQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [SemperCallApplicationEntity] {
        let supported = Self.supportedApplications
        let applicationsByID = Dictionary(uniqueKeysWithValues: supported.map { ($0.id, $0) })
        return identifiers.compactMap { applicationsByID[$0] }
    }

    func suggestedEntities() async throws -> [SemperCallApplicationEntity] {
        Self.supportedApplications
    }

    func entities(matching string: String) async throws -> [SemperCallApplicationEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.supportedApplications }
        return Self.supportedApplications.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private static let supportedApplications = VerifiedCallApplication.supported.map {
        SemperCallApplicationEntity(id: $0.identifier, displayName: $0.displayName)
    }
}

enum SemperMuteState: String, AppEnum {
    case muted
    case unmuted

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mute State")
    static let caseDisplayRepresentations: [SemperMuteState: DisplayRepresentation] = [
        .muted: "Muted",
        .unmuted: "Unmuted",
    ]
}

@MainActor
enum SemperAppIntentRuntime {
    private static var controller: AppShortcutController?

    static func install(_ controller: AppShortcutController) {
        self.controller = controller
        SemperAppShortcuts.updateAppShortcutParameters()
    }

    static func applications() -> [SemperApplicationEntity] {
        guard let controller else { return [] }
        return controller.applications().map {
            SemperApplicationEntity(
                id: $0.identifier,
                displayName: $0.displayName,
                isActive: $0.isActive
            )
        }
    }

    static func outputs() -> [SemperOutputDeviceEntity] {
        guard let controller else { return [] }
        return controller.outputs().map {
            SemperOutputDeviceEntity(
                id: $0.uid,
                displayName: $0.displayName,
                isConnected: true
            )
        }
    }

    static func perform(
        _ operation: @MainActor (AppShortcutController) throws -> AppShortcutExecution
    ) throws -> AppShortcutExecution {
        guard let controller else { throw AppShortcutExecutionError.unavailable }
        return try operation(controller)
    }
}

struct SemperSetAppVolumeIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Set App Volume"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Application")
    var application: SemperApplicationEntity

    @Parameter(title: "Volume", description: "A percentage from 0 to 100")
    var percent: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$application) volume to \(\.$percent)%")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.setVolume(applicationIdentifier: application.id, percent: percent)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperSetAppMuteIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Set App Mute"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Application")
    var application: SemperApplicationEntity

    @Parameter(title: "State")
    var state: SemperMuteState

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$application) to \(\.$state)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.setMute(
                applicationIdentifier: application.id,
                muted: state == .muted
            )
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperRouteAppIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Route App to Output"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Application")
    var application: SemperApplicationEntity

    @Parameter(title: "Output")
    var output: SemperOutputDeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Route \(\.$application) to \(\.$output)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.route(applicationIdentifier: application.id, outputUID: output.id)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperFollowDefaultOutputIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Make App Follow Default Output"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Application")
    var application: SemperApplicationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Make \(\.$application) follow the default output")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.followDefaultOutput(applicationIdentifier: application.id)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperSwitchOutputIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Switch Default Output"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Output")
    var output: SemperOutputDeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch the default output to \(\.$output)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.switchDefaultOutput(outputUID: output.id)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperStartCallModeIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Start Call Mode"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Call Application")
    var application: SemperCallApplicationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start Call Mode for \(\.$application)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.startCallMode(applicationIdentifier: application.id)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperEndCallModeIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "End Call Mode"
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            $0.endCallModeSession()
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperBypassAudioIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Bypass Audio Processing"
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.setAudioProcessingMode(.bypassed)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperResumeAudioIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Resume Audio Processing"
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.setAudioProcessingMode(.resumeRequested)
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperUndoAudioIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Undo Last Audio Change"
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperAppIntentRuntime.perform {
            try $0.undoLastChange()
        }
        return .result(dialog: "\(result.message)")
    }
}

struct SemperAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SemperSetAppVolumeIntent(),
            phrases: ["Set app volume with \(.applicationName)"],
            shortTitle: "Set App Volume",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: SemperSetAppMuteIntent(),
            phrases: ["Set app mute with \(.applicationName)"],
            shortTitle: "Set App Mute",
            systemImageName: "speaker.slash"
        )
        AppShortcut(
            intent: SemperRouteAppIntent(),
            phrases: ["Route an app with \(.applicationName)"],
            shortTitle: "Route App",
            systemImageName: "arrow.triangle.branch"
        )
        AppShortcut(
            intent: SemperFollowDefaultOutputIntent(),
            phrases: ["Make an app follow the default output with \(.applicationName)"],
            shortTitle: "Follow Default Output",
            systemImageName: "arrow.triangle.turn.up.right.diamond"
        )
        AppShortcut(
            intent: SemperSwitchOutputIntent(),
            phrases: ["Switch audio output with \(.applicationName)"],
            shortTitle: "Switch Output",
            systemImageName: "hifispeaker.2"
        )
        AppShortcut(
            intent: SemperStartCallModeIntent(),
            phrases: ["Start Call Mode with \(.applicationName)"],
            shortTitle: "Start Call Mode",
            systemImageName: "phone"
        )
        AppShortcut(
            intent: SemperEndCallModeIntent(),
            phrases: ["End Call Mode with \(.applicationName)"],
            shortTitle: "End Call Mode",
            systemImageName: "phone.down"
        )
        AppShortcut(
            intent: SemperBypassAudioIntent(),
            phrases: ["Bypass audio processing with \(.applicationName)"],
            shortTitle: "Bypass Processing",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: SemperResumeAudioIntent(),
            phrases: ["Resume audio processing with \(.applicationName)"],
            shortTitle: "Resume Processing",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: SemperUndoAudioIntent(),
            phrases: ["Undo my last audio change with \(.applicationName)"],
            shortTitle: "Undo Audio Change",
            systemImageName: "arrow.uturn.backward"
        )
    }
}
