import CoreGraphics
import Foundation

nonisolated enum DisplayMutationOwner: Sendable {
    case manual
    case scene

    var admissionOwner: MutationAdmissionOwner {
        switch self {
        case .manual: .manualDisplay
        case .scene: .scene
        }
    }

}

#if !APP_STORE

nonisolated struct DisplayFeatureProbeSummary: Equatable, Sendable {
    let readings: [DisplayFeature: DisplayFeatureReading]
    let sceneEligibleFeatures: Set<DisplayFeature>
}

nonisolated enum DisplayIdentityResolver {
    static func unique(_ identities: [DisplayIdentity?]) -> Set<DisplayIdentity> {
        let counts = Dictionary(grouping: identities.compactMap { $0 }, by: { $0 })
            .mapValues(\.count)
        return Set(counts.compactMap { identity, count in count == 1 ? identity : nil })
    }
}

nonisolated struct DisplayEndpointIdentity: Equatable, Sendable {
    let displayIdentity: DisplayIdentity
    let registryID: DDCDisplayCandidate.ID
}

nonisolated struct DisplayEndpointCandidate: Equatable, Sendable {
    let displayIdentity: DisplayIdentity
    let registryID: DDCDisplayCandidate.ID?
}

nonisolated struct DisplayConnectionToken: Equatable, Sendable {
    let endpoint: DisplayEndpointIdentity?
    let generation: UUID
}

typealias DisplayDiscoverOperation = @Sendable () -> [DDCExternalDisplayRecord]
typealias DisplayFeatureReadOperation = @Sendable (
    DDCService,
    DisplayFeature
) throws -> (current: UInt16, maximum: UInt16)
typealias DisplayFeatureWriteOperation = @Sendable (
    DDCService,
    DisplayFeature,
    UInt16
) throws -> Void
typealias DisplayCancellationCheck = @Sendable () -> Bool
nonisolated struct DisplayCapabilitiesReadRequest: Sendable {
    let service: DDCService
    let isCancelled: DisplayCancellationCheck
}
typealias DisplayCapabilitiesReadOperation = @Sendable (
    DisplayCapabilitiesReadRequest
) throws -> String
typealias DisplayVCPReadOperation = @Sendable (
    DDCService,
    UInt8
) throws -> (current: UInt16, maximum: UInt16)
typealias DisplayVCPWriteOperation = @Sendable (
    DDCService,
    UInt8,
    UInt16
) throws -> Void
typealias DisplayInputWriteOperation = @Sendable (DDCService, UInt8) throws -> Void

nonisolated struct DisplaySystemDisplayCandidate: Equatable, Sendable {
    let displayID: UInt32
    let identity: DisplayIdentity?
}

typealias DisplaySystemDisplayDiscoverOperation = @Sendable () -> [DisplaySystemDisplayCandidate]

nonisolated enum DisplayEndpointResolver {
    static func isCurrent(
        _ expected: DisplayEndpointIdentity,
        among candidates: [DisplayEndpointCandidate]
    ) -> Bool {
        let matches = candidates.filter { $0.displayIdentity == expected.displayIdentity }
        let registryMatches = candidates.filter { $0.registryID == expected.registryID }
        return matches.count == 1
            && matches[0].registryID == expected.registryID
            && registryMatches.count == 1
    }

    static func acceptsResult(
        captured: DisplayConnectionToken,
        current: DisplayConnectionToken?
    ) -> Bool {
        captured == current
    }

    static func connectionToken(
        for endpoint: DisplayEndpointIdentity?,
        reusing previous: DisplayConnectionToken?
    ) -> DisplayConnectionToken {
        if let endpoint, let previous, previous.endpoint == endpoint {
            return previous
        }
        return DisplayConnectionToken(endpoint: endpoint, generation: UUID())
    }
}

nonisolated enum DisplaySystemDisplayResolver {
    static func resolve(
        _ identity: DisplayIdentity,
        among candidates: [DisplaySystemDisplayCandidate]
    ) -> DisplaySystemDisplayMatch {
        let matches = candidates.filter { $0.identity == identity }
        guard matches.count == 1 else {
            return .unavailable(
                matches.isEmpty ? .systemDisplayNotFound : .ambiguousSystemDisplayMatch
            )
        }
        return .matched(matches[0].displayID)
    }
}

nonisolated enum DisplaySystemDisplayProbe {
    static func discover() -> [DisplaySystemDisplayCandidate] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }
        return displayIDs.prefix(Int(count)).map { displayID in
            DisplaySystemDisplayCandidate(
                displayID: displayID,
                identity: DisplayIdentity(
                    vendorID: CGDisplayVendorNumber(displayID),
                    productID: CGDisplayModelNumber(displayID),
                    serialNumber: CGDisplaySerialNumber(displayID)
                )
            )
        }
    }
}

nonisolated struct DisplayProbeFlight<Value: Sendable>: Sendable {
    let id: UInt64
    fileprivate let task: Task<Value, Never>

    func value() async -> Value {
        await task.value
    }
}

actor DisplayProbeSingleFlight<Value: Sendable> {
    private struct Active {
        let id: UInt64
        let task: Task<Value, Never>
    }

    private let operation: @Sendable () async -> Value
    private var nextFlightID: UInt64 = 0
    private var active: Active?

    init(operation: @escaping @Sendable () async -> Value) {
        self.operation = operation
    }

    func flight() throws -> DisplayProbeFlight<Value> {
        try Task.checkCancellation()
        if let active {
            return DisplayProbeFlight(id: active.id, task: active.task)
        }

        nextFlightID &+= 1
        let flightID = nextFlightID
        let operation = operation
        let task = Task { [weak self] in
            let value = await operation()
            await self?.complete(flightID)
            return value
        }
        active = Active(id: flightID, task: task)
        return DisplayProbeFlight(id: flightID, task: task)
    }

    func value() async throws -> Value {
        try await flight().value()
    }

    func cancelAndDrain() async {
        guard let active else { return }
        self.active = nil
        active.task.cancel()
        _ = await active.task.value
    }

    private func complete(_ flightID: UInt64) {
        guard active?.id == flightID else { return }
        active = nil
    }
}

nonisolated struct DisplayProbePublicationState<Value: Sendable>: Sendable {
    private(set) var latestRequestedFlightID: UInt64 = 0
    private(set) var latestAcceptedFlightID: UInt64 = 0
    private(set) var value: Value?

    mutating func requested(_ flightID: UInt64) {
        latestRequestedFlightID = max(latestRequestedFlightID, flightID)
    }

    mutating func publish(
        _ value: Value,
        from flightID: UInt64,
        isCancelled: Bool
    ) -> Bool {
        guard !isCancelled,
              flightID == latestRequestedFlightID,
              flightID >= latestAcceptedFlightID else {
            return false
        }
        latestAcceptedFlightID = flightID
        self.value = value
        return true
    }
}

nonisolated enum DisplayFeatureIO {
    typealias Read = () throws -> (current: UInt16, maximum: UInt16)
    typealias Write = (UInt16) throws -> Void

    static func probe(read: Read) -> DisplayFeatureReading? {
        validated(read: read)
    }

    static func probeAll(
        read: (DisplayFeature) throws -> (current: UInt16, maximum: UInt16)
    ) -> DisplayFeatureProbeSummary {
        var readings: [DisplayFeature: DisplayFeatureReading] = [:]

        for feature in DisplayFeature.allCases {
            guard let reading = probe(read: { try read(feature) }) else { continue }
            readings[feature] = reading
        }

        return DisplayFeatureProbeSummary(
            readings: readings,
            sceneEligibleFeatures: Set(readings.keys)
        )
    }

    static func set(
        normalized: Double,
        maximum: UInt16,
        isEndpointCurrent: () -> Bool = { true },
        claimMutation: () throws -> Void = {},
        write: Write,
        read: Read
    ) throws -> DisplayWriteResult {
        guard maximum > 0 else { return .unavailable }
        guard let requested = rawValue(normalized: normalized, maximum: maximum) else {
            return .invalidTarget
        }

        do {
            guard let liveReading = validated(read: read) else {
                return .failed(expected: requested, readback: nil)
            }
            guard liveReading.maximum == maximum else {
                return .failed(expected: requested, readback: liveReading)
            }
            guard isEndpointCurrent() else { return .unavailable }

            try claimMutation()
            try write(requested)
            let readback = validated(read: read)
            guard readback?.current == requested, readback?.maximum == maximum else {
                return .failed(expected: requested, readback: readback)
            }
            return .applied(readback!)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(expected: requested, readback: nil)
        }
    }

    static func read(_ operation: Read) -> DisplayFeatureReading? {
        validated(read: operation)
    }

    static func resolvedSliderValue(
        requested: Double,
        result: DisplayWriteResult,
        confirmed: Double?
    ) -> Double {
        switch result {
        case .applied(let reading):
            reading.normalized
        case .unavailable, .invalidTarget, .failed:
            confirmed ?? requested
        }
    }

    static func rawValue(normalized: Double, maximum: UInt16) -> UInt16? {
        guard normalized.isFinite, (0...1).contains(normalized) else { return nil }
        return UInt16((normalized * Double(maximum)).rounded())
    }

    private static func validated(read: Read) -> DisplayFeatureReading? {
        guard let value = try? read() else { return nil }
        return DisplayFeatureReading(current: value.current, maximum: value.maximum)
    }

    static func availability(
        _ feature: DisplayFeature,
        read: Read
    ) -> DisplayControlAvailability<DisplayFeatureReading> {
        do {
            let value = try read()
            guard let reading = DisplayFeatureReading(
                current: value.current,
                maximum: value.maximum
            ) else {
                return .unavailable(.invalidLiveValue(feature.controlKind))
            }
            return .available(reading)
        } catch {
            return .unavailable(.liveReadFailed(feature.controlKind))
        }
    }
}

private extension DisplayFeature {
    var controlKind: DisplayControlKind {
        switch self {
        case .brightness: .brightness
        case .contrast: .contrast
        }
    }
}

nonisolated enum DisplayCapabilityIO {
    static func read(
        _ operation: () throws -> String
    ) -> Result<DisplayCapabilities, DisplayControlUnavailableReason> {
        let raw: String
        do {
            raw = try operation()
        } catch {
            return .failure(.capabilitiesReadFailed)
        }
        switch DisplayCapabilities.parse(raw) {
        case .success(let capabilities):
            return .success(capabilities)
        case .failure(let failure):
            return .failure(.capabilitiesInvalid(failure))
        }
    }

    static func unavailableReason(
        _ reason: DisplayCapabilities.UnavailableReason,
        control: DisplayControlKind
    ) -> DisplayControlUnavailableReason {
        switch reason {
        case .missingVCPSection, .notAdvertised:
            .notAdvertised(control)
        case .missingVersion:
            .missingCapabilitiesVersion
        case .unsupportedVersion(let version):
            .unsupportedCapabilitiesVersion(major: version.major, minor: version.minor)
        case .inputValuesMissing:
            .inputValuesMissing
        case .inputValuesEmpty:
            .inputValuesEmpty
        case .unsupportedInputTable:
            .unsupportedInputTable
        }
    }
}

nonisolated enum DisplayVolumeIO {
    typealias Read = () throws -> (current: UInt16, maximum: UInt16)
    typealias Write = (UInt16) throws -> Void

    static func probe(
        encoding: DisplayCapabilities.VolumeEncoding,
        read: Read
    ) -> DisplayControlAvailability<DisplayVolumeReading> {
        do {
            let value = try read()
            guard let reading = DisplayVolumeReading(
                current: value.current,
                maximum: value.maximum,
                encoding: encoding
            ) else {
                return .unavailable(.invalidLiveValue(.volume))
            }
            return .available(reading)
        } catch {
            return .unavailable(.liveReadFailed(.volume))
        }
    }

    static func read(
        encoding: DisplayCapabilities.VolumeEncoding,
        operation: Read
    ) -> DisplayControlAvailability<DisplayVolumeReading> {
        probe(encoding: encoding, read: operation)
    }

    static func set(
        normalized: Double,
        expected: DisplayVolumeReading,
        isEndpointCurrent: () -> Bool = { true },
        claimMutation: () throws -> Void = {},
        write: Write,
        read: Read
    ) throws -> DisplayVolumeWriteResult {
        guard let requested = rawValue(
            normalized: normalized,
            maximum: expected.maximum,
            encoding: expected.encoding
        ) else {
            return .invalidTarget
        }

        do {
            let liveAvailability = probe(encoding: expected.encoding, read: read)
            guard case .available(let liveReading) = liveAvailability else {
                return .unavailable(liveAvailability.unavailableReason ?? .liveReadFailed(.volume))
            }
            guard liveReading.maximum == expected.maximum else {
                return .failed(expected: requested, readback: liveReading)
            }
            guard isEndpointCurrent() else {
                return .unavailable(.missingRegistryEndpoint)
            }

            try claimMutation()
            try write(requested)
            let readbackAvailability = probe(encoding: expected.encoding, read: read)
            let readback = readbackAvailability.value
            guard readback?.current == requested,
                  readback?.maximum == expected.maximum else {
                return .failed(expected: requested, readback: readback)
            }
            return .applied(readback!)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(expected: requested, readback: nil)
        }
    }

    static func rawValue(
        normalized: Double,
        maximum: UInt16,
        encoding: DisplayCapabilities.VolumeEncoding
    ) -> UInt16? {
        guard normalized.isFinite, (0...1).contains(normalized) else { return nil }
        switch encoding {
        case .continuous:
            guard maximum > 0 else { return nil }
            return UInt16((normalized * Double(maximum)).rounded())
        case .continuousSubrange:
            let upper = min(maximum, 0xFE)
            guard upper > 0 else { return nil }
            guard upper > 1 else { return 1 }
            return 1 + UInt16((normalized * Double(upper - 1)).rounded())
        }
    }
}

nonisolated enum DisplayInputIO {
    typealias Read = () throws -> (current: UInt16, maximum: UInt16)
    typealias WriteOnce = (UInt8) throws -> Void

    static func probe(
        advertisedValues: [UInt8],
        read: Read
    ) -> DisplayControlAvailability<DisplayInputReading> {
        do {
            let value = try read()
            guard let reading = DisplayInputReading(
                current: value.current,
                advertisedValues: advertisedValues
            ) else {
                return .unavailable(.invalidLiveValue(.input))
            }
            return .available(reading)
        } catch {
            return .unavailable(.liveReadFailed(.input))
        }
    }

    static func read(
        advertisedValues: [UInt8],
        operation: Read
    ) -> DisplayControlAvailability<DisplayInputReading> {
        probe(advertisedValues: advertisedValues, read: operation)
    }

    static func set(
        value: UInt8,
        advertisedValues: [UInt8],
        isEndpointCurrent: () -> Bool = { true },
        claimMutation: () throws -> Void = {},
        writeOnce: WriteOnce,
        read: Read
    ) throws -> DisplayInputWriteResult {
        guard advertisedValues.contains(value) else { return .invalidTarget }
        let live = probe(advertisedValues: advertisedValues, read: read)
        guard case .available = live else {
            return .unavailable(live.unavailableReason ?? .liveReadFailed(.input))
        }
        guard isEndpointCurrent() else {
            return .unavailable(.missingRegistryEndpoint)
        }

        try claimMutation()
        do {
            try writeOnce(value)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unconfirmed(expected: value, readback: nil)
        }

        let readback = probe(advertisedValues: advertisedValues, read: read).value
        guard readback?.current == value else {
            return .unconfirmed(expected: value, readback: readback)
        }
        return .applied(readback!)
    }
}

nonisolated struct DisplayResultPublication<Result: Sendable>: Sendable {
    let result: Result
    let shouldPublish: Bool
}

nonisolated enum DisplayResultPublicationPolicy {
    static func evaluate<Result: Sendable>(
        _ result: Result,
        captured: DisplayConnectionToken,
        current: DisplayConnectionToken?
    ) -> DisplayResultPublication<Result> {
        DisplayResultPublication(
            result: result,
            shouldPublish: DisplayEndpointResolver.acceptsResult(
                captured: captured,
                current: current
            )
        )
    }
}

@MainActor
enum DisplayGroupOperationRunner {
    static func run(
        members: [DisplayIdentity],
        operation: @escaping @MainActor (DisplayIdentity) async throws -> DisplayGroupTargetResult
    ) async -> [DisplayGroupTargetOutcome] {
        var outcomes: [DisplayGroupTargetOutcome] = []
        outcomes.reserveCapacity(members.count)

        for (index, identity) in members.enumerated() {
            if Task.isCancelled {
                outcomes.append(DisplayGroupTargetOutcome(identity: identity, result: .cancelled))
                outcomes.append(contentsOf: members.dropFirst(index + 1).map {
                    DisplayGroupTargetOutcome(identity: $0, result: .notAttempted)
                })
                break
            }

            do {
                let result = try await operation(identity)
                outcomes.append(DisplayGroupTargetOutcome(identity: identity, result: result))
            } catch is CancellationError {
                outcomes.append(DisplayGroupTargetOutcome(identity: identity, result: .cancelled))
                outcomes.append(contentsOf: members.dropFirst(index + 1).map {
                    DisplayGroupTargetOutcome(identity: $0, result: .notAttempted)
                })
                break
            } catch {
                outcomes.append(DisplayGroupTargetOutcome(identity: identity, result: .failed))
                outcomes.append(contentsOf: members.dropFirst(index + 1).map {
                    DisplayGroupTargetOutcome(identity: $0, result: .notAttempted)
                })
                break
            }
        }
        return outcomes
    }
}

private nonisolated struct DisplayTrackedOperation: Sendable {
    let cancel: @Sendable () -> Void
    let wait: @Sendable () async -> Void

    init<Value: Sendable>(_ task: Task<Value, Error>) {
        cancel = { task.cancel() }
        wait = { _ = try? await task.value }
    }
}

@MainActor
final class DisplayOperationRegistry {
    private var operations: [UUID: DisplayTrackedOperation] = [:]
    private var activeDrain: (id: UUID, task: Task<Void, Never>)?

    var isDraining: Bool {
        activeDrain != nil
    }

    func run<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task<Value, Error> { @MainActor in
            try Task.checkCancellation()
            return try await operation()
        }
        let operationID = UUID()
        operations[operationID] = DisplayTrackedOperation(task)
        defer { operations[operationID] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAndDrain(
        additionalCleanup: @escaping @MainActor @Sendable () async -> Void = {}
    ) async {
        if let activeDrain {
            await activeDrain.task.value
            if self.activeDrain?.id == activeDrain.id {
                self.activeDrain = nil
            }
            return
        }

        let drainingOperations = operations
        drainingOperations.values.forEach { $0.cancel() }
        let drainID = UUID()
        let drain = Task { @MainActor in
            await additionalCleanup()
            for operation in drainingOperations.values {
                await operation.wait()
            }
        }
        activeDrain = (drainID, drain)
        await drain.value
        if activeDrain?.id == drainID {
            activeDrain = nil
        }
        for operationID in drainingOperations.keys {
            operations[operationID] = nil
        }
    }
}

@Observable
@MainActor
final class DisplayControlService {
    private struct Connection: Sendable {
        let service: DDCService
        let token: DisplayConnectionToken
    }

    private struct ProbeSnapshot: Sendable {
        let service: DDCService
        let endpoint: DisplayEndpointIdentity?
        let device: DisplayDevice?
        let inventory: DisplayInventoryItem
    }

    private let ddcController: DDCController
    private let mutationAdmission: MutationAdmissionGate
    private let discoverDisplays: DisplayDiscoverOperation
    private let readFeature: DisplayFeatureReadOperation
    private let writeFeature: DisplayFeatureWriteOperation
    private let readVCP: DisplayVCPReadOperation
    private let writeVCP: DisplayVCPWriteOperation
    private let writeInputOnce: DisplayInputWriteOperation
    private let probeSingleFlight: DisplayProbeSingleFlight<[ProbeSnapshot]>
    private var probePublication = DisplayProbePublicationState<[ProbeSnapshot]>()
    private var connections: [DisplayIdentity: Connection] = [:]
    private let directOperations = DisplayOperationRegistry()
    private var lifecycleGeneration: UInt64 = 0
    private(set) var isRunning = false
    private(set) var displays: [DisplayDevice] = []
    private(set) var inventory: [DisplayInventoryItem] = []

    init(
        ddcController: DDCController,
        mutationAdmission: MutationAdmissionGate,
        discover: @escaping DisplayDiscoverOperation = {
            DDCExternalDisplayProbe.discover()
        },
        read: @escaping DisplayFeatureReadOperation = { service, feature in
            let value = try service.readVCP(feature.rawValue)
            return (value.current, value.max)
        },
        write: @escaping DisplayFeatureWriteOperation = { service, feature, value in
            try service.writeVCP(feature.rawValue, value: value)
        },
        readCapabilities: @escaping DisplayCapabilitiesReadOperation = { request in
            try request.service.readCapabilitiesString(isCancelled: request.isCancelled)
        },
        readVCP: @escaping DisplayVCPReadOperation = { service, code in
            let value = try service.readVCP(code)
            return (value.current, value.max)
        },
        writeVCP: @escaping DisplayVCPWriteOperation = { service, code, value in
            try service.writeVCP(code, value: value)
        },
        writeInputOnce: @escaping DisplayInputWriteOperation = { service, value in
            try service.writeVCPOnce(0x60, value: UInt16(value))
        },
        discoverSystemDisplays: @escaping DisplaySystemDisplayDiscoverOperation = {
            DisplaySystemDisplayProbe.discover()
        }
    ) {
        self.ddcController = ddcController
        self.mutationAdmission = mutationAdmission
        self.discoverDisplays = discover
        self.readFeature = read
        self.writeFeature = write
        self.readVCP = readVCP
        self.writeVCP = writeVCP
        self.writeInputOnce = writeInputOnce
        self.probeSingleFlight = DisplayProbeSingleFlight {
            do {
                return try await ddcController.performSerialized { context in
                    Self.makeProbeSnapshots(
                        from: discover(),
                        systemDisplays: discoverSystemDisplays(),
                        readFeature: read,
                        readCapabilities: readCapabilities,
                        readVCP: readVCP,
                        isCancelled: { context.isCancelled }
                    )
                }
            } catch {
                return []
            }
        }
    }

    func start() {
        guard !isRunning, !directOperations.isDraining else { return }
        lifecycleGeneration &+= 1
        isRunning = true
    }

    func resume() {
        start()
    }

    func stopAndDrain() async {
        if isRunning {
            isRunning = false
            lifecycleGeneration &+= 1
        }
        connections.removeAll()

        let probeSingleFlight = probeSingleFlight
        await directOperations.cancelAndDrain {
            await probeSingleFlight.cancelAndDrain()
        }
    }

    func probe() async {
        guard isRunning else { return }
        let generation = lifecycleGeneration
        try? await directOperations.run { @MainActor [self] in
            guard isRunning, generation == lifecycleGeneration else { return }
            let flight = try await probeSingleFlight.flight()
            guard isRunning, generation == lifecycleGeneration else {
                await probeSingleFlight.cancelAndDrain()
                return
            }
            probePublication.requested(flight.id)
            let snapshots = await flight.value()
            guard isRunning,
                  generation == lifecycleGeneration,
                  probePublication.publish(
                snapshots,
                from: flight.id,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            let previousConnections = connections
            connections = Dictionary(uniqueKeysWithValues: snapshots.compactMap {
                guard let device = $0.device, let endpoint = $0.endpoint else { return nil }
                let token = DisplayEndpointResolver.connectionToken(
                    for: endpoint,
                    reusing: previousConnections[device.id]?.token
                )
                return (device.id, Connection(service: $0.service, token: token))
            })
            displays = snapshots.compactMap(\.device).sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                if lhs.id.vendorID != rhs.id.vendorID { return lhs.id.vendorID < rhs.id.vendorID }
                if lhs.id.productID != rhs.id.productID { return lhs.id.productID < rhs.id.productID }
                return lhs.id.serialNumber < rhs.id.serialNumber
            }
            let previousInventory = inventory
            inventory = snapshots.map { snapshot in
                let item = snapshot.inventory
                return DisplayInventoryItem(
                    id: item.id,
                    name: item.name,
                    backend: item.backend,
                    identity: item.identity,
                    registryID: item.registryID,
                    systemDisplay: item.systemDisplay,
                    controls: item.controls,
                    unverifiedWrites: previousInventory.first(where: { $0.id == item.id })?
                        .unverifiedWrites ?? []
                )
            }.sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return Self.inventorySortKey(lhs.id) < Self.inventorySortKey(rhs.id)
            }
        }
    }

    func read(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) async -> DisplayFeatureReading? {
        guard isRunning,
              let connection = connections[identity],
              connection.token.endpoint != nil else {
            return nil
        }
        let generation = lifecycleGeneration

        let ddcController = ddcController
        let readFeature = readFeature
        return try? await directOperations.run { @MainActor [self] in
            let availability = (try? await ddcController.performSerialized {
                DisplayFeatureIO.availability(feature) {
                    try readFeature(connection.service, feature)
                }
            }) ?? .unavailable(.liveReadFailed(feature.controlKind))
            guard isRunning,
                  generation == lifecycleGeneration,
                  DisplayEndpointResolver.acceptsResult(
                captured: connection.token,
                current: connections[identity]?.token
              ) else {
                return nil
            }

            switch availability {
            case .available(let reading):
                updateFeature(feature, for: identity, reading: reading)
                return reading
            case .unavailable(let reason):
                removeFeature(feature, for: identity, reason: reason)
                return nil
            }
        }
    }

    func readVolume(
        for identity: DisplayIdentity
    ) async -> DisplayControlAvailability<DisplayVolumeReading> {
        guard isRunning else { return .unavailable(.serviceStopped) }
        guard let connection = connections[identity],
              connection.token.endpoint != nil,
              let encoding = displays.first(where: { $0.id == identity })?.volumeEncoding else {
            return currentVolumeAvailability(for: identity)
                ?? .unavailable(.missingRegistryEndpoint)
        }
        let generation = lifecycleGeneration
        let ddcController = ddcController
        let readVCP = readVCP
        return (try? await directOperations.run { @MainActor [self] in
            let availability = try await ddcController.performSerialized {
                DisplayVolumeIO.read(encoding: encoding) {
                    try readVCP(connection.service, 0x62)
                }
            }
            guard isRunning,
                  generation == lifecycleGeneration,
                  DisplayEndpointResolver.acceptsResult(
                    captured: connection.token,
                    current: connections[identity]?.token
                  ) else {
                return .unavailable(.serviceStopped)
            }
            updateVolume(for: identity, availability: availability)
            return availability
        }) ?? .unavailable(.serviceStopped)
    }

    func readInput(
        for identity: DisplayIdentity
    ) async -> DisplayControlAvailability<DisplayInputReading> {
        guard isRunning else { return .unavailable(.serviceStopped) }
        guard let connection = connections[identity],
              connection.token.endpoint != nil,
              let values = displays.first(where: { $0.id == identity })?.advertisedInputValues,
              !values.isEmpty else {
            return currentInputAvailability(for: identity)
                ?? .unavailable(.missingRegistryEndpoint)
        }
        let generation = lifecycleGeneration
        let ddcController = ddcController
        let readVCP = readVCP
        return (try? await directOperations.run { @MainActor [self] in
            let availability = try await ddcController.performSerialized {
                DisplayInputIO.read(advertisedValues: values) {
                    try readVCP(connection.service, 0x60)
                }
            }
            guard isRunning,
                  generation == lifecycleGeneration,
                  DisplayEndpointResolver.acceptsResult(
                    captured: connection.token,
                    current: connections[identity]?.token
                  ) else {
                return .unavailable(.serviceStopped)
            }
            updateInput(for: identity, availability: availability)
            return availability
        }) ?? .unavailable(.serviceStopped)
    }

    func set(
        _ normalized: Double,
        feature: DisplayFeature,
        for identity: DisplayIdentity,
        mutationOwner: DisplayMutationOwner = .manual
    ) async throws -> DisplayWriteResult {
        guard isRunning,
              let connection = connections[identity],
              let expectedEndpoint = connection.token.endpoint,
              let maximum = displays.first(where: { $0.id == identity })?.features[feature]?.maximum else {
            return .unavailable
        }
        let generation = lifecycleGeneration
        return try await directOperations.run { @MainActor [self] in
            let admissionPermit = try mutationAdmission.acquire(
                owner: mutationOwner.admissionOwner,
                mode: .shared
            )
            defer { mutationAdmission.release(admissionPermit) }

            let result: DisplayWriteResult
            let ddcController = ddcController
            let discoverDisplays = discoverDisplays
            let readFeature = readFeature
            let writeFeature = writeFeature
            do {
                result = try await ddcController.performSerialized { context in
                    try DisplayFeatureIO.set(
                        normalized: normalized,
                        maximum: maximum,
                        isEndpointCurrent: {
                            let liveEndpoints = discoverDisplays().compactMap {
                                record -> DisplayEndpointCandidate? in
                                guard let displayIdentity = DisplayIdentity(edid: record.edid) else {
                                    return nil
                                }
                                return DisplayEndpointCandidate(
                                    displayIdentity: displayIdentity,
                                    registryID: record.registryID
                                )
                            }
                            return DisplayEndpointResolver.isCurrent(
                                expectedEndpoint,
                                among: liveEndpoints
                            )
                        },
                        claimMutation: { try context.claimMutation() },
                        write: { try writeFeature(connection.service, feature, $0) },
                        read: {
                            try readFeature(connection.service, feature)
                        }
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let expected = DisplayFeatureIO.rawValue(
                    normalized: normalized,
                    maximum: maximum
                ) {
                    result = .failed(expected: expected, readback: nil)
                } else {
                    result = .invalidTarget
                }
            }

            guard isRunning, generation == lifecycleGeneration else {
                return result
            }
            let publication = DisplayResultPublicationPolicy.evaluate(
                result,
                captured: connection.token,
                current: connections[identity]?.token
            )
            guard publication.shouldPublish else { return publication.result }

            switch result {
            case .applied(let reading):
                updateFeature(feature, for: identity, reading: reading, writeConfirmed: true)
                setWriteVerified(true, control: feature.controlKind, for: identity)
            case .failed(_, let readback):
                if let readback {
                    updateFeature(feature, for: identity, reading: readback, writeConfirmed: false)
                } else {
                    removeFeature(
                        feature,
                        for: identity,
                        reason: .liveReadFailed(feature.controlKind)
                    )
                }
                setWriteVerified(false, control: feature.controlKind, for: identity)
            case .unavailable:
                removeFeature(
                    feature,
                    for: identity,
                    reason: .missingRegistryEndpoint
                )
            case .invalidTarget:
                break
            }
            return result
        }
    }

    func setVolume(
        _ normalized: Double,
        for identity: DisplayIdentity
    ) async throws -> DisplayVolumeWriteResult {
        guard isRunning else { return .unavailable(.serviceStopped) }
        guard let display = displays.first(where: { $0.id == identity }) else {
            return .unavailable(.missingStableIdentity)
        }
        guard case .available(let expected) = display.volume else {
            return .unavailable(display.volume.unavailableReason ?? .liveReadFailed(.volume))
        }
        guard let connection = connections[identity],
              let expectedEndpoint = connection.token.endpoint else {
            return .unavailable(.missingRegistryEndpoint)
        }
        let generation = lifecycleGeneration
        return try await directOperations.run { @MainActor [self] in
            let admissionPermit = try mutationAdmission.acquire(owner: .manualDisplay, mode: .shared)
            defer { mutationAdmission.release(admissionPermit) }

            let result: DisplayVolumeWriteResult
            let ddcController = ddcController
            let discoverDisplays = discoverDisplays
            let readVCP = readVCP
            let writeVCP = writeVCP
            do {
                result = try await ddcController.performSerialized { context in
                    try DisplayVolumeIO.set(
                        normalized: normalized,
                        expected: expected,
                        isEndpointCurrent: {
                            Self.isEndpointCurrent(expectedEndpoint, discover: discoverDisplays)
                        },
                        claimMutation: { try context.claimMutation() },
                        write: { try writeVCP(connection.service, 0x62, $0) },
                        read: { try readVCP(connection.service, 0x62) }
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let rawValue = DisplayVolumeIO.rawValue(
                    normalized: normalized,
                    maximum: expected.maximum,
                    encoding: expected.encoding
                ) {
                    result = .failed(expected: rawValue, readback: nil)
                } else {
                    result = .invalidTarget
                }
            }

            guard isRunning, generation == lifecycleGeneration else { return result }
            let publication = DisplayResultPublicationPolicy.evaluate(
                result,
                captured: connection.token,
                current: connections[identity]?.token
            )
            guard publication.shouldPublish else { return publication.result }

            switch result {
            case .applied(let reading):
                updateVolume(for: identity, availability: .available(reading))
                setWriteVerified(true, control: .volume, for: identity)
            case .failed(_, let readback):
                updateVolume(
                    for: identity,
                    availability: readback.map(DisplayControlAvailability.available)
                        ?? .unavailable(.liveReadFailed(.volume))
                )
                setWriteVerified(false, control: .volume, for: identity)
            case .unavailable(let reason):
                updateVolume(for: identity, availability: .unavailable(reason))
            case .invalidTarget:
                break
            }
            return result
        }
    }

    func setInput(
        _ value: UInt8,
        for identity: DisplayIdentity
    ) async throws -> DisplayInputWriteResult {
        guard isRunning else { return .unavailable(.serviceStopped) }
        guard let display = displays.first(where: { $0.id == identity }) else {
            return .unavailable(.missingStableIdentity)
        }
        guard case .available(let expected) = display.input else {
            return .unavailable(display.input.unavailableReason ?? .liveReadFailed(.input))
        }
        guard let connection = connections[identity],
              let expectedEndpoint = connection.token.endpoint else {
            return .unavailable(.missingRegistryEndpoint)
        }
        let generation = lifecycleGeneration
        return try await directOperations.run { @MainActor [self] in
            let admissionPermit = try mutationAdmission.acquire(owner: .manualDisplay, mode: .shared)
            defer { mutationAdmission.release(admissionPermit) }

            let result: DisplayInputWriteResult
            let ddcController = ddcController
            let discoverDisplays = discoverDisplays
            let readVCP = readVCP
            let writeInputOnce = writeInputOnce
            do {
                result = try await ddcController.performSerialized { context in
                    try DisplayInputIO.set(
                        value: value,
                        advertisedValues: expected.advertisedValues,
                        isEndpointCurrent: {
                            Self.isEndpointCurrent(expectedEndpoint, discover: discoverDisplays)
                        },
                        claimMutation: { try context.claimMutation() },
                        writeOnce: { try writeInputOnce(connection.service, $0) },
                        read: { try readVCP(connection.service, 0x60) }
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result = .unconfirmed(expected: value, readback: nil)
            }

            guard isRunning, generation == lifecycleGeneration else { return result }
            let publication = DisplayResultPublicationPolicy.evaluate(
                result,
                captured: connection.token,
                current: connections[identity]?.token
            )
            guard publication.shouldPublish else { return publication.result }

            switch result {
            case .applied(let reading):
                updateInput(for: identity, availability: .available(reading))
                setWriteVerified(true, control: .input, for: identity)
            case .unconfirmed(_, let readback):
                updateInput(
                    for: identity,
                    availability: readback.map(DisplayControlAvailability.available)
                        ?? .unavailable(.liveReadFailed(.input))
                )
                setWriteVerified(false, control: .input, for: identity)
            case .unavailable(let reason):
                updateInput(for: identity, availability: .unavailable(reason))
            case .invalidTarget:
                break
            }
            return result
        }
    }

    func apply(
        _ target: DisplayGroupControlTarget,
        to group: DisplayControlGroup
    ) async throws -> DisplayGroupWriteReport {
        let outcomes = await DisplayGroupOperationRunner.run(members: group.members) { identity in
            switch target {
            case .feature(let feature, let normalized):
                return .feature(try await self.set(normalized, feature: feature, for: identity))
            case .volume(let normalized):
                return .volume(try await self.setVolume(normalized, for: identity))
            case .input(let value):
                return .input(try await self.setInput(value, for: identity))
            }
        }
        return DisplayGroupWriteReport(groupID: group.id, outcomes: outcomes)
    }

    func systemDisplayID(for identity: DisplayIdentity) -> UInt32? {
        displays.first(where: { $0.id == identity })?.systemDisplayID
    }

    func isSceneEligible(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) -> Bool {
        displays.first(where: { $0.id == identity })?
            .sceneEligibleFeatures.contains(feature) == true
    }

    private nonisolated static func makeProbeSnapshots(
        from records: [DDCExternalDisplayRecord],
        systemDisplays: [DisplaySystemDisplayCandidate],
        readFeature: DisplayFeatureReadOperation,
        readCapabilities: DisplayCapabilitiesReadOperation,
        readVCP: DisplayVCPReadOperation,
        isCancelled: @escaping DisplayCancellationCheck
    ) -> [ProbeSnapshot] {
        let identities = records.map { DisplayIdentity(edid: $0.edid) }
        let uniqueIdentities = DisplayIdentityResolver.unique(identities)
        let registryCounts = Dictionary(
            grouping: records.compactMap(\.registryID),
            by: { $0 }
        ).mapValues(\.count)

        var snapshots: [ProbeSnapshot] = []
        snapshots.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            guard !isCancelled() else { break }
            let identity = identities[index]
            let registryID = record.registryID
            let prerequisiteFailure: DisplayControlUnavailableReason? = {
                guard let identity else { return .missingStableIdentity }
                guard uniqueIdentities.contains(identity) else { return .duplicateStableIdentity }
                guard let registryID else { return .missingRegistryEndpoint }
                guard registryCounts[registryID] == 1 else { return .duplicateRegistryEndpoint }
                return nil
            }()
            let systemDisplay: DisplaySystemDisplayMatch = {
                guard let identity else { return .unavailable(.missingStableIdentity) }
                guard uniqueIdentities.contains(identity) else {
                    return .unavailable(.duplicateStableIdentity)
                }
                return DisplaySystemDisplayResolver.resolve(identity, among: systemDisplays)
            }()

            let controls: DisplayControlInventory
            var volumeEncoding: DisplayCapabilities.VolumeEncoding?
            var advertisedInputValues: [UInt8] = []
            if let prerequisiteFailure {
                controls = unavailableControls(prerequisiteFailure)
            } else {
                let brightness = DisplayFeatureIO.availability(.brightness) {
                    try readFeature(record.service, .brightness)
                }
                let contrast = DisplayFeatureIO.availability(.contrast) {
                    try readFeature(record.service, .contrast)
                }
                let capabilityResult = DisplayCapabilityIO.read {
                    try readCapabilities(
                        DisplayCapabilitiesReadRequest(
                            service: record.service,
                            isCancelled: isCancelled
                        )
                    )
                }
                let volume: DisplayControlAvailability<DisplayVolumeReading>
                let input: DisplayControlAvailability<DisplayInputReading>
                switch capabilityResult {
                case .failure(let reason):
                    volume = .unavailable(reason)
                    input = .unavailable(reason)
                case .success(let capabilities):
                    switch capabilities.volume {
                    case .failure(let reason):
                        volume = .unavailable(
                            DisplayCapabilityIO.unavailableReason(reason, control: .volume)
                        )
                    case .success(let encoding):
                        volumeEncoding = encoding
                        volume = DisplayVolumeIO.probe(encoding: encoding) {
                            try readVCP(record.service, 0x62)
                        }
                    }
                    switch capabilities.inputSelection {
                    case .failure(let reason):
                        input = .unavailable(
                            DisplayCapabilityIO.unavailableReason(reason, control: .input)
                        )
                    case .success(let values):
                        advertisedInputValues = values
                        input = DisplayInputIO.probe(advertisedValues: values) {
                            try readVCP(record.service, 0x60)
                        }
                    }
                }
                controls = DisplayControlInventory(
                    brightness: brightness,
                    contrast: contrast,
                    volume: volume,
                    input: input
                )
            }

            var features: [DisplayFeature: DisplayFeatureReading] = [:]
            if let brightness = controls.brightness.value {
                features[.brightness] = brightness
            }
            if let contrast = controls.contrast.value {
                features[.contrast] = contrast
            }
            let endpoint: DisplayEndpointIdentity? = {
                guard prerequisiteFailure == nil, let identity, let registryID else { return nil }
                return DisplayEndpointIdentity(displayIdentity: identity, registryID: registryID)
            }()
            let device = identity.flatMap { identity -> DisplayDevice? in
                guard uniqueIdentities.contains(identity) else { return nil }
                return DisplayDevice(
                    id: identity,
                    name: record.name,
                    features: features,
                    sceneEligibleFeatures: endpoint == nil ? [] : Set(features.keys),
                    systemDisplayID: systemDisplay.displayID,
                    volumeEncoding: volumeEncoding,
                    advertisedInputValues: advertisedInputValues,
                    volume: controls.volume,
                    input: controls.input
                )
            }
            let inventoryID: DisplayInventoryID = {
                if let identity, uniqueIdentities.contains(identity) {
                    return .stable(identity)
                }
                if let registryID, registryCounts[registryID] == 1 {
                    return .registry(registryID.rawValue)
                }
                return .discovered(index)
            }()
            snapshots.append(ProbeSnapshot(
                service: record.service,
                endpoint: endpoint,
                device: device,
                inventory: DisplayInventoryItem(
                    id: inventoryID,
                    name: record.name,
                    backend: .ddcCI,
                    identity: identity,
                    registryID: registryID?.rawValue,
                    systemDisplay: systemDisplay,
                    controls: controls
                )
            ))
        }
        return snapshots
    }

    private nonisolated static func unavailableControls(
        _ reason: DisplayControlUnavailableReason
    ) -> DisplayControlInventory {
        DisplayControlInventory(
            brightness: .unavailable(reason),
            contrast: .unavailable(reason),
            volume: .unavailable(reason),
            input: .unavailable(reason)
        )
    }

    private nonisolated static func isEndpointCurrent(
        _ expected: DisplayEndpointIdentity,
        discover: DisplayDiscoverOperation
    ) -> Bool {
        let liveEndpoints = discover().compactMap { record -> DisplayEndpointCandidate? in
            guard let displayIdentity = DisplayIdentity(edid: record.edid) else { return nil }
            return DisplayEndpointCandidate(
                displayIdentity: displayIdentity,
                registryID: record.registryID
            )
        }
        return DisplayEndpointResolver.isCurrent(expected, among: liveEndpoints)
    }

    private nonisolated static func inventorySortKey(_ id: DisplayInventoryID) -> String {
        switch id {
        case .stable(let identity): "0:" + identity.rawValue
        case .registry(let registryID): "1:" + String(registryID)
        case .discovered(let index): "2:" + String(index)
        }
    }

    private func updateFeature(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity,
        reading: DisplayFeatureReading,
        writeConfirmed: Bool? = nil
    ) {
        guard let index = displays.firstIndex(where: { $0.id == identity }) else { return }
        let display = displays[index]
        var features = display.features
        let previousMaximum = features[feature]?.maximum
        features[feature] = reading
        var eligible = display.sceneEligibleFeatures
        if let writeConfirmed {
            if writeConfirmed {
                eligible.insert(feature)
            } else {
                eligible.remove(feature)
            }
        } else if previousMaximum != reading.maximum {
            eligible.remove(feature)
        }
        displays[index] = DisplayDevice(
            id: display.id,
            name: display.name,
            features: features,
            sceneEligibleFeatures: eligible,
            backend: display.backend,
            systemDisplayID: display.systemDisplayID,
            volumeEncoding: display.volumeEncoding,
            advertisedInputValues: display.advertisedInputValues,
            volume: display.volume,
            input: display.input
        )
        updateInventoryFeature(feature, for: identity, availability: .available(reading))
    }

    private func removeFeature(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity,
        reason: DisplayControlUnavailableReason
    ) {
        if let index = displays.firstIndex(where: { $0.id == identity }) {
            let display = displays[index]
            var features = display.features
            features[feature] = nil
            var eligible = display.sceneEligibleFeatures
            eligible.remove(feature)
            displays[index] = DisplayDevice(
                id: display.id,
                name: display.name,
                features: features,
                sceneEligibleFeatures: eligible,
                backend: display.backend,
                systemDisplayID: display.systemDisplayID,
                volumeEncoding: display.volumeEncoding,
                advertisedInputValues: display.advertisedInputValues,
                volume: display.volume,
                input: display.input
            )
        }
        updateInventoryFeature(feature, for: identity, availability: .unavailable(reason))
    }

    private func currentVolumeAvailability(
        for identity: DisplayIdentity
    ) -> DisplayControlAvailability<DisplayVolumeReading>? {
        displays.first(where: { $0.id == identity })?.volume
    }

    private func currentInputAvailability(
        for identity: DisplayIdentity
    ) -> DisplayControlAvailability<DisplayInputReading>? {
        displays.first(where: { $0.id == identity })?.input
    }

    private func updateVolume(
        for identity: DisplayIdentity,
        availability: DisplayControlAvailability<DisplayVolumeReading>
    ) {
        guard let index = displays.firstIndex(where: { $0.id == identity }) else { return }
        let display = displays[index]
        displays[index] = DisplayDevice(
            id: display.id,
            name: display.name,
            features: display.features,
            sceneEligibleFeatures: display.sceneEligibleFeatures,
            backend: display.backend,
            systemDisplayID: display.systemDisplayID,
            volumeEncoding: display.volumeEncoding,
            advertisedInputValues: display.advertisedInputValues,
            volume: availability,
            input: display.input
        )
        updateInventory(for: identity) { controls in
            DisplayControlInventory(
                brightness: controls.brightness,
                contrast: controls.contrast,
                volume: availability,
                input: controls.input
            )
        }
    }

    private func updateInput(
        for identity: DisplayIdentity,
        availability: DisplayControlAvailability<DisplayInputReading>
    ) {
        guard let index = displays.firstIndex(where: { $0.id == identity }) else { return }
        let display = displays[index]
        displays[index] = DisplayDevice(
            id: display.id,
            name: display.name,
            features: display.features,
            sceneEligibleFeatures: display.sceneEligibleFeatures,
            backend: display.backend,
            systemDisplayID: display.systemDisplayID,
            volumeEncoding: display.volumeEncoding,
            advertisedInputValues: display.advertisedInputValues,
            volume: display.volume,
            input: availability
        )
        updateInventory(for: identity) { controls in
            DisplayControlInventory(
                brightness: controls.brightness,
                contrast: controls.contrast,
                volume: controls.volume,
                input: availability
            )
        }
    }

    private func updateInventoryFeature(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity,
        availability: DisplayControlAvailability<DisplayFeatureReading>
    ) {
        updateInventory(for: identity) { controls in
            switch feature {
            case .brightness:
                DisplayControlInventory(
                    brightness: availability,
                    contrast: controls.contrast,
                    volume: controls.volume,
                    input: controls.input
                )
            case .contrast:
                DisplayControlInventory(
                    brightness: controls.brightness,
                    contrast: availability,
                    volume: controls.volume,
                    input: controls.input
                )
            }
        }
    }

    private func updateInventory(
        for identity: DisplayIdentity,
        controls transform: (DisplayControlInventory) -> DisplayControlInventory
    ) {
        guard let index = inventory.firstIndex(where: { $0.identity == identity }) else { return }
        let item = inventory[index]
        inventory[index] = DisplayInventoryItem(
            id: item.id,
            name: item.name,
            backend: item.backend,
            identity: item.identity,
            registryID: item.registryID,
            systemDisplay: item.systemDisplay,
            controls: transform(item.controls),
            unverifiedWrites: item.unverifiedWrites
        )
    }

    private func setWriteVerified(
        _ verified: Bool,
        control: DisplayControlKind,
        for identity: DisplayIdentity
    ) {
        guard let index = inventory.firstIndex(where: { $0.identity == identity }) else { return }
        let item = inventory[index]
        var unverifiedWrites = item.unverifiedWrites
        if verified {
            unverifiedWrites.remove(control)
        } else {
            unverifiedWrites.insert(control)
        }
        inventory[index] = DisplayInventoryItem(
            id: item.id,
            name: item.name,
            backend: item.backend,
            identity: item.identity,
            registryID: item.registryID,
            systemDisplay: item.systemDisplay,
            controls: item.controls,
            unverifiedWrites: unverifiedWrites
        )
    }
}

#else

@Observable
@MainActor
final class DisplayControlService {
    private(set) var displays: [DisplayDevice] = []
    private(set) var inventory: [DisplayInventoryItem] = []
    private(set) var isRunning = false

    init() {}

    func start() {
        isRunning = true
    }

    func resume() {
        start()
    }

    func stopAndDrain() async {
        isRunning = false
    }

    func probe() async {}

    func read(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) async -> DisplayFeatureReading? {
        nil
    }

    func set(
        _ normalized: Double,
        feature: DisplayFeature,
        for identity: DisplayIdentity,
        mutationOwner: DisplayMutationOwner = .manual
    ) async throws -> DisplayWriteResult {
        .unavailable
    }

    func readVolume(
        for identity: DisplayIdentity
    ) async -> DisplayControlAvailability<DisplayVolumeReading> {
        .unavailable(isRunning ? .appStoreBuild : .serviceStopped)
    }

    func readInput(
        for identity: DisplayIdentity
    ) async -> DisplayControlAvailability<DisplayInputReading> {
        .unavailable(isRunning ? .appStoreBuild : .serviceStopped)
    }

    func setVolume(
        _ normalized: Double,
        for identity: DisplayIdentity
    ) async throws -> DisplayVolumeWriteResult {
        .unavailable(isRunning ? .appStoreBuild : .serviceStopped)
    }

    func setInput(
        _ value: UInt8,
        for identity: DisplayIdentity
    ) async throws -> DisplayInputWriteResult {
        .unavailable(isRunning ? .appStoreBuild : .serviceStopped)
    }

    func apply(
        _ target: DisplayGroupControlTarget,
        to group: DisplayControlGroup
    ) async throws -> DisplayGroupWriteReport {
        let outcomes = group.members.map { identity in
            let result: DisplayGroupTargetResult = switch target {
            case .feature:
                .feature(.unavailable)
            case .volume:
                .volume(.unavailable(isRunning ? .appStoreBuild : .serviceStopped))
            case .input:
                .input(.unavailable(isRunning ? .appStoreBuild : .serviceStopped))
            }
            return DisplayGroupTargetOutcome(identity: identity, result: result)
        }
        return DisplayGroupWriteReport(groupID: group.id, outcomes: outcomes)
    }

    func systemDisplayID(for identity: DisplayIdentity) -> UInt32? {
        nil
    }

    func isSceneEligible(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) -> Bool {
        false
    }
}

#endif
