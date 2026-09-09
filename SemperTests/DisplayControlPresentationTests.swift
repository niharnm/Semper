import Foundation
import Testing

@testable import Semper

@MainActor
private final class MutableDisplaySceneState {
    var isInProgress = false
}

@Suite("Display control presentation")
struct DisplayControlPresentationTests {
    @Test("Known MCCS input values use standard port names")
    func standardInputNames() {
        let labels: [UInt8: String] = [
            0x01: "VGA 1",
            0x02: "VGA 2",
            0x03: "DVI 1",
            0x04: "DVI 2",
            0x05: "Composite 1",
            0x06: "Composite 2",
            0x07: "S-Video 1",
            0x08: "S-Video 2",
            0x09: "Tuner 1",
            0x0A: "Tuner 2",
            0x0B: "Tuner 3",
            0x0C: "Component 1",
            0x0D: "Component 2",
            0x0E: "Component 3",
            0x0F: "DisplayPort 1",
            0x10: "DisplayPort 2",
            0x11: "HDMI 1",
            0x12: "HDMI 2",
        ]

        for (value, label) in labels {
            #expect(DisplayInputLabel.text(for: value) == label)
        }
        #expect(DisplayInputLabel.text(for: 0x1B) == "Input 0x1B")
        #expect(DisplayInputLabel.text(for: 0xFF) == "Input 0xFF")
    }

    @Test("A confirmation opened before a Scene cannot dispatch after the Scene starts")
    @MainActor
    func sceneStartBlocksStaleConfirmation() async {
        let sceneState = MutableDisplaySceneState()
        let initiallyAllowed = DisplayManualControlDispatchPolicy.allowsDispatch(
            sceneOperationIsInProgress: { sceneState.isInProgress },
            isPending: false
        )
        #expect(initiallyAllowed)
        let queuedDispatch = Task { @MainActor in
            await Task.yield()
            return DisplayManualControlDispatchPolicy.allowsDispatch(
                sceneOperationIsInProgress: { sceneState.isInProgress },
                isPending: false
            )
        }
        sceneState.isInProgress = true
        #expect(await queuedDispatch.value == false)
        let duplicateBlocked = DisplayManualControlDispatchPolicy.allowsDispatch(
            sceneOperationIsInProgress: { false },
            isPending: true
        )
        #expect(!duplicateBlocked)
    }

    @Test("Active slider drafts survive unrelated display publication")
    func activeDraftPreservation() {
        #expect(DisplaySliderDraftPolicy.preservesDraft(
            isPending: false,
            isEditing: true,
            isLinkedToActiveEdit: false
        ))
        #expect(DisplaySliderDraftPolicy.preservesDraft(
            isPending: false,
            isEditing: false,
            isLinkedToActiveEdit: true
        ))
        #expect(!DisplaySliderDraftPolicy.preservesDraft(
            isPending: false,
            isEditing: false,
            isLinkedToActiveEdit: false
        ))

        #expect(DisplaySliderDraftPolicy.synchronizedValue(
            published: nil,
            draft: 0.42,
            preservesDraft: true
        ) == 0.42)
        #expect(DisplaySliderDraftPolicy.synchronizedValue(
            published: nil,
            draft: 0.42,
            preservesDraft: false
        ) == nil)
    }

    @Test("Volume drafts override published Default and Muted sentinels")
    func volumeDraftLabel() {
        let defaultReading = DisplayVolumeReading(
            current: 0,
            maximum: 0xFF,
            encoding: .continuousSubrange
        )!
        let mutedReading = DisplayVolumeReading(
            current: 0xFF,
            maximum: 0xFF,
            encoding: .continuousSubrange
        )!

        #expect(DisplayVolumeLabel.text(reading: defaultReading, draft: nil) == "Default")
        #expect(DisplayVolumeLabel.text(reading: mutedReading, draft: nil) == "Muted")
        #expect(DisplayVolumeLabel.text(reading: defaultReading, draft: 0.42) == "42%")
        #expect(DisplayVolumeLabel.text(reading: mutedReading, draft: 0.58) == "58%")
    }

    @Test("Group status names every requested target and its exact outcome")
    func groupTargetStatus() {
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let third = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 5)!
        let report = DisplayGroupWriteReport(
            groupID: UUID(),
            outcomes: [
                .init(
                    identity: first,
                    result: .feature(.applied(
                        DisplayFeatureReading(current: 50, maximum: 100)!
                    ))
                ),
                .init(identity: second, result: .cancelled),
                .init(identity: third, result: .notAttempted),
            ]
        )

        let message = DisplayGroupStatusFormatter.message(
            controlName: "Brightness",
            report: report,
            displayNames: [
                first: "Desk Left",
                second: "Desk Right",
                third: "Dock Display",
            ]
        )

        #expect(
            message
                == "Brightness: Desk Left: confirmed; Desk Right: cancelled; Dock Display: not attempted."
        )
    }

    @Test("Unconfirmed input uses attempted wording and disconnected targets stay visible")
    func uncertainAndDisconnectedStatus() {
        let input = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let disconnected = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let report = DisplayGroupWriteReport(
            groupID: UUID(),
            outcomes: [
                .init(
                    identity: input,
                    result: .input(.unconfirmed(expected: 0x0F, readback: nil))
                ),
                .init(identity: disconnected, result: .failed),
            ]
        )

        let message = DisplayGroupStatusFormatter.message(
            controlName: "Input",
            report: report,
            displayNames: [input: "Desk Display"]
        )

        #expect(
            message
                == "Input: Desk Display: attempted once, not confirmed; Disconnected display: failed."
        )
    }
}
