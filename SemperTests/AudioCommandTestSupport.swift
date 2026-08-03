import Foundation
@testable import Semper

@MainActor
final class RecordingAudioCommandSink: AudioCommandDispatching {
    private(set) var calls: [(command: AudioCommand, context: AudioCommandContext)] = []
    var onDispatch: ((AudioCommand) -> Void)?

    @discardableResult
    func dispatch(_ command: AudioCommand, context: AudioCommandContext) -> AudioCommandResult {
        calls.append((command, context))
        onDispatch?(command)
        let receipt = AudioCommandReceipt(
            command: command,
            context: context,
            previousValue: nil,
            observedValue: command.requestedValue,
            recoveryToken: nil,
            timestamp: Date()
        )
        return .applied(receipt)
    }
}
