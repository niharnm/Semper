// Semper/Shortcuts/MenuBarPopupController.swift
import AppKit
import os

/// Toggles the Semper menu-bar popup from outside the SwiftUI scene chain
/// (e.g. when a global hotkey fires).
///
/// Locates the underlying `NSStatusItem` via `NSApp.windows` + KVC introspection
/// of the private `NSStatusBarWindow.statusItem` key. This is the same technique
/// used by `orchetect/MenuBarExtraAccess` for Apple's `MenuBarExtra` and works
/// equally well for `FluidMenuBarExtra` because both ultimately call
/// `NSStatusBar.system.statusItem(...)` and rely on the standard menu-bar window
/// machinery. The technique is package-agnostic and avoids needing any callback
/// wiring (no `onStatusItemReady`, no Scene-reference capture).
///
/// Once the status item is located, we toggle the popup by posting a synthetic
/// `.leftMouseDown` event aimed at the button's window. `FluidMenuBarExtra`
/// installs a `LocalEventMonitor` that filters events on the status button's
/// window — the synthetic event satisfies that filter and re-uses the package's
/// existing visible→dismiss / hidden→show toggle logic, including the
/// screen-edge framing math.
@MainActor
protocol MenuBarPopupControlling: AnyObject {
    func toggle()
}

@MainActor
final class MenuBarPopupController: MenuBarPopupControlling {
    private static let logger = Logger(
        subsystem: "systems.semper.Semper",
        category: "MenuBarPopupController"
    )

    /// Accessibility title used to identify Semper's status item among any
    /// other status items in the same process. `FluidMenuBarExtra` sets this on
    /// the button via `setAccessibilityTitle(title)` where `title` is the first
    /// argument we pass to `FluidMenuBarExtra(...)` in `SemperApp`.
    private let accessibilityTitle: String

    init(accessibilityTitle: String = "Semper") {
        self.accessibilityTitle = accessibilityTitle
    }

    func toggle() {
        guard let statusItem = findStatusItem() else {
            Self.logger.debug("toggle: no status item found yet (cold-launch race?); ignoring")
            return
        }
        guard let button = statusItem.button, let window = button.window else {
            Self.logger.debug("toggle: status item found but button/window missing; ignoring")
            return
        }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        let location = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            Self.logger.error("toggle: failed to construct synthetic mouse-down event")
            return
        }

        NSApp.postEvent(event, atStart: false)
    }

    // MARK: - NSApp.windows + KVC introspection

    /// macOS renamed the concrete `NSStatusItem` runtime class in the macOS 26
    /// scene-based status item refactor. Keep both branches so we work across
    /// the deployment-target floor (14.2) up through current 26.x.
    private static var concreteStatusItemClassName: String {
        if #available(macOS 26.0, *) {
            return "NSSceneStatusItem"
        }
        return "NSStatusItem"
    }

    /// Exposed `internal` so tests can verify discovery without depending on
    /// `NSApp.postEvent` delivery, which is flaky in a unit-test process.
    func findStatusItem() -> NSStatusItem? {
        let concreteName = Self.concreteStatusItemClassName

        return NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap(Self.extractStatusItem(from:))
            // Multi-display setups with "Displays have separate Spaces" enabled produce
            // one NSStatusBarWindow per display; the inactive ones return an
            // `NSStatusItemReplicant` (a subclass of NSStatusItem). Skip replicants —
            // we only want the canonical item that owns the real button.
            .filter { $0.className == concreteName }
            .first { $0.button?.accessibilityTitle() == accessibilityTitle }
    }

    /// Pulls the `statusItem` private key off an `NSStatusBarWindow`.
    /// KVC is the primary path; `Mirror` is a defensive fallback in case Apple
    /// changes how the property is exposed in a future macOS release.
    private static func extractStatusItem(from window: NSWindow) -> NSStatusItem? {
        if let item = window.value(forKey: "statusItem") as? NSStatusItem {
            return item
        }
        return Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
    }
}
