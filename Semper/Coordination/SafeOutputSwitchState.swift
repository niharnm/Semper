import Foundation

struct SafeOutputSwitchState: Equatable, Sendable {
    static let preflightTimeout: Duration = .milliseconds(250)
    static let volumeTolerance: Float = 0.01

    enum Action: Equatable, Sendable {
        case switchOutput(deviceUID: String)
        case lowerTargetVolume(deviceUID: String, to: Float)
        case keepCurrentOutput
    }

    enum Event: Equatable, Sendable {
        case writeCompleted(succeeded: Bool, observedTargetVolume: Float?)
        case timeout(observedTargetVolume: Float?)
    }

    private enum Phase: Equatable, Sendable {
        case authorized
        case awaitingConfirmation(limit: Float)
        case rejected
    }

    let targetDeviceUID: String
    private var phase: Phase

    init(
        targetDeviceUID: String,
        volumeLimit: Float?,
        observedTargetVolume: Float?
    ) {
        self.targetDeviceUID = targetDeviceUID

        guard !targetDeviceUID.isEmpty else {
            phase = .rejected
            return
        }
        guard let volumeLimit else {
            phase = .authorized
            return
        }
        guard volumeLimit.isFinite, (0...1).contains(volumeLimit) else {
            phase = .rejected
            return
        }

        phase = Self.isAtOrBelowLimit(observedTargetVolume, limit: volumeLimit)
            ? .authorized
            : .awaitingConfirmation(limit: volumeLimit)
    }

    var action: Action {
        switch phase {
        case .authorized:
            .switchOutput(deviceUID: targetDeviceUID)
        case .awaitingConfirmation(let limit):
            .lowerTargetVolume(deviceUID: targetDeviceUID, to: limit)
        case .rejected:
            .keepCurrentOutput
        }
    }

    @discardableResult
    mutating func handle(_ event: Event) -> Action {
        guard case .awaitingConfirmation(let limit) = phase else {
            return action
        }

        switch event {
        case .writeCompleted(let succeeded, let observedTargetVolume):
            phase = succeeded && Self.isAtOrBelowLimit(observedTargetVolume, limit: limit)
                ? .authorized
                : .rejected
        case .timeout(let observedTargetVolume):
            phase = Self.isAtOrBelowLimit(observedTargetVolume, limit: limit)
                ? .authorized
                : .rejected
        }
        return action
    }

    private static func isAtOrBelowLimit(_ volume: Float?, limit: Float) -> Bool {
        guard let volume, volume.isFinite else { return false }
        return volume <= limit + volumeTolerance
    }
}
