import Foundation
import Testing
@testable import Semper

@MainActor
private final class RecordingExperimentSink: ExperimentEventSink {
    private(set) var events: [ExperimentEvent] = []

    func emit(_ event: ExperimentEvent) {
        events.append(event)
    }
}

@MainActor
private func experimentDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "SemperTests.Experiments.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

@Suite("ExperimentManager")
@MainActor
struct ExperimentManagerTests {
    private let treatmentSubject = "00000000-0000-4000-8000-000000000000"
    private let controlSubject = "22222222-2222-4222-8222-222222222222"

    @Test("FNV-1a fixtures match the website implementation")
    func hashFixtures() {
        #expect(
            ExperimentManager.fnv1a32(
                "website.hero-repository-cta-copy.v1:" +
                    "00000000-0000-4000-8000-000000000000"
            ) == 1_404_061_537
        )
        #expect(
            ExperimentManager.fnv1a32(
                "macos.popup-empty-state-guidance.v1:1"
            ) == 1_564_713_247
        )
    }

    @Test("Fixed subjects reach both variants")
    func fixedAssignments() {
        #expect(
            ExperimentManager.variant(
                experimentID: SemperExperiment.popupEmptyStateGuidance.rawValue,
                subjectID: treatmentSubject
            ) == .treatment
        )
        #expect(
            ExperimentManager.variant(
                experimentID: SemperExperiment.popupEmptyStateGuidance.rawValue,
                subjectID: controlSubject
            ) == .control
        )
    }

    @Test("A saved assignment stays fixed when the subject changes")
    func stickyAssignment() {
        let storage = experimentDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        storage.defaults.set(treatmentSubject, forKey: ExperimentManager.subjectKey)

        let firstManager = ExperimentManager(
            defaults: storage.defaults,
            sink: RecordingExperimentSink()
        )
        #expect(
            firstManager.assignment(for: .popupEmptyStateGuidance).variant
                == .treatment
        )

        storage.defaults.set(controlSubject, forKey: ExperimentManager.subjectKey)
        let secondManager = ExperimentManager(
            defaults: storage.defaults,
            sink: RecordingExperimentSink()
        )
        let secondAssignment = secondManager.assignment(
            for: .popupEmptyStateGuidance
        )

        #expect(secondAssignment.variant == .treatment)
        #expect(secondAssignment.source == .bucket)
    }

    @Test("A debug override does not replace the saved assignment")
    func debugOverride() {
        let storage = experimentDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        storage.defaults.set(treatmentSubject, forKey: ExperimentManager.subjectKey)
        let overrideKey =
            ExperimentManager.overridePrefix +
            SemperExperiment.popupEmptyStateGuidance.rawValue
        storage.defaults.set("control", forKey: overrideKey)

        let manager = ExperimentManager(
            defaults: storage.defaults,
            sink: RecordingExperimentSink()
        )
        let forcedAssignment = manager.assignment(
            for: .popupEmptyStateGuidance
        )

        #expect(forcedAssignment.variant == .control)
        #expect(forcedAssignment.source == .debugOverride)
        #expect(
            storage.defaults.dictionary(forKey: ExperimentManager.assignmentsKey)
                == nil
        )

        storage.defaults.removeObject(forKey: overrideKey)
        let bucketedAssignment = manager.assignment(
            for: .popupEmptyStateGuidance
        )
        #expect(bucketedAssignment.variant == .treatment)
        #expect(bucketedAssignment.source == .bucket)
    }

    @Test("Exposure and each declared outcome emit once per session")
    func eventOrderAndDeduplication() throws {
        let storage = experimentDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        storage.defaults.set(controlSubject, forKey: ExperimentManager.subjectKey)
        let sink = RecordingExperimentSink()
        let sessionID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let eventID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let eventDate = Date(timeIntervalSince1970: 1_775_203_200)
        let manager = ExperimentManager(
            defaults: storage.defaults,
            sink: sink,
            sessionID: sessionID,
            now: { eventDate },
            makeEventID: { eventID }
        )

        #expect(
            manager.recordOutcome(
                "first_app_volume_changed",
                for: .popupEmptyStateGuidance
            ) == false
        )
        #expect(manager.recordExposure(for: .popupEmptyStateGuidance))
        #expect(!manager.recordExposure(for: .popupEmptyStateGuidance))
        #expect(
            manager.recordOutcome(
                "first_audio_app_detected",
                for: .popupEmptyStateGuidance
            )
        )
        #expect(
            !manager.recordOutcome(
                "first_audio_app_detected",
                for: .popupEmptyStateGuidance
            )
        )
        #expect(
            manager.recordOutcome(
                "first_app_volume_changed",
                for: .popupEmptyStateGuidance
            )
        )

        #expect(
            sink.events.map(\.eventName) == [.exposure, .outcome, .outcome]
        )
        #expect(
            sink.events.map(\.metricKey) == [
                nil,
                "first_audio_app_detected",
                "first_app_volume_changed"
            ]
        )

        let encoded = try JSONEncoder().encode(sink.events[0])
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["surface"] as? String == "macos")
        #expect(object["collection_mode"] as? String == "local")
        #expect(object["subject_id"] as? String == controlSubject)
        #expect(object["session_id"] as? String == sessionID.uuidString)
        #expect(object["occurred_at"] is String)
        #expect(object["app_name"] == nil)
        #expect(object["device_id"] == nil)
        #expect(object["volume"] == nil)
    }
}
