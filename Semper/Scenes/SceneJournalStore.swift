// Semper/Scenes/SceneJournalStore.swift
import Foundation

/// Versioned envelope persisted by `FileSceneJournalStore`.
nonisolated struct SceneJournalDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var transaction: SceneTransaction
}

nonisolated protocol SceneJournalStoring: Sendable {
    /// Returns the pending transaction, or nil when no journal exists.
    func load() throws -> SceneTransaction?
    func save(_ transaction: SceneTransaction) throws
    func clear() throws
}

/// Atomic JSON persistence for the scene transaction journal.
///
/// The journal is written before every mutation it describes and rewritten
/// after each phase change, always with `Data.write(options: .atomic)`, so
/// the on-disk record is a consistent recovery point at any crash instant.
nonisolated final class FileSceneJournalStore: SceneJournalStoring, Sendable {
    private let fileURL: URL
    private let versioning: SceneDocumentVersioning

    init(
        directory: URL,
        fileName: String = "scene-journal.json",
        migrations: [Int: SceneDocumentMigration] = [:]
    ) {
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        self.versioning = SceneDocumentVersioning(
            currentVersion: SceneJournalDocument.currentVersion,
            migrations: migrations
        )
    }

    func load() throws -> SceneTransaction? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let raw = try Data(contentsOf: fileURL)
        let normalized = try versioning.normalizedData(from: raw)
        let transaction = try SceneJSONCoding.decoder()
            .decode(SceneJournalDocument.self, from: normalized)
            .transaction
        do {
            try transaction.validate()
        } catch {
            throw SceneDocumentError.invalidTransaction(error)
        }
        return transaction
    }

    func save(_ transaction: SceneTransaction) throws {
        do {
            try transaction.validate()
        } catch {
            throw SceneDocumentError.invalidTransaction(error)
        }
        let document = SceneJournalDocument(version: SceneJournalDocument.currentVersion, transaction: transaction)
        let data = try SceneJSONCoding.encoder().encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
