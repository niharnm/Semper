import Foundation

nonisolated struct SceneCommandDescriptor: Equatable, Sendable {
    let id: UUID
    let name: String
}

nonisolated struct SceneCommandExecution: Equatable, Sendable {
    let message: String
}

@MainActor
protocol SceneCommandHandling: AnyObject {
    func availableScenes() -> [SceneCommandDescriptor]
    func applyScene(id: UUID) async throws -> SceneCommandExecution
    func restoreScene() async throws -> SceneCommandExecution
}

nonisolated enum SceneCommandRuntimeError: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Scene controls are not available."
        }
    }
}
