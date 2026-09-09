import Foundation

enum DisplayFeature: UInt8, CaseIterable, Codable, Hashable, Sendable {
    case brightness = 0x10
    case contrast = 0x12
}

enum DisplayControlKind: String, CaseIterable, Codable, Hashable, Sendable {
    case brightness
    case contrast
    case volume
    case input
}

enum DisplayControlBackend: String, Codable, Hashable, Sendable {
    case ddcCI
    case macOSSettings

    var label: String {
        switch self {
        case .ddcCI: "DDC/CI"
        case .macOSSettings: "macOS Settings"
        }
    }
}

enum DisplayControlUnavailableReason: Error, Equatable, Sendable {
    case missingStableIdentity
    case duplicateStableIdentity
    case missingRegistryEndpoint
    case duplicateRegistryEndpoint
    case capabilitiesReadFailed
    case capabilitiesInvalid(DisplayCapabilities.ParseFailure)
    case notAdvertised(DisplayControlKind)
    case missingCapabilitiesVersion
    case unsupportedCapabilitiesVersion(major: UInt8, minor: UInt8)
    case inputValuesMissing
    case inputValuesEmpty
    case unsupportedInputTable
    case liveReadFailed(DisplayControlKind)
    case invalidLiveValue(DisplayControlKind)
    case systemDisplayNotFound
    case ambiguousSystemDisplayMatch
    case appStoreBuild
    case serviceStopped

    var message: String {
        switch self {
        case .missingStableIdentity:
            "The monitor did not provide a stable EDID identity."
        case .duplicateStableIdentity:
            "More than one monitor reported this EDID identity."
        case .missingRegistryEndpoint:
            "The monitor did not provide an addressable DDC endpoint."
        case .duplicateRegistryEndpoint:
            "More than one monitor reported this DDC endpoint."
        case .capabilitiesReadFailed:
            "The monitor capabilities could not be read."
        case .capabilitiesInvalid(let failure):
            failure.message
        case .notAdvertised(let control):
            "The monitor did not advertise " + control.rawValue + " control."
        case .missingCapabilitiesVersion:
            "The monitor did not advertise an MCCS version."
        case .unsupportedCapabilitiesVersion(let major, let minor):
            "MCCS " + String(major) + "." + String(minor) + " encoding is not supported."
        case .inputValuesMissing:
            "The monitor did not advertise input choices."
        case .inputValuesEmpty:
            "The monitor advertised an empty input list."
        case .unsupportedInputTable:
            "MCCS 3.0 input selection requires an unsupported table encoding."
        case .liveReadFailed(let control):
            "The monitor did not return a " + control.rawValue + " value."
        case .invalidLiveValue(let control):
            "The monitor returned an invalid " + control.rawValue + " value."
        case .systemDisplayNotFound:
            "No active macOS display matched this monitor identity."
        case .ambiguousSystemDisplayMatch:
            "More than one active macOS display matched this monitor identity."
        case .appStoreBuild:
            "Direct monitor controls are not included in this build."
        case .serviceStopped:
            "Display controls are stopped."
        }
    }
}

enum DisplayControlAvailability<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case unavailable(DisplayControlUnavailableReason)

    var value: Value? {
        guard case .available(let value) = self else { return nil }
        return value
    }

    var unavailableReason: DisplayControlUnavailableReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

struct DisplayIdentity: Codable, Hashable, RawRepresentable, Sendable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32

    init?(vendorID: UInt32, productID: UInt32, serialNumber: UInt32) {
        guard vendorID != 0, productID != 0, serialNumber != 0 else { return nil }
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    init?(rawValue: String) {
        let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let vendorID = UInt32(components[0]),
              let productID = UInt32(components[1]),
              let serialNumber = UInt32(components[2]) else {
            return nil
        }
        self.init(vendorID: vendorID, productID: productID, serialNumber: serialNumber)
    }

    var rawValue: String {
        "\(vendorID):\(productID):\(serialNumber)"
    }

    #if !APP_STORE
    init?(edid: DDCDisplayEDID?) {
        guard let edid else { return nil }
        self.init(
            vendorID: edid.vendorID,
            productID: edid.productID,
            serialNumber: edid.serialNumber
        )
    }
    #endif
}

struct DisplayFeatureReading: Equatable, Sendable {
    let current: UInt16
    let maximum: UInt16

    init?(current: UInt16, maximum: UInt16) {
        guard maximum > 0, current <= maximum else { return nil }
        self.current = current
        self.maximum = maximum
    }

    var normalized: Double {
        Double(current) / Double(maximum)
    }
}

struct DisplayVolumeReading: Equatable, Sendable {
    let current: UInt16
    let maximum: UInt16
    let encoding: DisplayCapabilities.VolumeEncoding

    init?(current: UInt16, maximum: UInt16, encoding: DisplayCapabilities.VolumeEncoding) {
        switch encoding {
        case .continuous:
            guard maximum > 0, current <= maximum else { return nil }
        case .continuousSubrange:
            let adjustmentMaximum = min(maximum, 0xFE)
            guard adjustmentMaximum > 0,
                  current == 0 || current == 0xFF || (1...adjustmentMaximum).contains(current) else {
                return nil
            }
        }
        self.current = current
        self.maximum = maximum
        self.encoding = encoding
    }

    var normalized: Double? {
        switch encoding {
        case .continuous:
            return Double(current) / Double(maximum)
        case .continuousSubrange:
            guard current != 0, current != 0xFF else { return nil }
            let upper = min(maximum, 0xFE)
            guard upper > 1 else { return 0 }
            return Double(current - 1) / Double(upper - 1)
        }
    }
}

struct DisplayInputReading: Equatable, Sendable {
    let current: UInt8
    let advertisedValues: [UInt8]

    init?(current: UInt16, advertisedValues: [UInt8]) {
        guard current <= UInt8.max,
              !advertisedValues.isEmpty,
              Set(advertisedValues).count == advertisedValues.count,
              advertisedValues.contains(UInt8(current)) else {
            return nil
        }
        self.current = UInt8(current)
        self.advertisedValues = advertisedValues
    }
}

struct DisplayControlInventory: Equatable, Sendable {
    let brightness: DisplayControlAvailability<DisplayFeatureReading>
    let contrast: DisplayControlAvailability<DisplayFeatureReading>
    let volume: DisplayControlAvailability<DisplayVolumeReading>
    let input: DisplayControlAvailability<DisplayInputReading>

    func availability(
        for feature: DisplayFeature
    ) -> DisplayControlAvailability<DisplayFeatureReading> {
        switch feature {
        case .brightness: brightness
        case .contrast: contrast
        }
    }
}

enum DisplaySystemDisplayMatch: Equatable, Sendable {
    case matched(UInt32)
    case unavailable(DisplayControlUnavailableReason)

    var displayID: UInt32? {
        guard case .matched(let displayID) = self else { return nil }
        return displayID
    }
}

enum DisplayInventoryID: Hashable, Sendable {
    case stable(DisplayIdentity)
    case registry(UInt64)
    case discovered(Int)
}

struct DisplayInventoryItem: Identifiable, Equatable, Sendable {
    let id: DisplayInventoryID
    let name: String
    let backend: DisplayControlBackend
    let identity: DisplayIdentity?
    let registryID: UInt64?
    let systemDisplay: DisplaySystemDisplayMatch
    let controls: DisplayControlInventory
    let unverifiedWrites: Set<DisplayControlKind>

    init(
        id: DisplayInventoryID,
        name: String,
        backend: DisplayControlBackend,
        identity: DisplayIdentity?,
        registryID: UInt64?,
        systemDisplay: DisplaySystemDisplayMatch,
        controls: DisplayControlInventory,
        unverifiedWrites: Set<DisplayControlKind> = []
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.identity = identity
        self.registryID = registryID
        self.systemDisplay = systemDisplay
        self.controls = controls
        self.unverifiedWrites = unverifiedWrites
    }

    var backendLabel: String { backend.label }
}

struct DisplayDevice: Identifiable, Equatable, Sendable {
    let id: DisplayIdentity
    let name: String
    let features: [DisplayFeature: DisplayFeatureReading]
    let sceneEligibleFeatures: Set<DisplayFeature>
    let backend: DisplayControlBackend
    let systemDisplayID: UInt32?
    let volumeEncoding: DisplayCapabilities.VolumeEncoding?
    let advertisedInputValues: [UInt8]
    let volume: DisplayControlAvailability<DisplayVolumeReading>
    let input: DisplayControlAvailability<DisplayInputReading>

    init(
        id: DisplayIdentity,
        name: String,
        features: [DisplayFeature: DisplayFeatureReading],
        sceneEligibleFeatures: Set<DisplayFeature>,
        backend: DisplayControlBackend = .ddcCI,
        systemDisplayID: UInt32? = nil,
        volumeEncoding: DisplayCapabilities.VolumeEncoding? = nil,
        advertisedInputValues: [UInt8] = [],
        volume: DisplayControlAvailability<DisplayVolumeReading> = .unavailable(
            .notAdvertised(.volume)
        ),
        input: DisplayControlAvailability<DisplayInputReading> = .unavailable(
            .notAdvertised(.input)
        )
    ) {
        self.id = id
        self.name = name
        self.features = features
        self.sceneEligibleFeatures = sceneEligibleFeatures
        self.backend = backend
        self.systemDisplayID = systemDisplayID
        self.volumeEncoding = volumeEncoding
        self.advertisedInputValues = advertisedInputValues
        self.volume = volume
        self.input = input
    }

    var backendLabel: String { backend.label }
}

enum DisplayWriteResult: Equatable, Sendable {
    case applied(DisplayFeatureReading)
    case unavailable
    case invalidTarget
    case failed(expected: UInt16, readback: DisplayFeatureReading?)
}

enum DisplayVolumeWriteResult: Equatable, Sendable {
    case applied(DisplayVolumeReading)
    case unavailable(DisplayControlUnavailableReason)
    case invalidTarget
    case failed(expected: UInt16, readback: DisplayVolumeReading?)
}

enum DisplayInputWriteResult: Equatable, Sendable {
    case applied(DisplayInputReading)
    case unavailable(DisplayControlUnavailableReason)
    case invalidTarget
    case unconfirmed(expected: UInt8, readback: DisplayInputReading?)
}

struct DisplayControlGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let members: [DisplayIdentity]

    init(id: UUID = UUID(), name: String, members: [DisplayIdentity]) {
        self.id = id
        self.name = name
        var seen: Set<DisplayIdentity> = []
        self.members = members.filter { seen.insert($0).inserted }
    }
}

enum DisplayGroupControlTarget: Equatable, Sendable {
    case feature(DisplayFeature, normalized: Double)
    case volume(normalized: Double)
    case input(UInt8)
}

enum DisplayGroupTargetResult: Equatable, Sendable {
    case feature(DisplayWriteResult)
    case volume(DisplayVolumeWriteResult)
    case input(DisplayInputWriteResult)
    case cancelled
    case failed
    case notAttempted
}

struct DisplayGroupTargetOutcome: Equatable, Sendable {
    let identity: DisplayIdentity
    let result: DisplayGroupTargetResult
}

struct DisplayGroupWriteReport: Equatable, Sendable {
    let groupID: UUID
    let outcomes: [DisplayGroupTargetOutcome]
}
