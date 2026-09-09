import CoreGraphics
import Foundation
import Testing

@testable import Semper

@Suite("Workspace operation receipts", .serialized)
@MainActor
struct WorkspaceOperationReceiptTests {
    let support = WorkspaceServiceTests()

    func prepared(count: Int = 2) async throws -> (
        WorkspaceService, WorkspaceTestBackend, [WorkspaceWindowID], WorkspaceRestorePlan
    ) {
        let (service, backend, ids, _) = support.fixture(count: count)
        await support.capture(service)
        for id in ids { await backend.change(id, frame: support.displaced) }
        await service.makePreview()
        let plan = try service.makeRestorePlan(selectedSlotIDs: Set(service.preview.map(\.id)))
        return (service, backend, ids, plan)
    }

    func waitForMove(_ backend: WorkspaceTestBackend, count: Int) async throws {
        for _ in 0..<400 {
            if await backend.moveAttempts >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The mock did not reach the expected move boundary.")
    }

    @Test("Plan creation is read-only and freezes only explicitly selected slots")
    func selectedSubset() async throws {
        let (service, backend, ids, fullPlan) = try await prepared()
        let prompts = await backend.permissionPrompts
        let plan = try service.makeRestorePlan(selectedSlotIDs: [fullPlan.steps[1].id])
        #expect(await backend.permissionPrompts == prompts)
        #expect(await backend.moves.isEmpty)
        #expect(plan.steps.count == 1 && plan.selectedSlotIDs == [fullPlan.steps[1].id])
        let result = await service.apply(plan)
        #expect(await backend.moves == [ids[1]])
        #expect(result.outcome == .completed)
        #expect(result.pendingRecoverySlotIDs == plan.selectedSlotIDs)
        #expect(result.steps.first?.observation?.before == support.displaced)
        #expect(result.steps.first?.observation?.after == support.original)
        #expect(service.undoEntries.isEmpty)
    }

    @Test("Frozen plans ignore later selection, binding and display mapping")
    func frozenPlan() async throws {
        let (service, backend, ids, originalPlan) = try await prepared(count: 1)
        let otherDisplay = WorkspaceDisplay(
            id: "other", name: "Other",
            visibleFrame: CGRect(x: 1000, y: 25, width: 1000, height: 700))
        await backend.setScreens([support.screen, otherDisplay])
        await service.makePreview()
        let plan = try service.makeRestorePlan(selectedSlotIDs: originalPlan.selectedSlotIDs)
        let replacement = WorkspaceWindowID(application: support.app, token: UUID())
        await backend.add(
            .init(id: replacement, application: support.app, ordinal: 2, frame: support.displaced, issue: nil))
        await service.makePreview()
        await service.bind(slotID: plan.steps[0].id, to: replacement)
        await service.mapDisplay(support.screen.id, to: otherDisplay.id)
        service.selectedArrangementID = nil
        let result = await service.apply(plan)
        #expect(result.outcome == .completed)
        #expect(await backend.moves == [ids[0]])
        #expect(try await backend.current(ids[0])?.frame == support.original)
        #expect(try await backend.current(replacement)?.frame == support.displaced)
    }

    @Test("Plan creation rejects empty, unknown and unpreviewed selections")
    func invalidSelections() async throws {
        let (service, _, _, _) = support.fixture()
        await support.capture(service)
        let slot = try #require(service.selectedArrangement?.windows.first?.id)
        #expect(throws: WorkspacePlanError.emptySelection) { try service.makeRestorePlan(selectedSlotIDs: []) }
        #expect(throws: WorkspacePlanError.previewRequired) { try service.makeRestorePlan(selectedSlotIDs: [slot]) }
        await service.makePreview()
        #expect(throws: WorkspacePlanError.unknownSelection) { try service.makeRestorePlan(selectedSlotIDs: [UUID()]) }
        await service.pause()
        #expect(throws: WorkspacePlanError.stopped) { try service.makeRestorePlan(selectedSlotIDs: [slot]) }
    }

    @Test("A failed preview and pause invalidate plan creation or application")
    func invalidatedPlans() async throws {
        let (service, backend, _, plan) = try await prepared(count: 1)
        await backend.setPermission(false)
        await service.makePreview()
        #expect(throws: WorkspacePlanError.previewRequired) {
            try service.makeRestorePlan(selectedSlotIDs: plan.selectedSlotIDs)
        }
        await service.pause()
        await service.start()
        let rejected = await service.apply(plan)
        #expect(rejected.issue == .invalidPlan)
        #expect(await backend.moves.isEmpty)
    }

    @Test("Partial and constrained applies retain each observed change")
    func partialAndConstrained() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 3)
        await backend.setFailingMoves([ids[1]])
        await backend.setConstrained(true)
        let applied = await service.apply(plan)
        #expect(applied.outcome == .partial)
        #expect(applied.steps.count == 3)
        #expect(applied.steps[0].outcome == .constrained)
        #expect(applied.steps[1].outcome == .failed(.missingWindow))
        #expect(applied.pendingRecoverySlotIDs == [plan.steps[0].id, plan.steps[2].id])
        await backend.setConstrained(false)
        await backend.setFailingMoves([])
        let reversed = await service.reverse(applied)
        #expect(!reversed.needsRecovery)
        #expect(try await backend.current(ids[0])?.frame == support.displaced)
        #expect(try await backend.current(ids[2])?.frame == support.displaced)
    }

    @Test("Cancellation before admission performs no permission or window work")
    func cancelledBeforeAdmission() async throws {
        let (service, backend, _, plan) = try await prepared(count: 1)
        let prompts = await backend.permissionPrompts
        let task = Task { @MainActor in await service.apply(plan) }
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(result.steps.allSatisfy { $0.outcome == .notAttempted })
        #expect(!result.needsRecovery)
        #expect(await backend.permissionPrompts == prompts)
        #expect(await backend.moves.isEmpty)
    }

    @Test("Caller cancellation before a write returns a complete receipt")
    func cancelledBeforeWrite() async throws {
        let (service, backend, _, plan) = try await prepared()
        await backend.setMovePauses(before: 1)
        let task = Task { await service.apply(plan) }
        try await waitForMove(backend, count: 1)
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled && result.steps.count == 2)
        #expect(result.steps[0].outcome == .cancelled)
        #expect(result.steps[1].outcome == .notAttempted)
        #expect(!result.needsRecovery)
        #expect(await backend.moves.isEmpty)
    }

    @Test("Cancellation between windows preserves completed changes and unattempted slots")
    func cancelledBetweenWindows() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 3)
        await backend.setMovePauses(before: 2)
        let task = Task { await service.apply(plan) }
        try await waitForMove(backend, count: 2)
        task.cancel()
        let applied = await task.value
        #expect(applied.outcome == .cancelled)
        #expect(applied.steps.map(\.outcome) == [.applied, .cancelled, .notAttempted])
        #expect(applied.pendingRecoverySlotIDs == [plan.steps[0].id])
        await backend.setMovePauses()
        let reversed = await service.reverse(applied)
        #expect(!reversed.needsRecovery)
        #expect(try await backend.current(ids[0])?.frame == support.displaced)
    }

    @Test("Cancellation after an actual write preserves readback and recovery")
    func cancelledAfterWrite() async throws {
        let (service, backend, ids, plan) = try await prepared()
        await backend.setMovePauses(after: 1)
        let task = Task { await service.apply(plan) }
        try await waitForMove(backend, count: 1)
        task.cancel()
        let applied = await task.value
        #expect(applied.outcome == .cancelled)
        #expect(applied.steps[0].observation?.writeAttempted == true)
        #expect(applied.steps[0].observation?.after == support.original)
        #expect(applied.hasPendingRecovery)
        await backend.setMovePauses()
        let reversed = await service.reverse(applied)
        #expect(!reversed.needsRecovery)
        #expect(try await backend.current(ids[0])?.frame == support.displaced)
    }

    @Test("Missing readback requires manual recovery and never automatic reversal")
    func missingReadback() async throws {
        let (service, backend, _, plan) = try await prepared(count: 1)
        await backend.setMissingReadback(true)
        let applied = await service.apply(plan)
        #expect(applied.steps[0].outcome == .failed(.unverifiedReadback))
        #expect(applied.requiresManualRecovery && !applied.hasPendingRecovery)
        #expect(applied.manualRecoverySlotIDs == plan.selectedSlotIDs)
        let count = await backend.moves.count
        let reversed = await service.reverse(applied)
        #expect(reversed.requiresManualRecovery)
        #expect(await backend.moves.count == count)
    }

    @Test("Receipt reversal does not read or replace direct Undo history")
    func independentUndo() async throws {
        let (service, backend, ids, plan) = try await prepared()
        let presentation = try service.makeRestorePlan(selectedSlotIDs: [plan.steps[0].id])
        let applied = await service.apply(presentation)
        await service.makePreview()
        await service.restore()
        let undo = service.undoEntries
        #expect(undo.count == 1 && undo[0].id == ids[1])
        let reversed = await service.reverse(applied)
        #expect(!reversed.needsRecovery)
        #expect(service.undoEntries.map(\.id) == undo.map(\.id))
        #expect(service.undoEntries.map(\.before) == undo.map(\.before))
        await service.undo()
        #expect(try await backend.current(ids[1])?.frame == support.displaced)
    }

    @Test("Exact later manual and direct moves are preserved without pending recovery")
    func manualAndDirectChanges() async throws {
        let (service, backend, ids, plan) = try await prepared()
        let applied = await service.apply(plan)
        let manual = CGRect(
            x: support.original.minX + 0.5, y: support.original.minY,
            width: support.original.width, height: support.original.height)
        await backend.change(ids[0], frame: manual)
        let otherDisplay = WorkspaceDisplay(
            id: "other", name: "Other", visibleFrame: CGRect(x: 1000, y: 25, width: 1000, height: 700))
        await backend.setScreens([support.screen, otherDisplay])
        await service.makePreview()
        await service.mapDisplay(support.screen.id, to: otherDisplay.id)
        await service.restore()
        let count = await backend.moves.count
        let reversed = await service.reverse(applied)
        #expect(reversed.preservedManualChangeSlotIDs == plan.selectedSlotIDs)
        #expect(!reversed.needsRecovery)
        #expect(await backend.moves.count == count)
    }

    @Test("Receipt reversal preserves a half-point manual change exactly")
    func subpointReverse() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 1)
        let applied = await service.apply(plan)
        let manual = CGRect(
            x: support.original.minX + 0.5, y: support.original.minY,
            width: support.original.width, height: support.original.height)
        await backend.change(ids[0], frame: manual)
        let reversed = await service.reverse(applied)
        #expect(reversed.steps[0].outcome == .skipped(.manualChangePreserved))
        #expect(!reversed.needsRecovery)
        #expect(try await backend.current(ids[0])?.frame == manual)
    }

    @Test("Stale frames and closed or recreated windows never receive a write")
    func staleWindows() async throws {
        let (service, backend, ids, plan) = try await prepared()
        await backend.change(ids[0], frame: support.original)
        await backend.remove(ids[1])
        let replacement = WorkspaceWindowID(application: support.app, token: UUID())
        await backend.add(
            .init(id: replacement, application: support.app, ordinal: 2, frame: support.displaced, issue: nil))
        let result = await service.apply(plan)
        #expect(result.steps[0].outcome == .skipped(.changedFrame))
        #expect(result.steps[1].outcome == .skipped(.missingWindow))
        #expect(await backend.moves.isEmpty)
    }

    @Test("Revoked permission and changed topology are explicit per-slot failures")
    func permissionAndTopology() async throws {
        let (service, backend, _, plan) = try await prepared()
        await backend.setPermission(false)
        let denied = await service.apply(plan)
        #expect(denied.steps.allSatisfy { $0.outcome == .failed(.permission) })
        #expect(service.permission == .revoked)
        await backend.setPermission(true)
        await backend.setScreens([])
        let changed = await service.apply(plan)
        #expect(changed.steps.allSatisfy { $0.outcome == .skipped(.changedDisplays) })
        #expect(await backend.moves.isEmpty)
    }

    @Test("Unsafe or unresolved windows remain refused in immutable plans")
    func unavailableCapabilities() async throws {
        let (service, backend, ids, plan) = try await prepared()
        await backend.change(ids[0], issue: .unknownState)
        await service.bind(slotID: plan.steps[1].id, to: nil)
        let refused = try service.makeRestorePlan(selectedSlotIDs: plan.selectedSlotIDs)
        let result = await service.apply(refused)
        #expect(result.steps.allSatisfy { $0.outcome == .skipped(.unresolved) })
        #expect(await backend.moves.isEmpty)
        let old = await service.apply(plan)
        #expect(old.steps[0].outcome == .skipped(.unsupported(.unknownState)))
    }

    @Test("Reverse requires the original display identity and geometry, even when another display fits")
    func reverseTopology() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 1)
        let applied = await service.apply(plan)
        let replacement = WorkspaceDisplay(
            id: "replacement", name: "Replacement", visibleFrame: support.screen.visibleFrame)
        let shifted = WorkspaceDisplay(
            id: support.screen.id, name: support.screen.name,
            visibleFrame: support.screen.visibleFrame.offsetBy(dx: -10, dy: 0))
        let count = await backend.moves.count
        for displays in [[replacement], [shifted], []] {
            await backend.setScreens(displays)
            let refused = await service.reverse(applied)
            #expect(refused.steps[0].outcome == .skipped(.changedDisplays))
            #expect(refused.pendingRecoverySlotIDs == plan.selectedSlotIDs)
            #expect(await backend.moves.count == count)
        }
        await backend.setScreens([support.screen])
        let reversed = await service.reverse(applied)
        #expect(!reversed.needsRecovery)
        #expect(try await backend.current(ids[0])?.frame == support.displaced)
    }

    @Test("Reverse continues after failure and returned recovery can be retried")
    func reversePartialFailure() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 3)
        let applied = await service.apply(plan)
        await backend.setFailingMoves([ids[1]])
        let reversed = await service.reverse(applied)
        #expect(reversed.steps.map(\.slotID) == plan.steps.reversed().map(\.id))
        #expect(reversed.pendingRecoverySlotIDs == [plan.steps[1].id])
        #expect(try await backend.current(ids[0])?.frame == support.displaced)
        #expect(try await backend.current(ids[2])?.frame == support.displaced)
        await backend.setFailingMoves([])
        let retry = await service.reverse(reversed)
        #expect(!retry.needsRecovery)
        #expect(try await backend.current(ids[1])?.frame == support.displaced)
    }

    @Test("Repeated reversal of original or completed receipts performs no further moves")
    func repeatedReverse() async throws {
        let (service, backend, _, plan) = try await prepared()
        let applied = await service.apply(plan)
        let reversed = await service.reverse(applied)
        #expect(reversed.steps.allSatisfy { $0.outcome == .restored })
        #expect(!reversed.hasPendingRecovery)
        let count = await backend.moves.count
        let repeated = await service.reverse(applied)
        let completed = await service.reverse(reversed)
        #expect(repeated.steps.allSatisfy { $0.outcome == .alreadyRestored })
        #expect(!repeated.needsRecovery && !completed.needsRecovery)
        #expect(await backend.moves.count == count)
    }

    @Test("Cancellation during a partial reverse preserves original goal and latest frame")
    func cancelledPartialReverse() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 2)
        let applied = await service.apply(plan)
        await backend.setConstrained(true)
        await backend.setMovePauses(after: 3)
        let task = Task { await service.reverse(applied) }
        try await waitForMove(backend, count: 3)
        task.cancel()
        let partial = await task.value
        #expect(partial.outcome == .cancelled)
        if case .pending(let change) = partial.steps[0].recovery {
            #expect(change.before == support.displaced)
            #expect(change.after.width == support.displaced.width + 80)
        } else {
            Issue.record("Partial reversal lost its remaining recovery state.")
        }
        #expect(partial.pendingRecoverySlotIDs == plan.selectedSlotIDs)
        await backend.setConstrained(false)
        await backend.setMovePauses()
        let resumed = await service.reverse(partial)
        #expect(!resumed.needsRecovery)
        #expect(try await backend.current(ids[0])?.frame == support.displaced)
        #expect(try await backend.current(ids[1])?.frame == support.displaced)
    }

    @Test("Reverse missing readback reports manual recovery instead of original pending frame")
    func reverseMissingReadback() async throws {
        let (service, backend, _, plan) = try await prepared(count: 1)
        let applied = await service.apply(plan)
        await backend.setMissingReadback(true)
        let reversed = await service.reverse(applied)
        #expect(reversed.requiresManualRecovery && !reversed.hasPendingRecovery)
        #expect(reversed.steps[0].step.currentFrame == support.displaced)
    }

    @Test("Receipt and direct operations share atomic admission and pause drains receipts")
    func admissionAndPause() async throws {
        let (service, backend, _, plan) = try await prepared()
        await backend.setMovePauses(after: 1)
        let task = Task { await service.apply(plan) }
        try await waitForMove(backend, count: 1)
        let rejected = await service.apply(plan)
        #expect(rejected.issue == .busy)
        #expect(throws: WorkspacePlanError.busy) { try service.makeRestorePlan(selectedSlotIDs: plan.selectedSlotIDs) }
        await service.restore()
        #expect(await backend.moveAttempts == 1)
        await service.pause()
        let result = await task.value
        #expect(result.outcome == .cancelled && result.hasPendingRecovery)
        #expect(!service.isRunning && !service.isBusy)
        await service.start()
        await backend.setMovePauses()
        let reversed = await service.reverse(result)
        #expect(!reversed.needsRecovery)
    }

    @Test("A manual move racing the backend reverse guard is never adopted or overwritten on retry")
    func reverseGuardRace() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 1)
        let applied = await service.apply(plan)
        let manual = CGRect(
            x: support.original.minX + 0.5, y: support.original.minY,
            width: support.original.width, height: support.original.height)
        await backend.setFrameBeforeNextGuard(manual)
        let reversed = await service.reverse(applied)
        #expect(reversed.steps[0].observation?.writeAttempted == false)
        #expect(reversed.steps[0].outcome == .skipped(.manualChangePreserved))
        #expect(reversed.preservedManualChangeSlotIDs == plan.selectedSlotIDs)
        #expect(!reversed.needsRecovery)
        let count = await backend.moves.count
        let retried = await service.reverse(reversed)
        #expect(!retried.needsRecovery)
        #expect(await backend.moves.count == count)
        #expect(try await backend.current(ids[0])?.frame == manual)
    }

    @Test("A rejected foreign receipt remains rejected when its result is retried")
    func foreignReceipt() async throws {
        let (service, backend, ids, plan) = try await prepared(count: 1)
        let applied = await service.apply(plan)
        let other = WorkspaceService(
            backend: backend,
            store: WorkspaceStore(
                url: FileManager.default.temporaryDirectory.appending(path: "foreign-workspace-\(UUID()).json")))
        await other.start()
        let count = await backend.moves.count
        let rejected = await other.reverse(applied)
        #expect(rejected.issue == .invalidPlan)
        let retried = await other.reverse(rejected)
        #expect(retried.issue == .invalidPlan)
        #expect(await backend.moves.count == count)
        #expect(try await backend.current(ids[0])?.frame == support.original)
    }

    @Test("A secondary pause caller returns after cleanup and can immediately restart")
    func concurrentPause() async throws {
        let (service, backend, _, plan) = try await prepared(count: 1)
        await backend.setHoldMoveReturn(true)
        let apply = Task { await service.apply(plan) }
        try await waitForMove(backend, count: 1)
        let first = Task { await service.pause() }
        for _ in 0..<400 {
            if !service.isRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await service.pause()
            await service.start()
            return service.isRunning
        }
        while !secondStarted { await Task.yield() }
        await backend.releaseMoveReturn()
        await first.value
        #expect(await second.value)
        #expect((await apply.value).outcome == .cancelled)
        #expect(service.isRunning && !service.isBusy)
    }

    @Test("Concurrent shutdown calls share a drain and prohibit restart until finished")
    func concurrentShutdown() async throws {
        let (service, backend, _, plan) = try await prepared()
        await backend.setMovePauses(before: 1)
        await backend.setHoldShutdown(true)
        let apply = Task { await service.apply(plan) }
        try await waitForMove(backend, count: 1)
        let first = Task { await service.shutdown() }
        for _ in 0..<400 {
            if await backend.shutdownCalls == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task {
            await service.shutdown()
            await service.start()
            return service.isRunning
        }
        await Task.yield()
        await service.start()
        #expect(!service.isRunning)
        #expect((await service.apply(plan)).issue != nil)
        #expect(await backend.shutdownCalls == 1)
        await backend.releaseShutdown()
        await first.value
        #expect(await second.value)
        #expect((await apply.value).outcome == .cancelled)
        #expect(!service.isBusy)
        await service.start()
        #expect(service.isRunning)
    }
}
