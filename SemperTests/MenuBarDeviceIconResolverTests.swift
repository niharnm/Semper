// SemperTests/MenuBarDeviceIconResolverTests.swift

import Testing
import AudioToolbox
@testable import Semper

@Suite("MenuBarDeviceIconResolver")
struct MenuBarDeviceIconResolverTests {
    private func device(id: AudioDeviceID, uid: String, name: String) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: true)
    }

    private func resolve(
        priorityOrder: [String],
        outputDevices: [AudioDevice],
        defaultDeviceID: AudioDeviceID = 999,
        unavailableUIDs: Set<String> = []
    ) -> String {
        MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: priorityOrder,
            outputDevices: outputDevices,
            defaultDeviceID: defaultDeviceID,
            isDeviceAvailable: { !unavailableUIDs.contains($0.uid) },
            symbolForDevice: { device in
                if device.name.contains("AirPods") { return "airpodspro" }
                if device.name.contains("HomePod") { return "homepod" }
                if device.name.contains("Display") { return "display" }
                if device.name.contains("HDMI") { return "tv" }
                return "headphones"
            },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
    }

    @Test("AirPods/Bluetooth priority returns headphone-style symbol")
    func airPodsPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(resolve(priorityOrder: ["airpods", "speakers"], outputDevices: devices) == "airpodspro")
    }

    @Test("Current default output takes precedence over saved priority")
    func defaultOutputTakesPrecedence() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(
            resolve(
                priorityOrder: ["speakers", "airpods"],
                outputDevices: devices,
                defaultDeviceID: 2
            ) == "airpodspro"
        )
    }

    @Test("HomePod/AirPlay priority returns HomePod-style symbol")
    func homePodPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "homepod", name: "HomePod")
        ]

        #expect(resolve(priorityOrder: ["homepod", "speakers"], outputDevices: devices) == "homepod")
    }

    @Test("HDMI or display priority returns display-style symbol")
    func displayPriority() {
        let devices = [
            device(id: 1, uid: "hdmi", name: "HDMI Output"),
            device(id: 2, uid: "studio-display", name: "Studio Display")
        ]

        #expect(resolve(priorityOrder: ["hdmi"], outputDevices: devices) == "tv")
        #expect(resolve(priorityOrder: ["studio-display"], outputDevices: devices) == "display")
    }

    @Test("Unavailable priority device falls back to next connected priority device")
    func unavailablePriorityFallsBack() {
        let devices = [
            device(id: 1, uid: "airpods", name: "AirPods Pro"),
            device(id: 2, uid: "homepod", name: "HomePod")
        ]

        #expect(
            resolve(
                priorityOrder: ["airpods", "homepod"],
                outputDevices: devices,
                unavailableUIDs: ["airpods"]
            ) == "homepod"
        )
    }

    @Test("Unavailable default output falls back to connected priority device")
    func unavailableDefaultFallsBackToPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(
            resolve(
                priorityOrder: ["speakers", "airpods"],
                outputDevices: devices,
                defaultDeviceID: 2,
                unavailableUIDs: ["airpods"]
            ) == "headphones"
        )
    }

    @Test("No output devices falls back to default device then hard fallback")
    func noOutputDevicesFallbacks() {
        #expect(resolve(priorityOrder: [], outputDevices: [], defaultDeviceID: 42) == "speaker.wave.2")

        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: .unknown,
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "unused" },
            symbolForDefaultID: { _ in "unused" }
        )
        #expect(symbol == MenuBarDeviceIconResolver.fallbackSymbol)
    }

    @Test("Resolvable override wins over the derived symbol")
    func resolvableOverrideWins() {
        let devices = [device(id: 2, uid: "airpods", name: "AirPods Pro")]
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: ["airpods"],
            outputDevices: devices,
            defaultDeviceID: 2,
            overrideForUID: { ["airpods": "gamecontroller.fill"][$0] },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "headphones" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "gamecontroller.fill")
    }

    @Test("Unresolvable override falls back to the derived symbol")
    func unresolvableOverrideFallsBack() {
        let devices = [device(id: 2, uid: "airpods", name: "AirPods Pro")]
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: ["airpods"],
            outputDevices: devices,
            defaultDeviceID: 2,
            overrideForUID: { _ in "not.a.real.symbol" },
            isSymbolResolvable: { _ in false },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "headphones" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "headphones")
    }

    @Test("The default validator accepts a real SF Symbol and rejects a bogus name")
    func defaultValidatorChecksRealSymbols() {
        let devices = [device(id: 2, uid: "airpods", name: "AirPods Pro")]
        func resolve(override: String) -> String {
            MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: ["airpods"],
                outputDevices: devices,
                defaultDeviceID: 2,
                overrideForUID: { _ in override },
                isDeviceAvailable: { _ in true },
                symbolForDevice: { _ in "headphones" },
                symbolForDefaultID: { _ in "speaker.wave.2" }
            )
        }
        #expect(resolve(override: "gamecontroller.fill") == "gamecontroller.fill")
        #expect(resolve(override: "not.a.real.symbol") == "headphones")
    }

    @Test("Priority-path device consults the override too")
    func priorityPathConsultsOverride() {
        let devices = [device(id: 2, uid: "homepod", name: "HomePod")]
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: ["homepod"],
            outputDevices: devices,
            defaultDeviceID: 999,
            overrideForUID: { ["homepod": "tv.fill"][$0] },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "homepod" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "tv.fill")
    }

    @Test("Default-ID path surfaces a resolvable override")
    func defaultIDOverrideWins() {
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: 42,
            overrideForUID: { ["monitor-uid": "tv.fill"][$0] },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            uidForDefaultID: { _ in "monitor-uid" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "tv.fill")
    }

    @Test("Default-ID path validates the override")
    func defaultIDOverrideValidated() {
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: 42,
            overrideForUID: { _ in "not.a.real.symbol" },
            isSymbolResolvable: { _ in false },
            isDeviceAvailable: { _ in true },
            uidForDefaultID: { _ in "monitor-uid" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "speaker.wave.2")
    }

    @Test("Default ID with unreadable UID falls through to the derived symbol")
    func defaultIDUnreadableUIDFallsThrough() {
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: 42,
            overrideForUID: { _ in "tv.fill" },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            uidForDefaultID: { _ in nil },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "speaker.wave.2")
    }

    @Test("Invalid default ID returns the fallback without consulting the override")
    func defaultIDInvalidReturnsFallback() {
        var consulted = false
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: .unknown,
            overrideForUID: { _ in
                consulted = true
                return "nope"
            },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "unused" },
            symbolForDefaultID: { _ in "unused" }
        )
        #expect(symbol == MenuBarDeviceIconResolver.fallbackSymbol)
        #expect(!consulted)
    }
}
