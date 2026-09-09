import Foundation

nonisolated struct DisplayDiagnosticsReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let applicationVersion: Version?
    let operatingSystemVersion: Version
    let distribution: Distribution
    let displays: [Display]

    init(
        generatedAt: Date,
        applicationVersion: Version?,
        operatingSystemVersion: Version,
        distribution: Distribution,
        displays: [Display]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.applicationVersion = applicationVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.distribution = distribution
        self.displays = displays
    }

    nonisolated struct Version: Codable, Equatable, Sendable {
        let major: UInt
        let minor: UInt
        let patch: UInt

        init(major: UInt, minor: UInt, patch: UInt = 0) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }
    }

    nonisolated enum Distribution: String, Codable, Equatable, Sendable {
        case direct
        case appStore
    }

    nonisolated struct Display: Codable, Equatable, Sendable {
        let connection: Connection
        let backend: Backend
        let screenMapping: ScreenMapping
        let controls: [Control]
        let issues: [Issue]

        init(
            connection: Connection,
            backend: Backend,
            screenMapping: ScreenMapping,
            controls: [Control],
            issues: [Issue] = []
        ) {
            self.connection = connection
            self.backend = backend
            self.screenMapping = screenMapping
            self.controls = controls.sorted {
                ($0.kind.rawValue, $0.state.rawValue) < ($1.kind.rawValue, $1.state.rawValue)
            }
            self.issues = issues.sorted { $0.rawValue < $1.rawValue }
        }
    }

    nonisolated enum Connection: String, Codable, Equatable, Sendable {
        case builtIn
        case external
        case unknown
    }

    nonisolated enum Backend: String, Codable, Equatable, Sendable {
        case ddcCI = "DDC/CI"
        case macOSSettings = "macOS Settings"
        case unavailable = "Unavailable"
    }

    nonisolated enum ScreenMapping: String, Codable, Equatable, Sendable {
        case matched
        case unmatched
        case ambiguous
        case notAttempted
    }

    nonisolated struct Control: Codable, Equatable, Sendable {
        let kind: Kind
        let state: State

        init(kind: Kind, state: State) {
            self.kind = kind
            self.state = state
        }

        nonisolated enum Kind: String, Codable, Equatable, Sendable {
            case brightness
            case contrast
            case volume
            case inputSelection
        }

        nonisolated enum State: String, Codable, Equatable, Sendable {
            case available
            case unsupported
            case unavailable
            case readFailed
        }
    }

    nonisolated enum Issue: String, Codable, Equatable, Sendable {
        case ambiguousScreenMatch
        case appStoreRestriction
        case capabilitiesInvalid
        case capabilitiesUnavailable
        case controlNotAdvertised
        case controlReadFailed
        case controlWriteUnverified
        case duplicateRegistryEndpoint
        case duplicateStableIdentity
        case inputTableUnsupported
        case inputValuesEmpty
        case inputValuesMissing
        case invalidControlValue
        case missingRegistryEndpoint
        case missingProtocolVersion
        case missingStableIdentity
        case noScreenMatch
        case protocolVersionUnsupported
        case serviceStopped
    }
}

nonisolated struct DisplayDiagnosticsExporter {
    typealias Writer = (Data, URL) throws -> Void

    nonisolated enum Failure: Error, Equatable, LocalizedError {
        case destinationMustBeLocalFile

        var errorDescription: String? {
            "Choose a local file for the display diagnostic report."
        }
    }

    private let writer: Writer

    init(writer: @escaping Writer = { data, destination in
        try data.write(to: destination, options: .atomic)
    }) {
        self.writer = writer
    }

    static func encodedData(for report: DisplayDiagnosticsReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var data = try encoder.encode(report)
        data.append(0x0A)
        return data
    }

    func export(_ report: DisplayDiagnosticsReport, to destination: URL) throws {
        guard destination.isFileURL,
              destination.host == nil || destination.host?.isEmpty == true || destination.host == "localhost"
        else {
            throw Failure.destinationMustBeLocalFile
        }

        try writer(Self.encodedData(for: report), destination)
    }
}
