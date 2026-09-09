import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Utility command center")
struct UtilityCommandCenterTests {
    @Test("Registration never invokes handlers or permission work")
    func registrationHasNoEffects() async throws {
        try await withCenter { center in
            var availabilityChecks = 0
            var permissionRequests = 0
            try center.register([
                handler(
                    disabledReason: {
                        availabilityChecks += 1
                        return nil
                    },
                    perform: {
                        permissionRequests += 1
                    })
            ])

            #expect(availabilityChecks == 0)
            #expect(permissionRequests == 0)
            #expect(center.running.isEmpty)
        }
    }

    @Test("Only added and resumed module actions can execute")
    func addedOnlyActions() async throws {
        try await withCenter { center in
            var calls = 0
            let shelf = handler(id: "shelf.open", module: .shelf) { calls += 1 }
            try center.register([shelf])

            #expect(await center.execute(shelf.descriptor.id) == .unavailable("Add this module in Modules first."))
            try center.registry.add(.shelf)
            #expect(await center.execute(shelf.descriptor.id) == .completed)
            try center.registry.beginPause(.shelf)
            try center.registry.completePause(.shelf)
            #expect(await center.execute(shelf.descriptor.id) == .unavailable("Resume this module in Modules first."))
            try center.registry.resume(.shelf)
            #expect(await center.execute(shelf.descriptor.id) == .completed)
            #expect(calls == 2)
        }
    }

    @Test("The exact current disabled reason is used without invoking the handler")
    func dynamicDisabledReason() async throws {
        try await withCenter { center in
            var reason: String? = "Select a supported display first."
            var calls = 0
            let action = handler(disabledReason: { reason }) { calls += 1 }
            try center.register([action])

            #expect(center.disabledReason(for: action.descriptor.id) == reason)
            #expect(await center.execute(action.descriptor.id) == .unavailable("Select a supported display first."))
            #expect(calls == 0)
            reason = nil
            #expect(await center.execute(action.descriptor.id) == .completed)
            #expect(calls == 1)
            #expect(center.lastResult == .completed)
        }
    }

    @Test("Duplicate registration rejects the whole batch and preserves existing routing")
    func duplicateRegistration() async throws {
        try await withCenter { center in
            var originalCalls = 0
            var replacementCalls = 0
            let original = handler { originalCalls += 1 }
            let replacement = handler { replacementCalls += 1 }
            let second = handler(id: "awake.second") {}
            try center.register([original])

            #expect(throws: ModuleRegistryError.duplicateAction(original.descriptor.id)) {
                try center.register([second, replacement])
            }
            #expect(center.registry.actionMetadata(for: second.descriptor.id) == nil)
            #expect(await center.execute(original.descriptor.id) == .completed)
            #expect(originalCalls == 1)
            #expect(replacementCalls == 0)
        }
    }

    @Test("Confirmation is required before handler and permission side effects")
    func confirmationBeforeEffects() async throws {
        try await withCenter { center in
            var permissionRequests = 0
            var clearCalls = 0
            let action = handler(confirmation: "Clear the shelf references?") {
                permissionRequests += 1
                clearCalls += 1
            }
            try center.register([action])

            #expect(await center.execute(action.descriptor.id) == .confirmationRequired("Clear the shelf references?"))
            #expect(permissionRequests == 0)
            #expect(clearCalls == 0)
            #expect(center.running.isEmpty)
            #expect(await center.execute(action.descriptor.id, confirmed: true) == .completed)
            #expect(permissionRequests == 1)
            #expect(clearCalls == 1)
        }
    }

    @Test("Concurrent execution of the same stable action is rejected")
    func concurrentSameAction() async throws {
        try await withCenter { center in
            let entered = CommandTestSignal()
            let release = CommandTestSignal()
            var calls = 0
            let action = handler {
                calls += 1
                entered.signal()
                await release.wait()
            }
            try center.register([action])
            let first = Task { await center.execute(action.descriptor.id) }
            await entered.wait()

            #expect(center.running == [action.descriptor.id])
            #expect(await center.execute(action.descriptor.id) == .unavailable("This action is already running."))
            #expect(calls == 1)
            release.signal()
            #expect(await first.value == .completed)
            #expect(center.running.isEmpty)
        }
    }

    @Test("Removal cancels owned work and waits for its cleanup before returning")
    func cancellationAndDrain() async throws {
        try await withCenter { center in
            let entered = CommandTestSignal()
            let cancelled = CommandTestSignal()
            let release = CommandTestSignal()
            var cleanupFinished = false
            var drainFinished = false
            var secondCalls = 0
            let action = handler {
                try await withTaskCancellationHandler {
                    entered.signal()
                    await release.wait()
                    cleanupFinished = true
                    try Task.checkCancellation()
                } onCancel: {
                    Task { @MainActor in cancelled.signal() }
                }
            }
            let second = handler(id: "awake.second") { secondCalls += 1 }
            try center.register([action, second])
            let execution = Task { await center.execute(action.descriptor.id) }
            await entered.wait()
            let drain = Task {
                await center.cancelAndDrain(module: .awake)
                drainFinished = true
            }
            await cancelled.wait()

            #expect(!cleanupFinished)
            #expect(!drainFinished)
            #expect(center.registry.state(for: .awake)?.presence == .added)
            #expect(await center.execute(action.descriptor.id) == .unavailable("This module is stopping."))
            #expect(await center.execute(second.descriptor.id) == .unavailable("This module is stopping."))
            #expect(secondCalls == 0)
            release.signal()
            await drain.value
            #expect(cleanupFinished)
            #expect(drainFinished)
            #expect(center.running.isEmpty)
            try center.registry.beginRemoval(.awake)
            try center.registry.completeRemoval(.awake)
            #expect(await execution.value == .cancelled)
            #expect(center.running.isEmpty)
            #expect(center.registry.state(for: .awake)?.presence == .available)
        }
    }

    @Test("Draining one module leaves another module's command running")
    func drainIsModuleScoped() async throws {
        try await withCenter { center in
            let awakeEntered = CommandTestSignal()
            let soundEntered = CommandTestSignal()
            let awakeCancelled = CommandTestSignal()
            let awakeRelease = CommandTestSignal()
            let soundRelease = CommandTestSignal()
            let awake = handler {
                try await withTaskCancellationHandler {
                    awakeEntered.signal()
                    await awakeRelease.wait()
                    try Task.checkCancellation()
                } onCancel: {
                    Task { @MainActor in awakeCancelled.signal() }
                }
            }
            let sound = handler(id: "sound.open", module: .sound) {
                soundEntered.signal()
                await soundRelease.wait()
            }
            try center.register([awake, sound])
            let awakeExecution = Task { await center.execute(awake.descriptor.id) }
            let soundExecution = Task { await center.execute(sound.descriptor.id) }
            await awakeEntered.wait()
            await soundEntered.wait()
            try center.registry.beginRemoval(.awake)
            let drain = Task { await center.cancelAndDrain(module: .awake) }
            await awakeCancelled.wait()
            awakeRelease.signal()
            await drain.value

            #expect(await awakeExecution.value == .cancelled)
            #expect(center.running == [sound.descriptor.id])
            soundRelease.signal()
            #expect(await soundExecution.value == .completed)
        }
    }

    @Test("Handler errors are reported and do not keep the action marked running")
    func handlerError() async throws {
        try await withCenter { center in
            let action = handler { throw CommandTestError.expected }
            try center.register([action])

            #expect(await center.execute(action.descriptor.id) == .failed("Test command failed."))
            #expect(center.lastResult == .failed("Test command failed."))
            #expect(center.running.isEmpty)
        }
    }

    @Test("Central admission denial prevents availability and handler side effects")
    func deniedCentralAdmission() async throws {
        try await withCenter(
            admissionReason: { "An Away session is active." },
            body: { center in
                var availabilityChecks = 0
                var permissionRequests = 0
                let action = handler(
                    disabledReason: {
                        availabilityChecks += 1
                        return nil
                    },
                    perform: {
                        permissionRequests += 1
                    })
                try center.register([action])

                #expect(
                    await center.execute(action.descriptor.id, confirmed: true)
                        == .unavailable("An Away session is active."))
                #expect(availabilityChecks == 0)
                #expect(permissionRequests == 0)
                #expect(center.running.isEmpty)
            })
    }

    @Test("Admission is checked again when the asynchronous handler is about to start")
    func admissionRecheckedBeforeHandler() async throws {
        var admissionChecks = 0
        try await withCenter(
            admissionReason: {
                admissionChecks += 1
                return admissionChecks == 1 ? nil : "An Away session started."
            },
            body: { center in
                var calls = 0
                let action = handler { calls += 1 }
                try center.register([action])

                #expect(await center.execute(action.descriptor.id) == .unavailable("An Away session started."))
                #expect(calls == 0)
                #expect(center.running.isEmpty)
            })
    }

    @Test("Catalog metadata without a handler has an exact disabled reason")
    func missingHandler() async throws {
        try await withCenter { center in
            let action = handler {}
            try center.registry.register(actions: [action.descriptor])

            #expect(center.disabledReason(for: action.descriptor.id) == "This action has no handler.")
            #expect(await center.execute(action.descriptor.id) == .unavailable("This action has no handler."))
        }
    }

    @Test("Unsupported modules expose their exact reason instead of an unusable add instruction")
    func unsupportedReason() async throws {
        let module = UtilityModuleDescriptor(
            id: .awake, title: "Awake", summary: "Awake", symbolName: "sun.max",
            unsupportedReason: "This feature is unavailable on this Mac."
        )
        try await withCenter(modules: [module]) { center in
            var calls = 0
            let action = handler { calls += 1 }
            try center.register([action])

            #expect(center.disabledReason(for: action.descriptor.id) == module.unsupportedReason)
            #expect(
                await center.execute(action.descriptor.id) == .unavailable("This feature is unavailable on this Mac."))
            #expect(calls == 0)
        }
    }

    @Test("An already cancelled caller cannot start a handler")
    func cancelledCallerCannotStart() async throws {
        try await withCenter { center in
            let release = CommandTestSignal()
            var calls = 0
            let action = handler { calls += 1 }
            try center.register([action])
            let execution = Task {
                await release.wait()
                return await center.execute(action.descriptor.id)
            }
            execution.cancel()
            release.signal()

            #expect(await execution.value == .cancelled)
            #expect(calls == 0)
            #expect(center.running.isEmpty)
        }
    }

    @Test("Caller cancellation reaches the handler and waits for its cleanup")
    func callerCancellationPropagates() async throws {
        try await withCenter { center in
            let entered = CommandTestSignal()
            let release = CommandTestSignal()
            var sawCancellation = false
            var cleanupFinished = false
            let action = handler {
                entered.signal()
                await release.wait()
                sawCancellation = Task.isCancelled
                cleanupFinished = true
                try Task.checkCancellation()
            }
            try center.register([action])
            let execution = Task { await center.execute(action.descriptor.id) }
            await entered.wait()
            execution.cancel()
            #expect(!cleanupFinished)
            release.signal()

            #expect(await execution.value == .cancelled)
            #expect(sawCancellation)
            #expect(cleanupFinished)
            #expect(center.running.isEmpty)
        }
    }

    private func handler(
        id: String = "awake.start",
        module: UtilityModuleID = .awake,
        confirmation: String? = nil,
        disabledReason: @escaping () -> String? = { nil },
        perform: @escaping () async throws -> Void
    ) -> UtilityActionHandler {
        UtilityActionHandler(
            descriptor: UtilityActionDescriptor(
                id: UtilityActionID(rawValue: id), module: module, title: "Test action",
                keywords: [], symbolName: "play", confirmationMessage: confirmation
            ),
            disabledReason: disabledReason,
            perform: perform
        )
    }

    private func withCenter(
        modules: [UtilityModuleDescriptor] = UtilityModuleDescriptor.catalog,
        admissionReason: @escaping () -> String? = { nil },
        body: @MainActor (UtilityCommandCenter) async throws -> Void
    ) async throws {
        let suite = "UtilityCommandCenterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = try ModuleRegistry(defaults: defaults, modules: modules)
        try await body(UtilityCommandCenter(registry: registry, admissionReason: admissionReason))
    }
}

@MainActor
private final class CommandTestSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private enum CommandTestError: LocalizedError {
    case expected

    var errorDescription: String? { "Test command failed." }
}
