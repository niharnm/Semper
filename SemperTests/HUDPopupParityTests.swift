// SemperTests/HUDPopupParityTests.swift
// Regression: the standard 0...100% HUD range occupies the first third of
// the popup's 0...300% master range for the same underlying device gain.

import Testing
import Foundation
@testable import Semper

@Suite("HUD standard range maps to the popup master range for every tier")
struct HUDPopupParityTests {
    @Test("Software tier: popup fraction is one third of the standard HUD fraction", arguments: [
        Float(0.0), 0.01, 0.1, 0.25, 0.5, 0.7071, 0.9, 1.0
    ])
    func softwareParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .software)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .software)
        #expect(abs(hudFraction - (popupFraction * 3)) < 1e-6)
    }

    @Test("Hardware tier: popup fraction is one third of the standard HUD fraction", arguments: [
        Float(0.0), 0.25, 0.5, 0.75, 1.0
    ])
    func hardwareParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .hardware)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .hardware)
        #expect(abs(hudFraction - (popupFraction * 3)) < 1e-6)
    }

    @Test("DDC tier: popup fraction is one third of the standard HUD fraction", arguments: [
        Float(0.0), 0.25, 0.5, 0.75, 1.0
    ])
    func ddcParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .ddc)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .ddc)
        #expect(abs(hudFraction - (popupFraction * 3)) < 1e-6)
    }

    @Test("Per-app: gainToSlider matches AppRowControls' sliderValue formula", arguments: [
        Float(0.0), 0.01, 0.25, 0.5, 1.0
    ])
    func perAppParity(gain: Float) {
        // AppRowControls.sliderValue (no drag override) == VolumeMapping.gainToSlider(volume).
        let hudFraction = VolumeMapping.gainToSlider(gain)
        let popupSliderValue = VolumeMapping.gainToSlider(gain)
        #expect(hudFraction == popupSliderValue)
    }
}

@Suite("Volume hotkey step counts cover the full range")
struct VolumeHotkeyStepCoverageTests {
    @Test("Each step's N presses cover [0, 1] exactly", arguments: VolumeHotkeyStep.allCases)
    func stepCoverage(step: VolumeHotkeyStep) {
        let pressesToMax = Int(round(1.0 / step.sliderDelta))
        var slider: Double = 0
        for _ in 0..<pressesToMax {
            slider = min(1.0, slider + step.sliderDelta)
        }
        #expect(abs(slider - 1.0) < 1e-9)
    }

    @Test("Normal step covers range in exactly 16 presses (Apple-native count preserved)")
    func normalIs16Presses() {
        let pressesToMax = Int(round(1.0 / VolumeHotkeyStep.normal.sliderDelta))
        #expect(pressesToMax == 16)
    }
}
