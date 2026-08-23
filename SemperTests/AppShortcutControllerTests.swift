import AppKit
import AudioToolbox
import Testing
@testable import Semper

@MainActor
@Suite("App Shortcut Controller", .serialized)
struct AppShortcutControllerTests {
    @Test("Catalog keeps stable IDs for active and inactive pinned apps")
    func catalogUsesStableIdentifiers() {
        let fixture = Fixture(
            activeApps: [
                Self.app(pid: 11, name: "Player", bundleID: "com.example.player.one"),
                Self.app(pid: 12, name: "Player", bundleID: "com.example.player.two"),
            ],
            pinnedApps: [
                PinnedAppInfo(
                    persistenceIdentifier: "com.example.pinned",
                    displayName: "Pinned Player",
                    bundleID: "com.example.pinned"
                )
            ]
        )

        let applications = fixture.controller.applications()

        #expect(applications.map(\.identifier) == [
            "com.example.pinned",
            "com.example.player.one",
            "com.example.player.two",
        ])
        #expect(applications.first?.isActive == false)
        #expect(applications.dropFirst().map(\.isActive) == [true, true])
    }

    @Test("Inactive pinned apps remain controllable by stable identifier")
    func controlsInactivePinnedApp() throws {
        let fixture = Fixture(
            pinnedApps: [
                PinnedAppInfo(
                    persistenceIdentifier: "com.example.pinned",
                    displayName: "Pinned Player",
                    bundleID: "com.example.pinned"
                )
            ]
        )

        let result = try fixture.controller.setVolume(
            applicationIdentifier: "com.example.pinned",
            percent: 35
        )

        #expect(result.status == .applied)
        #expect(fixture.commands.calls.count == 1)
        #expect(fixture.commands.calls.first?.command == .setAppVolume(
            target: .persisted("com.example.pinned"),
            volume: 0.35
        ))
        #expect(fixture.commands.calls.first?.context.source == .appIntent)
        #expect(fixture.commands.calls.first?.context.reason == .shortcut)
    }

    @Test("Inactive unpinned apps are rejected")
    func rejectsUnknownApp() {
        let fixture = Fixture()

        #expect(throws: AppShortcutExecutionError.appUnavailable("com.example.missing")) {
            try fixture.controller.setMute(
                applicationIdentifier: "com.example.missing",
                muted: true
            )
        }
        #expect(fixture.commands.calls.isEmpty)
    }

    @Test("Volume rejects values outside the supported percentage range")
    func rejectsInvalidVolume() {
        let fixture = Fixture(
            activeApps: [Self.app(pid: 20, name: "Player", bundleID: "com.example.player")]
        )

        #expect(throws: AppShortcutExecutionError.invalidValue(
            "Volume must be between 0 and 100 percent."
        )) {
            try fixture.controller.setVolume(
                applicationIdentifier: "com.example.player",
                percent: 101
            )
        }
        #expect(fixture.commands.calls.isEmpty)
    }

    @Test("Disconnected route output is rejected before dispatch")
    func rejectsDisconnectedRouteOutput() {
        let fixture = Fixture(
            activeApps: [Self.app(pid: 21, name: "Player", bundleID: "com.example.player")]
        )

        #expect(throws: AppShortcutExecutionError.deviceUnavailable("output.missing")) {
            try fixture.controller.route(
                applicationIdentifier: "com.example.player",
                outputUID: "output.missing"
            )
        }
        #expect(fixture.commands.calls.isEmpty)
    }

    @Test("Routing dispatches the saved device UID")
    func routingUsesDeviceUID() throws {
        let fixture = Fixture(
            activeApps: [Self.app(pid: 22, name: "Player", bundleID: "com.example.player")],
            outputs: [Self.output(id: 31, uid: "output.usb", name: "USB Audio")]
        )

        _ = try fixture.controller.route(
            applicationIdentifier: "com.example.player",
            outputUID: "output.usb"
        )

        #expect(fixture.commands.calls.first?.command == .setAppDevice(
            target: .persisted("com.example.player"),
            deviceUID: "output.usb"
        ))
    }

    @Test("Permission denial is returned to the shortcut")
    func reportsPermissionDenial() {
        let fixture = Fixture(
            activeApps: [Self.app(pid: 23, name: "Player", bundleID: "com.example.player")],
            outputs: [Self.output(id: 32, uid: "output.usb", name: "USB Audio")]
        )
        fixture.commands.nextResult = .rejected(.permissionDenied)

        #expect(throws: AppShortcutExecutionError.permissionDenied) {
            try fixture.controller.route(
                applicationIdentifier: "com.example.player",
                outputUID: "output.usb"
            )
        }
    }

    @Test("Accepted and unchanged command states remain distinct")
    func preservesCommandResultState() throws {
        let app = Self.app(pid: 25, name: "Player", bundleID: "com.example.player")
        let fixture = Fixture(activeApps: [app])
        let command = AudioCommand.setAppMute(target: .persisted("com.example.player"), muted: true)
        let context = AudioCommandContext(source: .appIntent, reason: .shortcut)
        let receipt = AudioCommandReceipt(
            command: command,
            context: context,
            previousValue: .flag(false),
            observedValue: nil,
            recoveryToken: nil,
            timestamp: Date()
        )

        fixture.commands.nextResult = .accepted(receipt)
        let accepted = try fixture.controller.setMute(
            applicationIdentifier: "com.example.player",
            muted: true
        )

        fixture.commands.nextResult = .unchanged(receipt)
        let unchanged = try fixture.controller.setMute(
            applicationIdentifier: "com.example.player",
            muted: true
        )

        #expect(accepted.status == .accepted)
        #expect(accepted.message == "Semper accepted the audio change request.")
        #expect(unchanged.status == .unchanged)
        #expect(unchanged.message == "That audio setting is already in place.")
    }

    @Test("Default output switching rejects a disconnected saved device")
    func rejectsDisconnectedDefaultOutput() {
        let fixture = Fixture(outputs: [])

        #expect(throws: AppShortcutExecutionError.deviceUnavailable("output.hdmi")) {
            try fixture.controller.switchDefaultOutput(outputUID: "output.hdmi")
        }
        #expect(fixture.commands.calls.isEmpty)
    }

    @Test("Start Call Mode requires its selected app to be running")
    func callModeRequiresRunningApp() {
        let fixture = Fixture()

        #expect(throws: AppShortcutExecutionError.callAppUnavailable("Zoom")) {
            try fixture.controller.startCallMode(applicationIdentifier: "us.zoom.xos")
        }
        #expect(fixture.startedCalls.isEmpty)
    }

    @Test("Start and end Call Mode report exact session state")
    func startsAndEndsCallMode() throws {
        let fixture = Fixture(
            activeApps: [Self.app(pid: 24, name: "Zoom", bundleID: "us.zoom.xos")]
        )

        let started = try fixture.controller.startCallMode(applicationIdentifier: "us.zoom.xos")
        fixture.activeCallSession = CallModeSession(
            applicationIdentifier: "us.zoom.xos",
            displayName: "Zoom",
            inputDeviceUID: nil,
            startedAt: Date()
        )
        let ended = fixture.controller.endCallModeSession()

        #expect(started.status == .applied)
        #expect(fixture.startedCalls == ["us.zoom.xos"])
        #expect(ended.status == .applied)
        #expect(fixture.endCallCount == 1)
    }

    @Test("Undo reports unavailable, stale, failed, and restored states")
    func reportsUndoStates() throws {
        let fixture = Fixture()

        fixture.commands.undoResult = .unavailable
        #expect(throws: AppShortcutExecutionError.undoUnavailable) {
            try fixture.controller.undoLastChange()
        }

        fixture.commands.undoResult = .stale
        #expect(throws: AppShortcutExecutionError.undoStale) {
            try fixture.controller.undoLastChange()
        }

        fixture.commands.undoResult = .failed
        #expect(throws: AppShortcutExecutionError.undoFailed) {
            try fixture.controller.undoLastChange()
        }

        fixture.commands.undoResult = .restored
        #expect(try fixture.controller.undoLastChange().status == .applied)
        #expect(fixture.commands.undoSources == [.appIntent, .appIntent, .appIntent, .appIntent])
    }

    @Test("Native intents request foreground launch when Semper is quit")
    func intentsOpenSemperWhenRun() {
        #expect(SemperSetAppVolumeIntent.openAppWhenRun)
        #expect(SemperSetAppMuteIntent.openAppWhenRun)
        #expect(SemperRouteAppIntent.openAppWhenRun)
        #expect(SemperFollowDefaultOutputIntent.openAppWhenRun)
        #expect(SemperSwitchOutputIntent.openAppWhenRun)
        #expect(SemperStartCallModeIntent.openAppWhenRun)
        #expect(SemperEndCallModeIntent.openAppWhenRun)
        #expect(SemperBypassAudioIntent.openAppWhenRun)
        #expect(SemperResumeAudioIntent.openAppWhenRun)
        #expect(SemperUndoAudioIntent.openAppWhenRun)
    }

    private static func app(
        pid: pid_t,
        name: String,
        bundleID: String?
    ) -> AudioApp {
        AudioApp(
            id: pid,
            processObjectIDs: [],
            name: name,
            icon: NSImage(size: NSSize(width: 16, height: 16)),
            bundleID: bundleID
        )
    }

    private static func output(
        id: AudioDeviceID,
        uid: String,
        name: String
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            uid: uid,
            name: name,
            icon: nil,
            supportsAutoEQ: false
        )
    }
}

@MainActor
private final class Fixture {
    let commands = AppShortcutCommandSink()
    var activeApps: [AudioApp]
    var pinnedApps: [PinnedAppInfo]
    var outputs: [AudioDevice]
    var isCallModeEnabled = true
    var activeCallSession: CallModeSession?
    var startedCalls: [String] = []
    var endCallCount = 0

    lazy var controller = AppShortcutController(
        activeApplications: { [unowned self] in activeApps },
        pinnedApplications: { [unowned self] in pinnedApps },
        outputDevices: { [unowned self] in outputs },
        dispatchCommand: { [unowned self] command, context in
            commands.dispatch(command, context: context)
        },
        undoCommand: { [unowned self] source in commands.undoLastChange(source: source) },
        callModeEnabled: { [unowned self] in isCallModeEnabled },
        activeCallSession: { [unowned self] in activeCallSession },
        startCallMode: { [unowned self] identifier, _ in startedCalls.append(identifier) },
        endCallMode: { [unowned self] in endCallCount += 1 }
    )

    init(
        activeApps: [AudioApp] = [],
        pinnedApps: [PinnedAppInfo] = [],
        outputs: [AudioDevice] = []
    ) {
        self.activeApps = activeApps
        self.pinnedApps = pinnedApps
        self.outputs = outputs
    }
}

@MainActor
private final class AppShortcutCommandSink {
    private(set) var calls: [(command: AudioCommand, context: AudioCommandContext)] = []
    private(set) var undoSources: [AudioCommandSource] = []
    var nextResult: AudioCommandResult?
    var undoResult: AudioUndoResult = .unavailable

    func dispatch(_ command: AudioCommand, context: AudioCommandContext) -> AudioCommandResult {
        calls.append((command, context))
        if let nextResult {
            self.nextResult = nil
            return nextResult
        }
        return .applied(AudioCommandReceipt(
            command: command,
            context: context,
            previousValue: nil,
            observedValue: command.requestedValue,
            recoveryToken: nil,
            timestamp: Date()
        ))
    }

    func undoLastChange(source: AudioCommandSource) -> AudioUndoResult {
        undoSources.append(source)
        return undoResult
    }
}
