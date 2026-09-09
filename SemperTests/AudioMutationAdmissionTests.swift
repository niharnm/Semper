import Foundation
import Testing

@testable import Semper

@MainActor
private final class AdmissionAudioBackend: AudioCommandBackend {
    var result: AudioBackendApplyResult = .accepted
    var reads = 0
    var writes = 0
    var preparations = 0
    var sceneBegins = 0
    var observed: AudioControlValue = .scalar(0.5)

    func read(_ key: AudioControlKey) -> AudioControlValue? {
        reads += 1
        return observed
    }

    func effectiveRequestedValue(for command: AudioCommand) -> AudioControlValue {
        preparations += 1
        return command.requestedValue
    }

    func apply(_ command: AudioCommand) -> AudioBackendApplyResult {
        writes += 1
        return result
    }

    func beginSceneTransaction() -> Bool {
        sceneBegins += 1
        return true
    }
}

@Suite("Sound mutation admission")
@MainActor
struct AudioMutationAdmissionTests {
    private let command = AudioCommand.setOutputVolume(deviceUID: "output", volume: 0.8)

    @Test("Exclusive Away blocks every command source before backend access")
    func deniesBeforeReadingOrWriting() throws {
        let gate = MutationAdmissionGate()
        let backend = AdmissionAudioBackend()
        let dispatcher = AudioCommandDispatcher(backend: backend)
        try dispatcher.installMutationAdmission(gate)
        let away = try gate.acquire(owner: .awayMode, mode: .exclusive)
        defer { gate.release(away) }

        for reason in [AudioChangeReason.directUser, .scene, .callMode, .recovery] {
            #expect(
                dispatcher.dispatch(command, context: .init(source: .automation, reason: reason))
                    == .rejected(.mutationAdmissionDenied(.exclusivePermitActive(owner: .awayMode))))
        }
        #expect(!dispatcher.beginSceneTransaction())
        #expect(dispatcher.undoLastChange() == .failed)
        #expect(backend.reads == 0)
        #expect(backend.preparations == 0)
        #expect(backend.writes == 0)
        #expect(backend.sceneBegins == 0)
    }

    @Test("Accepted writes retain admission until matching completion")
    func acceptedWriteLifetime() throws {
        let gate = MutationAdmissionGate()
        let dispatcher = AudioCommandDispatcher(backend: AdmissionAudioBackend())
        try dispatcher.installMutationAdmission(gate)
        guard case .accepted = dispatcher.dispatch(command, context: .init(source: .popup)) else {
            Issue.record("Expected accepted command")
            return
        }
        #expect(gate.activeSharedPermitCount == 1)
        #expect(throws: MutationAdmissionError.self) { try gate.acquire(owner: .awayMode, mode: .exclusive) }
        #expect(!dispatcher.completeAccepted(command.controlKey, observed: .scalar(0.6)))
        #expect(gate.activeSharedPermitCount == 1)
        #expect(dispatcher.completeAccepted(command.controlKey, observed: .scalar(0.8)))
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("Rejection releases accepted admission after backend reconciliation")
    func acceptedRejection() throws {
        let gate = MutationAdmissionGate()
        let dispatcher = AudioCommandDispatcher(backend: AdmissionAudioBackend())
        try dispatcher.installMutationAdmission(gate)
        dispatcher.dispatch(command, context: .init(source: .automation))
        dispatcher.rejectAccepted(command.controlKey)
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("Logical supersession cannot release pending backend admission")
    func unchangedDoesNotPretendToDrain() throws {
        let gate = MutationAdmissionGate()
        let backend = AdmissionAudioBackend()
        let dispatcher = AudioCommandDispatcher(backend: backend)
        try dispatcher.installMutationAdmission(gate)
        dispatcher.dispatch(command, context: .init(source: .popup))
        backend.observed = .scalar(0.8)
        dispatcher.dispatch(command, context: .init(source: .popup))
        #expect(gate.activeSharedPermitCount == 1)
        dispatcher.completeAccepted(command.controlKey, observed: .scalar(0.8))
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("Shutdown retains pending admission until the caller confirms backend drain")
    func shutdownNeedsActualDrain() throws {
        let gate = MutationAdmissionGate()
        let backend = AdmissionAudioBackend()
        let dispatcher = AudioCommandDispatcher(backend: backend)
        try dispatcher.installMutationAdmission(gate)
        dispatcher.dispatch(command, context: .init(source: .popup))
        dispatcher.finishShutdownAfterBackendDrain()
        #expect(gate.activeSharedPermitCount == 1)
        dispatcher.shutdown()
        let reads = backend.reads
        dispatcher.rejectAccepted(command.controlKey)
        dispatcher.completeAccepted(command.controlKey, observed: .scalar(0.8))
        #expect(backend.reads == reads)
        #expect(gate.activeSharedPermitCount == 1)
        dispatcher.finishShutdownAfterBackendDrain()
        dispatcher.finishShutdownAfterBackendDrain()
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("Synchronous writes and scene transactions release at their actual boundary")
    func synchronousAndSceneLifetime() throws {
        let gate = MutationAdmissionGate()
        let backend = AdmissionAudioBackend()
        backend.result = .applied(.scalar(0.8))
        let dispatcher = AudioCommandDispatcher(backend: backend)
        try dispatcher.installMutationAdmission(gate)
        dispatcher.dispatch(command, context: .init(source: .popup))
        #expect(gate.activeSharedPermitCount == 0)
        #expect(dispatcher.beginSceneTransaction())
        #expect(gate.activeSharedPermitCount == 1)
        dispatcher.endSceneTransaction()
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("Installation is inert and an operation lease survives cancellation until settled")
    func explicitOperationLifetime() async throws {
        let gate = MutationAdmissionGate()
        let admission = AudioMutationAdmission()
        try admission.install(gate)
        try admission.install(gate)
        #expect(gate.activeSharedPermitCount == 0)
        #expect(throws: AudioMutationAdmissionInstallationError.self) {
            try admission.install(MutationAdmissionGate())
        }
        let lease = try admission.acquire()
        let task = Task { @MainActor in
            defer { lease.finish() }
            #expect(gate.activeSharedPermitCount == 1)
        }
        task.cancel()
        #expect(gate.activeSharedPermitCount == 1)
        await task.value
        lease.finish()
        #expect(gate.activeSharedPermitCount == 0)
        let away = try gate.acquire(owner: .awayMode, mode: .exclusive)
        #expect(admission.begin() == nil)
        #expect(admission.lastError as? MutationAdmissionError == .exclusivePermitActive(owner: .awayMode))
        gate.release(away)
    }
}
