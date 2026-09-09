import Foundation
import Observation

struct ModuleStatusSnapshot: Equatable, Sendable {
    let runtime: ModuleRuntimeState
    let permission: ModulePermissionState
}

enum ModuleStatusObserverError: Error, Equatable {
    case invalidRuntimeState(ModuleRuntimeState)
}

@MainActor
final class ModuleStatusObserver {
    private struct Binding {
        let generation = UUID()
        let read: @MainActor () -> ModuleStatusSnapshot
    }

    private let registry: ModuleRegistry
    private let onError: @MainActor (UtilityModuleID, Error) -> Void
    private var bindings: [UtilityModuleID: Binding] = [:]

    init(
        registry: ModuleRegistry,
        onError: @escaping @MainActor (UtilityModuleID, Error) -> Void
    ) {
        self.registry = registry
        self.onError = onError
    }

    func observe(module: UtilityModuleID, read: @escaping @MainActor () -> ModuleStatusSnapshot) {
        let binding = Binding(read: read)
        bindings[module] = binding
        refresh(module: module, generation: binding.generation)
    }

    func stopObserving(module: UtilityModuleID) {
        bindings[module] = nil
    }

    func stopAll() {
        bindings.removeAll()
    }

    private func refresh(module: UtilityModuleID, generation: UUID) {
        guard let binding = bindings[module], binding.generation == generation else { return }
        do {
            guard try canPublish(module) else {
                stopObserving(module: module)
                return
            }
            let snapshot = withObservationTracking {
                binding.read()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refresh(module: module, generation: generation)
                }
            }
            guard bindings[module]?.generation == generation else { return }
            switch snapshot.runtime {
            case .ready, .active, .limited:
                break
            default:
                throw ModuleStatusObserverError.invalidRuntimeState(snapshot.runtime)
            }
            guard try canPublish(module) else {
                stopObserving(module: module)
                return
            }
            if registry.state(for: module)?.runtime != snapshot.runtime {
                try registry.setRuntime(snapshot.runtime, for: module)
            }
            guard bindings[module]?.generation == generation else { return }
            guard try canPublish(module) else {
                stopObserving(module: module)
                return
            }
            if registry.state(for: module)?.permission != snapshot.permission {
                try registry.setPermission(snapshot.permission, for: module)
            }
        } catch {
            guard bindings[module]?.generation == generation else { return }
            stopObserving(module: module)
            onError(module, error)
        }
    }

    private func canPublish(_ module: UtilityModuleID) throws -> Bool {
        guard let state = registry.state(for: module) else {
            throw ModuleRegistryError.unknownModule(module)
        }
        guard state.presence == .added, !registry.pausedModuleIDs.contains(module) else { return false }
        switch state.runtime {
        case .ready, .active, .limited:
            return true
        default:
            return false
        }
    }
}
