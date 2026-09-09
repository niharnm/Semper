import Foundation

struct SafeEjectDeviceID: Hashable, Sendable {
    let bsdName: String
    let registryID: UInt64
}

struct SafeEjectVolumeID: Hashable, Sendable {
    let bsdName: String
    let registryID: UInt64
    let volumeUUID: String?
    let mountURL: URL
}

struct SafeEjectVolume: Identifiable, Equatable, Sendable {
    let id: SafeEjectVolumeID
    let name: String
    let deviceID: SafeEjectDeviceID?
    let isInternal: Bool?
    let isRemovable: Bool?
    let isEjectable: Bool?
    let isRoot: Bool

    var isCandidate: Bool {
        !isRoot && (isInternal == false || isRemovable == true || isEjectable == true)
    }
}

struct SafeEjectInventory: Equatable, Sendable {
    let volumes: [SafeEjectVolume]
    let hasUnidentifiedLocalVolumes: Bool

    var hasCompleteDeviceMapping: Bool {
        !hasUnidentifiedLocalVolumes && volumes.allSatisfy { $0.deviceID != nil }
    }

    func refusal(for volume: SafeEjectVolume) -> SafeEjectFailure? {
        guard let current = volumes.first(where: { $0.id == volume.id }), current == volume else {
            return .changedVolume
        }
        guard volume.isCandidate else { return .ineligible }
        guard let deviceID = volume.deviceID else { return .unknownDevice }
        guard hasCompleteDeviceMapping else { return .incompleteInventory }
        guard !volumes.contains(where: { $0.deviceID == deviceID && $0.id != volume.id }) else {
            return .otherMountedVolumes
        }
        return nil
    }
}

enum SafeEjectFailure: Error, Equatable, Sendable {
    case paused
    case sleeping
    case operationInProgress
    case ineligible
    case incompleteInventory
    case unknownDevice
    case changedVolume
    case otherMountedVolumes
    case busy
    case denied
    case unsupported
    case unavailable
    case interrupted
    case timedOut
    case stillMounted
    case deviceStillPresent
    case system(Int32)

    var message: String {
        switch self {
        case .paused: "Safe Eject is paused. Start it to refresh mounted volumes."
        case .sleeping: "Safe Eject is waiting for this Mac to wake."
        case .operationInProgress: "Another eject request is still being checked."
        case .ineligible: "This volume is not eligible for external-device eject."
        case .incompleteInventory: "Some local volumes could not be identified. Refresh before ejecting."
        case .unknownDevice: "The device containing this volume could not be identified. Use Finder or Disk Utility."
        case .changedVolume: "The selected volume disconnected or changed. Select it again after refreshing."
        case .otherMountedVolumes:
            "Another volume on this device is mounted. Use Finder or Disk Utility to review the whole device."
        case .busy: "macOS reported that the device is busy. Close files or finish transfers, then try again."
        case .denied: "macOS did not permit this request. Check access to the device in Finder or Disk Utility."
        case .unsupported: "macOS does not support this eject request. Use Finder or Disk Utility."
        case .unavailable: "Mounted volumes could not be read. Refresh to try again."
        case .interrupted:
            "Checking stopped. A request already sent to macOS may still finish. Refresh before disconnecting."
        case .timedOut:
            "macOS did not finish within 15 seconds. The request may still finish. Refresh before disconnecting."
        case .stillMounted: "The volume is still mounted. Disconnecting has not been verified."
        case .deviceStillPresent:
            "macOS accepted eject, but device removal could not be verified. Check Finder or Disk Utility before disconnecting."
        case .system(let code): "macOS declined the request (code \(code)). No further attempt was made."
        }
    }
}

enum SafeEjectSystemEvent: Sendable {
    case volumesChanged
    case willSleep
    case didWake
}

enum SafeEjectDevicePresence: Sendable {
    case present
    case absent
    case unavailable
}

enum SafeEjectOutcome: Equatable, Sendable {
    case ejected
    case refused(SafeEjectFailure)
    case unmountedOnly(SafeEjectFailure)
    case unverified(SafeEjectFailure)

    var message: String {
        switch self {
        case .ejected: "Eject completed. The volume is unmounted and its device is no longer present."
        case .refused(let failure): failure.message
        case .unmountedOnly(let failure): "The selected volume was unmounted. \(failure.message)"
        case .unverified(let failure): "Eject was not verified. \(failure.message)"
        }
    }

    var isVerified: Bool { self == .ejected }
}

struct SafeEjectReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let volumeID: SafeEjectVolumeID
    let volumeName: String
    let outcome: SafeEjectOutcome
}

@MainActor
protocol SafeEjectBackend: AnyObject {
    func start(onEvent: @escaping @MainActor (SafeEjectSystemEvent) -> Void) throws
    func stop()
    func cancelPendingOperation()
    func inventory() throws -> SafeEjectInventory
    func unmount(_ volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure>
    func ejectDevice(containing volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure>
    func devicePresence(_ id: SafeEjectDeviceID) -> SafeEjectDevicePresence
}
