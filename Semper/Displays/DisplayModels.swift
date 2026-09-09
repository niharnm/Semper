import Foundation

enum DisplayFeature: UInt8, CaseIterable, Codable, Hashable, Sendable {
    case brightness = 0x10
    case contrast = 0x12
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

struct DisplayDevice: Identifiable, Equatable, Sendable {
    let id: DisplayIdentity
    let name: String
    let features: [DisplayFeature: DisplayFeatureReading]
    let sceneEligibleFeatures: Set<DisplayFeature>
}

enum DisplayWriteResult: Equatable, Sendable {
    case applied(DisplayFeatureReading)
    case unavailable
    case invalidTarget
    case failed(expected: UInt16, readback: DisplayFeatureReading?)
}
