import Foundation
import Testing
@testable import Semper

@Suite("Connected output default action")
@MainActor
struct OutputDeviceReconnectRoutingTests {
    @Test("Highest-priority device already selected is confirmed")
    func highestPriorityAlreadySelected() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "headphones",
            highestPriorityConnectedUID: "headphones",
            currentDefaultUID: "headphones"
        )

        #expect(action == .ensureHighestPriorityDefault)
    }

    @Test("Highest-priority reconnect switches from the old device")
    func highestPriorityReconnects() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "headphones",
            highestPriorityConnectedUID: "headphones",
            currentDefaultUID: "speakers"
        )

        #expect(action == .ensureHighestPriorityDefault)
    }

    @Test("Lower-priority system auto-switch restores the previous output")
    func lowerPriorityAutoSwitchRestoresPrevious() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "speakers",
            highestPriorityConnectedUID: "headphones",
            currentDefaultUID: "speakers"
        )

        #expect(action == .restorePrevious)
    }

    @Test("Lower-priority connection leaves an unchanged default alone")
    func lowerPriorityConnectionDoesNothing() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "speakers",
            highestPriorityConnectedUID: "headphones",
            currentDefaultUID: "headphones"
        )

        #expect(action == .none)
    }

    @Test("Priority resolution skips disconnected devices")
    func priorityResolutionSkipsDisconnectedDevices() {
        let headphones = AudioDevice(
            id: 2,
            uid: "headphones",
            name: "Headphones",
            icon: nil,
            supportsAutoEQ: false
        )
        let speakers = AudioDevice(
            id: 3,
            uid: "speakers",
            name: "Speakers",
            icon: nil,
            supportsAutoEQ: false
        )

        let resolved = AudioEngine.resolveHighestPriority(
            priorityOrder: ["disconnected", "headphones", "speakers"],
            connectedDevices: [headphones, speakers],
            isAlive: { _ in true }
        )

        #expect(resolved?.uid == "headphones")
    }
}
