import Foundation
import Testing
@testable import Semper

@Suite("Scene document stores")
struct SceneStoreTests {
    @Test("Fixed version one documents remain readable")
    func fixedVersionOneFixtures() throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = Bundle(for: SceneStoreTestBundleMarker.self)
        let libraryFixture = try #require(bundle.url(
            forResource: "scene-library-v1",
            withExtension: "json"
        ))
        let journalFixture = try #require(bundle.url(
            forResource: "scene-journal-v1",
            withExtension: "json"
        ))
        try FileManager.default.copyItem(
            at: libraryFixture,
            to: directory.appendingPathComponent("scenes.json")
        )
        try FileManager.default.copyItem(
            at: journalFixture,
            to: directory.appendingPathComponent("scene-journal.json")
        )

        let scenes = try FileSceneLibraryStore(directory: directory).loadScenes()
        let transaction = try FileSceneJournalStore(directory: directory).load()

        #expect(scenes.count == 1)
        #expect(scenes.first?.name == "Fixture Desk")
        #expect(scenes.first?.actions.first?.target == .awake(.system))
        #expect(transaction?.sceneName == "Fixture Recovery")
        #expect(transaction?.entries.first?.snapshotValue == .number(0.2))
        #expect(transaction?.originSessionID == nil)
    }

    @Test("An older document is migrated one version at a time")
    func migratesOlderDocument() throws {
        let versioning = SceneDocumentVersioning(currentVersion: 2, migrations: [
            0: { data in
                let text = String(decoding: data, as: UTF8.self)
                return Data(text.replacingOccurrences(of: "\"version\":0", with: "\"version\":1").utf8)
            },
            1: { data in
                let text = String(decoding: data, as: UTF8.self)
                return Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)
            },
        ])

        let normalized = try versioning.normalizedData(from: Data(#"{"version":0,"payload":"kept"}"#.utf8))
        #expect(try SceneDocumentVersioning.probeVersion(in: normalized) == 2)
        #expect(String(decoding: normalized, as: UTF8.self).contains(#""payload":"kept""#))
    }

    @Test("A newer document version is rejected")
    func rejectsUnsupportedNewerVersion() {
        let versioning = SceneDocumentVersioning(currentVersion: 1)
        #expect(throws: SceneDocumentError.unsupportedVersion(found: 2, current: 1)) {
            _ = try versioning.normalizedData(from: Data(#"{"version":2}"#.utf8))
        }
    }

    @Test("A missing migration step is rejected")
    func rejectsMigrationGap() {
        let versioning = SceneDocumentVersioning(currentVersion: 2)
        #expect(throws: SceneDocumentError.migrationGap(fromVersion: 0)) {
            _ = try versioning.normalizedData(from: Data(#"{"version":0}"#.utf8))
        }
    }

    @Test("A migration must increment the document by exactly one version")
    func rejectsWrongMigrationOutputVersion() {
        let versioning = SceneDocumentVersioning(currentVersion: 2, migrations: [
            0: { _ in Data(#"{"version":2}"#.utf8) },
        ])
        #expect(throws: SceneDocumentError.migrationProducedWrongVersion(expected: 1, found: 2)) {
            _ = try versioning.normalizedData(from: Data(#"{"version":0}"#.utf8))
        }
    }

    @Test("The scene library persists a full scene round trip")
    func libraryRoundTrip() throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSceneLibraryStore(directory: directory)
        let scene = SemperScene(
            id: UUID(uuidString: "7E537460-65C7-44EF-B8F1-C80EC090EFD7")!,
            name: "Studio",
            actions: [
                SceneAction(control: .awakeMode, target: .awake(.displayAndSystem), importance: .required),
                SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
                SceneAction(control: .audioOutputMuted(deviceID: "output.usb"), target: .boolean(false), importance: .optional),
                SceneAction(control: .displayBrightness(displayID: "display-a"), target: .number(0.72), importance: .optional),
                SceneAction(control: .displayContrast(displayID: "display-a"), target: .number(0.61), importance: .optional),
            ],
            shortcut: SceneShortcut(keyCode: 18, modifiers: 768)
        )

        #expect(try store.loadScenes().isEmpty)
        try store.saveScenes([scene])
        #expect(try store.loadScenes() == [scene])
    }

    @Test("A failed encode does not replace the existing scene library")
    func failedLibraryEncodePreservesExistingDocument() throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSceneLibraryStore(directory: directory)
        let original = SemperScene(name: "Original", actions: [
            SceneAction(control: .audioOutputVolume(deviceID: "output.usb"), target: .number(0.4), importance: .required),
        ])
        try store.saveScenes([original])

        let unencodable = SemperScene(name: "Invalid number", actions: [
            SceneAction(control: .audioOutputVolume(deviceID: "output.usb"), target: .number(.nan), importance: .required),
        ])
        #expect(throws: SceneDocumentError.self) {
            try store.saveScenes([unencodable])
        }
        #expect(try store.loadScenes() == [original])
    }

    @Test("The scene library rejects duplicate identifiers")
    func libraryRejectsDuplicateIdentifiers() throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSceneLibraryStore(directory: directory)
        let id = UUID()
        let first = SemperScene(
            id: id,
            name: "First",
            actions: [
                SceneAction(
                    control: .awakeMode,
                    target: .awake(.system),
                    importance: .required
                ),
            ]
        )
        let second = SemperScene(
            id: id,
            name: "Second",
            actions: [
                SceneAction(
                    control: .awakeMode,
                    target: .awake(.displayAndSystem),
                    importance: .required
                ),
            ]
        )

        #expect(throws: SceneDocumentError.duplicateSceneID(id)) {
            try store.saveScenes([first, second])
        }
    }

    @Test("The journal rejects unsafe values before persistence")
    func journalRejectsUnsafeValues() throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSceneJournalStore(directory: directory)
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        let transaction = SceneTransaction(
            sceneID: UUID(),
            sceneName: "Damaged",
            startedAt: SceneTestSupport.fixedDate,
            entries: [
                SceneTransactionEntry(
                    control: volume,
                    importance: .required,
                    snapshotValue: .number(1.5),
                    targetValue: .number(0.8),
                    appliedValue: .number(0.8),
                    phase: .applied
                ),
            ]
        )

        #expect(throws: SceneDocumentError.invalidTransaction(
            .numberOutOfRange(control: volume, role: .snapshot, value: 1.5)
        )) {
            try store.save(transaction)
        }
    }

    @Test("The journal persists every transaction entry phase")
    func journalRoundTrip() throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSceneJournalStore(directory: directory)
        let phases: [SceneEntryPhase] = [
            .pending,
            .inFlight,
            .applied,
            .rolledBack,
            .restored,
            .skippedDrift,
            .skippedUnavailable,
        ]
        let transaction = SceneTransaction(
            id: UUID(uuidString: "0ED27CB1-9E6B-4E77-A2E3-EBD58BDDC05F")!,
            sceneID: UUID(uuidString: "72FB9C62-2912-46D5-83C6-87D6B2258534")!,
            sceneName: "Persisted",
            startedAt: SceneTestSupport.fixedDate,
            entries: phases.enumerated().map { index, phase in
                SceneTransactionEntry(
                    control: .displayBrightness(displayID: "display-\(index)"),
                    importance: index.isMultiple(of: 2) ? .required : .optional,
                    snapshotValue: .number(0.2),
                    targetValue: .number(0.8),
                    appliedValue: phase == .applied ? .number(0.79) : nil,
                    phase: phase
                )
            }
        )

        #expect(try store.load() == nil)
        try store.save(transaction)
        #expect(try store.load() == transaction)
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()
    }

    @Test("Library and journal stores reject documents from a newer build")
    func storesRejectUnsupportedVersion() throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"version":2,"scenes":[]}"#.utf8)
            .write(to: directory.appendingPathComponent("scenes.json"), options: .atomic)
        try Data(#"{"version":2,"transaction":{}}"#.utf8)
            .write(to: directory.appendingPathComponent("scene-journal.json"), options: .atomic)

        #expect(throws: SceneDocumentError.unsupportedVersion(found: 2, current: 1)) {
            _ = try FileSceneLibraryStore(directory: directory).loadScenes()
        }
        #expect(throws: SceneDocumentError.unsupportedVersion(found: 2, current: 1)) {
            _ = try FileSceneJournalStore(directory: directory).load()
        }
    }
}

private final class SceneStoreTestBundleMarker {}
