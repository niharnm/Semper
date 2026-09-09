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
