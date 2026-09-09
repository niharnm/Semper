import Foundation

// Advertisement metadata only. Live reads, range validation and observed writes belong to the transport owner.
nonisolated struct DisplayCapabilities: Equatable, Sendable {
    struct Version: Equatable, Sendable {
        let major: UInt8
        let minor: UInt8
    }

    enum VolumeEncoding: Equatable, Sendable {
        case continuous
        // MCCS 2.2/3.0: 0x00 is fixed/default, 0xFF is mute, 0x01...0xFE is the adjustment subrange.
        case continuousSubrange
    }

    enum UnavailableReason: Error, Equatable, Sendable {
        case missingVCPSection
        case notAdvertised
        case missingVersion
        case unsupportedVersion(Version)
        case inputValuesMissing
        case inputValuesEmpty
        case unsupportedInputTable

        var message: String {
            switch self {
            case .missingVCPSection: "The monitor did not advertise a VCP feature list."
            case .notAdvertised: "This control was not advertised by the monitor."
            case .missingVersion: "The monitor did not advertise an MCCS version."
            case .unsupportedVersion(let version):
                "MCCS \(version.major).\(version.minor) encoding is not supported."
            case .inputValuesMissing: "The monitor did not advertise input choices."
            case .inputValuesEmpty: "The monitor advertised an empty input list."
            case .unsupportedInputTable:
                "MCCS 3.0 input selection requires an unsupported table encoding."
            }
        }
    }

    enum ParseFailure: Error, Equatable, Sendable {
        case empty
        case inputTooLarge
        case invalidCharacter
        case malformedStructure
        case trailingData
        case nestingLimitExceeded
        case sectionLimitExceeded
        case duplicateSection
        case malformedVersion
        case malformedVCPList
        case duplicateFeature(UInt8)
        case duplicateValue(feature: UInt8, value: UInt8)
        case featureLimitExceeded
        case valueLimitExceeded

        var message: String {
            switch self {
            case .empty: "No monitor capabilities were received."
            case .inputTooLarge: "The monitor capabilities exceed the size limit."
            case .invalidCharacter: "The monitor capabilities contain unsupported characters."
            case .malformedStructure: "The monitor capabilities are malformed or incomplete."
            case .trailingData: "Unexpected data follows the monitor capabilities."
            case .nestingLimitExceeded: "The monitor capabilities exceed the nesting limit."
            case .sectionLimitExceeded: "The monitor capabilities contain too many sections."
            case .duplicateSection: "The monitor advertised conflicting capability sections."
            case .malformedVersion: "The advertised MCCS version is malformed."
            case .malformedVCPList: "The advertised VCP list is malformed."
            case .duplicateFeature: "The monitor advertised the same VCP feature more than once."
            case .duplicateValue: "The monitor advertised a duplicate VCP value."
            case .featureLimitExceeded: "The monitor advertised too many VCP features."
            case .valueLimitExceeded: "The monitor advertised too many VCP values."
            }
        }
    }

    // Local admission limits, not MCCS maxima. Nesting includes the enclosing capabilities parentheses.
    static let maximumBytes = 16_384
    static let maximumNesting = 8
    static let maximumSections = 64
    static let maximumFeatures = 256
    static let maximumValuesPerFeature = 256

    let protocolVersion: Version?
    let advertisedVCPFeatures: Set<UInt8>
    // Original order, with no inferred values or connector names; nil differs from an explicit empty list.
    let advertisedInputValues: [UInt8]?
    let inputSelection: Result<[UInt8], UnavailableReason>
    let volume: Result<VolumeEncoding, UnavailableReason>

    // Requires complete enclosing parentheses, ASCII, and at most one final NUL terminator.
    // Protocol reference: https://www.ddcutil.com/vcpinfo_output/ and /command_capabilities/.
    static func parse(_ raw: String) -> Result<Self, ParseFailure> {
        var bytes = Array(raw.utf8.prefix(maximumBytes + 1))
        guard bytes.count <= maximumBytes else { return .failure(.inputTooLarge) }
        if bytes.last == 0 { bytes.removeLast() }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) || Scanner.isWhitespace($0) }) else {
            return .failure(.invalidCharacter)
        }
        do throws(ParseFailure) {
            var scanner = Scanner(bytes: bytes)
            scanner.skipWhitespace()
            guard scanner.current != nil else { return .failure(.empty) }
            guard scanner.consume(0x28) else { return .failure(.malformedStructure) }
            var version: Version?
            var features: Set<UInt8> = []
            var inputs: [UInt8]?
            var sawVCP = false
            var sawVersion = false
            var sections = 0
            while true {
                scanner.skipWhitespace()
                if scanner.consume(0x29) { break }
                guard scanner.current != nil else { throw ParseFailure.malformedStructure }
                sections += 1
                guard sections <= maximumSections else { throw ParseFailure.sectionLimitExceeded }
                let name = try scanner.sectionName()
                scanner.skipWhitespace()
                let body = try scanner.group()
                switch name {
                case "mccs_ver":
                    guard !sawVersion else { throw ParseFailure.duplicateSection }
                    sawVersion = true
                    version = try parseVersion(body)
                case "vcp":
                    guard !sawVCP else { throw ParseFailure.duplicateSection }
                    sawVCP = true
                    (features, inputs) = try parseVCP(body)
                default: break
                }
            }
            scanner.skipWhitespace()
            guard scanner.current == nil else { throw ParseFailure.trailingData }
            let input: Result<[UInt8], UnavailableReason>
            if let reason = unavailable(
                feature: 0x60, sawVCP: sawVCP, features: features, version: version)
            {
                input = .failure(reason)
            } else if version == Version(major: 3, minor: 0) {
                input = .failure(.unsupportedInputTable)
            } else if let inputs {
                input = inputs.isEmpty ? .failure(.inputValuesEmpty) : .success(inputs)
            } else {
                input = .failure(.inputValuesMissing)
            }
            let volume: Result<VolumeEncoding, UnavailableReason>
            if let reason = unavailable(
                feature: 0x62, sawVCP: sawVCP, features: features, version: version)
            {
                volume = .failure(reason)
            } else {
                volume = .success(
                    version == Version(major: 2, minor: 0) || version == Version(major: 2, minor: 1)
                        ? .continuous : .continuousSubrange)
            }
            return .success(
                Self(
                    protocolVersion: version, advertisedVCPFeatures: features, advertisedInputValues: inputs,
                    inputSelection: input, volume: volume))
        } catch {
            return .failure(error)
        }
    }

    private static func unavailable(
        feature: UInt8, sawVCP: Bool, features: Set<UInt8>, version: Version?
    ) -> UnavailableReason? {
        guard sawVCP else { return .missingVCPSection }
        guard features.contains(feature) else { return .notAdvertised }
        guard let version else { return .missingVersion }
        guard (version.major == 2 && version.minor <= 2) || version == Version(major: 3, minor: 0)
        else {
            return .unsupportedVersion(version)
        }
        return nil
    }

    private static func parseVersion(_ bytes: [UInt8]) throws(ParseFailure) -> Version {
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            parts.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) }
            }), let major = UInt8(parts[0]), let minor = UInt8(parts[1])
        else {
            throw ParseFailure.malformedVersion
        }
        return Version(major: major, minor: minor)
    }

    private static func parseVCP(_ bytes: [UInt8]) throws(ParseFailure) -> (Set<UInt8>, [UInt8]?) {
        var scanner = Scanner(bytes: bytes)
        var features: Set<UInt8> = []
        var inputs: [UInt8]?
        var count = 0
        while true {
            scanner.skipWhitespace()
            guard scanner.current != nil else { break }
            count += 1
            guard count <= maximumFeatures else { throw ParseFailure.featureLimitExceeded }
            let feature = try scanner.hexByte()
            guard features.insert(feature).inserted else { throw ParseFailure.duplicateFeature(feature) }
            scanner.skipWhitespace()
            if scanner.current == 0x28 {
                var values = Scanner(bytes: try scanner.group())
                var ordered: [UInt8] = []
                var seen: Set<UInt8> = []
                while true {
                    values.skipWhitespace()
                    guard values.current != nil else { break }
                    guard ordered.count < maximumValuesPerFeature else {
                        throw ParseFailure.valueLimitExceeded
                    }
                    let value = try values.hexByte()
                    guard seen.insert(value).inserted else {
                        throw ParseFailure.duplicateValue(feature: feature, value: value)
                    }
                    ordered.append(value)
                }
                if feature == 0x60 { inputs = ordered }
            }
        }
        return (features, inputs)
    }

    private struct Scanner {
        let bytes: [UInt8]
        var position = 0
        var current: UInt8? { position < bytes.count ? bytes[position] : nil }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        mutating func skipWhitespace() {
            while let current, Self.isWhitespace(current) { position += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            position += 1
            return true
        }

        mutating func sectionName() throws(ParseFailure) -> String {
            let start = position
            while let byte = current,
                (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || (0x30...0x39).contains(byte) || byte == 0x5F
            {
                position += 1
            }
            guard position > start else { throw ParseFailure.malformedStructure }
            return String(decoding: bytes[start..<position], as: UTF8.self).lowercased()
        }

        mutating func group() throws(ParseFailure) -> [UInt8] {
            guard consume(0x28) else { throw ParseFailure.malformedStructure }
            let start = position
            var depth = 2
            while let byte = current {
                position += 1
                if byte == 0x28 {
                    depth += 1
                    guard depth <= maximumNesting else { throw ParseFailure.nestingLimitExceeded }
                } else if byte == 0x29 {
                    depth -= 1
                    if depth == 1 { return Array(bytes[start..<(position - 1)]) }
                }
            }
            throw ParseFailure.malformedStructure
        }

        mutating func hexByte() throws(ParseFailure) -> UInt8 {
            let start = position
            guard bytes.count - position >= 2 else { throw ParseFailure.malformedVCPList }
            position += 2
            guard
                bytes[start..<position].allSatisfy({
                    (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
                }), let value = UInt8(String(decoding: bytes[start..<position], as: UTF8.self), radix: 16)
            else {
                throw ParseFailure.malformedVCPList
            }
            return value
        }
    }
}
