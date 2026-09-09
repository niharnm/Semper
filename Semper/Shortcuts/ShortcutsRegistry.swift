// Semper/Shortcuts/ShortcutsRegistry.swift
import AppKit
import Foundation
import KeyboardShortcuts
import os

@MainActor
protocol AudioEngineDispatching: AnyObject {
    var apps: [AudioApp] { get }
    func setVolume(for app: AudioApp, to volume: Float)
    func setMute(for app: AudioApp, to muted: Bool)
    func toggleMute(for app: AudioApp)
    func currentVolume(for app: AudioApp) -> Float
    func isMuted(for app: AudioApp) -> Bool
    func isAudibleNow(bundleID: String) -> Bool
}

@MainActor
protocol PerAppHUDPresenting: AnyObject {
    func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double)
    func showPerAppMuteHUD(app: AudioApp, isMuted: Bool)
    func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?)
}

@MainActor
protocol AwayShortcutHandling: AnyObject {
    var blocksOrdinaryShortcuts: Bool { get }
    func handleAwayShortcut()
}

nonisolated struct ShortcutTargetAppOption: Identifiable, Equatable, Sendable {
    let bundleID: String
    let displayName: String

    var id: String { bundleID }
}

/// Bridges `KeyboardShortcuts` (Carbon-backed global hotkey library, MIT) to
/// Semper's settings layer.
///
/// Responsibilities:
///   1. Load: on `start()`, push every persisted shortcut from `AppSettings`
///      into `KeyboardShortcuts` and register a `onKeyDown` handler that
///      dispatches the matching `ShortcutAction`.
///   2. Save: vend `recordCallback(for:)` closures that the UI's `Recorder`
///      passes as its `onChange` parameter. When the user records a new
///      chord, the callback writes the change back to `SettingsManager`,
///      keeping `settings.json` the source of truth.
///
/// Why no async-stream observer for write-back: `KeyboardShortcuts.events(...)`
/// only emits `.keyDown` / `.keyUp`, not "shortcut changed". The library's only
/// shortcut-mutation hook is the `Recorder.onChange` per-instance callback,
/// which we wire from the UI. This keeps re-entrancy impossible by construction:
/// programmatic `setShortcut(_:for:)` from `start()` never fires `Recorder.onChange`.
@MainActor
@Observable
final class ShortcutsRegistry {
    private static let logger = Logger(
        subsystem: "systems.semper.Semper",
        category: "ShortcutsRegistry"
    )

    private let settings: SettingsManager
    private let popupController: any MenuBarPopupControlling
    private let resolver: any TargetAppResolving
    private let audioEngine: any AudioEngineDispatching
    private let audioCommands: any AudioCommandDispatching
    private let hud: any PerAppHUDPresenting
    private let allowsShortcuts: @MainActor () -> Bool
    private weak var awayHandler: (any AwayShortcutHandling)?
    private var didStart = false
    private var isStopped = false
    private(set) var shortcutConflicts: [ShortcutAction: ShortcutAction] = [:]
    private var searchConflicts: Set<ShortcutAction> = []
    var onShortcutsChanged: (() -> Void)?

    /// Software-emulated key-repeat timing. Carbon hot keys don't auto-repeat,
    /// so holding the chord runs this loop. Values match macOS keyboard defaults.
    private static let repeatInitialDelay: Duration = .milliseconds(450)
    private static let repeatInterval: Duration = .milliseconds(60)

    private var repeatTasks: [ShortcutAction: Task<Void, Never>] = [:]

    init(
        settings: SettingsManager,
        popupController: any MenuBarPopupControlling,
        resolver: any TargetAppResolving,
        audioEngine: any AudioEngineDispatching,
        audioCommands: any AudioCommandDispatching,
        hud: any PerAppHUDPresenting,
        awayHandler: (any AwayShortcutHandling)? = nil,
        allowsShortcuts: @escaping @MainActor () -> Bool = { true }
    ) {
        self.settings = settings
        self.popupController = popupController
        self.resolver = resolver
        self.audioEngine = audioEngine
        self.audioCommands = audioCommands
        self.hud = hud
        self.awayHandler = awayHandler
        self.allowsShortcuts = allowsShortcuts
    }

    /// Stable `KeyboardShortcuts.Name` per action. The raw string is part of
    /// the persistence contract — don't change it without a migration.
    func name(for action: ShortcutAction) -> KeyboardShortcuts.Name {
        action.keyboardShortcutName
    }

    var hasAssignedShortcuts: Bool {
        ShortcutAction.soundActions.contains {
            settings.appSettings.customShortcuts[$0.rawValue] != nil
                || KeyboardShortcuts.getShortcut(for: name(for: $0)) != nil
        }
    }

    func conflictingAction(for action: ShortcutAction) -> ShortcutAction? {
        shortcutConflicts[action]
    }

    func conflictDescription(for action: ShortcutAction) -> String? {
        if searchConflicts.contains(action) { return "Already used by Search Semper." }
        return shortcutConflicts[action].map { "Already used by \($0.displayName)." }
    }

    func targetAppOptions() -> [ShortcutTargetAppOption] {
        var namesByBundleID: [String: String] = [:]
        for app in audioEngine.apps {
            guard let bundleID = app.bundleID, namesByBundleID[bundleID] == nil else { continue }
            namesByBundleID[bundleID] = app.name
        }

        if let selectedBundleID = settings.appSettings.selectedShortcutTargetBundleID,
           namesByBundleID[selectedBundleID] == nil {
            let runningApp = NSRunningApplication.runningApplications(
                withBundleIdentifier: selectedBundleID
            ).first
            namesByBundleID[selectedBundleID] = runningApp?.localizedName ?? selectedBundleID
        }

        return namesByBundleID
            .map { ShortcutTargetAppOption(bundleID: $0.key, displayName: $0.value) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Routes a fired action to its handler. Exposed `internal` so tests can
    /// drive it directly without faking a global key event.
    @discardableResult
    func dispatch(_ action: ShortcutAction) -> Bool {
        guard !isStopped, allowsShortcuts(), awayHandler?.blocksOrdinaryShortcuts != true else { return false }
        switch action {
        case .togglePopup:
            popupController.toggle()
            return true
        case .toggleAwayMode:
            return false
        case .targetAppVolumeUp:
            return adjustTargetVolume(direction: +1)
        case .targetAppVolumeDown:
            return adjustTargetVolume(direction: -1)
        case .targetAppMuteToggle:
            return toggleTargetMute()
        case .restoreWorkspace, .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter, .windowRestore:
            return false
        }
    }

    // MARK: - Per-app dispatch

    private func adjustTargetVolume(direction: Int) -> Bool {
        guard let app = resolveTargetAudioApp() else { return false }
        let sliderDelta = settings.appSettings.volumeHotkeySliderDelta * Double(direction)

        let currentGain = audioEngine.currentVolume(for: app)
        let currentSlider = VolumeMapping.gainToSlider(currentGain)
        let nextSlider = max(0.0, min(1.0, currentSlider + sliderDelta))
        let nextGain = VolumeMapping.sliderToGain(nextSlider)

        let currentMute = audioEngine.isMuted(for: app)
        let willBeSilent = nextSlider <= 0.001
        let action: ShortcutAction = direction > 0 ? .targetAppVolumeUp : .targetAppVolumeDown
        let transactionID = UUID()
        let context = AudioCommandContext(
            source: .globalShortcut,
            reason: .shortcut,
            transactionID: transactionID
        )

        if direction > 0 {
            if currentMute {
                guard commandSucceeded(audioCommands.dispatch(
                    .setAppMute(target: .active(app), muted: false),
                    context: context
                ), action: action) else {
                    return false
                }
            }
        } else {
            if currentMute && !willBeSilent {
                guard commandSucceeded(audioCommands.dispatch(
                    .setAppMute(target: .active(app), muted: false),
                    context: context
                ), action: action) else {
                    return false
                }
            } else if !currentMute && willBeSilent {
                guard commandSucceeded(audioCommands.dispatch(
                    .setAppMute(target: .active(app), muted: true),
                    context: context
                ), action: action) else {
                    return false
                }
            }
        }
        guard commandSucceeded(audioCommands.dispatch(
            .setAppVolume(target: .active(app), volume: nextGain),
            context: context
        ), action: action) else {
            return false
        }
        hud.showPerAppVolumeHUD(app: app, sliderFraction: nextSlider)
        return true
    }

    private func toggleTargetMute() -> Bool {
        guard let app = resolveTargetAudioApp() else { return false }
        guard commandSucceeded(audioCommands.dispatch(
            .setAppMute(target: .active(app), muted: !audioEngine.isMuted(for: app)),
            context: AudioCommandContext(source: .globalShortcut, reason: .shortcut)
        ), action: .targetAppMuteToggle) else {
            return false
        }
        hud.showPerAppMuteHUD(app: app, isMuted: audioEngine.isMuted(for: app))
        return true
    }

    private func commandSucceeded(_ result: AudioCommandResult, action: ShortcutAction) -> Bool {
        switch result {
        case .applied, .accepted, .unchanged:
            return true
        case .rejected(.sceneOperationInProgress):
            Self.logger.notice("Ignored \(action.rawValue, privacy: .public) while a scene operation is running")
            return false
        case .rejected(let rejection):
            Self.logger.warning(
                "Rejected \(action.rawValue, privacy: .public): \(String(describing: rejection), privacy: .public)"
            )
            return false
        }
    }

    private func startRepeating(action: ShortcutAction) {
        guard !isStopped, action.supportsRepeat else { return }
        repeatTasks[action]?.cancel()
        repeatTasks[action] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.repeatInitialDelay)
            while !Task.isCancelled {
                guard let self else { return }
                guard self.dispatch(action) else {
                    self.repeatTasks[action] = nil
                    return
                }
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func stopRepeating(action: ShortcutAction) {
        repeatTasks[action]?.cancel()
        repeatTasks[action] = nil
    }

    private func resolveTargetAudioApp() -> AudioApp? {
        let candidates = audioEngine.apps
            .compactMap { $0.bundleID }
            .filter { audioEngine.isAudibleNow(bundleID: $0) }

        guard let bundleID = resolver.resolveTargetBundleID(audibleCandidates: candidates) else {
            hud.showPerAppNotControlledHUD(displayName: nil, bundleID: nil, icon: nil)
            return nil
        }
        if let app = audioEngine.apps.first(where: { $0.bundleID == bundleID }) {
            return app
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        hud.showPerAppNotControlledHUD(
            displayName: running?.localizedName,
            bundleID: bundleID,
            icon: running?.icon
        )
        return nil
    }

    /// Idempotent. Subsequent calls are no-ops. Safe to call from a SwiftUI
    /// `.task` modifier on the popup content.
    func start() {
        guard !didStart, !isStopped else { return }
        didStart = true
        syncRegistrations()
        onShortcutsChanged?()

        Self.logger.debug("ShortcutsRegistry started; \(ShortcutAction.soundActions.count) action(s) registered")
    }

    func stop() {
        isStopped = true
        onShortcutsChanged = nil
        for task in repeatTasks.values { task.cancel() }
        repeatTasks.removeAll()
        guard didStart else { return }
        didStart = false
        ShortcutAction.preservingOtherRegistrations(excluding: ShortcutAction.soundActions.map(\.keyboardShortcutName))
        {
            for action in ShortcutAction.soundActions {
                KeyboardShortcuts.removeHandler(for: name(for: action))
            }
        }
    }

    /// Returns a closure suitable for `KeyboardShortcuts.Recorder(for:onChange:)`.
    /// When the user records or clears a chord, the closure mirrors the change
    /// into `SettingsManager.appSettings.customShortcuts`.
    ///
    /// The return type carries `@MainActor` even though the library's parameter
    /// type does not — this works today because `KeyboardShortcuts.Recorder` is
    /// SwiftUI-presented and its `Coordinator.handleChange(_:)` runs on the
    /// MainActor, so passing a more-isolated function value satisfies the
    /// less-isolated parameter via implicit conversion. If a future library
    /// version dispatches `onChange` from a non-MainActor context, that becomes
    /// a runtime crash; the annotation is the contract that makes it surface
    /// loudly rather than silently corrupt MainActor-isolated state.
    func recordCallback(for action: ShortcutAction) -> @MainActor (KeyboardShortcuts.Shortcut?) -> Void {
        return { [weak self] shortcut in
            self?.handleRecorderChange(shortcut: shortcut, for: action)
        }
    }

    private func handleRecorderChange(shortcut: KeyboardShortcuts.Shortcut?, for action: ShortcutAction) {
        guard !isStopped, ShortcutAction.soundActions.contains(action) else { return }
        var app = settings.appSettings
        if let shortcut {
            let recordedShortcut = ShortcutCodable.from(shortcut)
            let conflictingAction = action.conflictingAction(with: recordedShortcut, settings: settings)
            let conflictsWithSearch = ShortcutAction.conflictsWithSearch(recordedShortcut)
            if conflictingAction != nil || conflictsWithSearch {
                ShortcutAction.preservingOtherRegistrations(excluding: [name(for: action)]) {
                    KeyboardShortcuts.setShortcut(
                        app.customShortcuts[action.rawValue]?.keyboardShortcut, for: name(for: action))
                    syncRegistrations()
                }
                shortcutConflicts[action] = conflictingAction
                if conflictsWithSearch { searchConflicts.insert(action) }
                return
            }
            app.customShortcuts[action.rawValue] = recordedShortcut
        } else {
            app.customShortcuts[action.rawValue] = nil
        }
        settings.appSettings = app
        syncRegistrations()
        onShortcutsChanged?()
    }

    func clearAllShortcuts() {
        guard !isStopped else { return }
        ShortcutAction.preservingOtherRegistrations(excluding: ShortcutAction.soundActions.map(\.keyboardShortcutName))
        {
            var app = settings.appSettings
            for action in ShortcutAction.soundActions {
                KeyboardShortcuts.setShortcut(nil, for: name(for: action))
                app.customShortcuts[action.rawValue] = nil
            }
            settings.appSettings = app
            syncRegistrations()
        }
        onShortcutsChanged?()
    }

    func syncRegistrations() {
        guard !isStopped else { return }
        var desired: [ShortcutAction: ShortcutCodable] = [:]
        for action in ShortcutAction.soundActions {
            desired[action] = settings.appSettings.customShortcuts[action.rawValue]
                ?? KeyboardShortcuts.getShortcut(for: name(for: action)).map(ShortcutCodable.from)
        }

        ShortcutAction.preservingOtherRegistrations(excluding: ShortcutAction.soundActions.map(\.keyboardShortcutName))
        {
            var owners: [ShortcutCodable: ShortcutAction] = [:]
            searchConflicts.removeAll()
            var conflicts: [ShortcutAction: ShortcutAction] = [:]
            for action in ShortcutAction.soundActions {
                let actionName = name(for: action)
                stopRepeating(action: action)
                KeyboardShortcuts.removeHandler(for: actionName)

                if let shortcut = desired[action], ShortcutAction.conflictsWithSearch(shortcut) {
                    KeyboardShortcuts.setShortcut(nil, for: actionName)
                    searchConflicts.insert(action)
                } else if let shortcut = desired[action], let owner = owners[shortcut] {
                    KeyboardShortcuts.setShortcut(nil, for: actionName)
                    conflicts[action] = owner
                } else {
                    if let shortcut = desired[action] {
                        owners[shortcut] = action
                    }
                    KeyboardShortcuts.setShortcut(desired[action]?.keyboardShortcut, for: actionName)
                }

                if didStart {
                    KeyboardShortcuts.onKeyDown(for: actionName) { [weak self] in
                        guard let self, self.dispatch(action) else { return }
                        self.startRepeating(action: action)
                    }
                    KeyboardShortcuts.onKeyUp(for: actionName) { [weak self] in
                        self?.stopRepeating(action: action)
                    }
                }
            }
            for action in owners.values where didStart { KeyboardShortcuts.enable(name(for: action)) }
            shortcutConflicts = conflicts
        }
    }

}

extension AudioEngine: AudioEngineDispatching {}
extension HUDWindowController: PerAppHUDPresenting {}
