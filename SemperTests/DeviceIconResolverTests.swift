// SemperTests/DeviceIconResolverTests.swift

import Testing
import AppKit
@testable import Semper

@Suite("DeviceIconResolver")
struct DeviceIconResolverTests {
    private let automatic = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)

    @Test("Valid override symbol wins over the automatic icon")
    func overrideWins() {
        let resolved = DeviceIconResolver.displayIcon(
            overrideSymbol: "gamecontroller.fill", automatic: automatic, deviceName: "Test"
        )
        #expect(resolved != nil)
        #expect(resolved !== automatic)
    }

    @Test("Nil override falls back to the automatic icon")
    func nilOverrideFallsBack() {
        let resolved = DeviceIconResolver.displayIcon(
            overrideSymbol: nil, automatic: automatic, deviceName: "Test"
        )
        #expect(resolved === automatic)
    }

    @Test("Unresolvable override falls back to the automatic icon")
    func invalidOverrideFallsBack() {
        let resolved = DeviceIconResolver.displayIcon(
            overrideSymbol: "not.a.real.symbol.zzz", automatic: automatic, deviceName: "Test"
        )
        #expect(resolved === automatic)
    }

    @Test("Unresolvable override with no automatic icon returns nil")
    func invalidOverrideNoAutomatic() {
        let resolved = DeviceIconResolver.displayIcon(
            overrideSymbol: "not.a.real.symbol.zzz", automatic: nil, deviceName: "Test"
        )
        #expect(resolved == nil)
    }
}
