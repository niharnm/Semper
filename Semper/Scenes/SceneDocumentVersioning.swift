// Semper/Scenes/SceneDocumentVersioning.swift
import Foundation

/// Failures raised while validating or migrating a persisted scene document.
nonisolated enum SceneDocumentError: Error, Equatable {
    case missingVersion
    case corruptDocument(String)
    case unsupportedVersion(found: Int, current: Int)
    case migrationGap(fromVersion: Int)
    case migrationProducedWrongVersion(expected: Int, found: Int)
    case duplicateSceneID(UUID)
    case invalidScene(id: UUID, issue: SceneValidationIssue)
    case invalidTransaction(SceneTransactionValidationIssue)
}

extension SceneDocumentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingVersion:
            "The scene file has no format version."
        case .corruptDocument(let reason):
            "The scene file is damaged: \(reason)"
        case .unsupportedVersion:
            "The scene file was created by a newer Semper version."
        case .migrationGap:
            "This Semper version cannot update the scene file."
        case .migrationProducedWrongVersion:
            "The scene file update produced an invalid version."
        case .duplicateSceneID:
            "The scene file contains a duplicate scene identifier."
        case .invalidScene(_, let issue):
            "A saved scene is invalid: \(issue.localizedDescription)"
        case .invalidTransaction(let issue):
            "The restore point is invalid: \(issue.localizedDescription)"
        }
    }
}

/// Rewrites a persisted JSON document from one schema version to the next.
/// The output must carry the incremented top-level `version` field.
typealias SceneDocumentMigration = @Sendable (Data) throws -> Data

/// Version gate shared by the scene library and the transaction journal.
///
/// Every persisted document is an envelope with a top-level integer
/// `version`. Loading probes that field first, walks registered migrations
/// one version at a time up to `currentVersion`, and rejects documents that
/// are newer than this build or older than the earliest registered migration.
nonisolated struct SceneDocumentVersioning: Sendable {
    let currentVersion: Int
    let migrations: [Int: SceneDocumentMigration]

    init(currentVersion: Int, migrations: [Int: SceneDocumentMigration] = [:]) {
        self.currentVersion = currentVersion
        self.migrations = migrations
    }

    /// Returns document data at `currentVersion`, migrating step by step if
    /// needed, or throws a `SceneDocumentError` describing why the document
    /// cannot be used.
    func normalizedData(from data: Data) throws -> Data {
        var data = data
        var version = try Self.probeVersion(in: data)
        guard version <= currentVersion else {
            throw SceneDocumentError.unsupportedVersion(found: version, current: currentVersion)
        }
        while version < currentVersion {
            guard let migration = migrations[version] else {
                throw SceneDocumentError.migrationGap(fromVersion: version)
            }
            data = try migration(data)
            let migrated = try Self.probeVersion(in: data)
            guard migrated == version + 1 else {
                throw SceneDocumentError.migrationProducedWrongVersion(expected: version + 1, found: migrated)
            }
            version = migrated
        }
        return data
    }

    static func probeVersion(in data: Data) throws -> Int {
        do {
            return try JSONDecoder().decode(SceneVersionProbe.self, from: data).version
        } catch let error as DecodingError {
            switch error {
            case .keyNotFound, .valueNotFound:
                throw SceneDocumentError.missingVersion
            default:
                throw SceneDocumentError.corruptDocument(String(describing: error))
            }
        } catch {
            throw SceneDocumentError.corruptDocument(String(describing: error))
        }
    }
}

private nonisolated struct SceneVersionProbe: Decodable {
    let version: Int
}
