import Foundation

enum SemperExperiment: String, Sendable {
    case popupEmptyStateGuidance = "macos.popup-empty-state-guidance.v1"
}

enum ExperimentVariant: String, Codable, Sendable {
    case control
    case treatment
}

enum ExperimentAssignmentSource: String, Codable, Sendable {
    case bucket
    case debugOverride = "debug_override"
}

enum ExperimentEventName: String, Codable, Sendable {
    case exposure = "experiment_exposure"
    case outcome = "experiment_outcome"
}

struct ExperimentAssignment: Equatable, Sendable {
    let variant: ExperimentVariant
    let source: ExperimentAssignmentSource
}

struct ExperimentEvent: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let eventID: UUID
    let occurredAt: Date
    let eventName: ExperimentEventName
    let surface: String
    let experimentID: String
    let variant: ExperimentVariant
    let assignmentSource: ExperimentAssignmentSource
    let subjectID: UUID
    let sessionID: UUID
    let collectionMode: String
    let metricKey: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case occurredAt = "occurred_at"
        case eventName = "event_name"
        case surface
        case experimentID = "experiment_id"
        case variant
        case assignmentSource = "assignment_source"
        case subjectID = "subject_id"
        case sessionID = "session_id"
        case collectionMode = "collection_mode"
        case metricKey = "metric_key"
    }

    init(
        eventID: UUID,
        occurredAt: Date,
        eventName: ExperimentEventName,
        experimentID: String,
        variant: ExperimentVariant,
        assignmentSource: ExperimentAssignmentSource,
        subjectID: UUID,
        sessionID: UUID,
        metricKey: String?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.eventName = eventName
        self.surface = "macos"
        self.experimentID = experimentID
        self.variant = variant
        self.assignmentSource = assignmentSource
        self.subjectID = subjectID
        self.sessionID = sessionID
        self.collectionMode = "local"
        self.metricKey = metricKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        let dateString = try container.decode(String.self, forKey: .occurredAt)
        guard let date = ISO8601DateFormatter().date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurredAt,
                in: container,
                debugDescription: "Expected an RFC3339 timestamp"
            )
        }
        occurredAt = date
        eventName = try container.decode(ExperimentEventName.self, forKey: .eventName)
        surface = try container.decode(String.self, forKey: .surface)
        experimentID = try container.decode(String.self, forKey: .experimentID)
        variant = try container.decode(ExperimentVariant.self, forKey: .variant)
        assignmentSource = try container.decode(ExperimentAssignmentSource.self, forKey: .assignmentSource)
        subjectID = try container.decode(UUID.self, forKey: .subjectID)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        collectionMode = try container.decode(String.self, forKey: .collectionMode)
        metricKey = try container.decodeIfPresent(String.self, forKey: .metricKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(ISO8601DateFormatter().string(from: occurredAt), forKey: .occurredAt)
        try container.encode(eventName, forKey: .eventName)
        try container.encode(surface, forKey: .surface)
        try container.encode(experimentID, forKey: .experimentID)
        try container.encode(variant, forKey: .variant)
        try container.encode(assignmentSource, forKey: .assignmentSource)
        try container.encode(subjectID, forKey: .subjectID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(collectionMode, forKey: .collectionMode)
        try container.encodeIfPresent(metricKey, forKey: .metricKey)
    }
}

extension Notification.Name {
    static let semperExperiment = Notification.Name("semper.experiment")
}

@MainActor
protocol ExperimentEventSink {
    func emit(_ event: ExperimentEvent)
}

@MainActor
struct NotificationCenterExperimentEventSink: ExperimentEventSink {
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func emit(_ event: ExperimentEvent) {
        notificationCenter.post(name: .semperExperiment, object: event)
    }
}

@MainActor
final class ExperimentManager {
    static let subjectKey = "SemperAB.Subject.macos"
    static let assignmentsKey = "SemperAB.Assignments.macos"
    static let overridePrefix = "SemperABOverride."

    let subjectID: UUID
    let sessionID: UUID

    private let defaults: UserDefaults
    private let sink: any ExperimentEventSink
    private let now: () -> Date
    private let makeEventID: () -> UUID
    private var emittedKeys: Set<String> = []

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, sink: NotificationCenterExperimentEventSink())
    }

    init(
        defaults: UserDefaults,
        sink: any ExperimentEventSink,
        sessionID: UUID = UUID(),
        now: @escaping () -> Date = Date.init,
        makeEventID: @escaping () -> UUID = UUID.init
    ) {
        self.defaults = defaults
        self.sink = sink
        self.sessionID = sessionID
        self.now = now
        self.makeEventID = makeEventID

        if let storedSubject = defaults.string(forKey: Self.subjectKey),
           let subjectID = UUID(uuidString: storedSubject) {
            self.subjectID = subjectID
        } else {
            let subjectID = UUID()
            self.subjectID = subjectID
            defaults.set(subjectID.uuidString.lowercased(), forKey: Self.subjectKey)
        }
    }

    func assignment(for experiment: SemperExperiment) -> ExperimentAssignment {
        let overrideKey = Self.overridePrefix + experiment.rawValue
        if let rawOverride = defaults.string(forKey: overrideKey),
           let variant = ExperimentVariant(rawValue: rawOverride) {
            return ExperimentAssignment(variant: variant, source: .debugOverride)
        }

        var assignments = storedAssignments()
        if let rawVariant = assignments[experiment.rawValue],
           let variant = ExperimentVariant(rawValue: rawVariant) {
            return ExperimentAssignment(variant: variant, source: .bucket)
        }

        let variant = Self.variant(
            experimentID: experiment.rawValue,
            subjectID: subjectID.uuidString.lowercased()
        )
        assignments[experiment.rawValue] = variant.rawValue
        defaults.set(assignments, forKey: Self.assignmentsKey)
        return ExperimentAssignment(variant: variant, source: .bucket)
    }

    @discardableResult
    func recordExposure(for experiment: SemperExperiment) -> Bool {
        emitOnce(eventName: .exposure, metricKey: nil, experiment: experiment)
    }

    @discardableResult
    func recordOutcome(_ metricKey: String, for experiment: SemperExperiment) -> Bool {
        let assignment = assignment(for: experiment)
        guard hasEmitted(
            eventName: .exposure,
            metricKey: nil,
            experiment: experiment,
            assignment: assignment
        ) else {
            return false
        }
        return emitOnce(eventName: .outcome, metricKey: metricKey, experiment: experiment)
    }

    nonisolated static func fnv1a32(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(2_166_136_261)) { hash, byte in
            (hash ^ UInt32(byte)) &* 16_777_619
        }
    }

    nonisolated static func variant(
        experimentID: String,
        subjectID: String
    ) -> ExperimentVariant {
        fnv1a32("\(experimentID):\(subjectID)") % 10_000 < 5_000
            ? .control
            : .treatment
    }

    private func emitOnce(
        eventName: ExperimentEventName,
        metricKey: String?,
        experiment: SemperExperiment
    ) -> Bool {
        let assignment = assignment(for: experiment)
        let key = emittedKey(
            eventName: eventName,
            metricKey: metricKey,
            experiment: experiment,
            assignment: assignment
        )
        guard emittedKeys.insert(key).inserted else {
            return false
        }

        sink.emit(
            ExperimentEvent(
                eventID: makeEventID(),
                occurredAt: now(),
                eventName: eventName,
                experimentID: experiment.rawValue,
                variant: assignment.variant,
                assignmentSource: assignment.source,
                subjectID: subjectID,
                sessionID: sessionID,
                metricKey: metricKey
            )
        )
        return true
    }

    private func hasEmitted(
        eventName: ExperimentEventName,
        metricKey: String?,
        experiment: SemperExperiment,
        assignment: ExperimentAssignment
    ) -> Bool {
        emittedKeys.contains(
            emittedKey(
                eventName: eventName,
                metricKey: metricKey,
                experiment: experiment,
                assignment: assignment
            )
        )
    }

    private func emittedKey(
        eventName: ExperimentEventName,
        metricKey: String?,
        experiment: SemperExperiment,
        assignment: ExperimentAssignment
    ) -> String {
        [
            experiment.rawValue,
            assignment.source.rawValue,
            assignment.variant.rawValue,
            eventName.rawValue,
            metricKey ?? ""
        ].joined(separator: ":")
    }

    private func storedAssignments() -> [String: String] {
        defaults.dictionary(forKey: Self.assignmentsKey) as? [String: String] ?? [:]
    }
}
