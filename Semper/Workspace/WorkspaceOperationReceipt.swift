import CoreGraphics
import Foundation

struct WorkspaceRestorePlan: Sendable {
    let id: UUID
    let arrangementID: UUID
    let selectedSlotIDs: Set<UUID>
    let displays: [WorkspaceDisplay]
    let steps: [WorkspacePreviewItem]
    let ownerID: UUID
    let generationID: UUID
}

enum WorkspacePlanError: Error, Equatable {
    case stopped, busy, emptySelection, unknownSelection, previewRequired
}

enum WorkspaceOperationIssue: Equatable, Sendable {
    case stopped, busy, invalidPlan, permission, unresolved, missingWindow, changedFrame, changedDisplays
    case unsupported(WorkspaceWindowIssue)
    case writeFailed, unverifiedReadback, manualRecoveryRequired, manualChangePreserved
}

enum WorkspaceStepOutcome: Equatable, Sendable {
    case applied, unchanged, constrained, restored, alreadyRestored, cancelled, notAttempted
    case skipped(WorkspaceOperationIssue)
    case failed(WorkspaceOperationIssue)

    var succeeded: Bool {
        switch self {
        case .applied, .unchanged, .restored, .alreadyRestored: true
        default: false
        }
    }
}

enum WorkspaceOperationOutcome: Equatable, Sendable {
    case completed, partial, failed, cancelled
}

struct WorkspaceRecoveryChange: Equatable, Sendable {
    let windowID: WorkspaceWindowID
    let display: WorkspaceDisplay
    let before: CGRect
    let after: CGRect
}

enum WorkspaceRecoveryState: Equatable, Sendable {
    case none
    case pending(WorkspaceRecoveryChange)
    case manualRecoveryRequired
    case manualChangePreserved
}

struct WorkspaceStepReceipt: Sendable {
    let step: WorkspacePreviewItem
    let outcome: WorkspaceStepOutcome
    let observation: WorkspaceMoveObservation?
    let recovery: WorkspaceRecoveryState

    var slotID: UUID { step.id }
}

struct WorkspaceOperationReceipt: Sendable {
    let operationID: UUID
    let planID: UUID
    let reversesOperationID: UUID?
    let outcome: WorkspaceOperationOutcome
    let issue: WorkspaceOperationIssue?
    let steps: [WorkspaceStepReceipt]
    let ownerID: UUID

    var pendingRecoverySlotIDs: Set<UUID> {
        Set(steps.compactMap { if case .pending = $0.recovery { $0.slotID } else { nil } })
    }
    var manualRecoverySlotIDs: Set<UUID> {
        Set(steps.filter { $0.recovery == .manualRecoveryRequired }.map(\.slotID))
    }
    var preservedManualChangeSlotIDs: Set<UUID> {
        Set(steps.filter { $0.recovery == .manualChangePreserved }.map(\.slotID))
    }
    var hasPendingRecovery: Bool { !pendingRecoverySlotIDs.isEmpty }
    var requiresManualRecovery: Bool { !manualRecoverySlotIDs.isEmpty }
    var needsRecovery: Bool { hasPendingRecovery || requiresManualRecovery }
}
