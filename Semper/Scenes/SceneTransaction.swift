// Semper/Scenes/SceneTransaction.swift
import Foundation

/// Lifecycle of one journaled control mutation.
///
/// `pending` and `inFlight` are written before the mutation they describe so
/// a crash can never mutate hardware without a durable record. Every other
/// phase is settled: the entry needs no further restore work.
nonisolated enum SceneEntryPhase: String, Codable, Sendable {
    /// Snapshot recorded; no write attempted yet.
    case pending
    /// Write started; completion was never confirmed by readback.
    case inFlight
    /// Write confirmed by readback; `appliedValue` holds the readback.
    case applied
    /// Snapshot re-written while unwinding a failed apply.
    case rolledBack
    /// Snapshot re-written (or found already in place) during restore.
    case restored
    /// The user took ownership before changing the live control. A later
    /// launch treats this as user drift even if the process exited mid-change.
    case userOverridePending
    /// Left alone during restore because the value drifted after apply.
    case skippedDrift
    /// Left alone during restore because the control became unavailable.
    case skippedUnavailable

    /// True while the entry may still hold scene-applied hardware state.
    var needsRestore: Bool {
        switch self {
        case .inFlight, .applied:
            true
        case .pending, .rolledBack, .restored, .userOverridePending, .skippedDrift, .skippedUnavailable:
            false
        }
    }
}

nonisolated struct SceneUserOverrideReservation: Equatable, Sendable {
    let transactionID: UUID
    let control: SceneControl
    let previousPhase: SceneEntryPhase
}

/// One journaled mutation: what was there before, what the scene asked for,
/// and what the hardware actually reported after the write.
nonisolated struct SceneTransactionEntry: Codable, Hashable, Sendable {
    var control: SceneControl
    var importance: SceneActionImportance
    var snapshotValue: SceneValue
    var targetValue: SceneValue
    var appliedValue: SceneValue?
    var phase: SceneEntryPhase

    init(
        control: SceneControl,
        importance: SceneActionImportance,
        snapshotValue: SceneValue,
        targetValue: SceneValue,
        appliedValue: SceneValue? = nil,
        phase: SceneEntryPhase = .pending
    ) {
        self.control = control
        self.importance = importance
        self.snapshotValue = snapshotValue
        self.targetValue = targetValue
        self.appliedValue = appliedValue
        self.phase = phase
    }
}

/// Durable record of one scene application. Entries are stored in apply
/// order; restore and rollback always walk them in reverse.
nonisolated struct SceneTransaction: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let sceneID: UUID
    let sceneName: String
    let startedAt: Date
    let originSessionID: UUID?
    var entries: [SceneTransactionEntry]

    init(
        id: UUID = UUID(),
        sceneID: UUID,
        sceneName: String,
        startedAt: Date,
        originSessionID: UUID? = nil,
        entries: [SceneTransactionEntry]
    ) {
        self.id = id
        self.sceneID = sceneID
        self.sceneName = sceneName
        self.startedAt = startedAt
        self.originSessionID = originSessionID
        self.entries = entries
    }

    /// True when no entry can still hold scene-applied state, so the journal
    /// may be cleared safely.
    var isFullySettled: Bool {
        entries.allSatisfy { !$0.phase.needsRestore }
    }

    func validate() throws(SceneTransactionValidationIssue) {
        guard !sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptySceneName
        }
        guard !entries.isEmpty else { throw .noEntries }

        let controls = entries.map(\.control)
        guard Set(controls).count == controls.count else {
            throw .duplicateControl
        }
        guard controls == controls.sorted(by: SceneControl.orderedBefore) else {
            throw .controlsOutOfOrder
        }

        for entry in entries {
            try Self.validateValue(entry.snapshotValue, for: entry.control, role: .snapshot)
            try Self.validateValue(entry.targetValue, for: entry.control, role: .target)
            if let appliedValue = entry.appliedValue {
                try Self.validateValue(appliedValue, for: entry.control, role: .applied)
            }
            if entry.phase == .applied, entry.appliedValue == nil {
                throw .missingAppliedValue(entry.control)
            }
            if (entry.phase == .pending || entry.phase == .inFlight),
               entry.appliedValue != nil {
                throw .unexpectedAppliedValue(entry.control)
            }
        }
    }

    private static func validateValue(
        _ value: SceneValue,
        for control: SceneControl,
        role: SceneTransactionValueRole
    ) throws(SceneTransactionValidationIssue) {
        guard value.kind == control.valueKind else {
            throw .valueKindMismatch(
                control: control,
                role: role,
                expected: control.valueKind,
                found: value.kind
            )
        }
        if case .number(let number) = value,
           !number.isFinite || !(0...1).contains(number) {
            throw .numberOutOfRange(control: control, role: role, value: number)
        }
        if case .text(let text) = value, text.isEmpty {
            throw .emptyText(control: control, role: role)
        }
    }
}

nonisolated enum SceneTransactionValueRole: String, Equatable, Sendable {
    case snapshot
    case target
    case applied
}

nonisolated enum SceneTransactionValidationIssue: Error, Equatable, Sendable {
    case emptySceneName
    case noEntries
    case duplicateControl
    case controlsOutOfOrder
    case valueKindMismatch(
        control: SceneControl,
        role: SceneTransactionValueRole,
        expected: SceneValueKind,
        found: SceneValueKind
    )
    case numberOutOfRange(
        control: SceneControl,
        role: SceneTransactionValueRole,
        value: Double
    )
    case emptyText(control: SceneControl, role: SceneTransactionValueRole)
    case missingAppliedValue(SceneControl)
    case unexpectedAppliedValue(SceneControl)
}

extension SceneTransactionValidationIssue: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptySceneName:
            "The restore point has no scene name."
        case .noEntries:
            "The restore point has no settings."
        case .duplicateControl:
            "The restore point contains a setting more than once."
        case .controlsOutOfOrder:
            "The restore point settings are out of order."
        case .valueKindMismatch:
            "A restore point setting has the wrong value type."
        case .numberOutOfRange:
            "A restore point value is outside the allowed range."
        case .emptyText:
            "A restore point contains an empty device identifier."
        case .missingAppliedValue:
            "A restore point is missing a confirmed value."
        case .unexpectedAppliedValue:
            "A restore point contains an unexpected confirmed value."
        }
    }
}
