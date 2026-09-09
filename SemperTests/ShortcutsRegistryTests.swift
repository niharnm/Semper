// SemperTests/ShortcutsRegistryTests.swift
import Testing
import Foundation
import AppKit
import KeyboardShortcuts
@testable import Semper

@Suite("ShortcutsRegistry")
@MainActor
struct ShortcutsRegistryTests {
    @Test("Stopped registry ignores already queued shortcut dispatch")
    func stoppedRegistryIgnoresDispatch() {
        let recorder = RecordingPopupController()
        let registry = makeRegistry(popupController: recorder)
        registry.stop()
        registry.stop()
        registry.start()
        registry.dispatch(.togglePopup)
        #expect(recorder.toggleCount == 0)
    }

    // MARK: - dispatch

    @Test("dispatch(.togglePopup) calls popupController.toggle() exactly once")
    func dispatchTogglePopup() {
        let recorder = RecordingPopupController()
        let registry = makeRegistry(popupController: recorder)

        registry.dispatch(.togglePopup)

        #expect(recorder.toggleCount == 1)
    }

    @Test("dispatch(.targetAppVolumeUp) raises volume on the matched app")
    func dispatchFrontmostVolumeUpHappyPath() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let resolver = StubTargetResolver(target: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5)
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: resolver,
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.targetAppVolumeUp)

        let nextSlider = sqrt(0.5) + 1.0 / 16.0
        let expected = Float(nextSlider * nextSlider)
        #expect(engine.setVolumeCalls.count == 1)
        #expect(engine.setVolumeCalls.first?.app.bundleID == "com.test.app")
        #expect(abs((engine.setVolumeCalls.first?.volume ?? 0) - expected) < 1e-5)
        #expect(hud.successCalls == 1)
        #expect(hud.failureCalls == 0)
    }

    @Test("dispatch uses the custom volume percentage")
    func dispatchUsesCustomVolumePercentage() {
        let settings = makeIsolatedSettings()
        var appSettings = settings.appSettings
        appSettings.volumeHotkeyStep = .custom
        appSettings.customVolumeHotkeyStepPercent = 10
        settings.appSettings = appSettings

        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5)
        let registry = makeRegistry(
            settings: settings,
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine
        )

        registry.dispatch(.targetAppVolumeUp)

        let nextSlider = sqrt(0.5) + 0.1
        let expected = Float(nextSlider * nextSlider)
        #expect(abs((engine.setVolumeCalls.first?.volume ?? 0) - expected) < 1e-5)
    }

    @Test("dispatch(.targetAppVolumeDown) clamps at 0")
    func dispatchFrontmostVolumeDownClampsAtZero() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.0)
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: RecordingHUDController()
        )

        registry.dispatch(.targetAppVolumeDown)

        #expect(engine.setVolumeCalls.first?.volume == 0.0)
    }

    @Test("dispatch(.targetAppMuteToggle) applies the opposite mute state and reports it")
    func dispatchFrontmostMuteHappyPath() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialMuted: false)
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.targetAppMuteToggle)

        #expect(engine.setMuteCalls.count == 1)
        #expect(engine.setMuteCalls.first?.mute == true)
        #expect(hud.successCalls == 1)
    }

    @Test("dispatch falls through to failure HUD when resolver returns nil")
    func dispatchNoTarget() {
        let engine = RecordingAudioEngine(apps: [])
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: nil),
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.targetAppVolumeUp)

        #expect(engine.setVolumeCalls.isEmpty)
        #expect(hud.failureCalls == 1)
    }

    @Test("dispatch(.targetAppVolumeUp) unmutes a muted app (media-key parity)")
    func dispatchVolumeUpUnmutesMutedApp() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5, initialMuted: true)
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: RecordingHUDController()
        )

        registry.dispatch(.targetAppVolumeUp)

        #expect(engine.setMuteCalls.count == 1)
        #expect(engine.setMuteCalls.first?.mute == false)
    }

    @Test("dispatch(.targetAppVolumeDown) auto-mutes an unmuted app when volume hits zero")
    func dispatchVolumeDownAutoMutesAtZero() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.001, initialMuted: false)
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: RecordingHUDController()
        )

        registry.dispatch(.targetAppVolumeDown)

        #expect(engine.setMuteCalls.count == 1)
        #expect(engine.setMuteCalls.first?.mute == true)
    }

    @Test("dispatch(.targetAppVolumeDown) unmutes a muted app when next volume is still audible")
    func dispatchVolumeDownUnmutesMutedButAudibleApp() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5, initialMuted: true)
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: RecordingHUDController()
        )

        registry.dispatch(.targetAppVolumeDown)

        #expect(engine.setMuteCalls.count == 1)
        #expect(engine.setMuteCalls.first?.mute == false)
    }

    @Test("dispatch(.targetAppVolumeUp) on already-unmuted app does not call setMute")
    func dispatchVolumeUpNoMuteTransitionIfAlreadyUnmuted() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5, initialMuted: false)
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: RecordingHUDController()
        )

        registry.dispatch(.targetAppVolumeUp)

        #expect(engine.setMuteCalls.isEmpty)
    }

    @Test("Scene gate rejection does not show a successful volume HUD")
    func sceneGateRejectionSuppressesVolumeHUD() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5)
        let commands = ShortcutRejectingAudioCommandSink()
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            audioCommands: commands,
            hud: hud
        )

        let dispatched = registry.dispatch(.targetAppVolumeUp)

        #expect(!dispatched)
        #expect(commands.calls.count == 1)
        #expect(engine.setVolumeCalls.isEmpty)
        #expect(hud.successCalls == 0)
    }

    @Test("Scene gate rejection stops a compound volume hotkey")
    func sceneGateRejectionStopsCompoundHotkey() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5, initialMuted: true)
        let commands = ShortcutRejectingAudioCommandSink()
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            audioCommands: commands,
            hud: hud
        )

        let dispatched = registry.dispatch(.targetAppVolumeUp)

        #expect(!dispatched)
        #expect(commands.calls.map(\.command) == [
            .setAppMute(target: .active(app), muted: false)
        ])
        #expect(engine.setMuteCalls.isEmpty)
        #expect(engine.setVolumeCalls.isEmpty)
        #expect(hud.successCalls == 0)
    }

    @Test("dispatch falls through to failure HUD when no matching AudioApp exists")
    func dispatchNoMatchingApp() {
        let engine = RecordingAudioEngine(apps: [])
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.notap"),
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.targetAppVolumeDown)

        #expect(engine.setVolumeCalls.isEmpty)
        #expect(hud.failureCalls == 1)
    }

    // MARK: - name

    @Test("supportsRepeat is true only for volume up/down")
    func supportsRepeatFlag() {
        #expect(ShortcutAction.targetAppVolumeUp.supportsRepeat == true)
        #expect(ShortcutAction.targetAppVolumeDown.supportsRepeat == true)
        #expect(ShortcutAction.targetAppMuteToggle.supportsRepeat == false)
        #expect(ShortcutAction.togglePopup.supportsRepeat == false)
    }

    @Test("name(for: .togglePopup) is the stable persistence identifier")
    func nameStable() {
        let registry = makeRegistry()
        #expect(registry.name(for: .togglePopup).rawValue == "toggle-popup")
        #expect(registry.name(for: .targetAppVolumeUp).rawValue == "frontmost-app-volume-up")
        #expect(registry.name(for: .targetAppVolumeDown).rawValue == "frontmost-app-volume-down")
        #expect(registry.name(for: .targetAppMuteToggle).rawValue == "frontmost-app-mute-toggle")
    }

    // MARK: - start: load path

    @Test("start() loads stored shortcuts into KeyboardShortcuts")
    func startLoadsStoredShortcuts() {
        let settings = makeIsolatedSettings()
        let stored = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = stored
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        registry.start()

        let resolved = KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup))
        #expect(resolved?.carbonKeyCode == stored.keyCode)
        #expect(resolved?.carbonModifiers == stored.keyboardShortcut.carbonModifiers)

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    @Test("start() is idempotent")
    func startIsIdempotent() {
        let settings = makeIsolatedSettings()
        let registry = makeRegistry(settings: settings)

        registry.start()
        registry.start()

        let recorder = RecordingPopupController()
        let registryWithRecorder = makeRegistry(settings: settings, popupController: recorder)
        registryWithRecorder.start()
        registryWithRecorder.start()
        registryWithRecorder.dispatch(.togglePopup)
        #expect(recorder.toggleCount == 1)

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    // MARK: - recordCallback: write-back path

    @Test("recordCallback writes the new shortcut into AppSettings")
    func recordCallbackWritesBack() {
        let settings = makeIsolatedSettings()
        let registry = makeRegistry(settings: settings)
        defer { registry.clearAllShortcuts() }

        let callback = registry.recordCallback(for: .togglePopup)
        let newShortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: 11, carbonModifiers: 0x12_0000)
        callback(newShortcut)

        let stored = settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue]
        #expect(stored?.keyCode == 11)
        #expect(stored?.modifiers == UInt(newShortcut.carbonModifiers))
    }

    @Test("Recorder test cleanup leaves no assignments for the next recorder")
    func recordCallbacksCleanUpSharedStorage() throws {
        let registry = makeRegistry()
        let names = ShortcutAction.soundActions.map { registry.name(for: $0) }
        let priorShortcuts = names.map { KeyboardShortcuts.getShortcut(for: $0) }
        defer {
            registry.clearAllShortcuts()
            for (name, shortcut) in zip(names, priorShortcuts) {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            }
        }
        registry.clearAllShortcuts()

        recordCallbackClearsPriorConflict()

        for name in names {
            try #require(KeyboardShortcuts.getShortcut(for: name) == nil)
        }

        recordCallbackWritesBack()

        for name in names {
            #expect(KeyboardShortcuts.getShortcut(for: name) == nil)
        }
    }

    @Test("recordCallback clears the entry when given nil")
    func recordCallbackClearsOnNil() {
        let settings = makeIsolatedSettings()
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = ShortcutCodable(keyCode: 9, modifiers: 0)
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        let callback = registry.recordCallback(for: .togglePopup)
        callback(nil)

        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] == nil)
    }

    @Test("recordCallback rejects a shortcut assigned to another Semper action")
    func recordCallbackRejectsDuplicate() {
        let settings = makeIsolatedSettings()
        let duplicateShortcut = KeyboardShortcuts.Shortcut(
            carbonKeyCode: 11,
            carbonModifiers: 0x12_0000
        )
        let previousShortcut = KeyboardShortcuts.Shortcut(
            carbonKeyCode: 9,
            carbonModifiers: 0x18_0000
        )
        let duplicate = ShortcutCodable.from(duplicateShortcut)
        let previous = ShortcutCodable.from(previousShortcut)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.targetAppVolumeUp.rawValue] = duplicate
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = previous
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        KeyboardShortcuts.setShortcut(duplicateShortcut, for: registry.name(for: .togglePopup))

        registry.recordCallback(for: .togglePopup)(duplicateShortcut)

        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] == previous)
        #expect(registry.conflictingAction(for: .togglePopup) == .targetAppVolumeUp)
        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup)) == previous.keyboardShortcut)

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .targetAppVolumeUp))
    }

    @Test("recordCallback clears a rejected duplicate when the action has no prior setting")
    func recordCallbackRejectsDuplicateWithoutPriorSetting() {
        let settings = makeIsolatedSettings()
        let duplicateShortcut = KeyboardShortcuts.Shortcut(
            carbonKeyCode: 12,
            carbonModifiers: 0x12_0000
        )
        let duplicate = ShortcutCodable.from(duplicateShortcut)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.targetAppVolumeUp.rawValue] = duplicate
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        KeyboardShortcuts.setShortcut(duplicateShortcut, for: registry.name(for: .togglePopup))

        registry.recordCallback(for: .togglePopup)(duplicateShortcut)

        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] == nil)
        #expect(registry.conflictingAction(for: .togglePopup) == .targetAppVolumeUp)
        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup)) == nil)
        #expect(
            KeyboardShortcuts.getShortcut(for: registry.name(for: .targetAppVolumeUp))
                == duplicate.keyboardShortcut
        )

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .targetAppVolumeUp))
    }

    @Test("recordCallback rejects a shortcut owned only by KeyboardShortcuts storage")
    func recordCallbackRejectsLibraryOnlyDuplicate() {
        let settings = makeIsolatedSettings()
        let duplicateShortcut = KeyboardShortcuts.Shortcut(
            carbonKeyCode: 23,
            carbonModifiers: 0x12_0000
        )
        let duplicate = ShortcutCodable.from(duplicateShortcut)
        let registry = makeRegistry(settings: settings)
        let editedName = registry.name(for: .togglePopup)
        let ownerName = registry.name(for: .targetAppVolumeUp)
        KeyboardShortcuts.setShortcut(duplicateShortcut, for: ownerName)
        KeyboardShortcuts.setShortcut(duplicateShortcut, for: editedName)

        registry.recordCallback(for: .togglePopup)(duplicateShortcut)

        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] == nil)
        #expect(registry.conflictingAction(for: .togglePopup) == .targetAppVolumeUp)
        #expect(KeyboardShortcuts.getShortcut(for: editedName) == nil)
        #expect(KeyboardShortcuts.getShortcut(for: ownerName) == duplicate.keyboardShortcut)

        KeyboardShortcuts.setShortcut(nil, for: editedName)
        KeyboardShortcuts.setShortcut(nil, for: ownerName)
    }

    @Test("recordCallback clears a prior conflict after a unique shortcut is recorded")
    func recordCallbackClearsPriorConflict() {
        let settings = makeIsolatedSettings()
        let duplicate = ShortcutCodable(keyCode: 11, modifiers: 0x12_0000)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.targetAppVolumeUp.rawValue] = duplicate
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        defer { registry.clearAllShortcuts() }
        let callback = registry.recordCallback(for: .togglePopup)
        callback(duplicate.keyboardShortcut)
        callback(KeyboardShortcuts.Shortcut(carbonKeyCode: 9, carbonModifiers: 0x18_0000))

        #expect(registry.conflictingAction(for: .togglePopup) == nil)
        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue]?.keyCode == 9)
    }

    @Test("clearAllShortcuts clears settings and KeyboardShortcuts storage")
    func clearAllShortcuts() {
        let settings = makeIsolatedSettings()
        let first = ShortcutCodable(keyCode: 9, modifiers: 0x18_0000)
        let second = ShortcutCodable(keyCode: 11, modifiers: 0x12_0000)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = first
        app.customShortcuts[ShortcutAction.targetAppVolumeUp.rawValue] = second
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        KeyboardShortcuts.setShortcut(first.keyboardShortcut, for: registry.name(for: .togglePopup))
        KeyboardShortcuts.setShortcut(second.keyboardShortcut, for: registry.name(for: .targetAppVolumeUp))

        registry.clearAllShortcuts()

        #expect(settings.appSettings.customShortcuts.isEmpty)
        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup)) == nil)
        #expect(KeyboardShortcuts.getShortcut(for: registry.name(for: .targetAppVolumeUp)) == nil)
    }

    @Test("hasAssignedShortcuts detects KeyboardShortcuts storage not mirrored in settings")
    func hasAssignedShortcutsDetectsLibraryStorage() {
        let registry = makeRegistry()
        let shortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: 11, carbonModifiers: 0x12_0000)
        KeyboardShortcuts.setShortcut(shortcut, for: registry.name(for: .togglePopup))

        #expect(registry.hasAssignedShortcuts)

        registry.clearAllShortcuts()
        #expect(!registry.hasAssignedShortcuts)
    }

    @Test("targetAppOptions de-duplicates apps by bundle ID")
    func targetAppOptionsDeduplicatesBundleIDs() {
        let engine = RecordingAudioEngine(apps: [
            makeAudioApp(id: 1, bundleID: "com.test.shared"),
            makeAudioApp(id: 2, bundleID: "com.test.shared"),
            makeAudioApp(id: 3, bundleID: "com.test.other"),
        ])
        let registry = makeRegistry(audioEngine: engine)

        let options = registry.targetAppOptions()

        #expect(options.map(\.bundleID).sorted() == ["com.test.other", "com.test.shared"])
    }

    // MARK: - Helpers

    private func makeRegistry(
        settings: SettingsManager? = nil,
        popupController: (any MenuBarPopupControlling)? = nil,
        resolver: (any TargetAppResolving)? = nil,
        audioEngine: (any AudioEngineDispatching)? = nil,
        audioCommands: (any AudioCommandDispatching)? = nil,
        hud: (any PerAppHUDPresenting)? = nil
    ) -> ShortcutsRegistry {
        let resolvedEngine = audioEngine ?? RecordingAudioEngine(apps: [])
        let resolvedCommands: any AudioCommandDispatching
        if let audioCommands {
            resolvedCommands = audioCommands
        } else {
            let commands = RecordingAudioCommandSink()
            commands.onDispatch = { command in
                switch command {
                case .setAppVolume(let target, let volume):
                    guard let app = resolvedEngine.apps.first(where: {
                        $0.persistenceIdentifier == target.identifier
                            && (target.processID == nil || $0.id == target.processID)
                    }) else { return }
                    resolvedEngine.setVolume(for: app, to: volume)
                case .setAppMute(let target, let muted):
                    guard let app = resolvedEngine.apps.first(where: {
                        $0.persistenceIdentifier == target.identifier
                            && (target.processID == nil || $0.id == target.processID)
                    }) else { return }
                    resolvedEngine.setMute(for: app, to: muted)
                default:
                    break
                }
            }
            resolvedCommands = commands
        }
        return ShortcutsRegistry(
            settings: settings ?? makeIsolatedSettings(),
            popupController: popupController ?? RecordingPopupController(),
            resolver: resolver ?? StubTargetResolver(target: nil),
            audioEngine: resolvedEngine,
            audioCommands: resolvedCommands,
            hud: hud ?? RecordingHUDController()
        )
    }

    private func makeIsolatedSettings() -> SettingsManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SemperTests-\(UUID().uuidString)")
        return SettingsManager(directory: dir)
    }

    private func makeAudioApp(id: pid_t, bundleID: String?) -> AudioApp {
        AudioApp(
            id: id,
            processObjectIDs: [],
            name: "Test \(id)",
            icon: NSImage(systemSymbolName: "speaker", accessibilityDescription: nil) ?? NSImage(),
            bundleID: bundleID
        )
    }
}

// MARK: - Test doubles

@MainActor
final class RecordingPopupController: MenuBarPopupControlling {
    var toggleCount = 0
    func toggle() { toggleCount += 1 }
}

@MainActor
final class StubTargetResolver: TargetAppResolving {
    var target: String?
    init(target: String?) { self.target = target }
    func resolveTargetBundleID(audibleCandidates: [String]) -> String? { target }
}

@MainActor
final class RecordingAudioEngine: AudioEngineDispatching {
    var apps: [AudioApp]
    var audibleBundleIDs: Set<String> = []
    private var volume: Float
    private var muted: Bool
    var setVolumeCalls: [(app: AudioApp, volume: Float)] = []
    var toggleMuteCalls: [AudioApp] = []

    init(apps: [AudioApp], initialVolume: Float = 0.5, initialMuted: Bool = false) {
        self.apps = apps
        self.volume = initialVolume
        self.muted = initialMuted
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        self.volume = volume
        setVolumeCalls.append((app, volume))
    }

    func setMute(for app: AudioApp, to mute: Bool) {
        muted = mute
        setMuteCalls.append((app, mute))
    }

    func toggleMute(for app: AudioApp) {
        muted.toggle()
        toggleMuteCalls.append(app)
    }

    func currentVolume(for app: AudioApp) -> Float { volume }
    func isMuted(for app: AudioApp) -> Bool { muted }
    func isAudibleNow(bundleID: String) -> Bool { audibleBundleIDs.contains(bundleID) }

    var setMuteCalls: [(app: AudioApp, mute: Bool)] = []
}

@MainActor
final class RecordingHUDController: PerAppHUDPresenting {
    var successCalls = 0
    var failureCalls = 0

    func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double) { successCalls += 1 }
    func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) { successCalls += 1 }
    func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
        failureCalls += 1
    }
}

@MainActor
private final class ShortcutRejectingAudioCommandSink: AudioCommandDispatching {
    private(set) var calls: [(command: AudioCommand, context: AudioCommandContext)] = []

    func dispatch(_ command: AudioCommand, context: AudioCommandContext) -> AudioCommandResult {
        calls.append((command, context))
        return .rejected(.sceneOperationInProgress)
    }
}
