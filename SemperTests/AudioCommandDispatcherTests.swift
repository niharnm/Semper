import Foundation
import Testing
@testable import Semper

@Suite("AudioCommandDispatcher")
@MainActor
struct AudioCommandDispatcherTests {
    @Test("Applied result includes source, reason, values, and transaction")
    func appliedReceipt() {
        let target = AudioAppCommandTarget.persisted("com.test.app")
        let key = AudioControlKey.appVolume(target)
        let backend = StubAudioCommandBackend(state: [key: .scalar(0.5)])
        let dispatcher = AudioCommandDispatcher(backend: backend)
        let transactionID = UUID()
        let context = AudioCommandContext(
            source: .globalShortcut,
            reason: .shortcut,
            transactionID: transactionID
        )

        let result = dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.75),
            context: context
        )

        guard case .applied(let receipt) = result else {
            Issue.record("Expected applied result")
            return
        }
        #expect(receipt.previousValue == .scalar(0.5))
        #expect(receipt.observedValue == .scalar(0.75))
        #expect(receipt.context.source == .globalShortcut)
        #expect(receipt.context.reason == .shortcut)
        #expect(receipt.context.transactionID == transactionID)
    }

    @Test("Equal requested value is unchanged and does not call backend")
    func unchanged() {
        let target = AudioAppCommandTarget.persisted("com.test.app")
        let key = AudioControlKey.appMute(target)
        let backend = StubAudioCommandBackend(state: [key: .flag(true)])
        let activityStore = AudioActivityStore()
        let dispatcher = AudioCommandDispatcher(backend: backend, activityStore: activityStore)

        let result = dispatcher.dispatch(
            .setAppMute(target: target, muted: true),
            context: AudioCommandContext(
                source: .popup,
                presentation: AudioActivityPresentation(message: "Muted")
            )
        )

        guard case .unchanged = result else {
            Issue.record("Expected unchanged result")
            return
        }
        #expect(backend.appliedCommands.isEmpty)
        #expect(activityStore.visibleActivity == nil)
    }

    @Test("Shortcut reason records a default popup status")
    func shortcutStatusPresentation() {
        let target = AudioAppCommandTarget.persisted("com.test.app")
        let key = AudioControlKey.appMute(target)
        let backend = StubAudioCommandBackend(state: [key: .flag(false)])
        let activityStore = AudioActivityStore()
        let dispatcher = AudioCommandDispatcher(backend: backend, activityStore: activityStore)

        dispatcher.dispatch(
            .setAppMute(target: target, muted: true),
            context: AudioCommandContext(source: .globalShortcut, reason: .shortcut)
        )

        #expect(activityStore.visibleActivity?.presentation.message == "Keyboard shortcut app muted")
        #expect(activityStore.visibleActivity?.source == .globalShortcut)
    }

    @Test("Accepted result keeps a pending recovery token")
    func acceptedRecovery() {
        let owner = AudioAutomationOwner(rawValue: "call-mode")
        let target = AudioAppCommandTarget.persisted("com.test.app")
        let key = AudioControlKey.appDevice(target)
        let backend = StubAudioCommandBackend(state: [key: .identifier("old")])
        backend.nextResult = .accepted
        let dispatcher = AudioCommandDispatcher(backend: backend)

        let result = dispatcher.dispatch(
            .setAppDevice(target: target, deviceUID: "new"),
            context: AudioCommandContext(source: .automation, owner: owner)
        )

        guard case .accepted(let receipt) = result else {
            Issue.record("Expected accepted result")
            return
        }
        #expect(receipt.recoveryToken != nil)
        #expect(receipt.observedValue == nil)
    }

    @Test("Accepted completion uses the backend effective value")
    func acceptedEffectiveValue() {
        let key = AudioControlKey.outputVolume("headphones")
        let backend = StubAudioCommandBackend(state: [key: .scalar(0.8)])
        backend.effectiveValues[key] = .scalar(0.4)
        backend.nextResult = .accepted
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "headphones", volume: 0.9),
            context: AudioCommandContext(source: .popup)
        )

        #expect(dispatcher.completeAccepted(key, observed: .scalar(0.4)))
    }

    @Test("Rejected command cancels its recovery claim")
    func rejectedCancelsRecovery() {
        let owner = AudioAutomationOwner(rawValue: "guard")
        let key = AudioControlKey.inputMute("mic")
        let backend = StubAudioCommandBackend(state: [key: .flag(false)])
        backend.nextResult = .rejected(.writeFailed)
        let dispatcher = AudioCommandDispatcher(backend: backend)

        let result = dispatcher.dispatch(
            .setInputMute(deviceUID: "mic", muted: true),
            context: AudioCommandContext(source: .automation, owner: owner)
        )

        #expect(result == .rejected(.writeFailed))
        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { backend.read($0) },
            write: { _, _ in true }
        )
        #expect(report == AudioRecoveryReport())
    }

    @Test("Invalid scalar is rejected before backend application")
    func invalidValue() {
        let backend = StubAudioCommandBackend()
        let dispatcher = AudioCommandDispatcher(backend: backend)

        let result = dispatcher.dispatch(
            .setAppVolume(target: .persisted("com.test.app"), volume: .nan),
            context: AudioCommandContext(source: .url)
        )

        #expect(result == .rejected(.invalidValue))
        #expect(backend.appliedCommands.isEmpty)
    }

    @Test("Direct user command relinquishes an automation claim")
    func directUserRelinquishesClaim() {
        let owner = AudioAutomationOwner(rawValue: "call-mode")
        let target = AudioAppCommandTarget.persisted("com.test.app")
        let key = AudioControlKey.appVolume(target)
        let backend = StubAudioCommandBackend(state: [key: .scalar(1)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.25),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.5),
            context: AudioCommandContext(source: .popup)
        )

        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { backend.read($0) },
            write: { _, _ in true }
        )
        #expect(report == AudioRecoveryReport())
    }

    @Test("Quantized same-value user action relinquishes an automation claim")
    func sameValueUserTakeover() {
        let owner = AudioAutomationOwner(rawValue: "call-mode")
        let target = AudioAppCommandTarget.persisted("com.test.app")
        let key = AudioControlKey.appVolume(target)
        let backend = StubAudioCommandBackend(state: [key: .scalar(1)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.25),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        let result = dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.255),
            context: AudioCommandContext(source: .popup)
        )

        guard case .unchanged = result else {
            Issue.record("Expected unchanged result")
            return
        }
        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { backend.read($0) },
            write: { _, _ in true }
        )
        #expect(report == AudioRecoveryReport())
    }

    @Test("Rejected user action preserves an automation claim")
    func rejectedUserActionPreservesClaim() {
        let owner = AudioAutomationOwner(rawValue: "call-mode")
        let target = AudioAppCommandTarget.persisted("com.test.app")
        let key = AudioControlKey.appVolume(target)
        let backend = StubAudioCommandBackend(state: [key: .scalar(1)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.25),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        backend.nextResult = .rejected(.writeFailed)
        let rejected = dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.5),
            context: AudioCommandContext(source: .popup)
        )
        #expect(rejected == .rejected(.writeFailed))

        var current = AudioControlValue.scalar(0.25)
        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )
        #expect(report.restored == [key])
        #expect(current == .scalar(1))
    }

    @Test("Accepted command confirms recovery after observed completion")
    func acceptedCompletion() {
        let owner = AudioAutomationOwner(rawValue: "guard")
        let key = AudioControlKey.outputVolume("display")
        let backend = StubAudioCommandBackend(state: [key: .scalar(0.8)])
        backend.nextResult = .accepted
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.4),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        #expect(dispatcher.completeAccepted(key, observed: .scalar(0.4)))
        backend.state[key] = .scalar(0.4)

        var current = AudioControlValue.scalar(0.4)
        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )
        #expect(report.restored == [key])
        #expect(current == .scalar(0.8))
    }

    @Test("Repeated accepted commands retain the first recovery value")
    func repeatedAcceptedRecovery() {
        let owner = AudioAutomationOwner(rawValue: "guard")
        let key = AudioControlKey.outputVolume("display")
        let backend = StubAudioCommandBackend(state: [key: .scalar(0.8)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.6),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.4),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        #expect(dispatcher.completeAccepted(key, observed: .scalar(0.4)))

        var current = AudioControlValue.scalar(0.4)
        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )
        #expect(report.restored == [key])
        #expect(current == .scalar(0.8))
    }

    @Test("Failed replacement keeps a completed predecessor recoverable")
    func failedAcceptedReplacement() {
        let owner = AudioAutomationOwner(rawValue: "guard")
        let key = AudioControlKey.outputVolume("display")
        let backend = StubAudioCommandBackend(state: [key: .scalar(0.8)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.6),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.4),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        backend.state[key] = .scalar(0.6)
        dispatcher.rejectAccepted(key)

        var current = AudioControlValue.scalar(0.6)
        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )
        #expect(report.restored == [key])
        #expect(current == .scalar(0.8))
    }

    @Test("Failed direct accepted command preserves automation ownership")
    func failedDirectAcceptedPreservesClaim() {
        let owner = AudioAutomationOwner(rawValue: "call-mode")
        let key = AudioControlKey.outputVolume("display")
        let backend = StubAudioCommandBackend(state: [key: .scalar(0.8)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.4),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.6),
            context: AudioCommandContext(source: .popup)
        )
        backend.state[key] = .scalar(0.4)
        dispatcher.rejectAccepted(key)

        var current = AudioControlValue.scalar(0.4)
        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )
        #expect(report.restored == [key])
        #expect(current == .scalar(0.8))
    }

    @Test("Successful direct accepted command relinquishes automation ownership")
    func successfulDirectAcceptedRelinquishesClaim() {
        let owner = AudioAutomationOwner(rawValue: "call-mode")
        let key = AudioControlKey.outputVolume("display")
        let backend = StubAudioCommandBackend(state: [key: .scalar(0.8)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.4),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.6),
            context: AudioCommandContext(source: .popup)
        )
        #expect(dispatcher.completeAccepted(key, observed: .scalar(0.6)))

        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { backend.read($0) },
            write: { _, _ in true }
        )
        #expect(report == AudioRecoveryReport())
    }

    @Test("Completed predecessor relinquishes aliased automation ownership")
    func completedPredecessorRelinquishesAliasClaim() {
        let owner = AudioAutomationOwner(rawValue: "guard")
        let key = AudioControlKey.outputVolume("display")
        let aliasKey = AudioControlKey.outputMasterGain("display")
        let backend = StubAudioCommandBackend(state: [
            key: .scalar(0.8),
            aliasKey: .scalar(0.8),
        ])
        backend.recoveryAliases[key] = [aliasKey]
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputMasterGain(deviceUID: "display", gain: 0.4),
            context: AudioCommandContext(source: .automation, owner: owner)
        )
        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.6),
            context: AudioCommandContext(source: .popup)
        )
        backend.nextResult = .accepted
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.4),
            context: AudioCommandContext(source: .popup)
        )
        backend.state[key] = .scalar(0.6)
        dispatcher.rejectAccepted(key)

        let report = dispatcher.recoveryJournal.restore(
            owner: owner,
            read: { backend.read($0) },
            write: { _, _ in true }
        )
        #expect(report == AudioRecoveryReport())
    }
}

@MainActor
private final class StubAudioCommandBackend: AudioCommandBackend {
    var state: [AudioControlKey: AudioControlValue]
    var nextResult: AudioBackendApplyResult?
    var recoveryAliases: [AudioControlKey: Set<AudioControlKey>] = [:]
    var effectiveValues: [AudioControlKey: AudioControlValue] = [:]
    private(set) var appliedCommands: [AudioCommand] = []

    init(state: [AudioControlKey: AudioControlValue] = [:]) {
        self.state = state
    }

    func read(_ key: AudioControlKey) -> AudioControlValue? {
        state[key]
    }

    func apply(_ command: AudioCommand) -> AudioBackendApplyResult {
        appliedCommands.append(command)
        if let nextResult {
            self.nextResult = nil
            if nextResult == .accepted {
                state[command.controlKey] = command.requestedValue
            }
            return nextResult
        }
        state[command.controlKey] = command.requestedValue
        return .applied(command.requestedValue)
    }

    func recoveryAliasKeys(for command: AudioCommand) -> Set<AudioControlKey> {
        recoveryAliases[command.controlKey] ?? []
    }

    func effectiveRequestedValue(for command: AudioCommand) -> AudioControlValue {
        effectiveValues[command.controlKey] ?? command.requestedValue
    }
}
