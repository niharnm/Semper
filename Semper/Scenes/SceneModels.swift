// Semper/Scenes/SceneModels.swift
import Foundation

/// Routing domain for a scene control. Each domain maps to one injected
/// adapter in `SceneAdapterRegistry`.
nonisolated enum SceneControlDomain: String, Codable, Sendable {
    case audio
    case display
    case power
}

/// The kind of payload a control accepts and reports.
nonisolated enum SceneValueKind: String, Codable, Sendable {
    case number
    case boolean
    case text
    case awake
}

nonisolated enum SceneAwakeState: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case system
    case displayAndSystem
}

/// A single machine-controllable setting a scene can express.
///
/// Numeric controls use a normalized 0...1 scale so scenes stay independent
/// of hardware ranges; adapters own the conversion to device units.
nonisolated enum SceneControl: Codable, Hashable, Sendable {
    case awakeMode
    case audioOutputDevice
    case audioOutputVolume(deviceID: String)
    case audioOutputMuted(deviceID: String)
    case displayBrightness(displayID: String)
    case displayContrast(displayID: String)

    var domain: SceneControlDomain {
        switch self {
        case .awakeMode:
            .power
        case .audioOutputDevice, .audioOutputVolume, .audioOutputMuted:
            .audio
        case .displayBrightness, .displayContrast:
            .display
        }
    }

    var valueKind: SceneValueKind {
        switch self {
        case .awakeMode:
            .awake
        case .audioOutputMuted:
            .boolean
        case .audioOutputDevice:
            .text
        case .audioOutputVolume, .displayBrightness, .displayContrast:
            .number
        }
    }

    /// Identifier of the specific device this control addresses, when the
    /// control is per-device rather than global.
    var deviceIdentifier: String? {
        switch self {
        case .audioOutputVolume(let deviceID), .audioOutputMuted(let deviceID):
            deviceID
        case .displayBrightness(let displayID), .displayContrast(let displayID):
            displayID
        case .awakeMode, .audioOutputDevice:
            nil
        }
    }

    /// Deterministic apply ranking. The wake assertion lands first so later
    /// hardware writes are not raced by system sleep. A destination's volume
    /// and mute state are prepared while it is inactive, then routing changes,
    /// so rollback can switch away before restoring either value. Brightness
    /// lands before contrast on each display.
    var applyRank: Int {
        switch self {
        case .awakeMode: 0
        case .audioOutputVolume: 1
        case .audioOutputMuted: 2
        case .audioOutputDevice: 3
        case .displayBrightness: 4
        case .displayContrast: 5
        }
    }

    /// Total ordering used to apply scene actions. Ties inside one rank are
    /// broken by device identifier so multi-display scenes stay stable.
    static func orderedBefore(_ lhs: SceneControl, _ rhs: SceneControl) -> Bool {
        (lhs.applyRank, lhs.deviceIdentifier ?? "") < (rhs.applyRank, rhs.deviceIdentifier ?? "")
    }
}

/// A typed value carried by a scene action, snapshot, or readback.
nonisolated enum SceneValue: Codable, Hashable, Sendable {
    case number(Double)
    case boolean(Bool)
    case text(String)
    case awake(SceneAwakeState)

    /// Numeric slack for readback and drift comparison. Wide enough to absorb
    /// hardware quantization (for example DDC percent steps) while still
    /// detecting one-step user adjustments.
    static let defaultReadbackNumericTolerance = 0.01
    static let defaultDriftNumericTolerance = 0.0005

    var kind: SceneValueKind {
        switch self {
        case .number: .number
        case .boolean: .boolean
        case .text: .text
        case .awake: .awake
        }
    }

    /// Tolerant equality: numbers match within `numericTolerance`, booleans
    /// and text match exactly, mismatched kinds never match.
    func matches(
        _ other: SceneValue,
        numericTolerance: Double = SceneValue.defaultReadbackNumericTolerance
    ) -> Bool {
        switch (self, other) {
        case (.number(let lhs), .number(let rhs)):
            lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= numericTolerance
        case (.boolean(let lhs), .boolean(let rhs)):
            lhs == rhs
        case (.text(let lhs), .text(let rhs)):
            lhs == rhs
        case (.awake(let lhs), .awake(let rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

/// Whether a scene action must succeed for the scene to apply at all.
nonisolated enum SceneActionImportance: String, Codable, Sendable {
    /// Preflight failure aborts the whole apply before any mutation.
    case required
    /// Unsupported or unreadable controls are skipped and reported.
    case optional
}

nonisolated struct SceneShortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: Int
    var modifiers: UInt
}

/// One desired setting inside a scene.
nonisolated struct SceneAction: Codable, Hashable, Sendable {
    var control: SceneControl
    var target: SceneValue
    var importance: SceneActionImportance

    init(control: SceneControl, target: SceneValue, importance: SceneActionImportance) {
        self.control = control
        self.target = target
        self.importance = importance
    }
}

/// A structural problem that makes a scene unsafe to apply.
nonisolated enum SceneValidationIssue: Error, Equatable, Sendable {
    case emptyName
    case noActions
    case duplicateControl(SceneControl)
    case valueKindMismatch(control: SceneControl, expected: SceneValueKind, found: SceneValueKind)
    case numberOutOfRange(control: SceneControl, value: Double)
    case emptyControlIdentifier(SceneControl)
    case emptyTargetText(SceneControl)
}

extension SceneValidationIssue: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Scene name cannot be empty."
        case .noActions:
            "A scene must contain at least one setting."
        case .duplicateControl:
            "A scene contains the same setting more than once."
        case .valueKindMismatch:
            "A scene setting has the wrong value type."
        case .numberOutOfRange:
            "A scene value must be between 0 and 1."
        case .emptyControlIdentifier:
            "A scene refers to a device without an identifier."
        case .emptyTargetText:
            "A scene refers to an empty device identifier."
        }
    }
}

/// A user-defined scene: a named set of settings applied together.
nonisolated struct SemperScene: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var actions: [SceneAction]
    var shortcut: SceneShortcut?

    init(
        id: UUID = UUID(),
        name: String,
        actions: [SceneAction],
        shortcut: SceneShortcut? = nil
    ) {
        self.id = id
        self.name = name
        self.actions = actions
        self.shortcut = shortcut
    }

    /// Actions sorted into the deterministic apply order. Restore always runs
    /// in the exact reverse of this order.
    var actionsInApplyOrder: [SceneAction] {
        actions.sorted { SceneControl.orderedBefore($0.control, $1.control) }
    }

    /// Rejects scenes that cannot apply deterministically: duplicate controls,
    /// wrongly typed or out-of-range targets, and empty identifiers.
    func validate() throws(SceneValidationIssue) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyName
        }
        guard !actions.isEmpty else {
            throw .noActions
        }
        var seenControls = Set<SceneControl>()
        for action in actions {
            guard seenControls.insert(action.control).inserted else {
                throw .duplicateControl(action.control)
            }
            if let identifier = action.control.deviceIdentifier, identifier.isEmpty {
                throw .emptyControlIdentifier(action.control)
            }
            let expected = action.control.valueKind
            guard action.target.kind == expected else {
                throw .valueKindMismatch(control: action.control, expected: expected, found: action.target.kind)
            }
            if case .number(let value) = action.target {
                guard value.isFinite, (0.0...1.0).contains(value) else {
                    throw .numberOutOfRange(control: action.control, value: value)
                }
            }
            if case .text(let text) = action.target, text.isEmpty {
                throw .emptyTargetText(action.control)
            }
        }
    }
}
