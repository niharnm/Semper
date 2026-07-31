// Semper/Models/AudioDevice.swift
import AppKit
import AudioToolbox

struct StereoChannelPair: Equatable, Sendable {
    let left: Int
    let right: Int
}

struct OutputDeviceTopology: Equatable, Sendable {
    let channelCount: Int
    let preferredStereoPair: StereoChannelPair?
    let isAlive: Bool
    let isAggregate: Bool

    static let assumedStereo = OutputDeviceTopology(
        channelCount: 2,
        preferredStereoPair: StereoChannelPair(left: 0, right: 1),
        isAlive: true,
        isAggregate: false
    )

    var supportsProcessedAudio: Bool {
        isAlive && channelCount > 0
    }

    var supportsIndependentBalance: Bool {
        guard supportsProcessedAudio, !isAggregate, channelCount >= 2 else {
            return false
        }
        if channelCount == 2 {
            return true
        }
        guard let pair = preferredStereoPair else { return false }
        return pair.left >= 0
            && pair.right >= 0
            && pair.left != pair.right
            && pair.left < channelCount
            && pair.right < channelCount
    }
}

struct OutputDeviceCapabilities: Equatable, Sendable {
    let maximumGain: Float
    let supportsBalance: Bool
    let channelCount: Int
    let isRouteVerified: Bool
    let unavailableReason: String?

    static let assumedVerifiedStereo = OutputDeviceCapabilities(
        maximumGain: 3,
        supportsBalance: true,
        channelCount: 2,
        isRouteVerified: true,
        unavailableReason: nil
    )

    static func unavailable(
        channelCount: Int,
        reason: String
    ) -> OutputDeviceCapabilities {
        OutputDeviceCapabilities(
            maximumGain: 1,
            supportsBalance: false,
            channelCount: channelCount,
            isRouteVerified: false,
            unavailableReason: reason
        )
    }
}

enum AppRouteLifecycle: Equatable, Sendable {
    case preparing(deviceUIDs: [String])
    case active(deviceUIDs: [String])
    case failed(previousDeviceUIDs: [String], message: String)
    case unavailable(message: String)
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let icon: NSImage?
    let supportsAutoEQ: Bool
    let outputTopology: OutputDeviceTopology

    init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        icon: NSImage?,
        supportsAutoEQ: Bool,
        outputTopology: OutputDeviceTopology = .assumedStereo
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.icon = icon
        self.supportsAutoEQ = supportsAutoEQ
        self.outputTopology = outputTopology
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid
    }
}
