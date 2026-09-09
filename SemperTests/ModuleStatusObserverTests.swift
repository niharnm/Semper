import Foundation
import Observation
import Testing

@testable import Semper

@MainActor
@Suite("Module status observation")
struct ModuleStatusObserverTests {
    @Test("Construction is inert and observation publishes the initial active service state")
    func initialPublication() async throws {
        try await withRegistry { registry in
            let service = StatusService(runtime: .active, permission: .granted)
            let observer = makeObserver(registry)
            #expect(service.readCount == 0)
            #expect(registry.state(for: .sound)?.runtime == .stopped)

            try registry.setRuntime(.ready, for: .sound)
            observer.observe(module: .sound) { service.snapshot() }

            #expect(service.readCount == 1)
            #expect(registry.state(for: .sound)?.runtime == .active)
            #expect(registry.state(for: .sound)?.permission == .granted)
        }
    }

    @Test("Service changes update both axes and rearm observation for subsequent changes")
    func serviceChanges() async throws {
        try await withRegistry { registry in
            let service = StatusService(runtime: .active, permission: .granted)
            let observer = makeObserver(registry)
            try registry.setRuntime(.ready, for: .sound)
            observer.observe(module: .sound) { service.snapshot() }

            service.runtime = .limited(reason: "Audio access is required")
            service.permission = .denied
            await advanceTasks()
            #expect(registry.state(for: .sound)?.runtime == .limited(reason: "Audio access is required"))
            #expect(registry.state(for: .sound)?.permission == .denied)
            #expect(service.readCount == 2)

            service.runtime = .ready
            service.permission = .granted
            await advanceTasks()
            #expect(registry.state(for: .sound)?.runtime == .ready)
            #expect(registry.state(for: .sound)?.permission == .granted)
            #expect(service.readCount == 3)
        }
    }

    @Test("Stopping invalidates pending callbacks and never reads the stopped service again")
    func stopInvalidatesPendingChanges() async throws {
        try await withRegistry { registry in
            let service = StatusService(runtime: .active, permission: .granted)
            let observer = makeObserver(registry)
            try registry.setRuntime(.ready, for: .sound)
            observer.observe(module: .sound) { service.snapshot() }

            service.runtime = .limited(reason: "Stopped")
            observer.stopObserving(module: .sound)
            try registry.setRuntime(.stopped, for: .sound)
            await advanceTasks()
            service.runtime = .active
            service.permission = .denied
            await advanceTasks()

            #expect(service.readCount == 1)
            #expect(registry.state(for: .sound)?.runtime == .stopped)
            #expect(registry.state(for: .sound)?.permission == .granted)
        }
    }

    @Test("A queued service change cannot overwrite a pause transition or publish after resume")
    func pauseTransitionProtection() async throws {
        try await withRegistry { registry in
            let service = StatusService(runtime: .active, permission: .granted)
            let observer = makeObserver(registry)
            try registry.setRuntime(.ready, for: .sound)
            observer.observe(module: .sound) { service.snapshot() }

            service.permission = .denied
            try registry.beginPause(.sound)
            await advanceTasks()
            #expect(registry.state(for: .sound)?.runtime == .paused)
            #expect(registry.state(for: .sound)?.permission == .granted)
            #expect(service.readCount == 1)

            try registry.completePause(.sound)
            try registry.resume(.sound)
            try registry.setRuntime(.ready, for: .sound)
            service.runtime = .limited(reason: "Old service")
            await advanceTasks()
            #expect(registry.state(for: .sound)?.runtime == .ready)
            #expect(registry.state(for: .sound)?.permission == .granted)
            #expect(service.readCount == 1)
        }
    }

    @Test("A replacement binding ignores the old callback without duplicating its own observation")
    func replacementBinding() async throws {
        try await withRegistry { registry in
            let oldService = StatusService(runtime: .active, permission: .granted)
            let replacement = StatusService(runtime: .ready, permission: .notRequired)
            let observer = makeObserver(registry)
            try registry.setRuntime(.ready, for: .sound)
            observer.observe(module: .sound) { oldService.snapshot() }

            oldService.runtime = .limited(reason: "Old binding")
            observer.observe(module: .sound) { replacement.snapshot() }
            await advanceTasks()
            #expect(oldService.readCount == 1)
            #expect(replacement.readCount == 1)
            #expect(registry.state(for: .sound)?.runtime == .ready)
            #expect(registry.state(for: .sound)?.permission == .notRequired)

            replacement.runtime = .active
            await advanceTasks()
            #expect(replacement.readCount == 2)
            #expect(registry.state(for: .sound)?.runtime == .active)
        }
    }

    @Test("Shutdown drops every binding and pending callbacks do not rearm after a new binding")
    func stopAllInvalidatesEveryBinding() async throws {
        try await withRegistry { registry in
            let sound = StatusService(runtime: .active, permission: .granted)
            let awake = StatusService(runtime: .active, permission: .notRequired)
            let observer = makeObserver(registry)
            try registry.setRuntime(.ready, for: .sound)
            try registry.setRuntime(.ready, for: .awake)
            observer.observe(module: .sound) { sound.snapshot() }
            observer.observe(module: .awake) { awake.snapshot() }

            sound.permission = .denied
            awake.runtime = .ready
            observer.stopAll()
            try registry.setRuntime(.stopped, for: .sound)
            try registry.setRuntime(.stopped, for: .awake)
            await advanceTasks()
            #expect(sound.readCount == 1)
            #expect(awake.readCount == 1)
            #expect(registry.state(for: .sound)?.runtime == .stopped)
            #expect(registry.state(for: .sound)?.permission == .granted)
            #expect(registry.state(for: .awake)?.runtime == .stopped)

            let replacement = StatusService(runtime: .ready, permission: .granted)
            try registry.setRuntime(.ready, for: .sound)
            observer.observe(module: .sound) { replacement.snapshot() }
            sound.runtime = .limited(reason: "Stopped service")
            awake.runtime = .active
            await advanceTasks()
            #expect(sound.readCount == 1)
            #expect(awake.readCount == 1)
            #expect(replacement.readCount == 1)
            #expect(registry.state(for: .sound)?.runtime == .ready)
            #expect(registry.state(for: .awake)?.runtime == .stopped)
        }
    }

    @Test("Shutdown releases captured services even when a callback is pending")
    func shutdownReleasesServices() async throws {
        try await withRegistry { registry in
            let observer = makeObserver(registry)
            try registry.setRuntime(.ready, for: .sound)
            weak var releasedService: StatusService?
            do {
                let service = StatusService(runtime: .active, permission: .granted)
                releasedService = service
                observer.observe(module: .sound) { service.snapshot() }
                service.permission = .denied
            }
            #expect(releasedService != nil)
            observer.stopAll()
            #expect(releasedService == nil)
            await advanceTasks()
            #expect(registry.state(for: .sound)?.permission == .granted)
        }
    }

    @Test("Stopped, preparing, failed, paused, removing, and available modules are not read")
    func lifecycleStatesAreProtected() async throws {
        try await withRegistry { registry in
            let service = StatusService(runtime: .active, permission: .granted)
            let observer = makeObserver(registry)
            observer.observe(module: .shelf) { service.snapshot() }
            for runtime: ModuleRuntimeState in [.stopped, .preparing, .failed(reason: "Startup failed")] {
                try registry.setRuntime(runtime, for: .sound)
                observer.observe(module: .sound) { service.snapshot() }
                #expect(registry.state(for: .sound)?.runtime == runtime)
            }
            try registry.beginPause(.sound)
            observer.observe(module: .sound) { service.snapshot() }
            try registry.completePause(.sound)
            try registry.resume(.sound)
            try registry.beginRemoval(.sound)
            observer.observe(module: .sound) { service.snapshot() }

            #expect(service.readCount == 0)
            #expect(registry.state(for: .sound)?.runtime == .removing)
            #expect(registry.state(for: .sound)?.permission == .unknown)
            #expect(registry.state(for: .shelf)?.presence == .available)
        }
    }

    @Test("Invalid snapshot runtime is reported explicitly and its observation is stopped")
    func invalidSnapshot() async throws {
        try await withRegistry { registry in
            var errors: [ModuleStatusObserverError] = []
            let observer = ModuleStatusObserver(registry: registry) { module, error in
                #expect(module == .sound)
                guard let error = error as? ModuleStatusObserverError else {
                    Issue.record("Unexpected observer error: \(error)")
                    return
                }
                errors.append(error)
            }
            let service = StatusService(runtime: .paused, permission: .denied)
            try registry.setRuntime(.ready, for: .sound)
            observer.observe(module: .sound) { service.snapshot() }
            #expect(errors == [.invalidRuntimeState(.paused)])
            #expect(registry.state(for: .sound)?.runtime == .ready)
            #expect(registry.state(for: .sound)?.permission == .unknown)
            service.runtime = .active
            await advanceTasks()
            #expect(service.readCount == 1)
            #expect(errors.count == 1)
        }
    }

    @Test("Unknown registry modules are reported without reading the service")
    func registryErrorsAreReported() async throws {
        try await withRegistry(modules: UtilityModuleDescriptor.catalog.filter { $0.id == .awake }) { registry in
            var errors: [ModuleRegistryError] = []
            let observer = ModuleStatusObserver(registry: registry) { module, error in
                #expect(module == .sound)
                guard let error = error as? ModuleRegistryError else {
                    Issue.record("Unexpected registry error: \(error)")
                    return
                }
                errors.append(error)
            }
            let service = StatusService(runtime: .active, permission: .granted)
            observer.observe(module: .sound) { service.snapshot() }
            #expect(errors == [.unknownModule(.sound)])
            #expect(service.readCount == 0)
        }
    }

    private func makeObserver(_ registry: ModuleRegistry) -> ModuleStatusObserver {
        ModuleStatusObserver(registry: registry) { module, error in
            Issue.record("Unexpected status error for \(module): \(error)")
        }
    }

    private func withRegistry(
        modules: [UtilityModuleDescriptor] = UtilityModuleDescriptor.catalog,
        body: (ModuleRegistry) async throws -> Void
    ) async throws {
        let suite = "ModuleStatusObserverTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(ModuleRegistry(defaults: defaults, modules: modules))
    }

    private func advanceTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@Observable
@MainActor
private final class StatusService {
    var runtime: ModuleRuntimeState
    var permission: ModulePermissionState
    @ObservationIgnored private(set) var readCount = 0

    init(runtime: ModuleRuntimeState, permission: ModulePermissionState) {
        self.runtime = runtime
        self.permission = permission
    }

    func snapshot() -> ModuleStatusSnapshot {
        readCount += 1
        return ModuleStatusSnapshot(runtime: runtime, permission: permission)
    }
}
