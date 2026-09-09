import AppIntents
import Foundation

struct SemperSceneEntity: AppEntity, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scene")
    static let defaultQuery = SemperSceneQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct SemperSceneQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [SemperSceneEntity] {
        let available = await SemperSceneAppIntentRuntime.scenes()
        var scenesByID: [UUID: SemperSceneEntity] = [:]
        for scene in available where scenesByID[scene.id] == nil {
            scenesByID[scene.id] = scene
        }
        return identifiers.compactMap { scenesByID[$0] }
    }

    func suggestedEntities() async throws -> [SemperSceneEntity] {
        await SemperSceneAppIntentRuntime.scenes()
    }

    func entities(matching string: String) async throws -> [SemperSceneEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return await SemperSceneAppIntentRuntime.scenes() }
        return await SemperSceneAppIntentRuntime.scenes().filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }
}

@MainActor
enum SemperSceneAppIntentRuntime {
    private static weak var controller: (any SceneCommandHandling)?
    private static weak var activationOwner: AnyObject?
    private static var activate: (@MainActor () async throws -> Void)?

    static func installActivation(owner: AnyObject, activate: @escaping @MainActor () async throws -> Void) {
        activationOwner = owner
        self.activate = activate
    }

    static func uninstallActivation(owner: AnyObject) {
        guard activationOwner === owner else { return }
        activationOwner = nil
        activate = nil
    }

    static func install(_ controller: any SceneCommandHandling) {
        self.controller = controller
    }

    static func uninstall(_ controller: any SceneCommandHandling) {
        guard self.controller === controller else { return }
        self.controller = nil
    }

    static func scenes() -> [SemperSceneEntity] {
        guard let controller else { return [] }
        return controller.availableScenes().map {
            SemperSceneEntity(id: $0.id, name: $0.name)
        }
    }

    static func applyScene(id: UUID) async throws -> SceneCommandExecution {
        try Task.checkCancellation()
        if activationOwner != nil, let activate { try await activate() }
        try Task.checkCancellation()
        guard let controller else { throw SceneCommandRuntimeError.unavailable }
        return try await controller.applyScene(id: id)
    }

    static func restoreScene() async throws -> SceneCommandExecution {
        try Task.checkCancellation()
        if activationOwner != nil, let activate { try await activate() }
        try Task.checkCancellation()
        guard let controller else { throw SceneCommandRuntimeError.unavailable }
        return try await controller.restoreScene()
    }
}

struct SemperApplySceneIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Apply Scene"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Scene")
    var scene: SemperSceneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$scene)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperSceneAppIntentRuntime.applyScene(id: scene.id)
        return .result(dialog: "\(result.message)")
    }
}

struct SemperRestoreSceneIntent: SemperForegroundAppIntent {
    static let title: LocalizedStringResource = "Restore Previous Setup"
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SemperSceneAppIntentRuntime.restoreScene()
        return .result(dialog: "\(result.message)")
    }
}
