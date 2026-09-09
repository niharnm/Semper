import Foundation
import Testing

@testable import Semper

@Suite("Workspace admission and Presentation ownership", .serialized)
@MainActor
struct WorkspaceAdmissionTests {
    let support = WorkspaceServiceTests()

    @Test("Away blocks direct and receipt window writes before permission work")
    func exclusiveAdmission() async throws {
        let gate = MutationAdmissionGate()
        let (service, backend, ids, _) = support.fixture()
        try service.installMutationAdmission(gate)
        await support.capture(service)
        await backend.change(ids[0], frame: support.displaced)
        await service.makePreview()
        let plan = try service.makeRestorePlan(selectedSlotIDs: Set(service.preview.map(\.id)))
        let prompts = await backend.permissionPrompts
        let permit = try gate.acquire(owner: .awayMode, mode: .exclusive)
        await service.restore()
        let refused = await service.apply(plan)
        #expect(refused.issue == .mutationsBlocked)
        #expect(await backend.moves.isEmpty)
        #expect(await backend.permissionPrompts == prompts)
        #expect(gate.release(permit))
        let result = await service.apply(plan)
        #expect(result.outcome == .completed)
    }

    @Test("Presentation reservation blocks direct changes and lifecycle invalidation")
    func reservedPlan() async throws {
        let (service, backend, _, plan) = try await WorkspaceOperationReceiptTests().prepared(count: 1)
        let token = UUID()
        try service.reserveForPresentation(plan, token: token)
        service.selectedArrangementID = nil
        await service.makePreview()
        await service.bind(slotID: plan.steps[0].id, to: nil)
        await service.restore()
        await service.pause()
        await service.shutdown()
        #expect(service.selectedArrangementID == plan.arrangementID)
        #expect(service.isRunning)
        #expect(await backend.moves.isEmpty)
        #expect(await backend.shutdownCalls == 0)
        #expect((await service.apply(plan)).issue == .busy)
        let applied = await service.apply(plan, ownerToken: token)
        #expect(applied.outcome == .completed)
        #expect(throws: WorkspacePlanError.busy) { try service.releasePresentationReservation(token) }
        let restored = await service.reverse(applied, ownerToken: token)
        #expect(!restored.needsRecovery)
        try service.releasePresentationReservation(token)
        await service.shutdown()
        #expect(await backend.shutdownCalls == 1)
    }

    @Test("Only the latest owner receipt can be reversed again")
    func staleReceipt() async throws {
        let (service, backend, ids, plan) = try await WorkspaceOperationReceiptTests().prepared(count: 1)
        let token = UUID()
        try service.reserveForPresentation(plan, token: token)
        let applied = await service.apply(plan, ownerToken: token)
        await backend.setFailingMoves([ids[0]])
        let first = await service.reverse(applied, ownerToken: token)
        #expect(first.needsRecovery)
        let rejected = await service.reverse(applied, ownerToken: token)
        #expect(rejected.issue == .invalidPlan)
        #expect(throws: WorkspacePlanError.busy) { try service.releasePresentationReservation(token) }
        await backend.setFailingMoves([])
        let final = await service.reverse(first, ownerToken: token)
        #expect(!final.needsRecovery)
        try service.releasePresentationReservation(token)
    }

    @Test("Unverified readback retains ownership until explicit keep-current acceptance")
    func manualRecovery() async throws {
        let (service, backend, _, plan) = try await WorkspaceOperationReceiptTests().prepared(count: 1)
        let token = UUID()
        try service.reserveForPresentation(plan, token: token)
        await backend.setMissingReadback(true)
        let applied = await service.apply(plan, ownerToken: token)
        #expect(applied.requiresManualRecovery)
        #expect(throws: WorkspacePlanError.busy) { try service.releasePresentationReservation(token) }
        #expect(throws: WorkspacePlanError.busy) {
            try service.releasePresentationReservation(UUID(), keepingCurrent: true)
        }
        try service.releasePresentationReservation(token, keepingCurrent: true)
        #expect(service.presentationReservation == nil)
    }
}
