import Foundation
import Testing
@testable import Semper

@Suite("Audio undo")
@MainActor
struct AudioUndoTests {
    @Test("Undo restores the previous value once")
    func restoresOnce() {
        let key = AudioControlKey.outputVolume("speakers")
        let backend = UndoAudioCommandBackend(state: [key: .scalar(0.4)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "speakers", volume: 0.8),
            context: AudioCommandContext(source: .popup)
        )

        #expect(dispatcher.activityStore.visibleActivity?.presentation.actionTitle == "Undo")
        #expect(dispatcher.undoLastChange(source: .popup) == .restored)
        #expect(backend.state[key] == .scalar(0.4))
        #expect(dispatcher.undoLastChange(source: .popup) == .unavailable)
    }

    @Test("Slider samples keep the first value and latest confirmed value")
    func groupsSliderSamples() {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let target = AudioAppCommandTarget.persisted("music")
        let key = AudioControlKey.appVolume(target)
        let backend = UndoAudioCommandBackend(state: [key: .scalar(1)])
        let dispatcher = makeDispatcher(backend: backend, now: { currentTime })

        dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.8),
            context: AudioCommandContext(source: .popup)
        )
        currentTime.addTimeInterval(0.2)
        dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.5),
            context: AudioCommandContext(source: .popup)
        )
        currentTime.addTimeInterval(0.2)
        dispatcher.dispatch(
            .setAppVolume(target: target, volume: 0.25),
            context: AudioCommandContext(source: .popup)
        )

        #expect(dispatcher.undoLastChange(source: .popup) == .restored)
        #expect(backend.state[key] == .scalar(1))
        #expect(backend.appliedCommands.count == 4)
    }

    @Test("Held media key events form one transaction")
    func groupsMediaKeys() {
        var currentTime = Date(timeIntervalSince1970: 2_000)
        let key = AudioControlKey.outputVolume("speakers")
        let backend = UndoAudioCommandBackend(state: [key: .scalar(0.5)])
        let dispatcher = makeDispatcher(backend: backend, now: { currentTime })

        for volume: Float in [0.55, 0.6, 0.65] {
            dispatcher.dispatch(
                .setOutputVolume(deviceUID: "speakers", volume: volume),
                context: AudioCommandContext(source: .mediaKey, reason: .shortcut)
            )
            currentTime.addTimeInterval(0.1)
        }

        #expect(dispatcher.undoLastChange(source: .popup) == .restored)
        #expect(backend.state[key] == .scalar(0.5))
    }

    @Test("A shared transaction restores every affected control")
    func restoresSharedTransaction() {
        let transactionID = UUID()
        let volumeKey = AudioControlKey.outputVolume("speakers")
        let muteKey = AudioControlKey.outputMute("speakers")
        let backend = UndoAudioCommandBackend(state: [
            volumeKey: .scalar(0),
            muteKey: .flag(true),
        ])
        let dispatcher = AudioCommandDispatcher(backend: backend)
        let context = AudioCommandContext(
            source: .mediaKey,
            reason: .shortcut,
            transactionID: transactionID
        )

        dispatcher.dispatch(
            .setOutputMute(deviceUID: "speakers", muted: false),
            context: context
        )
        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "speakers", volume: 0.1),
            context: context
        )

        #expect(dispatcher.undoLastChange(source: .popup) == .restored)
        #expect(backend.state[volumeKey] == .scalar(0))
        #expect(backend.state[muteKey] == .flag(true))
    }

    @Test("A later unrelated change replaces the active transaction")
    func replacesTransaction() {
        let firstKey = AudioControlKey.outputVolume("speakers")
        let secondKey = AudioControlKey.inputMute("microphone")
        let backend = UndoAudioCommandBackend(state: [
            firstKey: .scalar(0.4),
            secondKey: .flag(false),
        ])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "speakers", volume: 0.7),
            context: AudioCommandContext(source: .popup)
        )
        dispatcher.dispatch(
            .setInputMute(deviceUID: "microphone", muted: true),
            context: AudioCommandContext(source: .popup)
        )

        #expect(dispatcher.undoLastChange(source: .popup) == .restored)
        #expect(backend.state[firstKey] == .scalar(0.7))
        #expect(backend.state[secondKey] == .flag(false))
    }

    @Test("Undo expires 30 seconds after the latest grouped change")
    func expires() {
        var currentTime = Date(timeIntervalSince1970: 3_000)
        let key = AudioControlKey.outputVolume("speakers")
        let backend = UndoAudioCommandBackend(state: [key: .scalar(0.4)])
        let dispatcher = makeDispatcher(backend: backend, now: { currentTime })

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "speakers", volume: 0.7),
            context: AudioCommandContext(source: .popup)
        )
        currentTime.addTimeInterval(29.9)
        dispatcher.expireUndoIfNeeded(at: currentTime)
        #expect(dispatcher.activityStore.visibleActivity?.presentation.actionTitle == "Undo")

        currentTime.addTimeInterval(0.1)
        dispatcher.expireUndoIfNeeded(at: currentTime)
        #expect(dispatcher.activityStore.visibleActivity?.presentation.actionTitle == nil)
        #expect(dispatcher.undoLastChange(source: .popup) == .unavailable)
    }

    @Test("Stale state prevents every write in a grouped undo")
    func staleStateIsAtomic() {
        let transactionID = UUID()
        let volumeKey = AudioControlKey.outputVolume("speakers")
        let muteKey = AudioControlKey.outputMute("speakers")
        let backend = UndoAudioCommandBackend(state: [
            volumeKey: .scalar(0.4),
            muteKey: .flag(false),
        ])
        let dispatcher = AudioCommandDispatcher(backend: backend)
        let context = AudioCommandContext(source: .popup, transactionID: transactionID)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "speakers", volume: 0.7),
            context: context
        )
        dispatcher.dispatch(
            .setOutputMute(deviceUID: "speakers", muted: true),
            context: context
        )
        let writesBeforeUndo = backend.appliedCommands.count
        backend.state[volumeKey] = .scalar(0.2)

        #expect(dispatcher.undoLastChange(source: .popup) == .stale)
        #expect(backend.appliedCommands.count == writesBeforeUndo)
        #expect(backend.state[muteKey] == .flag(true))
        #expect(dispatcher.activityStore.visibleActivity?.presentation.message
            == "Can’t undo because the audio setting changed again")
    }

    @Test("Accepted changes become undoable only after confirmation")
    func acceptedConfirmation() {
        let key = AudioControlKey.outputVolume("display")
        let backend = UndoAudioCommandBackend(state: [key: .scalar(0.8)])
        let dispatcher = AudioCommandDispatcher(backend: backend)
        backend.nextResult = .accepted

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "display", volume: 0.4),
            context: AudioCommandContext(source: .popup)
        )
        #expect(dispatcher.undoLastChange(source: .popup) == .unavailable)

        backend.state[key] = .scalar(0.4)
        #expect(dispatcher.completeAccepted(key, observed: .scalar(0.4)))
        #expect(dispatcher.undoLastChange(source: .popup) == .restored)
        #expect(backend.state[key] == .scalar(0.8))
    }

    @Test("Rejected commands do not replace an available undo")
    func rejectedDoesNotReplace() {
        let key = AudioControlKey.outputVolume("speakers")
        let backend = UndoAudioCommandBackend(state: [key: .scalar(0.4)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "speakers", volume: 0.7),
            context: AudioCommandContext(source: .popup)
        )
        backend.nextResult = .rejected(.writeFailed)
        dispatcher.dispatch(
            .setInputMute(deviceUID: "microphone", muted: true),
            context: AudioCommandContext(source: .popup)
        )

        #expect(dispatcher.undoLastChange(source: .popup) == .restored)
        #expect(backend.state[key] == .scalar(0.4))
    }

    @Test("Automatic changes explain their cause and offer undo")
    func automaticExplanation() {
        let key = AudioControlKey.outputVolume("speakers")
        let backend = UndoAudioCommandBackend(state: [key: .scalar(0.8)])
        let dispatcher = AudioCommandDispatcher(backend: backend)

        dispatcher.dispatch(
            .setOutputVolume(deviceUID: "speakers", volume: 0.5),
            context: AudioCommandContext(source: .automation, reason: .safeCap)
        )

        #expect(dispatcher.activityStore.visibleActivity?.presentation.message
            == "Volume lowered to respect this device’s limit")
        #expect(dispatcher.activityStore.visibleActivity?.presentation.actionTitle == "Undo")
    }

    @Test("Default input undo preserves the original selection intent")
    func inputIntent() {
        let command = AudioCommand.setDefaultInput(
            deviceUID: "new-microphone",
            intent: .userPreference
        )

        #expect(
            command.restoring(.identifier("old-microphone"))
                == .setDefaultInput(deviceUID: "old-microphone", intent: .userPreference)
        )
        #expect(command.restoring(.identifier(nil)) == nil)
    }

    private func makeDispatcher(
        backend: UndoAudioCommandBackend,
        now: @escaping () -> Date
    ) -> AudioCommandDispatcher {
        AudioCommandDispatcher(
            backend: backend,
            undoJournal: AudioUndoJournal(lifetime: 30, groupingWindow: 0.8),
            undoLifetime: 30,
            now: now
        )
    }
}

@MainActor
private final class UndoAudioCommandBackend: AudioCommandBackend {
    var state: [AudioControlKey: AudioControlValue]
    var nextResult: AudioBackendApplyResult?
    private(set) var appliedCommands: [AudioCommand] = []

    init(state: [AudioControlKey: AudioControlValue]) {
        self.state = state
    }

    func read(_ key: AudioControlKey) -> AudioControlValue? {
        state[key]
    }

    func apply(_ command: AudioCommand) -> AudioBackendApplyResult {
        appliedCommands.append(command)
        if let nextResult {
            self.nextResult = nil
            if case .applied(let observed) = nextResult {
                state[command.controlKey] = observed
            }
            return nextResult
        }
        state[command.controlKey] = command.requestedValue
        return .applied(command.requestedValue)
    }
}
