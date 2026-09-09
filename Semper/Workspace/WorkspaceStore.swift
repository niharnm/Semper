import CoreGraphics
import Foundation

actor WorkspaceStore {
    private struct Document: Codable {
        let version: Int
        let arrangements: [WorkspaceArrangement]
    }
    let url: URL
    private let maximumBytes = 1_048_576

    init(url: URL) { self.url = url }

    func load() throws -> [WorkspaceArrangement] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= maximumBytes else { throw WorkspaceError.storeTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        try handle.close()
        guard data.count <= maximumBytes else { throw WorkspaceError.storeTooLarge }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw WorkspaceError.unsupportedVersion }
        try validate(document.arrangements)
        return document.arrangements
    }

    func save(_ arrangements: [WorkspaceArrangement]) throws {
        try validate(arrangements)
        let data = try JSONEncoder().encode(Document(version: 1, arrangements: arrangements))
        guard data.count <= maximumBytes else { throw WorkspaceError.storeTooLarge }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: [.atomic])
    }

    private struct TopologyPreference: Codable {
        let version: Int
        let enabled: Bool
    }

    nonisolated var topologyPreferenceURL: URL {
        url.deletingLastPathComponent().appending(path: "topology-prompts-v1.json")
    }

    func loadTopologyPromptsEnabled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: topologyPreferenceURL.path) else { return false }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: topologyPreferenceURL)
            let read = Result { try handle.read(upToCount: 4_097) ?? Data() }
            try handle.close()
            data = try read.get()
        } catch { throw WorkspaceError.topologyPreferenceIO }
        guard data.count <= 4_096 else { throw WorkspaceError.invalidTopologyPreference }
        struct Version: Decodable { let version: Int }
        let version: Version
        do { version = try JSONDecoder().decode(Version.self, from: data) } catch {
            throw WorkspaceError.invalidTopologyPreference
        }
        guard version.version == 1 else { throw WorkspaceError.unsupportedTopologyPreferenceVersion }
        do { return try JSONDecoder().decode(TopologyPreference.self, from: data).enabled } catch {
            throw WorkspaceError.invalidTopologyPreference
        }
    }

    func saveTopologyPromptsEnabled(_ enabled: Bool) throws {
        _ = try loadTopologyPromptsEnabled()
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(TopologyPreference(version: 1, enabled: enabled))
            try data.write(to: topologyPreferenceURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: topologyPreferenceURL.path)
        } catch { throw WorkspaceError.topologyPreferenceIO }
    }

    func resetTopologyPreference() throws {
        guard FileManager.default.fileExists(atPath: topologyPreferenceURL.path) else { return }
        do { try FileManager.default.removeItem(at: topologyPreferenceURL) } catch {
            throw WorkspaceError.topologyPreferenceIO
        }
    }

    private func validate(_ arrangements: [WorkspaceArrangement]) throws {
        guard arrangements.count <= 30, Set(arrangements.map(\.id)).count == arrangements.count else {
            throw WorkspaceError.invalidStore
        }
        for arrangement in arrangements {
            guard !arrangement.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                arrangement.name.count <= 80, arrangement.windows.count <= 200,
                Set(arrangement.windows.map(\.id)).count == arrangement.windows.count,
                arrangement.windows.allSatisfy({
                    WorkspaceGeometry.valid($0.relativeFrame) && abs($0.relativeFrame.minX) < 100
                        && abs($0.relativeFrame.minY) < 100 && $0.relativeFrame.width <= 10
                        && $0.relativeFrame.height <= 10 && $0.label.count <= 300
                        && !$0.applicationBundleID.isEmpty && !$0.displayID.isEmpty
                })
            else { throw WorkspaceError.invalidStore }
        }
    }
}
