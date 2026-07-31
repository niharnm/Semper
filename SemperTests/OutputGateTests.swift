import Foundation
import Testing
@testable import Semper

private let belowGateThreshold: Float = 0.00005
private let aboveGateThreshold: Float = 0.01
private let gateRampSamples: Float = 1_920

@Suite("OutputGate state machine")
struct OutputGateTests {
    @Test("Armed gate waits for audible input")
    func armedGateWaitsForAudio() {
        var phase: UInt8 = 0
        var progress: Float = 0

        let multiplier = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: belowGateThreshold,
            frameCount: 512,
            rampSamples: gateRampSamples
        )

        #expect(multiplier == 0)
        #expect(phase == 0)
        #expect(progress == 0)
    }

    @Test("Audible input starts the fade")
    func audibleInputStartsFade() {
        var phase: UInt8 = 0
        var progress: Float = 0.5

        let multiplier = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveGateThreshold,
            frameCount: 512,
            rampSamples: gateRampSamples
        )

        #expect(multiplier == 0)
        #expect(phase == 1)
        #expect(progress == 0)
    }

    @Test("Threshold value remains silent")
    func thresholdRemainsSilent() {
        var phase: UInt8 = 0
        var progress: Float = 0

        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: 0.0001,
            frameCount: 512,
            rampSamples: gateRampSamples
        )

        #expect(phase == 0)
    }

    @Test("Fade follows the half-cosine curve")
    func fadeUsesHalfCosineCurve() {
        var phase: UInt8 = 1
        var progress: Float = 0

        let multiplier = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveGateThreshold,
            frameCount: 960,
            rampSamples: gateRampSamples
        )

        #expect(abs(progress - 0.5) < 0.000_001)
        #expect(abs(multiplier - 0.5) < 0.000_001)
        #expect(phase == 1)
    }

    @Test("Fade opens after the configured sample count")
    func fadeReachesOpen() {
        var phase: UInt8 = 1
        var progress: Float = 0

        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveGateThreshold,
            frameCount: 960,
            rampSamples: gateRampSamples
        )
        let multiplier = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveGateThreshold,
            frameCount: 960,
            rampSamples: gateRampSamples
        )

        #expect(multiplier == 1)
        #expect(progress == 1)
        #expect(phase == 2)
    }

    @Test("Silence does not re-arm an open gate")
    func silenceDoesNotRearmOpenGate() {
        var phase: UInt8 = 2
        var progress: Float = 1

        for _ in 0..<100 {
            let multiplier = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                maxPeak: belowGateThreshold,
                frameCount: 512,
                rampSamples: gateRampSamples
            )
            #expect(multiplier == 1)
        }

        #expect(phase == 2)
        #expect(progress == 1)
    }

    @Test("Short sound after silence is not faded again")
    func shortSoundAfterSilencePassesThrough() {
        var phase: UInt8 = 2
        var progress: Float = 1

        for _ in 0..<20 {
            _ = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                maxPeak: belowGateThreshold,
                frameCount: 512,
                rampSamples: gateRampSamples
            )
        }

        let multiplier = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveGateThreshold,
            frameCount: 128,
            rampSamples: gateRampSamples
        )

        #expect(multiplier == 1)
        #expect(phase == 2)
    }
}
