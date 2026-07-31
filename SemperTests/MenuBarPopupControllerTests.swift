// SemperTests/MenuBarPopupControllerTests.swift
import Testing
import AppKit
@testable import Semper

@Suite("MenuBarPopupController", .serialized)
@MainActor
struct MenuBarPopupControllerTests {
    @Test("toggle is a no-op when no matching status item exists")
    func noMatchingItem() {
        // Use a deliberately unique accessibility title so no real status item
        // (e.g. one materialized by another concurrently-running test) can match.
        let controller = MenuBarPopupController(accessibilityTitle: "SemperTest-NoSuchItem-\(UUID().uuidString)")
        controller.toggle()  // must not crash; logs a debug message and returns
    }

    @Test("findStatusItem returns nil when no matching status item exists")
    func findReturnsNilWhenNoMatch() {
        let controller = MenuBarPopupController(accessibilityTitle: "SemperTest-NoSuchItem-\(UUID().uuidString)")
        #expect(controller.findStatusItem() == nil)
    }

    @Test("findStatusItem locates the matching status item by accessibility title")
    func findLocatesMatching() {
        let title = "SemperTest-Match-\(UUID().uuidString)"
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.setAccessibilityTitle(title)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        // Materialize the button window so KVC has a fully-formed window to walk.
        _ = statusItem.button?.window?.windowNumber

        let controller = MenuBarPopupController(accessibilityTitle: title)
        let found = controller.findStatusItem()

        #expect(found === statusItem)
    }

    @Test("findStatusItem ignores items with non-matching accessibility titles")
    func findIgnoresNonMatching() {
        let otherTitle = "SemperTest-Other-\(UUID().uuidString)"
        let other = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        other.button?.setAccessibilityTitle(otherTitle)
        defer { NSStatusBar.system.removeStatusItem(other) }
        _ = other.button?.window?.windowNumber

        let controller = MenuBarPopupController(accessibilityTitle: "SemperTest-Searching-\(UUID().uuidString)")
        #expect(controller.findStatusItem() == nil)
    }

    @Test("toggle on a discovered status item runs to completion without crashing")
    func toggleEndToEndSmoke() {
        // We don't assert event delivery here — `NSApp.postEvent` -> `LocalEventMonitor`
        // round-trips inside a unit-test process are flaky because the test runner's
        // event-pump differs from a normal app's. Production validation lives in the
        // manual smoke check in /ft-verify and Phase 8 of the plan. This test
        // exercises the full discovery + event-construction path so a regression
        // (nil event, missing window, KVC failure) surfaces as a crash or early return.
        let title = "SemperTest-Smoke-\(UUID().uuidString)"
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.setAccessibilityTitle(title)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        _ = statusItem.button?.window?.windowNumber

        let controller = MenuBarPopupController(accessibilityTitle: title)
        controller.toggle()  // must not crash
    }
}
