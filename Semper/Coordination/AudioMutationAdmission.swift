import Foundation
import Observation

enum AudioMutationAdmissionInstallationError: Error, Equatable {
    case differentGateAlreadyInstalled
}

@MainActor
final class AudioMutationLease {
    private var release: (() -> Void)?

    fileprivate init(release: @escaping () -> Void) {
        self.release = release
    }

    func finish() {
        let operation = release
        release = nil
        operation?()
    }
}

@Observable
@MainActor
final class AudioMutationAdmission {
    private var gate: MutationAdmissionGate?
    private(set) var lastError: (any Error)?

    func install(_ gate: MutationAdmissionGate) throws {
        if let installed = self.gate, installed !== gate {
            throw AudioMutationAdmissionInstallationError.differentGateAlreadyInstalled
        }
        self.gate = gate
    }

    func acquire() throws -> AudioMutationLease {
        guard let gate else { return AudioMutationLease(release: {}) }
        let permit = try gate.acquire(owner: .manual, mode: .shared)
        lastError = nil
        return AudioMutationLease { gate.release(permit) }
    }

    func begin() -> AudioMutationLease? {
        do {
            return try acquire()
        } catch {
            lastError = error
            return nil
        }
    }
}
