import Foundation

enum AudioUndoResult: Equatable, Sendable {
    case restored
    case unavailable
    case stale
    case failed
}

struct AudioUndoRecordUpdate: Equatable, Sendable {
    let transactionID: UUID
    let replacedActivityID: UUID?
}

struct AudioUndoEntry: Equatable, Sendable {
    let key: AudioControlKey
    var command: AudioCommand
    let originalValue: AudioControlValue
    var appliedValue: AudioControlValue
}

enum AudioUndoPreparation: Equatable, Sendable {
    case ready(entries: [AudioUndoEntry], activityID: UUID?)
    case unavailable(expiredActivityID: UUID?)
    case stale(activityID: UUID?)
}

@MainActor
final class AudioUndoJournal {
    private enum ContinuousGroup: Hashable {
        case appLevel(AudioAppCommandTarget)
        case outputLevel(String)
        case inputLevel(String)
    }

    private struct Transaction {
        let id: UUID
        var lastContextTransactionID: UUID
        var lastSource: AudioCommandSource
        var continuousGroup: ContinuousGroup?
        var lastUpdatedAt: Date
        var expiresAt: Date
        var entriesByKey: [AudioControlKey: AudioUndoEntry]
        var orderedKeys: [AudioControlKey]
        var activityID: UUID?
    }

    private var transaction: Transaction?
    private let lifetime: TimeInterval
    private let groupingWindow: TimeInterval

    init(lifetime: TimeInterval = 30, groupingWindow: TimeInterval = 0.8) {
        self.lifetime = max(0.1, lifetime)
        self.groupingWindow = max(0, groupingWindow)
    }

    func record(
        _ receipt: AudioCommandReceipt,
        at timestamp: Date
    ) -> AudioUndoRecordUpdate? {
        guard receipt.context.reason != .undo,
              receipt.command.isUndoEligible,
              let original = receipt.previousValue,
              let applied = receipt.observedValue,
              !original.matches(applied),
              receipt.command.restoring(original) != nil else {
            return nil
        }

        let entry = AudioUndoEntry(
            key: receipt.command.controlKey,
            command: receipt.command,
            originalValue: original,
            appliedValue: applied
        )
        let continuousGroup = Self.continuousGroup(for: receipt.command)
        let shouldAppend = shouldAppend(
            receipt: receipt,
            group: continuousGroup,
            timestamp: timestamp
        )

        if shouldAppend, var current = transaction {
            if var existing = current.entriesByKey[entry.key] {
                existing.command = entry.command
                existing.appliedValue = entry.appliedValue
                current.entriesByKey[entry.key] = existing
            } else {
                current.entriesByKey[entry.key] = entry
                current.orderedKeys.append(entry.key)
            }
            current.lastContextTransactionID = receipt.context.transactionID
            current.lastSource = receipt.context.source
            current.continuousGroup = continuousGroup ?? current.continuousGroup
            current.lastUpdatedAt = timestamp
            current.expiresAt = timestamp.addingTimeInterval(lifetime)
            transaction = current
            return AudioUndoRecordUpdate(
                transactionID: current.id,
                replacedActivityID: current.activityID
            )
        }

        let replacedActivityID = transaction?.activityID
        let id = UUID()
        transaction = Transaction(
            id: id,
            lastContextTransactionID: receipt.context.transactionID,
            lastSource: receipt.context.source,
            continuousGroup: continuousGroup,
            lastUpdatedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(lifetime),
            entriesByKey: [entry.key: entry],
            orderedKeys: [entry.key],
            activityID: nil
        )
        return AudioUndoRecordUpdate(
            transactionID: id,
            replacedActivityID: replacedActivityID
        )
    }

    func attachActivity(_ activityID: UUID, to transactionID: UUID) {
        guard transaction?.id == transactionID else { return }
        transaction?.activityID = activityID
    }

    func prepare(
        at timestamp: Date,
        read: (AudioControlKey) -> AudioControlValue?
    ) -> AudioUndoPreparation {
        guard let current = transaction else {
            return .unavailable(expiredActivityID: nil)
        }
        guard timestamp < current.expiresAt else {
            transaction = nil
            return .unavailable(expiredActivityID: current.activityID)
        }
        for key in current.orderedKeys {
            guard let entry = current.entriesByKey[key],
                  let observed = read(key),
                  entry.appliedValue.matches(observed) else {
                transaction = nil
                return .stale(activityID: current.activityID)
            }
        }

        transaction = nil
        return .ready(
            entries: current.orderedKeys.reversed().compactMap { current.entriesByKey[$0] },
            activityID: current.activityID
        )
    }

    func expire(at timestamp: Date) -> UUID? {
        guard let current = transaction,
              timestamp >= current.expiresAt else { return nil }
        transaction = nil
        return current.activityID
    }

    @discardableResult
    func clear() -> UUID? {
        defer { transaction = nil }
        return transaction?.activityID
    }

    private func shouldAppend(
        receipt: AudioCommandReceipt,
        group: ContinuousGroup?,
        timestamp: Date
    ) -> Bool {
        guard let current = transaction,
              timestamp < current.expiresAt else { return false }
        if receipt.context.transactionID == current.lastContextTransactionID {
            return true
        }
        guard let group,
              group == current.continuousGroup,
              receipt.context.source == current.lastSource,
              Self.isContinuous(receipt.context.source) else {
            return false
        }
        let elapsed = timestamp.timeIntervalSince(current.lastUpdatedAt)
        return elapsed >= 0 && elapsed <= groupingWindow
    }

    private static func isContinuous(_ source: AudioCommandSource) -> Bool {
        switch source {
        case .popup, .popupKeyboard, .hud, .mediaKey, .globalShortcut:
            true
        case .url, .appIntent, .automation, .recovery, .system:
            false
        }
    }

    private static func continuousGroup(for command: AudioCommand) -> ContinuousGroup? {
        switch command {
        case .setAppVolume(let target, _), .setAppMute(let target, _):
            .appLevel(target)
        case .setOutputVolume(let uid, _),
             .setOutputMasterGain(let uid, _),
             .setOutputMute(let uid, _):
            .outputLevel(uid)
        case .setInputVolume(let uid, _), .setInputMute(let uid, _):
            .inputLevel(uid)
        default:
            nil
        }
    }
}

extension AudioCommand {
    var isUndoEligible: Bool {
        switch self {
        case .setAudioProcessingMode:
            false
        default:
            true
        }
    }

    func restoring(_ value: AudioControlValue) -> AudioCommand? {
        switch (self, value) {
        case (.setAppVolume(let target, _), .scalar(let volume)):
            return .setAppVolume(target: target, volume: volume)
        case (.setAppMute(let target, _), .flag(let muted)):
            return .setAppMute(target: target, muted: muted)
        case (.setAppBoost(let target, _), .boost(let boost)):
            return .setAppBoost(target: target, boost: boost)
        case (.setAppDevice(let target, _), .identifier(let uid)):
            return .setAppDevice(target: target, deviceUID: uid)
        case (.setAppDeviceMode(let target, _), .mode(let rawValue)):
            guard let mode = DeviceSelectionMode(rawValue: rawValue) else { return nil }
            return .setAppDeviceMode(target: target, mode: mode)
        case (.setAppDevices(let target, _), .identifiers(let uids)):
            return .setAppDevices(target: target, deviceUIDs: uids)
        case (.setOutputVolume(let uid, _), .scalar(let volume)):
            return .setOutputVolume(deviceUID: uid, volume: volume)
        case (.setOutputMasterGain(let uid, _), .scalar(let gain)):
            return .setOutputMasterGain(deviceUID: uid, gain: gain)
        case (.setOutputMute(let uid, _), .flag(let muted)):
            return .setOutputMute(deviceUID: uid, muted: muted)
        case (.setOutputBalance(let uid, _), .scalar(let balance)):
            return .setOutputBalance(deviceUID: uid, balance: balance)
        case (.setDefaultOutput, .identifier(let uid)):
            guard let uid else { return nil }
            return .setDefaultOutput(deviceUID: uid)
        case (.setInputVolume(let uid, _), .scalar(let volume)):
            return .setInputVolume(deviceUID: uid, volume: volume)
        case (.setInputMute(let uid, _), .flag(let muted)):
            return .setInputMute(deviceUID: uid, muted: muted)
        case (.setDefaultInput(_, let intent), .identifier(let uid)):
            guard let uid else { return nil }
            return .setDefaultInput(deviceUID: uid, intent: intent)
        case (.setAudioProcessingMode, .mode(let rawValue)):
            guard let mode = AudioProcessingMode(rawValue: rawValue) else { return nil }
            return .setAudioProcessingMode(mode)
        default:
            return nil
        }
    }
}
