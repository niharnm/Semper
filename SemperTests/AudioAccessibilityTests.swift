import SwiftUI
import Testing
@testable import Semper

@Suite("Audio accessibility values")
struct AudioAccessibilityTests {
    @Test("Percentage values use rounded whole numbers")
    func percentageValue() {
        #expect(AudioAccessibility.percentage(0.754) == "75 percent")
        #expect(AudioAccessibility.percentage(1) == "100 percent")
    }

    @Test("Adjustments use the requested step and clamp to the range")
    func adjustableValues() {
        #expect(AudioAccessibility.adjustedValue(
            0.5,
            direction: .increment,
            step: 0.05,
            range: 0...1
        ) == 0.55)
        #expect(AudioAccessibility.adjustedValue(
            0.98,
            direction: .increment,
            step: 0.05,
            range: 0...1
        ) == 1)
        #expect(AudioAccessibility.adjustedValue(
            -0.98,
            direction: .decrement,
            step: 0.05,
            range: -1...1
        ) == -1)
    }
}
