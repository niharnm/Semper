import Foundation
import Observation

enum UtilityStopReason: Sendable {
    case pause, removal, termination
}

@MainActor
struct UtilityServiceBinding {
    let start: () async throws -> Void
    let stop: (UtilityStopReason) async throws -> Void
    let validateStop: (UtilityStopReason) throws -> Void

    init(
        start: @escaping () async throws -> Void, stop: @escaping (UtilityStopReason) async throws -> Void,
        validateStop: @escaping (UtilityStopReason) throws -> Void = { _ in }
    ) {
        self.start = start
        self.stop = stop
        self.validateStop = validateStop
    }
}

enum UtilityLifecycleError: LocalizedError {
    case unavailable(String)
    case shuttingDown
    case cleanupRequired(reason: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .shuttingDown: "Semper is shutting down."
        case .cleanupRequired(let reason): "Retry pausing this module before starting it. \(reason)"
        }
    }
}

struct UtilityCleanupDeferral: LocalizedError, Equatable, Sendable {
    let reason: String
    let retaining: Set<UtilityModuleID>

    var errorDescription: String? { reason }
}

@Observable
@MainActor
final class UtilityLifecycle {
    let registry: ModuleRegistry
    private(set) var isShuttingDown = false
    private(set) var stopping: Set<UtilityModuleID> = []
    private(set) var failures: [UtilityModuleID: String] = [:]
    @ObservationIgnored private var bindings: [UtilityModuleID: UtilityServiceBinding] = [:]
    @ObservationIgnored private var starting: [UtilityModuleID: Task<Void, Error>] = [:]
    @ObservationIgnored private var started: Set<UtilityModuleID> = []
    @ObservationIgnored private var cleanupFailures: [UtilityModuleID: String] = [:]
    @ObservationIgnored private var stopTasks: [UtilityModuleID: Task<Void, Error>] = [:]
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var terminated: Set<UtilityModuleID> = []
    #if DEBUG
        @ObservationIgnored var startupDisabledForTesting = false
    #endif

    init(registry: ModuleRegistry) {
        self.registry = registry
    }

    func register(_ id: UtilityModuleID, binding: UtilityServiceBinding) throws {
        guard bindings[id] == nil else { throw ModuleRegistryError.duplicateModule(id) }
        guard registry.descriptor(for: id) != nil else { throw ModuleRegistryError.unknownModule(id) }
        bindings[id] = binding
    }

    func start(_ id: UtilityModuleID) async throws {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw UtilityLifecycleError.shuttingDown }
        guard !stopping.contains(id) else { throw ModuleRegistryError.transitionInProgress(id) }
        guard registry.state(for: id)?.presence == .added else { throw ModuleRegistryError.moduleNotAdded(id) }
        guard !registry.pausedModuleIDs.contains(id) else { throw ModuleRegistryError.modulePaused(id) }
        #if DEBUG
            guard !startupDisabledForTesting else {
                throw UtilityLifecycleError.unavailable("Service startup is unavailable in shell UI tests.")
            }
        #endif
        if let task = starting[id] {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        if let reason = cleanupFailures[id] {
            try registry.setRuntime(.failed(reason: reason), for: id)
            throw UtilityLifecycleError.cleanupRequired(reason: reason)
        }
        guard !started.contains(id) else { return }
        guard let binding = bindings[id] else {
            throw UtilityLifecycleError.unavailable("This module has no runtime available.")
        }
        try registry.setRuntime(.preparing, for: id)
        failures[id] = nil
        let task = Task { @MainActor in
            defer { self.starting[id] = nil }
            do {
                try Task.checkCancellation()
                try await binding.start()
                try Task.checkCancellation()
                guard !self.isShuttingDown, !self.stopping.contains(id) else { throw CancellationError() }
                try self.registry.setRuntime(.ready, for: id)
                self.started.insert(id)
            } catch {
                if !self.stopping.contains(id), !self.isShuttingDown {
                    let cleanup = Task { @MainActor in try await binding.stop(.pause) }
                    do { try await cleanup.value } catch {
                        let reason = "Startup cleanup failed: \(error.localizedDescription)"
                        self.cleanupFailures[id] = reason
                        self.failures[id] = reason
                    }
                    self.failures[id] = self.failures[id] ?? error.localizedDescription
                    if !self.stopping.contains(id), !self.isShuttingDown {
                        try self.registry.setRuntime(
                            .failed(reason: self.failures[id] ?? error.localizedDescription), for: id)
                    }
                }
                throw error
            }
        }
        starting[id] = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func pause(_ id: UtilityModuleID) async throws {
        try await stop(id, reason: .pause)
    }

    func remove(_ id: UtilityModuleID) async throws {
        try await stop(id, reason: .removal)
    }

    private func stop(_ id: UtilityModuleID, reason: UtilityStopReason) async throws {
        guard !isShuttingDown else { throw UtilityLifecycleError.shuttingDown }
        guard !stopping.contains(id) else { throw ModuleRegistryError.transitionInProgress(id) }
        try bindings[id]?.validateStop(reason)
        if reason == .pause { try registry.beginPause(id) } else { try registry.beginRemoval(id) }
        stopping.insert(id)
        let startup = starting[id]
        startup?.cancel()
        let task = Task { @MainActor in
            defer {
                self.stopping.remove(id)
                self.stopTasks[id] = nil
            }
            _ = await startup?.result
            do {
                try await self.bindings[id]?.stop(reason)
                self.started.remove(id)
                self.cleanupFailures[id] = nil
                self.failures[id] = nil
                if reason == .pause {
                    try self.registry.completePause(id)
                } else {
                    try self.registry.completeRemoval(id)
                }
            } catch {
                self.cleanupFailures[id] = error.localizedDescription
                self.failures[id] = error.localizedDescription
                try self.registry.failTransition(id, reason: error.localizedDescription)
                throw error
            }
        }
        stopTasks[id] = task
        try await task.value
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        let task = Task { @MainActor in
            let startups = Array(self.starting.values)
            let stops = Array(self.stopTasks.values)
            for task in startups { task.cancel() }
            for task in startups { _ = await task.result }
            for task in stops { _ = await task.result }
            // Composed sessions restore before their underlying services stop.
            let order: [UtilityModuleID] = [
                .away, .presentation, .scenes, .windowLayout, .workspace, .shelf, .storage, .displays, .sound, .awake,
            ]
            var retainedServices: [UtilityModuleID: String] = [:]
            for id in order {
                guard !self.terminated.contains(id), let binding = self.bindings[id] else { continue }
                if let reason = retainedServices[id] {
                    self.failures[id] = reason
                    self.cleanupFailures[id] = reason
                    continue
                }
                do {
                    try await binding.stop(.termination)
                    self.started.remove(id)
                    self.terminated.insert(id)
                    self.failures[id] = nil
                    self.cleanupFailures[id] = nil
                } catch {
                    self.failures[id] = error.localizedDescription
                    self.cleanupFailures[id] = error.localizedDescription
                    if let deferral = error as? UtilityCleanupDeferral {
                        let title = self.registry.descriptor(for: id)?.title ?? id.rawValue
                        for retainedID in deferral.retaining {
                            retainedServices[retainedID] = "Kept running for \(title) recovery. \(deferral.reason)"
                        }
                    }
                }
            }
            if !self.failures.isEmpty { self.shutdownTask = nil }
        }
        shutdownTask = task
        await task.value
    }
}
