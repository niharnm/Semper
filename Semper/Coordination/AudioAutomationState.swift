import Foundation

struct AudioAutomationOwner: Hashable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
}

@MainActor
final class AudioModeOverlayStore {
    typealias AppIdentifier = String

    private var gainsByOwner: [AudioAutomationOwner: [AppIdentifier: Float]] = [:]
    var onChange: ((Set<AppIdentifier>) -> Void)?

    @discardableResult
    func setGain(
        _ multiplier: Float,
        for appIdentifier: AppIdentifier,
        owner: AudioAutomationOwner
    ) -> Bool {
        guard !appIdentifier.isEmpty,
              multiplier.isFinite,
              (0...1).contains(multiplier) else {
            return false
        }

        var ownerGains = gainsByOwner[owner, default: [:]]
        guard ownerGains[appIdentifier] != multiplier else { return true }
        ownerGains[appIdentifier] = multiplier
        gainsByOwner[owner] = ownerGains
        onChange?([appIdentifier])
        return true
    }

    func removeGain(for appIdentifier: AppIdentifier, owner: AudioAutomationOwner) {
        guard var ownerGains = gainsByOwner[owner],
              ownerGains.removeValue(forKey: appIdentifier) != nil else {
            return
        }
        gainsByOwner[owner] = ownerGains.isEmpty ? nil : ownerGains
        onChange?([appIdentifier])
    }

    func removeAll(for owner: AudioAutomationOwner) {
        guard let removed = gainsByOwner.removeValue(forKey: owner), !removed.isEmpty else {
            return
        }
        onChange?(Set(removed.keys))
    }

    func effectiveGain(for appIdentifier: AppIdentifier) -> Float {
        gainsByOwner.values.compactMap { $0[appIdentifier] }.min() ?? 1
    }
}

enum AudioControlKey: Hashable, Sendable {
    case appVolume(AudioAppCommandTarget)
    case appMute(AudioAppCommandTarget)
    case appBoost(AudioAppCommandTarget)
    case appDevice(AudioAppCommandTarget)
    case appDeviceMode(AudioAppCommandTarget)
    case appDevices(AudioAppCommandTarget)
    case outputVolume(String)
    case outputMasterGain(String)
    case outputMute(String)
    case outputBalance(String)
    case defaultOutput
    case inputVolume(String)
    case inputMute(String)
    case defaultInput
    case audioProcessingMode
}

enum AudioControlValue: Equatable, Sendable {
    case scalar(Float)
    case flag(Bool)
    case boost(BoostLevel)
    case identifier(String?)
    case identifiers(Set<String>)
    case mode(String)

    func matches(_ other: AudioControlValue, scalarTolerance: Float = 0.01) -> Bool {
        switch (self, other) {
        case (.scalar(let lhs), .scalar(let rhs)):
            abs(lhs - rhs) <= scalarTolerance
        default:
            self == other
        }
    }
}

struct AudioRecoveryToken: Hashable, Sendable {
    fileprivate let id: UUID
}

struct AudioRecoveryReport: Equatable, Sendable {
    var restored: [AudioControlKey] = []
    var skipped: [AudioControlKey] = []
    var failed: [AudioControlKey] = []
}

@MainActor
final class AudioAutomationRecoveryJournal {
    private struct Claim {
        var token: AudioRecoveryToken
        let owner: AudioAutomationOwner
        let key: AudioControlKey
        let original: AudioControlValue
        var applied: AudioControlValue?
    }

    private struct ClaimSnapshot {
        let claim: Claim?
        let orderedIndex: Int?
    }

    private var claimsByKey: [AudioControlKey: Claim] = [:]
    private var orderedKeys: [AudioControlKey] = []
    private var snapshotsByToken: [AudioRecoveryToken: ClaimSnapshot] = [:]

    func begin(
        owner: AudioAutomationOwner,
        key: AudioControlKey,
        original: AudioControlValue
    ) -> AudioRecoveryToken {
        let token = AudioRecoveryToken(id: UUID())
        let existing = claimsByKey[key]
        snapshotsByToken[token] = ClaimSnapshot(
            claim: existing,
            orderedIndex: orderedKeys.firstIndex(of: key)
        )

        if existing?.owner != owner {
            orderedKeys.removeAll { $0 == key }
            orderedKeys.append(key)
        }
        claimsByKey[key] = Claim(
            token: token,
            owner: owner,
            key: key,
            original: existing?.owner == owner ? existing?.original ?? original : original,
            applied: nil
        )
        return token
    }

    @discardableResult
    func confirm(_ token: AudioRecoveryToken, applied: AudioControlValue) -> Bool {
        guard let key = claimsByKey.first(where: { $0.value.token == token })?.key,
              var claim = claimsByKey[key], claim.token == token else {
            return false
        }
        claim.applied = applied
        claimsByKey[key] = claim
        if let snapshot = snapshotsByToken.removeValue(forKey: token),
           let previous = snapshot.claim {
            discardSnapshotChain(startingAt: previous.token)
        }
        return true
    }

    func cancel(_ token: AudioRecoveryToken) {
        guard let key = claimsByKey.first(where: { $0.value.token == token })?.key,
              claimsByKey[key]?.token == token else {
            return
        }
        claimsByKey[key] = nil
        orderedKeys.removeAll { $0 == key }
        if let snapshot = snapshotsByToken.removeValue(forKey: token),
           let previous = snapshot.claim {
            claimsByKey[key] = previous
            let insertionIndex = min(snapshot.orderedIndex ?? orderedKeys.endIndex, orderedKeys.endIndex)
            orderedKeys.insert(key, at: insertionIndex)
        }
    }

    func relinquish(_ key: AudioControlKey) {
        if let claim = claimsByKey[key] {
            discardSnapshotChain(startingAt: claim.token)
        }
        claimsByKey[key] = nil
        orderedKeys.removeAll { $0 == key }
    }

    private func discardSnapshotChain(startingAt token: AudioRecoveryToken) {
        var current: AudioRecoveryToken? = token
        while let token = current,
              let snapshot = snapshotsByToken.removeValue(forKey: token) {
            current = snapshot.claim?.token
        }
    }

    func restore(
        owner: AudioAutomationOwner,
        read: (AudioControlKey) -> AudioControlValue?,
        write: (AudioControlKey, AudioControlValue) -> Bool
    ) -> AudioRecoveryReport {
        var report = AudioRecoveryReport()
        let keys = orderedKeys.reversed().filter { claimsByKey[$0]?.owner == owner }

        for key in keys {
            guard let claim = claimsByKey[key], let applied = claim.applied else {
                report.skipped.append(key)
                continue
            }
            guard let current = read(key), applied.matches(current) else {
                report.skipped.append(key)
                relinquish(key)
                continue
            }
            if write(key, claim.original) {
                report.restored.append(key)
                relinquish(key)
            } else {
                report.failed.append(key)
            }
        }
        return report
    }
}

enum InputPolicyOwner: Int, Hashable, Sendable {
    case inputLock = 0
    case callMode = 100
    case bluetoothGuard = 200
    case explicitUser = 300
}

struct InputPolicyResolution: Equatable, Sendable {
    let deviceUID: String?
    let owner: InputPolicyOwner?
}

struct InputPolicyCoordinator: Sendable {
    private var requestedUIDs: [InputPolicyOwner: String] = [:]

    mutating func setRequest(deviceUID: String, owner: InputPolicyOwner) {
        guard !deviceUID.isEmpty else { return }
        requestedUIDs[owner] = deviceUID
    }

    mutating func removeRequest(owner: InputPolicyOwner) {
        requestedUIDs[owner] = nil
    }

    func resolve(availableUIDs: Set<String>, currentUID: String?) -> InputPolicyResolution {
        let selected = requestedUIDs
            .filter { availableUIDs.contains($0.value) }
            .max { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
        if let selected {
            return InputPolicyResolution(deviceUID: selected.value, owner: selected.key)
        }
        if let currentUID, availableUIDs.contains(currentUID) {
            return InputPolicyResolution(deviceUID: currentUID, owner: nil)
        }
        return InputPolicyResolution(deviceUID: nil, owner: nil)
    }
}

struct AudioActivityPresentation: Equatable, Sendable {
    let message: String
    let systemImage: String
    let actionTitle: String?

    init(message: String, systemImage: String = "waveform", actionTitle: String? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
    }
}

struct AudioActivity: Identifiable, Equatable, Sendable {
    let id: UUID
    let presentation: AudioActivityPresentation
    let source: AudioCommandSource
    let reason: AudioChangeReason
    let timestamp: Date
}

@Observable
@MainActor
final class AudioActivityStore {
    private(set) var visibleActivity: AudioActivity?
    private(set) var history: [AudioActivity] = []
    private var actions: [UUID: () -> Void] = [:]
    private let historyLimit: Int

    init(historyLimit: Int = 20) {
        self.historyLimit = max(1, historyLimit)
    }

    func record(
        presentation: AudioActivityPresentation,
        source: AudioCommandSource,
        reason: AudioChangeReason,
        action: (() -> Void)? = nil,
        at timestamp: Date = Date()
    ) {
        let activity = AudioActivity(
            id: UUID(),
            presentation: presentation,
            source: source,
            reason: reason,
            timestamp: timestamp
        )
        visibleActivity = activity
        history.append(activity)
        if history.count > historyLimit {
            let removalCount = history.count - historyLimit
            let removed = Array(history.prefix(removalCount))
            history.removeFirst(removalCount)
            for item in removed { actions[item.id] = nil }
        }
        if let action { actions[activity.id] = action }
    }

    func dismiss() {
        visibleActivity = nil
    }

    func performVisibleAction() {
        guard let id = visibleActivity?.id else { return }
        actions[id]?()
    }
}
