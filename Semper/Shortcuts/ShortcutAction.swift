// Semper/Shortcuts/ShortcutAction.swift
import AppKit
import Foundation
import KeyboardShortcuts

/// Actions that can be bound to a user-recordable global keyboard shortcut.
///
/// Sound and shell registries own their respective handlers. The `rawValue` is the persistence key
/// in `AppSettings.customShortcuts` and must be stable across releases.
enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case togglePopup
    case toggleAwayMode
    case targetAppVolumeUp = "frontmostAppVolumeUp"
    case targetAppVolumeDown = "frontmostAppVolumeDown"
    case targetAppMuteToggle = "frontmostAppMuteToggle"
    case restoreWorkspace

    static var soundActions: [Self] { allCases.filter { !shellActions.contains($0) } }

    static let shellActions: [Self] = [.restoreWorkspace, .toggleAwayMode]

    var displayName: String {
        switch self {
        case .togglePopup: "Toggle Semper Popup"
        case .toggleAwayMode: "Away Mode"
        case .targetAppVolumeUp: "App Volume Up"
        case .targetAppVolumeDown: "App Volume Down"
        case .targetAppMuteToggle: "App Mute"
        case .restoreWorkspace: "Restore workspace"
        }
    }

    /// Whether holding the chord should keep firing the action while held,
    /// matching macOS media-key auto-repeat. Toggles must not repeat
    /// (would flip-flop state every interval).
    var supportsRepeat: Bool {
        switch self {
        case .targetAppVolumeUp, .targetAppVolumeDown: true
        case .togglePopup, .toggleAwayMode, .targetAppMuteToggle, .restoreWorkspace: false
        }
    }

    @MainActor
    var keyboardShortcutName: KeyboardShortcuts.Name {
        switch self {
        case .togglePopup: KeyboardShortcuts.Name("toggle-popup")
        case .toggleAwayMode: KeyboardShortcuts.Name("toggle-away-mode")
        case .targetAppVolumeUp: KeyboardShortcuts.Name("frontmost-app-volume-up")
        case .targetAppVolumeDown: KeyboardShortcuts.Name("frontmost-app-volume-down")
        case .targetAppMuteToggle: KeyboardShortcuts.Name("frontmost-app-mute-toggle")
        case .restoreWorkspace: KeyboardShortcuts.Name("workspace-restore")
        }
    }

    @MainActor
    static let searchShortcut = KeyboardShortcuts.Name(
        "search-semper-actions", default: .init(.k, modifiers: [.command, .option]))

    @MainActor
    static func conflictsWithSearch(_ shortcut: ShortcutCodable) -> Bool {
        KeyboardShortcuts.getShortcut(for: searchShortcut).map(ShortcutCodable.from) == shortcut
    }

    // The library unregisters by chord, including when a recorder rejects a duplicate.
    @MainActor
    static func preservingOtherRegistrations(
        excluding names: [KeyboardShortcuts.Name], additionalNames: [KeyboardShortcuts.Name] = [],
        _ update: () -> Void
    ) {
        let candidates = allCases.map(\.keyboardShortcutName) + [searchShortcut] + additionalNames
        let preserved = candidates.filter { !names.contains($0) && KeyboardShortcuts.isEnabled(for: $0) }
            .compactMap { name in KeyboardShortcuts.getShortcut(for: name).map { (name, $0) } }
        update()
        for (name, shortcut) in preserved where KeyboardShortcuts.getShortcut(for: name) == shortcut {
            KeyboardShortcuts.enable(name)
        }
    }

    @MainActor
    func assignedShortcut(in settings: SettingsManager) -> ShortcutCodable? {
        settings.appSettings.customShortcuts[rawValue]
            ?? KeyboardShortcuts.getShortcut(for: keyboardShortcutName).map(ShortcutCodable.from)
    }

    @MainActor
    func conflictingAction(with shortcut: ShortcutCodable, settings: SettingsManager) -> Self? {
        Self.allCases.first { $0 != self && $0.assignedShortcut(in: settings) == shortcut }
    }
}
