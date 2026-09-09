import Foundation

struct SafeEjectBatchExclusion: Identifiable, Equatable, Sendable {
    let volume: SafeEjectVolume
    let reason: SafeEjectFailure
    var id: SafeEjectVolumeID { volume.id }
}

struct SafeEjectBatchConfirmation: Identifiable, Equatable, Sendable {
    static let maximumVolumes = 128
    let id: UUID
    let eligible: [SafeEjectVolume]
    let excluded: [SafeEjectBatchExclusion]
}

enum SafeEjectBatchStopReason: Equatable, Sendable {
    case cancelled
    case paused
    case sleeping
    case shutDown
    case failure(SafeEjectFailure)

    var message: String {
        switch self {
        case .cancelled: "The batch was cancelled."
        case .paused: "Safe Eject was paused."
        case .sleeping: "This Mac went to sleep."
        case .shutDown: "Safe Eject was shut down."
        case .failure(let failure): "The batch stopped. \(failure.message)"
        }
    }
}

enum SafeEjectBatchItemOutcome: Equatable, Sendable {
    case completed(SafeEjectOutcome)
    case notAttempted(SafeEjectBatchStopReason)

    var message: String {
        switch self {
        case .completed(let outcome): outcome.message
        case .notAttempted(let reason): "Not attempted. \(reason.message)"
        }
    }

    var isEjected: Bool { self == .completed(.ejected) }
    var isNotAttempted: Bool {
        if case .notAttempted = self { return true }
        return false
    }
}

struct SafeEjectBatchItemResult: Identifiable, Equatable, Sendable {
    let volume: SafeEjectVolume
    let outcome: SafeEjectBatchItemOutcome
    var id: SafeEjectVolumeID { volume.id }
}

struct SafeEjectBatchProgress: Equatable, Sendable {
    let confirmationID: UUID
    let total: Int
    let completedCount: Int
    let currentVolume: SafeEjectVolume?
    var isCancelling = false
}

struct SafeEjectBatchResult: Identifiable, Equatable, Sendable {
    let confirmationID: UUID
    let items: [SafeEjectBatchItemResult]
    let excluded: [SafeEjectBatchExclusion]
    var id: UUID { confirmationID }
    var ejectedCount: Int { items.filter { $0.outcome.isEjected }.count }
    var notAttemptedCount: Int { items.filter { $0.outcome.isNotAttempted }.count }
    var failedCount: Int { items.count - ejectedCount - notAttemptedCount }
}
