import Foundation
import Testing
@testable import Semper

@Suite("Scene models")
struct SceneModelsTests {
    @Test("Every scene control survives a Codable round trip")
    func controlCodableRoundTrips() throws {
        let controls: [SceneControl] = [
            .awakeMode,
            .audioOutputDevice,
            .audioOutputVolume(deviceID: "output.usb"),
            .audioOutputMuted(deviceID: "output.usb"),
            .displayBrightness(displayID: "display-a"),
            .displayContrast(displayID: "display-b"),
        ]

        for control in controls {
            let data = try SceneJSONCoding.encoder().encode(control)
            let decoded = try SceneJSONCoding.decoder().decode(SceneControl.self, from: data)
            #expect(decoded == control)
        }
    }

    @Test("Every scene value survives a Codable round trip")
    func valueCodableRoundTrips() throws {
        let values: [SceneValue] = [
            .number(0.625),
            .boolean(true),
            .boolean(false),
            .text("output.usb"),
            .awake(.off),
            .awake(.system),
            .awake(.displayAndSystem),
        ]

        for value in values {
            let data = try SceneJSONCoding.encoder().encode(value)
            let decoded = try SceneJSONCoding.decoder().decode(SceneValue.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("Controls report their domain, value kind, and device identifier")
    func controlMetadata() {
        #expect(SceneControl.awakeMode.domain == .power)
        #expect(SceneControl.awakeMode.valueKind == .awake)
        #expect(SceneControl.audioOutputDevice.domain == .audio)
        #expect(SceneControl.audioOutputDevice.valueKind == .text)
        #expect(SceneControl.audioOutputVolume(deviceID: "output.usb").valueKind == .number)
        #expect(SceneControl.audioOutputVolume(deviceID: "output.usb").deviceIdentifier == "output.usb")
        #expect(SceneControl.audioOutputMuted(deviceID: "output.usb").valueKind == .boolean)
        #expect(SceneControl.audioOutputMuted(deviceID: "output.usb").deviceIdentifier == "output.usb")
        #expect(SceneControl.displayBrightness(displayID: "a").domain == .display)
        #expect(SceneControl.displayBrightness(displayID: "a").deviceIdentifier == "a")
        #expect(SceneControl.displayContrast(displayID: "b").valueKind == .number)
        #expect(SceneControl.displayContrast(displayID: "b").deviceIdentifier == "b")
    }

    @Test("Output volume is prepared before output routing")
    func audioApplyOrder() {
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        #expect(SceneControl.orderedBefore(volume, .audioOutputDevice))
    }

    @Test("Scene validation accepts a well-formed scene")
    func validScene() throws {
        let scene = SemperScene(name: "Desk", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
            SceneAction(control: .audioOutputVolume(deviceID: "output.usb"), target: .number(0.4), importance: .optional),
            SceneAction(control: .displayBrightness(displayID: "display-a"), target: .number(0.7), importance: .optional),
        ])

        try scene.validate()
    }

    @Test("Scene validation rejects empty names and action lists")
    func rejectsEmptySceneStructure() {
        #expect(throws: SceneValidationIssue.emptyName) {
            try SemperScene(
                name: " \n ",
                actions: [SceneAction(control: .awakeMode, target: .awake(.system), importance: .required)]
            ).validate()
        }
        #expect(throws: SceneValidationIssue.noActions) {
            try SemperScene(name: "Empty", actions: []).validate()
        }
    }

    @Test("Scene validation rejects duplicate controls")
    func rejectsDuplicateControls() {
        let control = SceneControl.audioOutputVolume(deviceID: "output.usb")
        #expect(throws: SceneValidationIssue.duplicateControl(control)) {
            try SemperScene(name: "Duplicate", actions: [
                SceneAction(control: control, target: .number(0.2), importance: .required),
                SceneAction(control: control, target: .number(0.8), importance: .optional),
            ]).validate()
        }
    }

    @Test("Scene validation rejects the wrong value kind")
    func rejectsValueKindMismatch() {
        let control = SceneControl.audioOutputMuted(deviceID: "output.usb")
        #expect(throws: SceneValidationIssue.valueKindMismatch(
            control: control,
            expected: .boolean,
            found: .number
        )) {
            try SemperScene(name: "Wrong type", actions: [
                SceneAction(control: control, target: .number(0.5), importance: .required),
            ]).validate()
        }
    }

    @Test("Scene validation rejects finite out-of-range numbers")
    func rejectsOutOfRangeNumbers() {
        let control = SceneControl.displayContrast(displayID: "display-a")
        #expect(throws: SceneValidationIssue.numberOutOfRange(control: control, value: 1.01)) {
            try SemperScene(name: "Too high", actions: [
                SceneAction(control: control, target: .number(1.01), importance: .required),
            ]).validate()
        }
    }

    @Test("Scene validation rejects non-finite numbers")
    func rejectsNonFiniteNumbers() {
        let control = SceneControl.audioOutputVolume(deviceID: "output.usb")
        do {
            try SemperScene(name: "Not finite", actions: [
                SceneAction(control: control, target: .number(.infinity), importance: .required),
            ]).validate()
            Issue.record("Expected non-finite target validation to fail")
        } catch let issue {
            guard case .numberOutOfRange(let foundControl, let value) = issue else {
                Issue.record("Unexpected validation issue: \(issue)")
                return
            }
            #expect(foundControl == control)
            #expect(value.isInfinite)
        }
    }

    @Test("Scene validation rejects empty control identifiers and text targets")
    func rejectsEmptyIdentifiersAndText() {
        let display = SceneControl.displayBrightness(displayID: "")
        #expect(throws: SceneValidationIssue.emptyControlIdentifier(display)) {
            try SemperScene(name: "No display", actions: [
                SceneAction(control: display, target: .number(0.5), importance: .required),
            ]).validate()
        }

        #expect(throws: SceneValidationIssue.emptyTargetText(.audioOutputDevice)) {
            try SemperScene(name: "No output", actions: [
                SceneAction(control: .audioOutputDevice, target: .text(""), importance: .required),
            ]).validate()
        }
    }

    @Test("Numeric matching uses tolerance and rejects non-finite values")
    func tolerantNumericMatching() {
        #expect(SceneValue.number(0.5).matches(.number(0.509)))
        #expect(!SceneValue.number(0.5).matches(.number(0.511)))
        #expect(!SceneValue.number(.nan).matches(.number(.nan)))
        #expect(!SceneValue.number(0.5).matches(.boolean(true)))
    }
}
