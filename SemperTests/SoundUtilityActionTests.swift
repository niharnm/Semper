import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Sound utility actions")
struct SoundUtilityActionTests {
    @Test("Registration and cold availability do not start Sound or dispatch commands")
    func coldAvailabilityHasNoEffects() async throws {
        try await withCenter { center, probe in
            #expect(probe.outputReads == 0)
            #expect(
                center.registry.search("sound").map(\.id) == [SoundUtilityActions.muteID, SoundUtilityActions.unmuteID])
            #expect(center.disabledReason(for: SoundUtilityActions.muteID) == nil)
            #expect(center.disabledReason(for: SoundUtilityActions.unmuteID) == nil)
            #expect(probe.startCalls == 0)
            #expect(probe.commands.isEmpty)
            #expect(probe.output == .stopped)
        }
    }

    @Test("Mute and unmute dispatch the current output with popup context", arguments: [true, false])
    func typedCommand(muted: Bool) async throws {
        try await withCenter { center, probe in
            probe.output = .available(deviceUID: "current-output", muted: !muted)

            #expect(await center.execute(actionID(muted)) == .completed)

            let call = try #require(probe.commands.first)
            #expect(probe.commands.count == 1)
            #expect(call.command == .setOutputMute(deviceUID: "current-output", muted: muted))
            #expect(call.context.source == .popup)
            #expect(call.context.reason == .directUser)
            #expect(call.context.owner == nil)
            #expect(call.context.presentation == nil)
            #expect(probe.startCalls == 0)
        }
    }

    @Test(
        "Accepted audio requests stay distinct from completed changes",
        arguments: [
            SoundActionReply.applied, .accepted, .unchanged,
        ])
    func commandOutcomes(reply: SoundActionReply) async throws {
        try await withCenter { center, probe in
            probe.output = .available(deviceUID: "output", muted: false)
            probe.reply = reply

            let result = await center.execute(SoundUtilityActions.muteID)

            #expect(result == (reply == .accepted ? .accepted : .completed))
            #expect(center.lastResult == result)
            #expect(probe.commands.count == 1)
        }
    }

    @Test(
        "Cancellation at dispatch completion preserves the audio outcome and history",
        arguments: [SoundActionReply.applied, .unchanged, .accepted])
    func dispatchCompletionCancellation(reply: SoundActionReply) async throws {
        try await withCenter { center, probe in
            probe.output = .available(deviceUID: "output", muted: false)
            probe.reply = reply
            probe.cancelAtDispatchCompletion = true

            let expected: UtilityCommandResult = reply == .accepted ? .accepted : .completed
            #expect(await center.execute(SoundUtilityActions.muteID) == expected)
            #expect(probe.commands.count == 1)
            #expect(probe.observedDispatchCancellation)
            #expect(center.lastResult == expected)
            #expect(center.recentActions.map(\.actionID) == [SoundUtilityActions.muteID])
            #expect(center.recentActions.map(\.result) == [reply == .accepted ? .accepted : .completed])
            #expect(center.running.isEmpty)
        }
    }

    @Test(
        "Audio rejections retain the existing explicit failure text",
        arguments: [
            SoundActionRejection(.invalidValue, "The shortcut contains an invalid value."),
            SoundActionRejection(
                .appUnavailable("app"), "The app with identifier app is no longer available in Semper."),
            SoundActionRejection(.deviceUnavailable("output"), "The output with UID output is disconnected."),
            SoundActionRejection(
                .permissionDenied, "Allow System Audio Recording for Semper, then run this shortcut again."),
            SoundActionRejection(
                .unsupportedRoute("Mute is unavailable on this output."), "Mute is unavailable on this output."),
            SoundActionRejection(.sceneOperationInProgress, "Semper could not apply the audio change."),
            SoundActionRejection(
                .mutationAdmissionDenied(.exclusivePermitActive(owner: .awayMode)),
                "Sound controls are unavailable while Away Mode is active."),
            SoundActionRejection(.writeFailed, "Semper could not apply the audio change."),
        ])
    func rejectedCommand(fixture: SoundActionRejection) async throws {
        try await withCenter { center, probe in
            probe.output = .available(deviceUID: "output", muted: false)
            probe.reply = .rejected(fixture.rejection)

            #expect(await center.execute(SoundUtilityActions.muteID) == .failed(fixture.message))
            #expect(probe.commands.count == 1)
            #expect(probe.startCalls == 0)
        }
    }

    @Test(
        "Known missing and unsupported output reasons block both actions",
        arguments: [
            "No output device is available.", "This output does not support mute control.",
        ])
    func unavailableOutput(reason: String) async throws {
        try await withCenter { center, probe in
            probe.output = .unavailable(reason)

            for id in [SoundUtilityActions.muteID, SoundUtilityActions.unmuteID] {
                #expect(center.disabledReason(for: id) == reason)
                #expect(await center.execute(id) == .unavailable(reason))
            }
            #expect(probe.startCalls == 0)
            #expect(probe.commands.isEmpty)
        }
    }

    @Test("An already requested mute state blocks redundant execution", arguments: [true, false])
    func alreadyRequestedState(muted: Bool) async throws {
        try await withCenter { center, probe in
            probe.output = .available(deviceUID: "output", muted: muted)
            let reason = "The current output is already \(muted ? "muted" : "unmuted")."

            #expect(center.disabledReason(for: actionID(muted)) == reason)
            #expect(await center.execute(actionID(muted)) == .unavailable(reason))
            #expect(center.disabledReason(for: actionID(!muted)) == nil)
            #expect(probe.commands.isEmpty)
            #expect(probe.startCalls == 0)
        }
    }

    @Test("Execution resolves the output again after asynchronous Sound startup")
    func outputChangesDuringStartup() async throws {
        try await withCenter { center, probe in
            let entered = SoundActionSignal()
            let release = SoundActionSignal()
            probe.onStart = {
                probe.output = .available(deviceUID: "previous-output", muted: false)
                entered.signal()
                await release.wait()
            }
            let execution = Task { await center.execute(SoundUtilityActions.muteID) }
            await entered.wait()
            #expect(probe.commands.isEmpty)
            probe.output = .available(deviceUID: "replacement-output", muted: false)
            release.signal()

            #expect(await execution.value == .completed)
            #expect(probe.startCalls == 1)
            #expect(probe.commands.map(\.command) == [.setOutputMute(deviceUID: "replacement-output", muted: true)])
        }
    }

    @Test("A cancelled startup cannot dispatch an output change afterward")
    func cancellationDuringStartup() async throws {
        try await withCenter { center, probe in
            let entered = SoundActionSignal()
            let release = SoundActionSignal()
            probe.onStart = {
                entered.signal()
                await release.wait()
                probe.output = .available(deviceUID: "output", muted: false)
            }
            let execution = Task { await center.execute(SoundUtilityActions.muteID) }
            await entered.wait()
            execution.cancel()
            release.signal()

            #expect(await execution.value == .cancelled)
            #expect(probe.commands.isEmpty)
            #expect(probe.startCalls == 1)
        }
    }

    @Test("Startup errors are reported before dispatch")
    func startupFailure() async throws {
        try await withCenter { center, probe in
            probe.onStart = { throw SoundActionStartupError() }

            #expect(await center.execute(SoundUtilityActions.muteID) == .failed("Sound startup failed."))
            #expect(probe.startCalls == 1)
            #expect(probe.commands.isEmpty)
        }
    }

    @Test(
        "An unavailable output discovered during startup is not dispatched",
        arguments: [
            SoundUtilityOutputState.stopped, .unavailable("The current output disconnected."),
        ])
    func unavailableAfterStartup(output: SoundUtilityOutputState) async throws {
        try await withCenter { center, probe in
            probe.onStart = { probe.output = output }
            let reason =
                output == .stopped
                ? "Sound did not start. Open Sound and try again." : "The current output disconnected."

            #expect(await center.execute(SoundUtilityActions.muteID) == .failed(reason))
            #expect(probe.startCalls == 1)
            #expect(probe.commands.isEmpty)
        }
    }

    private func actionID(_ muted: Bool) -> UtilityActionID {
        muted ? SoundUtilityActions.muteID : SoundUtilityActions.unmuteID
    }

    private func withCenter(
        _ body: (UtilityCommandCenter, SoundActionProbe) async throws -> Void
    ) async throws {
        let suite = "SoundUtilityActionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = try ModuleRegistry(defaults: defaults)
        let center = UtilityCommandCenter(registry: registry)
        let probe = SoundActionProbe()
        try center.register(
            SoundUtilityActions.handlers(
                start: probe.start, currentOutput: probe.currentOutput,
                dispatch: { probe.dispatch($0, context: $1) }))
        try await body(center, probe)
    }
}

enum SoundActionReply: Equatable, Sendable {
    case applied, accepted, unchanged
    case rejected(AudioCommandRejection)
}

struct SoundActionRejection: Sendable {
    let rejection: AudioCommandRejection
    let message: String

    nonisolated init(_ rejection: AudioCommandRejection, _ message: String) {
        self.rejection = rejection
        self.message = message
    }
}

private struct SoundActionStartupError: LocalizedError {
    var errorDescription: String? { "Sound startup failed." }
}

@MainActor
private final class SoundActionProbe: AudioCommandDispatching {
    var output: SoundUtilityOutputState = .stopped
    var reply: SoundActionReply = .applied
    var onStart: (() async throws -> Void)?
    var cancelAtDispatchCompletion = false
    private(set) var observedDispatchCancellation = false
    private(set) var startCalls = 0
    private(set) var outputReads = 0
    private(set) var commands: [(command: AudioCommand, context: AudioCommandContext)] = []

    func start() async throws {
        startCalls += 1
        try await onStart?()
    }

    func currentOutput() -> SoundUtilityOutputState {
        outputReads += 1
        return output
    }

    func dispatch(_ command: AudioCommand, context: AudioCommandContext) -> AudioCommandResult {
        commands.append((command, context))
        let receipt = AudioCommandReceipt(
            command: command, context: context, previousValue: nil, observedValue: command.requestedValue,
            recoveryToken: nil, timestamp: Date())
        let result: AudioCommandResult =
            switch reply {
            case .applied: .applied(receipt)
            case .accepted: .accepted(receipt)
            case .unchanged: .unchanged(receipt)
            case .rejected(let rejection): .rejected(rejection)
            }
        if cancelAtDispatchCompletion { withUnsafeCurrentTask { $0?.cancel() } }
        observedDispatchCancellation = Task.isCancelled
        return result
    }
}

@MainActor
private final class SoundActionSignal {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }
}
