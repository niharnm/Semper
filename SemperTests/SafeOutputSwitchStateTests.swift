import Foundation
import Testing
@testable import Semper

@Suite("Safe output switch state")
struct SafeOutputSwitchStateTests {
    @Test("A switch without a volume limit is immediate")
    func noLimit() {
        let state = SafeOutputSwitchState(
            targetDeviceUID: "usb-output",
            volumeLimit: nil,
            observedTargetVolume: nil
        )

        #expect(state.action == .switchOutput(deviceUID: "usb-output"))
    }

    @Test("A target already within its limit switches immediately")
    func alreadyWithinLimit() {
        let state = SafeOutputSwitchState(
            targetDeviceUID: "headphones",
            volumeLimit: 0.5,
            observedTargetVolume: 0.505
        )

        #expect(state.action == .switchOutput(deviceUID: "headphones"))
    }

    @Test("A target above its limit must be lowered first")
    func aboveLimit() {
        let state = SafeOutputSwitchState(
            targetDeviceUID: "display",
            volumeLimit: 0.4,
            observedTargetVolume: 0.8
        )

        #expect(state.action == .lowerTargetVolume(deviceUID: "display", to: 0.4))
    }

    @Test("An unknown target volume must be preflighted")
    func unknownVolume() {
        let state = SafeOutputSwitchState(
            targetDeviceUID: "airplay",
            volumeLimit: 0.3,
            observedTargetVolume: nil
        )

        #expect(state.action == .lowerTargetVolume(deviceUID: "airplay", to: 0.3))
    }

    @Test("A confirmed write authorizes only an observed capped target")
    func confirmedWrite() {
        var accepted = SafeOutputSwitchState(
            targetDeviceUID: "usb-output",
            volumeLimit: 0.45,
            observedTargetVolume: 0.9
        )
        var missingReadback = accepted
        var highReadback = accepted

        #expect(accepted.handle(.writeCompleted(
            succeeded: true,
            observedTargetVolume: 0.45
        )) == .switchOutput(deviceUID: "usb-output"))
        #expect(missingReadback.handle(.writeCompleted(
            succeeded: true,
            observedTargetVolume: nil
        )) == .keepCurrentOutput)
        #expect(highReadback.handle(.writeCompleted(
            succeeded: true,
            observedTargetVolume: 0.7
        )) == .keepCurrentOutput)
    }

    @Test("A failed write keeps the current output even if the readback is low")
    func failedWrite() {
        var state = SafeOutputSwitchState(
            targetDeviceUID: "headphones",
            volumeLimit: 0.5,
            observedTargetVolume: 0.8
        )

        #expect(state.handle(.writeCompleted(
            succeeded: false,
            observedTargetVolume: 0.2
        )) == .keepCurrentOutput)
        #expect(state.handle(.timeout(observedTargetVolume: 0.2)) == .keepCurrentOutput)
    }

    @Test("Timeout authorizes only an observed capped target")
    func timeoutReadback() {
        var accepted = SafeOutputSwitchState(
            targetDeviceUID: "headphones",
            volumeLimit: 0.5,
            observedTargetVolume: nil
        )
        var missingReadback = accepted
        var highReadback = accepted

        #expect(accepted.handle(.timeout(observedTargetVolume: 0.49))
            == .switchOutput(deviceUID: "headphones"))
        #expect(missingReadback.handle(.timeout(observedTargetVolume: nil))
            == .keepCurrentOutput)
        #expect(highReadback.handle(.timeout(observedTargetVolume: 0.7))
            == .keepCurrentOutput)
    }

    @Test("Non-finite readbacks never authorize a capped switch")
    func nonFiniteReadback() {
        var state = SafeOutputSwitchState(
            targetDeviceUID: "headphones",
            volumeLimit: 0.5,
            observedTargetVolume: .nan
        )

        #expect(state.action == .lowerTargetVolume(deviceUID: "headphones", to: 0.5))
        #expect(state.handle(.timeout(observedTargetVolume: .infinity)) == .keepCurrentOutput)
    }

    @Test("Invalid requests keep the current output")
    func invalidRequest() {
        let missingUID = SafeOutputSwitchState(
            targetDeviceUID: "",
            volumeLimit: 0.5,
            observedTargetVolume: 0.2
        )
        let invalidLimit = SafeOutputSwitchState(
            targetDeviceUID: "headphones",
            volumeLimit: .nan,
            observedTargetVolume: 0.2
        )

        #expect(missingUID.action == .keepCurrentOutput)
        #expect(invalidLimit.action == .keepCurrentOutput)
    }

    @Test("Preflight timeout is 250 milliseconds")
    func timeoutDuration() {
        #expect(SafeOutputSwitchState.preflightTimeout == .milliseconds(250))
    }
}
