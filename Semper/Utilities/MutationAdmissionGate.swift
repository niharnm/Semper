import Foundation

nonisolated enum MutationAdmissionOwner: Hashable, Sendable {
    case scene
    case awayMode
}

nonisolated enum MutationAdmissionMode: Sendable {
    case shared
    case exclusive
}

nonisolated enum MutationAdmissionError: Error, Equatable, Sendable {
    case exclusivePermitActive(owner: MutationAdmissionOwner)
    case sharedPermitsActive(owners: Set<MutationAdmissionOwner>)
}

@MainActor
final class MutationAdmissionPermit {
    let owner: MutationAdmissionOwner
    let mode: MutationAdmissionMode

    fileprivate let gateID: UUID
    fileprivate let tokenID: UUID
    fileprivate var isReleased = false

    fileprivate init(
        gateID: UUID,
        tokenID: UUID,
        owner: MutationAdmissionOwner,
        mode: MutationAdmissionMode
    ) {
        self.gateID = gateID
        self.tokenID = tokenID
        self.owner = owner
        self.mode = mode
    }
}

@MainActor
final class MutationAdmissionGate {
    private let gateID = UUID()
    private var sharedPermits: [UUID: MutationAdmissionPermit] = [:]
    private var exclusivePermit: MutationAdmissionPermit?

    var activeSharedPermitCount: Int {
        sharedPermits.count
    }

    var activeExclusiveOwner: MutationAdmissionOwner? {
        exclusivePermit?.owner
    }

    func acquire(
        owner: MutationAdmissionOwner,
        mode: MutationAdmissionMode
    ) throws -> MutationAdmissionPermit {
        switch mode {
        case .shared:
            if let exclusivePermit {
                throw MutationAdmissionError.exclusivePermitActive(owner: exclusivePermit.owner)
            }
        case .exclusive:
            if let exclusivePermit {
                throw MutationAdmissionError.exclusivePermitActive(owner: exclusivePermit.owner)
            }
            guard sharedPermits.isEmpty else {
                throw MutationAdmissionError.sharedPermitsActive(
                    owners: Set(sharedPermits.values.map(\.owner))
                )
            }
        }

        let permit = MutationAdmissionPermit(
            gateID: gateID,
            tokenID: UUID(),
            owner: owner,
            mode: mode
        )
        switch mode {
        case .shared:
            sharedPermits[permit.tokenID] = permit
        case .exclusive:
            exclusivePermit = permit
        }
        return permit
    }

    @discardableResult
    func release(_ permit: MutationAdmissionPermit) -> Bool {
        guard permit.gateID == gateID else { return false }
        guard !permit.isReleased else { return true }

        switch permit.mode {
        case .shared:
            guard sharedPermits[permit.tokenID] === permit else { return false }
            sharedPermits[permit.tokenID] = nil
        case .exclusive:
            guard exclusivePermit === permit else { return false }
            exclusivePermit = nil
        }
        permit.isReleased = true
        return true
    }
}
