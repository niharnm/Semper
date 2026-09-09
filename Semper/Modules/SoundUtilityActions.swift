import Foundation

enum SoundUtilityOutputState: Equatable, Sendable {
    case stopped
    case unavailable(String)
    case available(deviceUID: String, muted: Bool)
}

@MainActor
enum SoundUtilityActions {
    static let muteID = UtilityActionID(rawValue: "sound.output.mute")
    static let unmuteID = UtilityActionID(rawValue: "sound.output.unmute")

    static func handlers(
        start: @escaping @MainActor () async throws -> Void,
        currentOutput: @escaping @MainActor () -> SoundUtilityOutputState,
        dispatch: @escaping @MainActor (AudioCommand, AudioCommandContext) -> AudioCommandResult
    ) -> [UtilityActionHandler] {
        [true, false].map { muted in
            UtilityActionHandler(
                descriptor: UtilityActionDescriptor(
                    id: muted ? muteID : unmuteID, module: .sound,
                    title: muted ? "Mute current output" : "Unmute current output",
                    keywords: ["audio", "speaker", muted ? "silence" : "restore sound"],
                    symbolName: muted ? "speaker.slash" : "speaker.wave.2"),
                disabledReason: {
                    switch currentOutput() {
                    case .stopped: nil
                    case .unavailable(let reason): reason
                    case .available(_, let currentMute):
                        currentMute == muted
                            ? "The current output is already \(muted ? "muted" : "unmuted")." : nil
                    }
                },
                performOutcome: {
                    try Task.checkCancellation()
                    var output = currentOutput()
                    if case .stopped = output {
                        try await start()
                        try Task.checkCancellation()
                        output = currentOutput()
                    }
                    let deviceUID: String
                    switch output {
                    case .stopped:
                        throw AppShortcutExecutionError.unsupportedRoute(
                            "Sound did not start. Open Sound and try again.")
                    case .unavailable(let reason):
                        throw AppShortcutExecutionError.unsupportedRoute(reason)
                    case .available(let uid, _):
                        deviceUID = uid
                    }
                    switch dispatch(
                        .setOutputMute(deviceUID: deviceUID, muted: muted), AudioCommandContext(source: .popup))
                    {
                    case .applied, .unchanged: return .completed
                    case .accepted: return .accepted
                    case .rejected(let rejection): throw AppShortcutController.error(for: rejection)
                    }
                })
        }
    }
}
