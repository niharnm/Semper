// Semper/Settings/Types/SettingsUITypes.swift
import Foundation
import AppKit

// MARK: - App-Wide Settings Enums

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default` = "Default"
    case speaker = "Speaker"
    case device = "Device"
    case waveform = "Waveform"
    case equalizer = "Equalizer"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "Semper"
        case .speaker: return "Volume"
        case .device: return "Output"
        case .waveform: return "Signal"
        case .equalizer: return "Levels"
        }
    }

    /// The SF Symbol used for this menu bar style.
    var iconName: String {
        switch self {
        case .default: return "infinity"
        case .speaker: return "speaker.wave.2"
        case .device: return "hifispeaker"
        case .waveform: return "waveform.path.ecg"
        case .equalizer: return "chart.bar.xaxis"
        }
    }

    var isSystemSymbol: Bool { true }
}

// MARK: - HUD Style

/// Style of the on-screen HUD shown when media keys drive Semper's volume.
/// `.tahoe` renders a small top-right pill; `.classic` renders a center-bottom panel
/// with 16 segment tiles matching Apple's pre-Tahoe HUD aesthetic.
enum HUDStyle: String, Codable, CaseIterable, Identifiable {
    case tahoe
    case classic

    var id: String { rawValue }
}

// MARK: - Appearance Preference

/// User preference for app appearance. `.system` follows macOS appearance live;
/// `.light` and `.dark` lock the override regardless of system setting.
enum AppearancePreference: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case system
    case light
    case dark

    var id: String { rawValue }

    var description: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

extension AppearancePreference {
    /// AppKit appearance override. `nil` means "inherit from window or app".
    /// Apply via `nsView.window?.appearance = value` for any `NSWindow`/`NSPanel`
    /// the app hosts (popup, popover, HUD).
    /// `.aqua` available since macOS 10.9; `.darkAqua` since 10.14.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Menu Bar Popup Size

enum MenuBarPopupSize: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var description: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }
}

struct PopupDimensions: Equatable {
    let width: CGFloat
    let contentPadding: CGFloat
    /// Ceiling on the scrollable body. Sized to stay within a 13" MacBook Air's
    /// usable height after the menu bar, since FluidMenuBarExtra does not clamp
    /// the popup against `screen.visibleFrame` vertically.
    let maxContentHeight: CGFloat
}

extension MenuBarPopupSize {
    var dimensions: PopupDimensions {
        switch self {
        case .compact:
            return PopupDimensions(
                width: 260,
                contentPadding: 8,
                maxContentHeight: 560
            )
        case .comfortable:
            return PopupDimensions(
                width: 280,
                contentPadding: 10,
                maxContentHeight: 660
            )
        case .spacious:
            return PopupDimensions(
                width: 320,
                contentPadding: 12,
                maxContentHeight: 760
            )
        }
    }
}

// MARK: - Volume Hotkey Step Size

enum VolumeHotkeyStep: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case coarse
    case normal
    case fine
    case extraFine
    case custom

    static let defaultCustomPercent = 5.0
    static let customPercentRange = 1.0...25.0

    var id: String { rawValue }

    var sliderDelta: Double {
        switch self {
        case .coarse:    return 1.0 / 8.0
        case .normal:    return 1.0 / 16.0
        case .fine:      return 1.0 / 32.0
        case .extraFine: return 1.0 / 64.0
        case .custom:    return Self.defaultCustomPercent / 100.0
        }
    }

    func sliderDelta(customPercent: Double) -> Double {
        guard self == .custom else { return sliderDelta }
        return Self.clampedCustomPercent(customPercent) / 100.0
    }

    static func clampedCustomPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return defaultCustomPercent }
        return min(max(percent, customPercentRange.lowerBound), customPercentRange.upperBound)
    }

    var description: String {
        switch self {
        case .coarse:    return "Coarse (12.5%)"
        case .normal:    return "Normal (6.25%)"
        case .fine:      return "Fine (3.13%)"
        case .extraFine: return "Extra-Fine (1.56%)"
        case .custom:    return "Custom"
        }
    }
}

// MARK: - App Hotkey Target

enum ShortcutTargetMode: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case playingApp
    case frontmostApp
    case selectedApp

    var id: String { rawValue }

    var description: String {
        switch self {
        case .playingApp: return "Playing App"
        case .frontmostApp: return "Frontmost App"
        case .selectedApp: return "Selected App"
        }
    }
}
