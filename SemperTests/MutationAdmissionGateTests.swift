import Testing
@testable import Semper

@Suite("MutationAdmissionGate")
@MainActor
struct MutationAdmissionGateTests {
    @Test("Shared permits coexist and block exclusive admission")
    func sharedPermitsBlockExclusiveAdmission() throws {
        let gate = MutationAdmissionGate()
        let first = try gate.acquire(owner: .scene, mode: .shared)
        let second = try gate.acquire(owner: .scene, mode: .shared)

        #expect(gate.activeSharedPermitCount == 2)
        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.scene])) {
            try gate.acquire(owner: .awayMode, mode: .exclusive)
        }

        #expect(gate.release(first))
        #expect(gate.activeSharedPermitCount == 1)
        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.scene])) {
            try gate.acquire(owner: .awayMode, mode: .exclusive)
        }

        #expect(gate.release(second))
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)
        #expect(gate.activeExclusiveOwner == .awayMode)
        #expect(gate.release(exclusive))
    }

    @Test("Exclusive admission blocks every other permit")
    func exclusivePermitBlocksOtherAdmission() throws {
        let gate = MutationAdmissionGate()
        let exclusive = try gate.acquire(owner: .awayMode, mode: .exclusive)

        #expect(throws: MutationAdmissionError.exclusivePermitActive(owner: .awayMode)) {
            try gate.acquire(owner: .scene, mode: .shared)
        }
        #expect(throws: MutationAdmissionError.exclusivePermitActive(owner: .awayMode)) {
            try gate.acquire(owner: .manualDisplay, mode: .shared)
        }
        #expect(throws: MutationAdmissionError.exclusivePermitActive(owner: .awayMode)) {
            try gate.acquire(owner: .awayMode, mode: .exclusive)
        }

        #expect(gate.release(exclusive))
        let shared = try gate.acquire(owner: .scene, mode: .shared)
        #expect(gate.release(shared))
    }

    @Test("Scene and manual display permits conflict in both orderings")
    func sceneAndManualDisplayPermitsConflict() throws {
        let sceneFirst = MutationAdmissionGate()
        let scene = try sceneFirst.acquire(owner: .scene, mode: .shared)
        let ordinaryManual = try sceneFirst.acquire(owner: .manual, mode: .shared)

        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.scene])) {
            try sceneFirst.acquire(owner: .manualDisplay, mode: .shared)
        }
        #expect(sceneFirst.release(ordinaryManual))
        #expect(sceneFirst.release(scene))

        let displayFirst = MutationAdmissionGate()
        let manualDisplay = try displayFirst.acquire(owner: .manualDisplay, mode: .shared)
        let secondOrdinaryManual = try displayFirst.acquire(owner: .manual, mode: .shared)

        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.manualDisplay])) {
            try displayFirst.acquire(owner: .scene, mode: .shared)
        }
        #expect(displayFirst.release(secondOrdinaryManual))
        #expect(displayFirst.release(manualDisplay))
    }

    @Test("Release checks the issuing gate and is idempotent")
    func releaseIsCheckedAndIdempotent() throws {
        let firstGate = MutationAdmissionGate()
        let secondGate = MutationAdmissionGate()
        let permit = try firstGate.acquire(owner: .scene, mode: .shared)

        #expect(!secondGate.release(permit))
        #expect(firstGate.activeSharedPermitCount == 1)
        #expect(firstGate.release(permit))
        #expect(firstGate.release(permit))
        #expect(firstGate.activeSharedPermitCount == 0)
    }

    @Test("A shared permit remains held across suspension")
    func sharedPermitRemainsHeldAcrossSuspension() async throws {
        let gate = MutationAdmissionGate()
        let permit = try gate.acquire(owner: .scene, mode: .shared)

        await Task.yield()

        #expect(throws: MutationAdmissionError.sharedPermitsActive(owners: [.scene])) {
            try gate.acquire(owner: .awayMode, mode: .exclusive)
        }
        #expect(gate.release(permit))
    }
}
