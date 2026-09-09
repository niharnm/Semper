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

actor DisplayProbeSingleFlight<Value: Sendable> {
    private struct Active {
        let task: Task<Value, Never>
        var waiterCount: Int
    }

    private let operation: @Sendable () async -> Value
    private var active: Active?

    init(operation: @escaping @Sendable () async -> Value) {
        self.operation = operation
    }

    func value() async -> Value {
        let task: Task<Value, Never>
        if var active {
            active.waiterCount += 1
            self.active = active
            task = active.task
        } else {
            let operation = operation
            let created = Task { await operation() }
            self.active = Active(task: created, waiterCount: 1)
            task = created
        }

        let value = await task.value
        if var active {
            active.waiterCount -= 1
            self.active = active.waiterCount == 0 ? nil : active
        }
        return value
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
        write: Write,
        read: Read
    ) -> DisplayWriteResult {
        guard maximum > 0 else { return .unavailable }
        guard let requested = rawValue(normalized: normalized, maximum: maximum) else {
            return .invalidTarget
        }

        do {
            try write(requested)
            let readback = validated(read: read)
            guard readback?.current == requested, readback?.maximum == maximum else {
                return .failed(expected: requested, readback: readback)
            }
            return .applied(readback!)
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

@Observable
@MainActor
final class DisplayControlService {
    private struct ProbeSnapshot: Sendable {
        let service: DDCService
        let device: DisplayDevice
    }

    private let ddcController: DDCController
    private let probeSingleFlight: DisplayProbeSingleFlight<[ProbeSnapshot]>
    private var services: [DisplayIdentity: DDCService] = [:]
    private(set) var displays: [DisplayDevice] = []

    init(ddcController: DDCController) {
        self.ddcController = ddcController
        self.probeSingleFlight = DisplayProbeSingleFlight {
            do {
                return try await ddcController.performSerialized {
                    Self.makeProbeSnapshots(from: DDCExternalDisplayProbe.discover())
                }
            } catch {
                return []
            }
        }
    }

    func probe() async {
        let snapshots = await probeSingleFlight.value()
        services = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.device.id, $0.service) })
        displays = snapshots.map(\.device).sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            if lhs.id.vendorID != rhs.id.vendorID { return lhs.id.vendorID < rhs.id.vendorID }
            if lhs.id.productID != rhs.id.productID { return lhs.id.productID < rhs.id.productID }
            return lhs.id.serialNumber < rhs.id.serialNumber
        }
    }

    func read(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) async -> DisplayFeatureReading? {
        guard let service = services[identity] else { return nil }

        let reading = try? await ddcController.performSerialized {
            DisplayFeatureIO.read {
                let value = try service.readVCP(feature.rawValue)
                return (value.current, value.max)
            }
        }
        guard let reading else { return nil }

        updateFeature(feature, for: identity, reading: reading)
        return reading
    }

    func set(
        _ normalized: Double,
        feature: DisplayFeature,
        for identity: DisplayIdentity
    ) async -> DisplayWriteResult {
        guard let service = services[identity],
              let maximum = displays.first(where: { $0.id == identity })?.features[feature]?.maximum else {
            return .unavailable
        }

        let result: DisplayWriteResult
        do {
            result = try await ddcController.performSerialized {
                DisplayFeatureIO.set(
                    normalized: normalized,
                    maximum: maximum,
                    write: { try service.writeVCP(feature.rawValue, value: $0) },
                    read: {
                        let value = try service.readVCP(feature.rawValue)
                        return (value.current, value.max)
                    }
                )
            }
        } catch {
            guard let expected = DisplayFeatureIO.rawValue(
                normalized: normalized,
                maximum: maximum
            ) else { return .invalidTarget }
            return .failed(expected: expected, readback: nil)
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

    func isSceneEligible(
        _ feature: DisplayFeature,
        for identity: DisplayIdentity
    ) -> Bool {
        displays.first(where: { $0.id == identity })?
            .sceneEligibleFeatures.contains(feature) == true
    }

    private nonisolated static func makeProbeSnapshots(
        from records: [DDCExternalDisplayRecord]
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
                    let value = try record.service.readVCP(feature.rawValue)
                    return (value.current, value.max)
                }
            )

            guard !summary.readings.isEmpty else { return nil }
            return ProbeSnapshot(
                service: record.service,
                device: DisplayDevice(
                    id: identity,
                    name: record.name,
                    features: summary.readings,
                    sceneEligibleFeatures: summary.sceneEligibleFeatures
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

    init() {}

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
    ) async -> DisplayWriteResult {
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
