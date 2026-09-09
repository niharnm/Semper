import Foundation
import Testing
@testable import Semper

@MainActor
@Suite("URLHandler")
struct URLHandlerTests {
    @Test("Update URL starts a user-requested update check")
    func updateURLStartsUpdateCheck() {
        let engine = URLHandlerEngineStub()
        var updateCheckCount = 0
        let handler = URLHandler(
            audioEngine: engine,
            audioCommands: RecordingAudioCommandSink(),
            checkForUpdates: { updateCheckCount += 1 }
        )

        handler.handleURL(URL(string: "semper://update")!)

        #expect(updateCheckCount == 1)
    }

    @Test("Unknown URL does not start an update check")
    func unknownURLDoesNotStartUpdateCheck() {
        let engine = URLHandlerEngineStub()
        var updateCheckCount = 0
        let handler = URLHandler(
            audioEngine: engine,
            audioCommands: RecordingAudioCommandSink(),
            checkForUpdates: { updateCheckCount += 1 }
        )

        handler.handleURL(URL(string: "semper://unknown")!)

        #expect(updateCheckCount == 0)
    }

    @Test("Volume URLs dispatch stable identifiers with URL source metadata")
    func volumeURLDispatchesCommand() {
        let commands = RecordingAudioCommandSink()
        let handler = URLHandler(
            audioEngine: URLHandlerEngineStub(),
            audioCommands: commands
        )

        handler.handleURL(
            URL(string: "semper://set-volumes?app=com.test.inactive&volume=25")!
        )

        #expect(commands.calls.count == 1)
        #expect(commands.calls.first?.command == .setAppVolume(
            target: .persisted("com.test.inactive"),
            volume: 0.25
        ))
        #expect(commands.calls.first?.context.source == .url)
        #expect(commands.calls.first?.context.reason == .directUser)
    }

    @Test("Scene gate rejection stops a multi-app volume URL")
    func sceneGateRejectionStopsMultiAppVolumeURL() {
        let commands = URLRejectingAudioCommandSink()
        let handler = URLHandler(
            audioEngine: URLHandlerEngineStub(),
            audioCommands: commands
        )

        handler.handleURL(URL(
            string: "semper://set-volumes?app=com.test.one&volume=25&app=com.test.two&volume=50"
        )!)

        #expect(commands.calls.map(\.command) == [
            .setAppVolume(target: .persisted("com.test.one"), volume: 0.25)
        ])
    }

    @Test("Scene gate rejection stops reset before its mute command")
    func sceneGateRejectionStopsResetPair() {
        let commands = URLRejectingAudioCommandSink()
        let handler = URLHandler(
            audioEngine: URLHandlerEngineStub(),
            audioCommands: commands
        )

        handler.handleURL(URL(string: "semper://reset?app=com.test.one")!)

        #expect(commands.calls.map(\.command) == [
            .setAppVolume(target: .persisted("com.test.one"), volume: 1)
        ])
    }

    @Test("Apply scene URL dispatches a valid scene identifier")
    func applySceneURLDispatchesIdentifier() async {
        let sceneID = UUID()
        let scenes = RecordingSceneCommands()
        let handler = URLHandler(
            audioEngine: URLHandlerEngineStub(),
            audioCommands: RecordingAudioCommandSink(),
            sceneCommands: scenes
        )

        let appliedID = await withCheckedContinuation { continuation in
            scenes.onApply = { continuation.resume(returning: $0) }
            handler.handleURL(URL(string: "semper://apply-scene?id=\(sceneID.uuidString)")!)
        }

        #expect(appliedID == sceneID)
    }

    @Test("Apply scene URL rejects a malformed identifier")
    func applySceneURLRejectsMalformedIdentifier() async {
        let scenes = RecordingSceneCommands()
        let handler = URLHandler(
            audioEngine: URLHandlerEngineStub(),
            audioCommands: RecordingAudioCommandSink(),
            sceneCommands: scenes
        )

        handler.handleURL(URL(string: "semper://apply-scene?id=not-a-uuid")!)
        await Task.yield()

        #expect(scenes.appliedIDs.isEmpty)
    }

    @Test("Restore scene URL dispatches restore")
    func restoreSceneURLDispatchesRestore() async {
        let scenes = RecordingSceneCommands()
        let handler = URLHandler(
            audioEngine: URLHandlerEngineStub(),
            audioCommands: RecordingAudioCommandSink(),
            sceneCommands: scenes
        )

        await withCheckedContinuation { continuation in
            scenes.onRestore = { continuation.resume() }
            handler.handleURL(URL(string: "semper://restore-scene")!)
        }

        #expect(scenes.restoreCount == 1)
    }

    @Test("Away Mode blocks URL mutations until it ends")
    func awayModeBlocksURLMutations() {
        let commands = RecordingAudioCommandSink()
        let scenes = RecordingSceneCommands()
        let mutationPermission = URLMutationPermissionProbe(allowsMutations: false)
        var updateCheckCount = 0
        let handler = URLHandler(
            audioEngine: URLHandlerEngineStub(),
            audioCommands: commands,
            sceneCommands: scenes,
            allowsMutations: { mutationPermission.allowsMutations },
            checkForUpdates: { updateCheckCount += 1 }
        )
        let volumeURL = URL(
            string: "semper://set-volumes?app=com.test.inactive&volume=25"
        )!

        let blockedURLs = [
            volumeURL,
            URL(string: "semper://step-volume?app=com.test.inactive&direction=up")!,
            URL(string: "semper://set-mute?app=com.test.inactive&muted=true")!,
            URL(string: "semper://toggle-mute?app=com.test.inactive")!,
            URL(string: "semper://set-device?app=com.test.inactive&device=output.usb")!,
            URL(string: "semper://apply-scene?id=\(UUID().uuidString)")!,
            URL(string: "semper://restore-scene")!,
            URL(string: "semper://reset?app=com.test.inactive")!,
        ]
        for url in blockedURLs {
            handler.handleURL(url)
        }
        handler.handleURL(URL(string: "semper://update")!)

        #expect(commands.calls.isEmpty)
        #expect(scenes.appliedIDs.isEmpty)
        #expect(scenes.restoreCount == 0)
        #expect(updateCheckCount == 1)

        mutationPermission.allowsMutations = true
        handler.handleURL(volumeURL)

        #expect(commands.calls.count == 1)
        #expect(commands.calls.first?.command == .setAppVolume(
            target: .persisted("com.test.inactive"),
            volume: 0.25
        ))
    }
}

@MainActor
private final class URLMutationPermissionProbe {
    var allowsMutations: Bool

    init(allowsMutations: Bool) {
        self.allowsMutations = allowsMutations
    }
}

@MainActor
private final class URLHandlerEngineStub: URLHandlerEngine {
    let settingsManager = SettingsManager(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("URLHandlerTests-\(UUID().uuidString)", isDirectory: true),
        managesLaunchAtLogin: false
    )
    var apps: [AudioApp] = []

    func setVolume(for app: AudioApp, to volume: Float) {}
    func getVolume(for app: AudioApp) -> Float { 1 }
    func setMute(for app: AudioApp, to muted: Bool) {}
    func getMute(for app: AudioApp) -> Bool { false }
    func setDevice(for app: AudioApp, deviceUID: String?) {}
    func setVolumeForInactive(identifier: String, to volume: Float) {}
    func setMuteForInactive(identifier: String, to muted: Bool) {}
    func getMuteForInactive(identifier: String) -> Bool { false }
}

@MainActor
private final class RecordingSceneCommands: SceneCommandHandling {
    var appliedIDs: [UUID] = []
    var restoreCount = 0
    var onApply: ((UUID) -> Void)?
    var onRestore: (() -> Void)?

    func availableScenes() -> [SceneCommandDescriptor] { [] }

    func applyScene(id: UUID) async throws -> SceneCommandExecution {
        appliedIDs.append(id)
        onApply?(id)
        return SceneCommandExecution(message: "Applied")
    }

    func restoreScene() async throws -> SceneCommandExecution {
        restoreCount += 1
        onRestore?()
        return SceneCommandExecution(message: "Restored")
    }
}

@MainActor
private final class URLRejectingAudioCommandSink: AudioCommandDispatching {
    private(set) var calls: [(command: AudioCommand, context: AudioCommandContext)] = []

    func dispatch(_ command: AudioCommand, context: AudioCommandContext) -> AudioCommandResult {
        calls.append((command, context))
        return .rejected(.sceneOperationInProgress)
    }
}
