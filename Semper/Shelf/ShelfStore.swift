import Foundation

nonisolated struct ShelfSnapshot: Codable, Sendable {
    let version: Int
    let persistenceEnabled: Bool
    let defaultExpiry: ShelfExpiry
    let items: [ShelfItem]
}

nonisolated struct ShelfStore: Sendable {
    let root: URL
    var manifest: URL { root.appendingPathComponent("shelf-v1.json") }
    var cache: URL { root.appendingPathComponent("items", isDirectory: true) }

    static var standard: ShelfStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ShelfStore(root: support.appendingPathComponent("Semper/Shelf/v1", isDirectory: true))
    }

    func prepareCache() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
    }

    func cacheURL(named name: String) throws -> URL {
        guard name.hasPrefix("shelf-item-"), !name.contains("/"), !name.contains("\\"),
            let separator = name.lastIndex(of: "."),
            UUID(uuidString: String(name[name.index(name.startIndex, offsetBy: 11)..<separator])) != nil,
            ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "image", "txt"].contains(
                String(name[name.index(after: separator)...]))
        else {
            throw ShelfFailure.invalidStore
        }
        let url = cache.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == cache.resolvingSymlinksInPath().path
        else {
            throw ShelfFailure.invalidStore
        }
        return url
    }

    func load() throws -> ShelfSnapshot? {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        let data = try ShelfIO.readBounded(manifest, limit: ShelfLimits.storeBytes)
        let snapshot: ShelfSnapshot
        do { snapshot = try JSONDecoder().decode(ShelfSnapshot.self, from: data) } catch {
            throw ShelfFailure.invalidStore
        }
        guard snapshot.version == 1 else { throw ShelfFailure.storeVersion }
        guard snapshot.persistenceEnabled, snapshot.items.count <= ShelfLimits.items,
            Set(snapshot.items.map(\.id)).count == snapshot.items.count
        else { throw ShelfFailure.invalidStore }
        for item in snapshot.items {
            guard item.name.utf8.count <= 960, item.createdAt.timeIntervalSinceReferenceDate.isFinite,
                item.expiresAt?.timeIntervalSinceReferenceDate.isFinite != false
            else { throw ShelfFailure.invalidStore }
            switch item.payload {
            case .cachedFile(let name): _ = try cacheURL(named: name)
            case .text(let text):
                guard text.utf8.count <= ShelfLimits.textBytes else { throw ShelfFailure.invalidStore }
            case .link(let url): guard Self.isAllowedLink(url) else { throw ShelfFailure.invalidStore }
            case .file(let url, let bookmark):
                guard url.isFileURL, let bookmark, !bookmark.isEmpty, bookmark.count <= ShelfLimits.textBytes else {
                    throw ShelfFailure.invalidStore
                }
            }
        }
        return snapshot
    }

    func save(items: [ShelfItem], expiry: ShelfExpiry) throws {
        let snapshot = ShelfSnapshot(version: 1, persistenceEnabled: true, defaultExpiry: expiry, items: items)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= ShelfLimits.storeBytes else { throw ShelfFailure.tooLarge }
        try prepareCache()
        try data.write(to: manifest, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }

    func removeManifest() throws {
        if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
    }

    func removeCachedFile(named name: String) throws {
        let url = try cacheURL(named: name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func isAllowedLink(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
            && url.absoluteString.utf8.count <= ShelfLimits.urlBytes
    }
}
