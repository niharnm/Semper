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
            #expect(center.recentActions.isEmpty)
            #expect(center.attentionItems(lifecycleFailures: [:]).isEmpty)
            #expect(availabilityChecks == 0)
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

    @Test("Recent actions are bounded, newest first, and identify repeated actions separately")
    func recentActionsAreBounded() async throws {
        var timestamp = Date(timeIntervalSince1970: 100)
        try await withCenter(
            now: { timestamp },
            body: { center in
                let action = handler {}
                try center.register([action])
                for offset in 0..<12 {
                    timestamp = Date(timeIntervalSince1970: Double(100 + offset))
                    #expect(await center.execute(action.descriptor.id) == .completed)
                }

                #expect(center.recentActions.count == UtilityCommandCenter.maximumRecentActions)
                #expect(Set(center.recentActions.map(\.id)).count == UtilityCommandCenter.maximumRecentActions)
                #expect(
                    center.recentActions.allSatisfy { $0.actionID == action.descriptor.id && $0.result == .completed })
                #expect(
                    center.recentActions.map(\.timestamp)
                        == (104...111).reversed().map { Date(timeIntervalSince1970: Double($0)) })
            })
    }

    @Test("History stores result classes without errors, confirmation text, or unknown identifiers")
    func recentActionsKeepOnlyRegisteredIdentityAndResultClass() async throws {
        try await withCenter { center in
            let completed = handler(id: "awake.completed") {}
            let accepted = UtilityActionHandler(
                descriptor: handler(id: "awake.accepted") {}.descriptor, disabledReason: { nil },
                performOutcome: { .accepted })
            let failed = handler(id: "awake.failed") { throw CommandTestError.sensitive }
            let cancelled = handler(id: "awake.cancelled") { throw CancellationError() }
            let unavailable = handler(id: "awake.unavailable", disabledReason: { "/private/secret-file.txt" }) {}
            let confirmation = handler(id: "awake.confirmation", confirmation: "Private window title") {}
            try center.register([completed, accepted, failed, cancelled, unavailable, confirmation])
            for action in [completed, accepted, failed, cancelled, unavailable, confirmation] {
                await center.execute(action.descriptor.id)
            }

            #expect(
                center.recentActions.map(\.result) == [
                    .confirmationRequired, .unavailable, .cancelled, .failed, .accepted, .completed,
                ])
            for entry in center.recentActions {
                #expect(
                    Mirror(reflecting: entry).children.compactMap(\.label) == ["id", "actionID", "timestamp", "result"])
                #expect(center.registry.actionMetadata(for: entry.actionID)?.title == "Test action")
                #expect(!String(reflecting: entry).contains("secret-file"))
                #expect(!String(reflecting: entry).contains("Private window title"))
            }
            let before = center.recentActions
            await center.execute(UtilityActionID(rawValue: "/private/unknown-action.txt"))
            let missingHandler = handler(id: "awake.no-handler") {}
            try center.registry.register(actions: [missingHandler.descriptor])
            await center.execute(missingHandler.descriptor.id)
            #expect(center.recentActions == before)
        }
    }

    @Test("Accepted asynchronous work is not reported as completed or cancelled", arguments: [false, true])
    func acceptedOutcomeIsHonest(cancelCaller: Bool) async throws {
        try await withCenter { center in
            let entered = CommandTestSignal()
            let release = CommandTestSignal()
            let action = UtilityActionHandler(
                descriptor: handler {}.descriptor, disabledReason: { nil },
                performOutcome: {
                    entered.signal()
                    await release.wait()
                    return .accepted
                })
            try center.register([action])
            let execution = Task { await center.execute(action.descriptor.id) }
            await entered.wait()
            #expect(center.recentActions.isEmpty)
            #expect(center.running == [action.descriptor.id])
            if cancelCaller { execution.cancel() }
            release.signal()
            #expect(await execution.value == .accepted)
            #expect(center.lastResult == .accepted)
            #expect(center.recentActions.map(\.result) == [.accepted])
            #expect(center.running.isEmpty)
        }
    }

    @Test(
        "Typed outcomes remain authoritative when completion cancels the current task",
        arguments: [UtilityActionOutcome.completed, .accepted])
    func typedOutcomeSurvivesCompletionCancellation(outcome: UtilityActionOutcome) async throws {
        try await withCenter { center in
            var completions = 0
            var observedCancellation = false
            let action = UtilityActionHandler(
                descriptor: handler {}.descriptor, disabledReason: { nil },
                performOutcome: {
                    completions += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    observedCancellation = Task.isCancelled
                    return outcome
                })
            try center.register([action])

            let expected: UtilityCommandResult = outcome == .completed ? .completed : .accepted
            #expect(await center.execute(action.descriptor.id) == expected)
            #expect(completions == 1)
            #expect(observedCancellation)
            #expect(center.lastResult == expected)
            #expect(center.recentActions.map(\.result) == [outcome == .completed ? .completed : .accepted])
            #expect(center.running.isEmpty)
        }
    }

    @Test("Legacy Void handlers retain post-perform cancellation checking")
    func legacyCompletionCancellation() async throws {
        try await withCenter { center in
            var calls = 0
            let action = handler {
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
            try center.register([action])

            #expect(await center.execute(action.descriptor.id) == .cancelled)
            #expect(calls == 1)
            #expect(center.lastResult == .cancelled)
            #expect(center.recentActions.map(\.result) == [.cancelled])
            #expect(center.running.isEmpty)
        }
    }

    @Test("Action history is session-only and never changes persisted registry data")
    func recentActionsAreNotPersisted() async throws {
        let suite = "UtilityHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = try ModuleRegistry(defaults: defaults)
        let center = UtilityCommandCenter(registry: registry)
        let action = handler {}
        try center.register([action])
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        await center.execute(action.descriptor.id)
        #expect(center.recentActions.count == 1)
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]).isEqual(to: before))
        let replacement = UtilityCommandCenter(registry: try ModuleRegistry(defaults: defaults))
        #expect(replacement.recentActions.isEmpty)
    }

    @Test("Home attention includes registry failures and permission reasons without duplicate module items")
    func attentionIncludesRegistryReasons() async throws {
        try await withCenter { center in
            try center.registry.setRuntime(.limited(reason: "Allow audio access."), for: .sound)
            try center.registry.setPermission(.denied, for: .sound)
            try center.registry.setRuntime(.failed(reason: "Cleanup failed."), for: .awake)
            try center.registry.setPermission(.revoked, for: .awake)
            try center.registry.add(.shelf)
            try center.registry.setPermission(.restricted, for: .shelf)
            let items = center.attentionItems(lifecycleFailures: [
                .sound: "  Allow audio access.\n", .awake: "Cleanup failed.",
            ])

            #expect(items.count == 3)
            #expect(items.first(where: { $0.id == .sound })?.reasons == ["Allow audio access.", "Permission denied."])
            #expect(items.first(where: { $0.id == .awake })?.reasons == ["Cleanup failed.", "Permission revoked."])
            #expect(items.first(where: { $0.id == .shelf })?.reasons == ["Permission restricted."])
        }
    }

    @Test("Home attention ignores healthy and unadded modules but retains cleanup failures")
    func attentionPresenceAndRecovery() async throws {
        try await withCenter { center in
            try center.registry.setRuntime(.ready, for: .sound)
            try center.registry.setPermission(.granted, for: .sound)
            try center.registry.setPermission(.denied, for: .workspace)
            #expect(center.attentionItems(lifecycleFailures: [:]).isEmpty)
            let items = center.attentionItems(lifecycleFailures: [.workspace: "Restore remains pending."])
            #expect(
                items == [
                    UtilityModuleAttention(id: .workspace, reasons: ["Restore remains pending.", "Permission denied."])
                ])
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
        now: @escaping () -> Date = Date.init,
        body: @MainActor (UtilityCommandCenter) async throws -> Void
    ) async throws {
        let suite = "UtilityCommandCenterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = try ModuleRegistry(defaults: defaults, modules: modules)
        try await body(UtilityCommandCenter(registry: registry, admissionReason: admissionReason, now: now))
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
    case sensitive

    var errorDescription: String? {
        switch self {
        case .expected: "Test command failed."
        case .sensitive: "/private/secret-file.txt: Private window title"
        }
    }
}
