// Semper/Models/VolumeMapping.swift
import Foundation

/// Volume mapping for per-app software gain and the 0%...300% master slider.
///
/// Per-app gain is a linear PCM amplitude multiplier (0.0–1.0). Without a curve,
/// slider movement at low volumes produces barely perceptible change while movement
/// at high volumes changes loudness drastically. The x² curve redistributes control
/// to the perceptually important low-gain region.
///
/// Do not apply the per-app square-law helpers directly to device hardware volume.
/// The master helpers below preserve the selected backend's existing curve through
/// 100%, then return linear PCM gain for the boosted range.
/// CoreAudio's HAL scalar (kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
/// is already audio-tapered by the driver — IOAudioLevelControl applies a dB curve
/// by default (see `setLinearScale()` in IOAudioLevelControl.h). Applying x² on top
/// creates a "double taper" that kills the bottom 10% of slider range.
///
/// Evidence: empirical measurement of built-in output shows scalar maps linearly to dB:
///   scalar 0.50 → -50 dB, scalar 0.10 → -90 dB (100 dB range, linear-in-dB taper).
///   Square-law on top: slider 10% → scalar 0.01 → -99 dB (effective silence).
///
/// References:
/// - IOAudioLevelControl.h `setLinearScale(bool)`: "FALSE instructs CoreAudio to apply
///   a curve, which is CoreAudio's default behavior."
/// - dr-lex.be/info-stuff/volumecontrols.html: x⁴ recommended for linear-amplitude
///   controls; unnecessary when the backend is already perceptually mapped.
/// - Microsoft "Audio-Tapered Volume Controls": Windows scalar volume is also pre-tapered;
///   applications should NOT apply additional curves on the scalar endpoint API.
/// - Discord perceptual (github.com/discord/perceptual): 50 dB exponential mapping for
///   linear PCM gain — similar purpose to our x² curve for per-app volume.
enum VolumeMapping {
    static let maximumMasterGain: Float = 3.0
    static let unityMasterSliderFraction: Double = 1.0 / Double(maximumMasterGain)

    static func unityMasterSliderFraction(maximumGain: Float) -> Double {
        1.0 / Double(max(1, maximumGain))
    }

    /// Convert per-app slider position to linear PCM gain using square-law curve.
    /// Slider 50% → gain 0.25 (−12 dB). Provides perceptual linearity for software gain.
    static func sliderToGain(_ slider: Double) -> Float {
        if slider <= 0 { return 0 }
        let t = min(slider, 1.0)
        return Float(t * t)
    }

    /// Convert linear PCM gain to per-app slider position using inverse square-law (sqrt).
    /// Gain 0.25 → slider 50%. Inverse of `sliderToGain`.
    static func gainToSlider(_ gain: Float) -> Double {
        if gain <= 0 { return 0 }
        return Double(sqrt(min(gain, 1.0)))
    }

    /// `.software` is linear PCM; `.hardware` / `.ddc` scalars are already audio-tapered
    /// by the driver/firmware (see the top-level docstring on this enum).
    static func sliderFraction(forSystemGain gain: Float, tier: VolumeControlTier) -> Double {
        switch tier {
        case .software:
            return gainToSlider(gain)
        case .hardware, .ddc:
            return Double(max(0, min(1, gain)))
        }
    }

    static func systemGain(forSliderFraction fraction: Double, tier: VolumeControlTier) -> Float {
        switch tier {
        case .software:
            return sliderToGain(fraction)
        case .hardware, .ddc:
            return Float(max(0, min(1, fraction)))
        }
    }

    /// Maps the master slider's normalized 0...1 position onto 0%...300%.
    /// The 0%...100% segment retains the selected backend's existing curve.
    /// Above 100%, the returned value is linear PCM gain for AudioEngine.
    static func masterGain(
        forSliderFraction fraction: Double,
        tier: VolumeControlTier,
        maximumGain: Float = maximumMasterGain
    ) -> Float {
        let maximumGain = max(1, maximumGain)
        let masterScale = max(0, min(1, fraction)) * Double(maximumGain)
        if masterScale <= 1 {
            return systemGain(forSliderFraction: masterScale, tier: tier)
        }
        return Float(masterScale)
    }

    /// Inverse of `masterGain(forSliderFraction:tier:)`.
    static func masterSliderFraction(
        forGain gain: Float,
        tier: VolumeControlTier,
        maximumGain: Float = maximumMasterGain
    ) -> Double {
        let maximumGain = max(1, maximumGain)
        let clampedGain = max(0, min(maximumGain, gain))
        if clampedGain <= 1 {
            return sliderFraction(forSystemGain: clampedGain, tier: tier) / Double(maximumGain)
        }
        return Double(clampedGain / maximumGain)
    }
}
