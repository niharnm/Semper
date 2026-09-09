import Foundation

enum LazySceneAdapterError: LocalizedError, Equatable {
    case unavailable(SceneControlDomain)

    var errorDescription: String? {
        switch self {
        case .unavailable(let domain): "The \(domain.rawValue) module for this scene control is not running."
        }
    }
}

@MainActor
final class LazySceneAdapter: SceneControlAdapting {
    private let domain: SceneControlDomain
    private let resolve: @MainActor () -> (any SceneControlAdapting)?

    init(domain: SceneControlDomain, resolve: @escaping @MainActor () -> (any SceneControlAdapting)?) {
        self.domain = domain
        self.resolve = resolve
    }

    func capability(for control: SceneControl) async -> SceneControlCapability {
        guard let adapter = adapter(for: control) else { return .unsupported }
        return await adapter.capability(for: control)
    }

    func preflightTarget(_ value: SceneValue, for control: SceneControl) async -> SceneTargetPreflight {
        guard let adapter = adapter(for: control) else {
            return .unavailable(LazySceneAdapterError.unavailable(domain).localizedDescription)
        }
        return await adapter.preflightTarget(value, for: control)
    }

    func prerequisites(of value: SceneValue, for control: SceneControl) async -> [SceneControlPrerequisite] {
        guard let adapter = adapter(for: control) else { return [] }
        return await adapter.prerequisites(of: value, for: control)
    }

    func restorationValue(for snapshot: SceneValue, control: SceneControl) async -> SceneValue {
        guard let adapter = adapter(for: control) else { return snapshot }
        return await adapter.restorationValue(for: snapshot, control: control)
    }

    func readValue(for control: SceneControl) async throws -> SceneValue {
        guard let adapter = adapter(for: control) else { throw LazySceneAdapterError.unavailable(domain) }
        return try await adapter.readValue(for: control)
    }

    func writeValue(_ value: SceneValue, for control: SceneControl) async throws {
        guard let adapter = adapter(for: control) else { throw LazySceneAdapterError.unavailable(domain) }
        try await adapter.writeValue(value, for: control)
    }

    private func adapter(for control: SceneControl) -> (any SceneControlAdapting)? {
        guard control.domain == domain else { return nil }
        return resolve()
    }
}
