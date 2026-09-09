import Foundation

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

nonisolated enum DisplayEndpointResolver {
    static func isCurrent(
        _ expected: DisplayEndpointIdentity,
        among candidates: [DisplayEndpointCandidate]
    ) -> Bool {
        let matches = candidates.filter { $0.displayIdentity == expected.displayIdentity }
        return matches.count == 1 && matches[0].registryID == expected.registryID
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
        let device: DisplayDevice
    }

    private let ddcController: DDCController
    private let mutationAdmission: MutationAdmissionGate
    private let discoverDisplays: DisplayDiscoverOperation
    private let readFeature: DisplayFeatureReadOperation
    private let writeFeature: DisplayFeatureWriteOperation
    private let probeSingleFlight: DisplayProbeSingleFlight<[ProbeSnapshot]>
    private var probePublication = DisplayProbePublicationState<[ProbeSnapshot]>()
    private var connections: [DisplayIdentity: Connection] = [:]
    private let directOperations = DisplayOperationRegistry()
    private var lifecycleGeneration: UInt64 = 0
    private(set) var isRunning = false
    private(set) var displays: [DisplayDevice] = []

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
        }
    ) {
        self.ddcController = ddcController
        self.mutationAdmission = mutationAdmission
        self.discoverDisplays = discover
        self.readFeature = read
        self.writeFeature = write
        self.probeSingleFlight = DisplayProbeSingleFlight {
            do {
                return try await ddcController.performSerialized {
                    Self.makeProbeSnapshots(from: discover(), read: read)
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
            connections = Dictionary(uniqueKeysWithValues: snapshots.map {
                let token = DisplayEndpointResolver.connectionToken(
                    for: $0.endpoint,
                    reusing: previousConnections[$0.device.id]?.token
                )
                return ($0.device.id, Connection(service: $0.service, token: token))
            })
            displays = snapshots.map(\.device).sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                if lhs.id.vendorID != rhs.id.vendorID { return lhs.id.vendorID < rhs.id.vendorID }
                if lhs.id.productID != rhs.id.productID { return lhs.id.productID < rhs.id.productID }
                return lhs.id.serialNumber < rhs.id.serialNumber
            }
        }
    }

    func read(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) async -> DisplayFeatureReading? {
        guard isRunning, let connection = connections[identity] else { return nil }
        let generation = lifecycleGeneration

        let ddcController = ddcController
        let readFeature = readFeature
        return try? await directOperations.run { @MainActor [self] in
            let reading = try? await ddcController.performSerialized {
                DisplayFeatureIO.read {
                    try readFeature(connection.service, feature)
                }
            }
            guard isRunning,
                  generation == lifecycleGeneration,
                  let reading,
                  DisplayEndpointResolver.acceptsResult(
                captured: connection.token,
                current: connections[identity]?.token
              ) else {
                return nil
            }

            updateFeature(feature, for: identity, reading: reading)
            return reading
        }
    }

    func set(
        _ normalized: Double,
        feature: DisplayFeature,
        for identity: DisplayIdentity
    ) async throws -> DisplayWriteResult {
        guard isRunning,
              let connection = connections[identity],
              let expectedEndpoint = connection.token.endpoint,
              let maximum = displays.first(where: { $0.id == identity })?.features[feature]?.maximum else {
            return .unavailable
        }
        let generation = lifecycleGeneration
        return try await directOperations.run { @MainActor [self] in
            let admissionPermit = try mutationAdmission.acquire(owner: .manual, mode: .shared)
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
            guard DisplayEndpointResolver.acceptsResult(
                captured: connection.token,
                current: connections[identity]?.token
            ) else {
                return .unavailable
            }

            switch result {
            case .applied(let reading):
                updateFeature(feature, for: identity, reading: reading, writeConfirmed: true)
            case .failed(_, let readback):
                if let readback {
                    updateFeature(feature, for: identity, reading: readback, writeConfirmed: false)
                } else {
                    removeSceneEligibility(feature, for: identity)
                }
            case .unavailable:
                removeSceneEligibility(feature, for: identity)
            case .invalidTarget:
                break
            }
            return result
        }
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
        read: DisplayFeatureReadOperation
    ) -> [ProbeSnapshot] {
        let identified = records.compactMap { record -> (DisplayIdentity, DDCExternalDisplayRecord)? in
            guard let identity = DisplayIdentity(edid: record.edid) else { return nil }
            return (identity, record)
        }
        let uniqueIdentities = DisplayIdentityResolver.unique(identified.map(\.0))

        return identified.compactMap { identity, record in
            guard uniqueIdentities.contains(identity) else { return nil }

            let summary = DisplayFeatureIO.probeAll(
                read: { feature in
                    try read(record.service, feature)
                }
            )

            guard !summary.readings.isEmpty else { return nil }
            let endpoint = record.registryID.map {
                DisplayEndpointIdentity(displayIdentity: identity, registryID: $0)
            }
            return ProbeSnapshot(
                service: record.service,
                endpoint: endpoint,
                device: DisplayDevice(
                    id: identity,
                    name: record.name,
                    features: summary.readings,
                    sceneEligibleFeatures: endpoint == nil ? [] : summary.sceneEligibleFeatures
                )
            )
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
            sceneEligibleFeatures: eligible
        )
    }

    private func removeSceneEligibility(_ feature: DisplayFeature, for identity: DisplayIdentity) {
        guard let index = displays.firstIndex(where: { $0.id == identity }) else { return }
        let display = displays[index]
        var eligible = display.sceneEligibleFeatures
        eligible.remove(feature)
        displays[index] = DisplayDevice(
            id: display.id,
            name: display.name,
            features: display.features,
            sceneEligibleFeatures: eligible
        )
    }
}

#else

@Observable
@MainActor
final class DisplayControlService {
    private(set) var displays: [DisplayDevice] = []
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
        for identity: DisplayIdentity
    ) async throws -> DisplayWriteResult {
        .unavailable
    }

    func isSceneEligible(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) -> Bool {
        false
    }
}

#endif
