// Semper/Scenes/SceneLibraryStore.swift
import Foundation

/// Default on-disk home for scene documents, kept separate from settings so
/// scene files can be versioned and recovered independently.
nonisolated enum SceneStorageLocation {
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Semper", isDirectory: true)
            .appendingPathComponent("Scenes", isDirectory: true)
    }
}

/// Versioned envelope persisted by `FileSceneLibraryStore`.
nonisolated struct SceneLibraryDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var scenes: [SemperScene]
}

nonisolated protocol SceneLibraryStoring: Sendable {
    func loadScenes() throws -> [SemperScene]
    func saveScenes(_ scenes: [SemperScene]) throws
}

nonisolated enum SceneLibraryValidation {
    static func validate(_ scenes: [SemperScene]) throws {
        var sceneIDs = Set<UUID>()
        for scene in scenes {
            guard sceneIDs.insert(scene.id).inserted else {
                throw SceneDocumentError.duplicateSceneID(scene.id)
            }
            do {
                try scene.validate()
            } catch {
                throw SceneDocumentError.invalidScene(id: scene.id, issue: error)
            }
        }
    }
}

/// Atomic JSON persistence for the user's scene library.
///
/// Saves replace the whole document with `Data.write(options: .atomic)` so a
/// crash mid-save can never leave a half-written library on disk. The store
nonisolated final class FileSceneLibraryStore: SceneLibraryStoring, Sendable {
    private let fileURL: URL
    private let versioning: SceneDocumentVersioning

    init(
        directory: URL,
        fileName: String = "scenes.json",
        migrations: [Int: SceneDocumentMigration] = [:]
    ) {
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        self.versioning = SceneDocumentVersioning(
            currentVersion: SceneLibraryDocument.currentVersion,
            migrations: migrations
        )
    }

    func loadScenes() throws -> [SemperScene] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let raw = try Data(contentsOf: fileURL)
        let normalized = try versioning.normalizedData(from: raw)
        let scenes = try SceneJSONCoding.decoder()
            .decode(SceneLibraryDocument.self, from: normalized)
            .scenes
        try SceneLibraryValidation.validate(scenes)
        return scenes
    }

    func saveScenes(_ scenes: [SemperScene]) throws {
        try SceneLibraryValidation.validate(scenes)
        let document = SceneLibraryDocument(version: SceneLibraryDocument.currentVersion, scenes: scenes)
        let data = try SceneJSONCoding.encoder().encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Shared JSON configuration so scene documents stay byte-stable and diffable.
nonisolated enum SceneJSONCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
