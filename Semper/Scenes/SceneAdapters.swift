// Semper/Scenes/SceneAdapters.swift
import Foundation

/// What an adapter can do with a control right now.
///
/// Scenes journal a snapshot before every write and confirm every write by
/// reading back, so only `readWrite` controls participate. Write-only
/// controls (for example DDC codes a monitor accepts but never reports) are
/// excluded here rather than special-cased in the coordinator.
nonisolated enum SceneControlCapability: String, Codable, Sendable {
    case readWrite
    case readOnly
    case writeOnly
    case unsupported

    var isSceneEligible: Bool {
        self == .readWrite
    }
}

nonisolated enum SceneTargetPreflight: Equatable, Sendable {
    case ready
    case unavailable(String)
}

/// A control that must be part of the same scene before another control can
/// be changed without an untracked hardware write.
nonisolated struct SceneControlPrerequisite: Equatable, Sendable {
    let control: SceneControl
}

/// Seam between the scene coordinator and real hardware services.
///
/// Adapters translate `SceneControl` cases into CoreAudio, DDC, or power
/// assertion calls. Implementations must be side-effect free for
/// `capability(for:)` and `readValue(for:)`; only `writeValue` mutates.
nonisolated protocol SceneControlAdapting: Sendable {
    @MainActor
    func capability(for control: SceneControl) async -> SceneControlCapability
    @MainActor
    func preflightTarget(_ value: SceneValue, for control: SceneControl) async -> SceneTargetPreflight
    @MainActor
    func prerequisites(
        of value: SceneValue,
        for control: SceneControl
    ) async -> [SceneControlPrerequisite]
    @MainActor
    func restorationValue(
        for snapshot: SceneValue,
        control: SceneControl
    ) async -> SceneValue
    @MainActor
    func readValue(for control: SceneControl) async throws -> SceneValue
    @MainActor
    func writeValue(_ value: SceneValue, for control: SceneControl) async throws
}

extension SceneControlAdapting {
    @MainActor
    func preflightTarget(_ value: SceneValue, for control: SceneControl) async -> SceneTargetPreflight {
        .ready
    }

    @MainActor
    func prerequisites(
        of value: SceneValue,
        for control: SceneControl
    ) async -> [SceneControlPrerequisite] {
        []
    }

    @MainActor
    func restorationValue(
        for snapshot: SceneValue,
        control: SceneControl
    ) async -> SceneValue {
        snapshot
    }
}

/// Routes each control to the adapter owning its domain.
nonisolated struct SceneAdapterRegistry: Sendable {
    let audio: any SceneControlAdapting
    let display: any SceneControlAdapting
    let power: any SceneControlAdapting

    init(
        audio: any SceneControlAdapting,
        display: any SceneControlAdapting,
        power: any SceneControlAdapting
    ) {
        self.audio = audio
        self.display = display
        self.power = power
    }

    func adapter(for control: SceneControl) -> any SceneControlAdapting {
        switch control.domain {
        case .audio: audio
        case .display: display
        case .power: power
        }
    }
}
