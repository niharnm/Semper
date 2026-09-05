struct StereoAudioLevel: Equatable, Sendable {
    let left: Float
    let right: Float

    static let zero = StereoAudioLevel(left: 0, right: 0)

    init(left: Float, right: Float) {
        self.left = max(0, min(1, left))
        self.right = max(0, min(1, right))
    }

    init(mono: Float) {
        self.init(left: mono, right: mono)
    }

    var peak: Float {
        max(left, right)
    }
}

/// Abstraction over process tap controllers for testability.
///
/// **Threading:** The protocol surface is `@MainActor` — AudioEngine and tests
/// interact with controllers from main. The concrete class straddles main and the
/// CoreAudio HAL I/O thread, but the audio callback never goes through this
/// protocol; it reads `nonisolated(unsafe)` atomic fields directly on the concrete
/// type via a `void *` userdata pointer.
@MainActor
protocol ProcessTapControlling: AnyObject, Sendable {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var stereoAudioLevel: StereoAudioLevel { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }

    func activate(initial: TapInitialState) throws
    func invalidate()
    func invalidateAsync() async -> TapResourceCleanupResult
    func updateEQSettings(_ settings: EQSettings)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    func updateLoudnessCompensation(volume: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func updateMonoAudio(_ enabled: Bool)
    func updateBalance(_ balance: Float)
    func switchDevice(
        to newDeviceUID: String,
        preferredTapSourceDeviceUID: String?,
        requiresExclusiveOutput: Bool
    ) async throws
    func updateDevices(
        to newDeviceUIDs: [String],
        preferredTapSourceDeviceUID: String?,
        requiresExclusiveOutput: Bool
    ) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    var tapSourceDeviceUID: String? { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws
    func recreateForOutputRateChange() async throws
}

extension ProcessTapControlling {
    var stereoAudioLevel: StereoAudioLevel {
        StereoAudioLevel(mono: audioLevel)
    }

    /// Convenience activation with default state. Production callers must pass an
    /// `initial:` populated from persisted settings — defaults leave the first audio
    /// callbacks running with no EQ/AutoEQ/Loudness and unity volume ramp.
    func activate() throws {
        try activate(initial: TapInitialState())
    }

    /// Convenience: allows a crossfade when the source is producing audio.
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?) async throws {
        try await switchDevice(
            to: newDeviceUID,
            preferredTapSourceDeviceUID: preferredTapSourceDeviceUID,
            requiresExclusiveOutput: false
        )
    }

    /// Convenience: allows a crossfade when the source is producing audio.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?) async throws {
        try await updateDevices(
            to: newDeviceUIDs,
            preferredTapSourceDeviceUID: preferredTapSourceDeviceUID,
            requiresExclusiveOutput: false
        )
    }

    func invalidateAsync() async -> TapResourceCleanupResult {
        invalidate()
        return .empty
    }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        // Default no-op for mocks that don't override
    }

    func recreateForOutputRateChange() async throws {
        // Default no-op for mocks that don't override
    }

    func updateBalance(_ balance: Float) {
        // Default no-op for test controllers that do not process sample buffers.
    }

    func updateMonoAudio(_ enabled: Bool) {
        // Default no-op for test controllers that do not process sample buffers.
    }
}
