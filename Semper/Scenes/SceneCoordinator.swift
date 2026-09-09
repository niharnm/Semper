// Semper/Scenes/SceneCoordinator.swift
import Foundation

// MARK: - Apply reporting

/// Why an action was skipped (optional) or refused (required) in preflight.
nonisolated enum SceneSkipReason: Equatable, Sendable {
    case capability(SceneControlCapability)
    case targetUnavailable(String)
    case readFailed(String)
    case writeFailed(String)
}

nonisolated struct ScenePreflightFailure: Equatable, Sendable {
    let control: SceneControl
    let reason: SceneSkipReason
}

nonisolated struct SceneSkippedAction: Equatable, Sendable {
    let control: SceneControl
    let reason: SceneSkipReason
}

nonisolated struct ScenePreviewReport: Equatable, Sendable {
    let sceneID: UUID
    let entries: [SceneTransactionEntry]
    let skippedOptional: [SceneSkippedAction]
    let requiredFailures: [ScenePreflightFailure]

    var canApply: Bool { requiredFailures.isEmpty }
}

nonisolated struct SceneAppliedAction: Equatable, Sendable {
    let control: SceneControl
    let snapshotValue: SceneValue
    /// The value the hardware reported after the write, not the requested
    /// target; drift detection during restore compares against this.
    let appliedValue: SceneValue
}

nonisolated struct SceneApplyReport: Equatable, Sendable {
    /// Nil when every action was skipped, so nothing was mutated or journaled.
    let transactionID: UUID?
    let sceneID: UUID
    let applied: [SceneAppliedAction]
    let skippedOptional: [SceneSkippedAction]
}

/// State of the system after a failed apply was unwound.
nonisolated enum SceneApplyFailureCleanup: Equatable, Sendable {
    /// Every mutated control was returned to its snapshot; journal cleared.
    case rolledBack
    /// These controls could not be verifiably returned; journal retained so
    /// restore can be retried.
    case rollbackIncomplete(controls: [SceneControl])
}

nonisolated enum SceneApplyError: Error, Equatable, Sendable {
    case operationInProgress
    case invalidScene(SceneValidationIssue)
    case previewChanged
    case transactionAlreadyActive(transactionID: UUID)
    case journalUnreadable(String)
    case journalWriteFailed(String)
    case requiredPreflightFailed(failures: [ScenePreflightFailure])
    case actionFailed(control: SceneControl, reason: String, cleanup: SceneApplyFailureCleanup)
}

extension SceneApplyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Another scene operation is still running."
        case .invalidScene(let issue):
            issue.localizedDescription
        case .previewChanged:
            "The settings changed after preview. Review them again before applying."
        case .transactionAlreadyActive:
            "Restore or keep the current setup before applying another scene."
        case .journalUnreadable(let reason):
            "The saved restore point could not be read: \(reason)"
        case .journalWriteFailed(let reason):
            "The restore point could not be saved: \(reason)"
        case .requiredPreflightFailed(let failures):
            "Scene apply stopped because \(failures.count) required setting\(failures.count == 1 ? " is" : "s are") unavailable."
        case .actionFailed(_, let reason, let cleanup):
            switch cleanup {
            case .rolledBack:
                "Scene apply failed, and earlier changes were restored: \(reason)"
            case .rollbackIncomplete(let controls):
                "Scene apply failed, and \(controls.count) setting\(controls.count == 1 ? " still needs" : "s still need") recovery. Use Restore Previous Setup or Keep Current."
            }
        }
    }
}

// MARK: - Restore reporting

nonisolated enum SceneRestoreOutcome: Equatable, Sendable {
    case restored(SceneControl)
    /// The live value no longer matches what the scene applied, so the user
    /// changed it deliberately; restore leaves it alone.
    case skippedDrift(SceneControl, currentValue: SceneValue)
    /// The control is no longer read-write capable, so restore cannot act;
    /// counted as intentionally completed.
    case skippedUnavailable(SceneControl)
    /// The entry never reached its write, so there is nothing to undo.
    case untouched(SceneControl)
    /// The entry was settled by an earlier rollback or restore pass.
    case alreadySettled(SceneControl)
    case failed(SceneControl, reason: String)
}

nonisolated struct SceneRestoreReport: Equatable, Sendable {
    let transactionID: UUID
    let sceneID: UUID
    /// Outcomes in processing order, which is the reverse of apply order.
    let outcomes: [SceneRestoreOutcome]
    let journalCleared: Bool
}

nonisolated enum SceneRestoreError: Error, Equatable {
    case operationInProgress
    case transactionMismatch(expected: UUID, actual: UUID?)
    case journalUnreadable(String)
    /// Some entries could not be restored; the journal was kept so a later
    /// call can retry exactly the unfinished entries.
    case incomplete(SceneRestoreReport)
}

extension SceneRestoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another scene operation is still running."
        case .transactionMismatch:
            return "The saved restore point no longer belongs to this session."
        case .journalUnreadable(let reason):
            return "The saved restore point could not be read: \(reason)"
        case .incomplete(let report):
            let failedCount = report.outcomes.reduce(into: 0) { count, outcome in
                if case .failed = outcome { count += 1 }
            }
            if failedCount == 0 {
                return "Restore finished, but its restore point could not be removed. Try again or choose Keep Current."
            } else {
                return "Restore is incomplete for \(failedCount) setting\(failedCount == 1 ? "" : "s"). Reconnect devices and try again, or choose Keep Current."
            }
        }
    }
}

private nonisolated enum SceneReadBackFailure: Error {
    case mismatch(expected: SceneValue, found: SceneValue)
    case snapshotChanged(expected: SceneValue, found: SceneValue)
}

// MARK: - Coordinator

/// Applies and restores scenes as journaled transactions over injected
/// adapters.
///
/// Apply pipeline: validate, preflight every action without mutating,
/// snapshot current values, persist the journal, then write and read back
/// each action in deterministic order. A required action that fails
/// preflight aborts before any mutation. Any failure after mutation begins
/// rolls the already-applied entries back in reverse order.
///
/// Restore walks the journal in reverse apply order and is drift aware: an
/// entry is only restored when the live value still matches the value the
/// scene applied. The journal is cleared only when every entry has settled,
/// either restored or intentionally skipped.
actor SceneCoordinator {
    private let adapters: SceneAdapterRegistry
    private let journalStore: any SceneJournalStoring
    private let readbackNumericTolerance: Double
    private let driftNumericTolerance: Double
    private let now: @Sendable () -> Date
    private let sessionID: UUID
    private var operationInProgress = false

    init(
        adapters: SceneAdapterRegistry,
        journalStore: any SceneJournalStoring,
        readbackNumericTolerance: Double = SceneValue.defaultReadbackNumericTolerance,
        driftNumericTolerance: Double = SceneValue.defaultDriftNumericTolerance,
        now: @escaping @Sendable () -> Date = { Date() },
        sessionID: UUID = UUID()
    ) {
        self.adapters = adapters
        self.journalStore = journalStore
        self.readbackNumericTolerance = readbackNumericTolerance
        self.driftNumericTolerance = driftNumericTolerance
        self.now = now
        self.sessionID = sessionID
    }

    /// The unfinished transaction, if one is journaled.
    func pendingTransaction() throws -> SceneTransaction? {
        guard let transaction = try journalStore.load() else { return nil }
        try transaction.validate()
        return transaction
    }

    /// Discards the pending journal without restoring anything. This is the
    /// explicit "accept current state" escape hatch; it must come from a
    /// deliberate user decision, never from automatic cleanup.
    func abandonPendingTransaction() throws {
        try discardPendingTransaction(expectedTransactionID: nil)
    }

    func abandonPendingTransaction(expectedTransactionID: UUID) throws {
        try discardPendingTransaction(expectedTransactionID: expectedTransactionID)
    }

    private func discardPendingTransaction(expectedTransactionID: UUID?) throws {
        guard !operationInProgress else { throw SceneRestoreError.operationInProgress }
        try Task.checkCancellation()
        if let expectedTransactionID {
            let actual: UUID?
            do {
                actual = try journalStore.load()?.id
            } catch {
                throw SceneRestoreError.journalUnreadable(String(describing: error))
            }
            guard actual == expectedTransactionID else {
                throw SceneRestoreError.transactionMismatch(expected: expectedTransactionID, actual: actual)
            }
        }
        try journalStore.clear()
    }

    /// Persists user ownership before the caller changes the live control.
    /// The reservation can be committed after success or cancelled if the
    /// live change is rejected.
    func beginUserOverride(
        for control: SceneControl
    ) throws -> SceneUserOverrideReservation? {
        guard !operationInProgress else { throw SceneRestoreError.operationInProgress }
        guard var transaction = try journalStore.load() else { return nil }
        guard let index = transaction.entries.firstIndex(where: {
            $0.control == control && $0.phase.needsRestore
        }) else {
            return nil
        }

        let reservation = SceneUserOverrideReservation(
            transactionID: transaction.id,
            control: control,
            previousPhase: transaction.entries[index].phase
        )
        transaction.entries[index].phase = .userOverridePending
        try journalStore.save(transaction)
        return reservation
    }

    @discardableResult
    func commitUserOverride(
        _ reservation: SceneUserOverrideReservation?
    ) throws -> Bool {
        guard !operationInProgress else { throw SceneRestoreError.operationInProgress }
        guard let reservation else {
            return try journalStore.load().map { !$0.isFullySettled } ?? false
        }
        guard var transaction = try journalStore.load(),
              transaction.id == reservation.transactionID,
              let index = transaction.entries.firstIndex(where: {
                  $0.control == reservation.control && $0.phase == .userOverridePending
              }) else {
            throw SceneRestoreError.journalUnreadable("The user change reservation is missing.")
        }

        transaction.entries[index].phase = .skippedDrift
        if transaction.isFullySettled {
            try journalStore.clear()
            return false
        }
        try journalStore.save(transaction)
        return true
    }

    @discardableResult
    func cancelUserOverride(
        _ reservation: SceneUserOverrideReservation?
    ) throws -> Bool {
        guard !operationInProgress else { throw SceneRestoreError.operationInProgress }
        guard let reservation else {
            return try journalStore.load().map { !$0.isFullySettled } ?? false
        }
        guard var transaction = try journalStore.load(),
              transaction.id == reservation.transactionID,
              let index = transaction.entries.firstIndex(where: {
                  $0.control == reservation.control && $0.phase == .userOverridePending
              }) else {
            throw SceneRestoreError.journalUnreadable("The user change reservation is missing.")
        }

        transaction.entries[index].phase = reservation.previousPhase
        try journalStore.save(transaction)
        return !transaction.isFullySettled
    }

    func preview(_ scene: SemperScene) async throws -> ScenePreviewReport {
        guard !operationInProgress else { throw SceneApplyError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }

        try Task.checkCancellation()
        do {
            try scene.validate()
        } catch {
            throw SceneApplyError.invalidScene(error)
        }
        return try await preflight(scene)
    }

    private func preflight(_ scene: SemperScene) async throws -> ScenePreviewReport {
        // Preflight: capability and snapshot reads only, no mutation. All
        // required failures are collected so the error reports every problem
        // at once.
        var requiredFailures: [ScenePreflightFailure] = []
        var skippedOptional: [SceneSkippedAction] = []
        var stagedEntries: [SceneTransactionEntry] = []

        for action in scene.actionsInApplyOrder {
            try Task.checkCancellation()
            let adapter = adapters.adapter(for: action.control)
            let capability = await adapter.capability(for: action.control)
            try Task.checkCancellation()
            guard capability.isSceneEligible else {
                switch action.importance {
                case .required:
                    requiredFailures.append(ScenePreflightFailure(control: action.control, reason: .capability(capability)))
                case .optional:
                    skippedOptional.append(SceneSkippedAction(control: action.control, reason: .capability(capability)))
                }
                continue
            }
            let targetPreflight = await adapter.preflightTarget(
                action.target,
                for: action.control
            )
            try Task.checkCancellation()
            if case .unavailable(let reason) = targetPreflight {
                let skipReason = SceneSkipReason.targetUnavailable(reason)
                switch action.importance {
                case .required:
                    requiredFailures.append(ScenePreflightFailure(
                        control: action.control,
                        reason: skipReason
                    ))
                case .optional:
                    skippedOptional.append(SceneSkippedAction(
                        control: action.control,
                        reason: skipReason
                    ))
                }
                continue
            }
            do {
                let snapshot = try await adapter.readValue(for: action.control)
                try Task.checkCancellation()
                stagedEntries.append(SceneTransactionEntry(
                    control: action.control,
                    importance: action.importance,
                    snapshotValue: snapshot,
                    targetValue: action.target
                ))
            } catch {
                try Task.checkCancellation()
                switch action.importance {
                case .required:
                    requiredFailures.append(ScenePreflightFailure(control: action.control, reason: .readFailed(String(describing: error))))
                case .optional:
                    skippedOptional.append(SceneSkippedAction(control: action.control, reason: .readFailed(String(describing: error))))
                }
            }
        }

        var optionalTriggersToSkip = Set<SceneControl>()
        for triggerEntry in stagedEntries {
            try Task.checkCancellation()
            let adapter = adapters.adapter(for: triggerEntry.control)
            let prerequisites = await adapter.prerequisites(
                of: triggerEntry.targetValue,
                for: triggerEntry.control
            )
            try Task.checkCancellation()
            guard !prerequisites.isEmpty else { continue }

            var missingControl: SceneControl?
            for prerequisite in prerequisites {
                guard let affectedIndex = stagedEntries.firstIndex(where: {
                          $0.control == prerequisite.control
                      }) else {
                    missingControl = prerequisite.control
                    break
                }
                if triggerEntry.importance == .required {
                    stagedEntries[affectedIndex].importance = .required
                }
            }

            if let missingControl {
                let reason = SceneSkipReason.targetUnavailable(
                    "The output switch would also change \(missingControl), which is not stored in this scene."
                )
                switch triggerEntry.importance {
                case .required:
                    requiredFailures.append(ScenePreflightFailure(
                        control: triggerEntry.control,
                        reason: reason
                    ))
                case .optional:
                    optionalTriggersToSkip.insert(triggerEntry.control)
                    skippedOptional.append(SceneSkippedAction(
                        control: triggerEntry.control,
                        reason: reason
                    ))
                }
                continue
            }
        }

        if !optionalTriggersToSkip.isEmpty {
            stagedEntries.removeAll { optionalTriggersToSkip.contains($0.control) }
        }

        return ScenePreviewReport(
            sceneID: scene.id,
            entries: stagedEntries,
            skippedOptional: skippedOptional,
            requiredFailures: requiredFailures
        )
    }

    // MARK: Apply

    func apply(
        _ scene: SemperScene,
        expectedPreview: ScenePreviewReport? = nil
    ) async throws -> SceneApplyReport {
        guard !operationInProgress else { throw SceneApplyError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }

        try Task.checkCancellation()

        do {
            try scene.validate()
        } catch {
            throw SceneApplyError.invalidScene(error)
        }

        let existing: SceneTransaction?
        do {
            existing = try journalStore.load()
        } catch {
            throw SceneApplyError.journalUnreadable(String(describing: error))
        }
        if let existing {
            do {
                try existing.validate()
            } catch {
                throw SceneApplyError.journalUnreadable(String(describing: error))
            }
            guard existing.isFullySettled else {
                throw SceneApplyError.transactionAlreadyActive(transactionID: existing.id)
            }
        }

        let preview = try await preflight(scene)
        if let expectedPreview, preview != expectedPreview {
            throw SceneApplyError.previewChanged
        }
        let requiredFailures = preview.requiredFailures
        var skippedOptional = preview.skippedOptional
        let stagedEntries = preview.entries

        guard requiredFailures.isEmpty else {
            throw SceneApplyError.requiredPreflightFailed(failures: requiredFailures)
        }
        if existing != nil {
            // Settled journals hold no restorable state. Clear only after
            // confirming that the reviewed preflight still matches.
            do {
                try journalStore.clear()
            } catch {
                throw SceneApplyError.journalWriteFailed(String(describing: error))
            }
        }
        guard !stagedEntries.isEmpty else {
            return SceneApplyReport(transactionID: nil, sceneID: scene.id, applied: [], skippedOptional: skippedOptional)
        }

        try Task.checkCancellation()

        var transaction = SceneTransaction(
            sceneID: scene.id,
            sceneName: scene.name,
            startedAt: now(),
            originSessionID: sessionID,
            entries: stagedEntries
        )
        do {
            try journalStore.save(transaction)
        } catch {
            // Nothing was mutated yet; without a durable journal the apply
            // must not begin.
            throw SceneApplyError.journalWriteFailed(String(describing: error))
        }

        var appliedActions: [SceneAppliedAction] = []
        for index in transaction.entries.indices {
            let entry = transaction.entries[index]
            let adapter = adapters.adapter(for: entry.control)
            if Task.isCancelled {
                throw await unwindFailedApply(
                    transaction: transaction,
                    failedControl: entry.control,
                    underlying: CancellationError()
                )
            }
            do {
                let current = try await adapter.readValue(for: entry.control)
                try Task.checkCancellation()
                guard current.matches(
                    entry.snapshotValue,
                    numericTolerance: driftNumericTolerance
                ) else {
                    throw SceneReadBackFailure.snapshotChanged(
                        expected: entry.snapshotValue,
                        found: current
                    )
                }
            } catch {
                let prewriteFailure = error
                if error is CancellationError || Task.isCancelled {
                    throw await unwindFailedApply(
                        transaction: transaction,
                        failedControl: entry.control,
                        underlying: CancellationError()
                    )
                }
                if entry.importance == .optional {
                    transaction.entries[index].phase = .rolledBack
                    do {
                        try journalStore.save(transaction)
                    } catch {
                        throw await unwindFailedApply(
                            transaction: transaction,
                            failedControl: entry.control,
                            underlying: error
                        )
                    }
                    skippedOptional.append(SceneSkippedAction(
                        control: entry.control,
                        reason: .readFailed(Self.describeApplyFailure(prewriteFailure))
                    ))
                    continue
                }
                throw await unwindFailedApply(
                    transaction: transaction,
                    failedControl: entry.control,
                    underlying: prewriteFailure
                )
            }

            transaction.entries[index].appliedValue = nil
            transaction.entries[index].phase = .inFlight
            do {
                try journalStore.save(transaction)
            } catch {
                throw await unwindFailedApply(
                    transaction: transaction,
                    failedControl: entry.control,
                    underlying: error
                )
            }

            do {
                try Task.checkCancellation()
                try await adapter.writeValue(entry.targetValue, for: entry.control)
                try Task.checkCancellation()
                let readBack = try await adapter.readValue(for: entry.control)
                try Task.checkCancellation()
                guard readBack.matches(
                    entry.targetValue,
                    numericTolerance: readbackNumericTolerance
                ) else {
                    throw SceneReadBackFailure.mismatch(expected: entry.targetValue, found: readBack)
                }

                transaction.entries[index].appliedValue = readBack
                transaction.entries[index].phase = .applied
                try journalStore.save(transaction)
                appliedActions.append(SceneAppliedAction(
                    control: entry.control,
                    snapshotValue: entry.snapshotValue,
                    appliedValue: readBack
                ))
            } catch {
                let actionFailure = error
                if error is CancellationError || Task.isCancelled {
                    throw await unwindFailedApply(
                        transaction: transaction,
                        failedControl: entry.control,
                        underlying: CancellationError()
                    )
                }
                if entry.importance == .optional {
                    do {
                        let restorationValue = await adapter.restorationValue(
                            for: entry.snapshotValue,
                            control: entry.control
                        )
                        try Task.checkCancellation()
                        try await adapter.writeValue(restorationValue, for: entry.control)
                        try Task.checkCancellation()
                        let readBack = try await adapter.readValue(for: entry.control)
                        try Task.checkCancellation()
                        guard readBack.matches(
                            restorationValue,
                            numericTolerance: readbackNumericTolerance
                        ) else {
                            throw SceneReadBackFailure.mismatch(
                                expected: restorationValue,
                                found: readBack
                            )
                        }
                        transaction.entries[index].phase = .rolledBack
                        try journalStore.save(transaction)
                        skippedOptional.append(SceneSkippedAction(
                            control: entry.control,
                            reason: .writeFailed(Self.describeApplyFailure(actionFailure))
                        ))
                        continue
                    } catch {
                        throw await unwindFailedApply(
                            transaction: transaction,
                            failedControl: entry.control,
                            underlying: error is CancellationError || Task.isCancelled
                                ? CancellationError()
                                : actionFailure
                        )
                    }
                }

                throw await unwindFailedApply(
                    transaction: transaction,
                    failedControl: entry.control,
                    underlying: actionFailure
                )
            }
        }

        if Task.isCancelled, let lastEntry = transaction.entries.last {
            throw await unwindFailedApply(
                transaction: transaction,
                failedControl: lastEntry.control,
                underlying: CancellationError()
            )
        }

        return SceneApplyReport(
            transactionID: transaction.id,
            sceneID: scene.id,
            applied: appliedActions,
            skippedOptional: skippedOptional
        )
    }

    /// Rolls back every mutated entry in reverse apply order, verifying each
    /// restoration write by readback, and reports what could not be undone.
    /// An output route failure blocks earlier output volume and mute controls
    /// because their snapshots depend on restoring that route first.
    private func unwindFailedApply(
        transaction: SceneTransaction,
        failedControl: SceneControl,
        underlying: Error
    ) async -> SceneApplyError {
        let reason = Self.describeApplyFailure(underlying)
        return await Task.detached { [self] in
            await performUnwindFailedApply(
                transaction: transaction,
                failedControl: failedControl,
                underlyingReason: reason
            )
        }.value
    }

    private func performUnwindFailedApply(
        transaction: SceneTransaction,
        failedControl: SceneControl,
        underlyingReason: String
    ) async -> SceneApplyError {
        var transaction = transaction
        var rollbackFailures: [SceneControl] = []
        var outputRouteBlocksDependentRestoration = false

        for index in transaction.entries.indices.reversed() {
            let entry = transaction.entries[index]
            if outputRouteBlocksDependentRestoration,
               entry.phase.needsRestore,
               Self.isOutputRouteDependent(entry.control) {
                rollbackFailures.append(entry.control)
                continue
            }
            if entry.control == .audioOutputDevice,
               !entry.phase.needsRestore,
               transaction.entries[..<index].contains(where: {
                   $0.phase.needsRestore && Self.isOutputRouteDependent($0.control)
               }) {
                let adapter = adapters.adapter(for: entry.control)
                do {
                    let current = try await adapter.readValue(for: entry.control)
                    let restorationValue = await adapter.restorationValue(
                        for: entry.snapshotValue,
                        control: entry.control
                    )
                    let routeIsSafe = outputRouteIsSafeForDependentRestoration(
                        entry: entry,
                        current: current,
                        restorationValue: restorationValue
                    )
                    if routeIsSafe {
                        continue
                    }
                } catch {
                    // The unsettled route is handled by the barrier below.
                }
                rollbackFailures.append(entry.control)
                outputRouteBlocksDependentRestoration = true
                continue
            }
            guard entry.phase.needsRestore else { continue }
            let adapter = adapters.adapter(for: entry.control)
            let restorationValue = await adapter.restorationValue(
                for: entry.snapshotValue,
                control: entry.control
            )
            let isOutputBarrier = entry.control == .audioOutputDevice

            if isOutputBarrier {
                let capability = await adapter.capability(for: entry.control)
                let current: SceneValue
                do {
                    current = try await adapter.readValue(for: entry.control)
                } catch {
                    rollbackFailures.append(entry.control)
                    outputRouteBlocksDependentRestoration = true
                    continue
                }
                if current.matches(
                    restorationValue,
                    numericTolerance: readbackNumericTolerance
                ) {
                    transaction.entries[index].phase = .rolledBack
                    try? journalStore.save(transaction)
                    continue
                }
                guard capability.isSceneEligible else {
                    rollbackFailures.append(entry.control)
                    outputRouteBlocksDependentRestoration = true
                    continue
                }
            }

            do {
                try await adapter.writeValue(restorationValue, for: entry.control)
                let readBack = try await adapter.readValue(for: entry.control)
                guard readBack.matches(
                    restorationValue,
                    numericTolerance: readbackNumericTolerance
                ) else {
                    throw SceneReadBackFailure.mismatch(
                        expected: restorationValue,
                        found: readBack
                    )
                }
                transaction.entries[index].phase = .rolledBack
                // Journal persistence is best effort during unwind; the
                // definitive clear or save below decides recoverability.
                try? journalStore.save(transaction)
            } catch {
                rollbackFailures.append(entry.control)
                if isOutputBarrier {
                    outputRouteBlocksDependentRestoration = true
                }
            }
        }

        let cleanup: SceneApplyFailureCleanup
        if rollbackFailures.isEmpty {
            // A failed clear leaves a fully settled journal behind, which the
            // next apply or restore drops safely.
            try? journalStore.clear()
            cleanup = .rolledBack
        } else {
            try? journalStore.save(transaction)
            cleanup = .rollbackIncomplete(controls: rollbackFailures)
        }
        return .actionFailed(
            control: failedControl,
            reason: underlyingReason,
            cleanup: cleanup
        )
    }

    private static func describeApplyFailure(_ error: Error) -> String {
        if case SceneReadBackFailure.mismatch(let expected, let found) = error {
            return "read-back value \(found) did not match target \(expected)"
        }
        if case SceneReadBackFailure.snapshotChanged(let expected, let found) = error {
            return "value changed after preflight from \(expected) to \(found)"
        }
        return String(describing: error)
    }

    // MARK: Restore

    /// Restores the journaled transaction, drift aware, in reverse apply
    /// order. An output route failure blocks earlier output volume and mute
    /// controls while independent controls continue. Returns nil when no
    /// transaction is pending. This is also the recovery path after a crash:
    /// `pending` entries are reported untouched and `inFlight` entries are
    /// resolved against snapshot and target.
    func restore() async throws -> SceneRestoreReport? {
        try await restoreTransaction(expectedTransactionID: nil)
    }

    func restore(expectedTransactionID: UUID) async throws -> SceneRestoreReport? {
        try await restoreTransaction(expectedTransactionID: expectedTransactionID)
    }

    private func restoreTransaction(expectedTransactionID: UUID?) async throws -> SceneRestoreReport? {
        guard !operationInProgress else { throw SceneRestoreError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }

        try Task.checkCancellation()

        let loaded: SceneTransaction?
        do {
            loaded = try journalStore.load()
        } catch {
            throw SceneRestoreError.journalUnreadable(String(describing: error))
        }
        if let expectedTransactionID, loaded?.id != expectedTransactionID {
            throw SceneRestoreError.transactionMismatch(expected: expectedTransactionID, actual: loaded?.id)
        }
        guard var transaction = loaded else { return nil }
        do {
            try transaction.validate()
        } catch {
            throw SceneRestoreError.journalUnreadable(String(describing: error))
        }

        var outcomes: [SceneRestoreOutcome] = []
        var outputRouteBlocksDependentRestoration = false
        for index in transaction.entries.indices.reversed() {
            try Task.checkCancellation()
            let entry = transaction.entries[index]
            if outputRouteBlocksDependentRestoration,
               entry.phase.needsRestore,
               Self.isOutputRouteDependent(entry.control) {
                outcomes.append(.failed(
                    entry.control,
                    reason: "Output route must be restored first."
                ))
                continue
            }
            let earlierRouteDependentEntriesNeedRestore = transaction.entries[..<index]
                .contains(where: {
                    $0.phase.needsRestore && Self.isOutputRouteDependent($0.control)
                })
            if entry.control == .audioOutputDevice,
               !entry.phase.needsRestore,
               earlierRouteDependentEntriesNeedRestore {
                let adapter = adapters.adapter(for: entry.control)
                let current: SceneValue
                do {
                    current = try await adapter.readValue(for: entry.control)
                    try Task.checkCancellation()
                } catch {
                    try Task.checkCancellation()
                    outcomes.append(.failed(
                        entry.control,
                        reason: String(describing: error)
                    ))
                    outputRouteBlocksDependentRestoration = true
                    continue
                }
                let restorationValue = await adapter.restorationValue(
                    for: entry.snapshotValue,
                    control: entry.control
                )
                try Task.checkCancellation()
                let routeIsSafe = outputRouteIsSafeForDependentRestoration(
                    entry: entry,
                    current: current,
                    restorationValue: restorationValue
                )
                guard routeIsSafe else {
                    outcomes.append(.failed(
                        entry.control,
                        reason: "Output route is not safe for dependent restoration."
                    ))
                    outputRouteBlocksDependentRestoration = true
                    continue
                }
            }
            switch entry.phase {
            case .pending:
                outcomes.append(.untouched(entry.control))
                continue
            case .rolledBack, .restored, .userOverridePending, .skippedDrift, .skippedUnavailable:
                outcomes.append(.alreadySettled(entry.control))
                continue
            case .inFlight, .applied:
                break
            }

            let adapter = adapters.adapter(for: entry.control)
            let restorationValue = await adapter.restorationValue(
                for: entry.snapshotValue,
                control: entry.control
            )
            try Task.checkCancellation()
            let isOutputBarrier = entry.control == .audioOutputDevice
            let alreadyRestoredTolerance = entry.phase == .inFlight
                ? readbackNumericTolerance
                : driftNumericTolerance
            let capability = await adapter.capability(for: entry.control)
            try Task.checkCancellation()
            guard capability.isSceneEligible else {
                if entry.control == .audioOutputDevice,
                   let current = try? await adapter.readValue(for: entry.control),
                   current.matches(
                       restorationValue,
                       numericTolerance: alreadyRestoredTolerance
                   ) {
                    transaction.entries[index].phase = .restored
                    try? journalStore.save(transaction)
                    outcomes.append(.restored(entry.control))
                    continue
                }
                if isOutputBarrier {
                    outcomes.append(.failed(
                        entry.control,
                        reason: "Output route is unavailable."
                    ))
                    outputRouteBlocksDependentRestoration = true
                } else if entry.importance == .optional {
                    outcomes.append(.failed(
                        entry.control,
                        reason: "Optional control is unavailable."
                    ))
                } else {
                    outcomes.append(.failed(
                        entry.control,
                        reason: "Required control is unavailable."
                    ))
                }
                continue
            }

            let current: SceneValue
            do {
                current = try await adapter.readValue(for: entry.control)
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                outcomes.append(.failed(entry.control, reason: String(describing: error)))
                if isOutputBarrier {
                    outputRouteBlocksDependentRestoration = true
                }
                continue
            }

            if (entry.phase == .inFlight || entry.control == .audioOutputDevice),
               current.matches(
                   restorationValue,
                   numericTolerance: alreadyRestoredTolerance
               ) {
                // The interrupted write never landed; the control already
                // holds its snapshot value.
                transaction.entries[index].phase = .restored
                try? journalStore.save(transaction)
                outcomes.append(.restored(entry.control))
                continue
            }

            // For confirmed writes the readback value is the drift baseline;
            // an interrupted write is compared with its requested target.
            let appliedBaseline = entry.appliedValue ?? entry.targetValue
            let appliedBaselineTolerance = entry.phase == .inFlight
                ? readbackNumericTolerance
                : driftNumericTolerance
            let awakeActivityEndedWithPriorProcess = transaction.originSessionID != nil
                && transaction.originSessionID != sessionID
                && entry.control == .awakeMode
                && current == .awake(.off)
                && appliedBaseline != .awake(.off)
            guard awakeActivityEndedWithPriorProcess || current.matches(
                appliedBaseline,
                numericTolerance: appliedBaselineTolerance
            ) else {
                transaction.entries[index].phase = .skippedDrift
                try? journalStore.save(transaction)
                outcomes.append(.skippedDrift(entry.control, currentValue: current))
                continue
            }

            do {
                try Task.checkCancellation()
                try await adapter.writeValue(restorationValue, for: entry.control)
                try Task.checkCancellation()
                let readBack = try await adapter.readValue(for: entry.control)
                try Task.checkCancellation()
                guard readBack.matches(
                    restorationValue,
                    numericTolerance: readbackNumericTolerance
                ) else {
                    outcomes.append(.failed(entry.control, reason: "restore read-back \(readBack) did not match restoration value \(restorationValue)"))
                    if isOutputBarrier {
                        outputRouteBlocksDependentRestoration = true
                    }
                    continue
                }
                transaction.entries[index].phase = .restored
                try? journalStore.save(transaction)
                outcomes.append(.restored(entry.control))
            } catch {
                try Task.checkCancellation()
                outcomes.append(.failed(entry.control, reason: String(describing: error)))
                if isOutputBarrier {
                    outputRouteBlocksDependentRestoration = true
                }
            }
        }

        try Task.checkCancellation()

        if transaction.isFullySettled {
            let report = SceneRestoreReport(
                transactionID: transaction.id,
                sceneID: transaction.sceneID,
                outcomes: outcomes,
                journalCleared: true
            )
            do {
                try journalStore.clear()
            } catch {
                // The settled journal could not be removed; report the pass
                // as incomplete so the caller retries, which will clear it.
                throw SceneRestoreError.incomplete(SceneRestoreReport(
                    transactionID: transaction.id,
                    sceneID: transaction.sceneID,
                    outcomes: outcomes,
                    journalCleared: false
                ))
            }
            return report
        }

        try? journalStore.save(transaction)
        throw SceneRestoreError.incomplete(SceneRestoreReport(
            transactionID: transaction.id,
            sceneID: transaction.sceneID,
            outcomes: outcomes,
            journalCleared: false
        ))
    }

    private func outputRouteIsSafeForDependentRestoration(
        entry: SceneTransactionEntry,
        current: SceneValue,
        restorationValue: SceneValue
    ) -> Bool {
        switch entry.phase {
        case .pending:
            current.matches(
                restorationValue,
                numericTolerance: readbackNumericTolerance
            ) || !current.matches(
                entry.targetValue,
                numericTolerance: driftNumericTolerance
            )
        case .rolledBack, .restored:
            current.matches(
                restorationValue,
                numericTolerance: readbackNumericTolerance
            )
        case .userOverridePending, .skippedDrift, .skippedUnavailable:
            !current.matches(
                entry.appliedValue ?? entry.targetValue,
                numericTolerance: driftNumericTolerance
            )
        case .inFlight, .applied:
            false
        }
    }

    private nonisolated static func isOutputRouteDependent(_ control: SceneControl) -> Bool {
        switch control {
        case .audioOutputVolume, .audioOutputMuted:
            true
        default:
            false
        }
    }
}
