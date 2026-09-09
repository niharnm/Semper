import CryptoKit
import Darwin
import Foundation
import ImageIO

nonisolated protocol ShelfFileAccess: Sendable {
    func begin(_ url: URL) -> Bool
    func end(_ url: URL)
    func state(of url: URL) -> ShelfFileState
    func bookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> URL
}

nonisolated struct NativeShelfFileAccess: ShelfFileAccess {
    func begin(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func end(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    func state(of url: URL) -> ShelfFileState {
        do {
            var currentURL = url
            currentURL.removeAllCachedResourceValues()
            let values = try currentURL.resourceValues(forKeys: [
                .isDirectoryKey, .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey, .isReadableKey,
            ])
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                return .cloudOnly
            }
            if values.isReadable == false { return .inaccessible }
            return .available(isDirectory: values.isDirectory == true)
        } catch {
            let code = (error as NSError).code
            return code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError ? .missing : .inaccessible
        }
    }
    func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        return try URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

nonisolated enum ShelfIO {
    static func readBounded(_ url: URL, limit: Int, cancelled: () -> Bool = { false }) throws -> Data {
        let file = try regularFileHandle(url)
        defer { try? file.close() }
        var result = Data()
        while true {
            if cancelled() { throw ShelfFailure.cancelled }
            let data = try file.read(upToCount: min(ShelfLimits.chunkBytes, limit - result.count + 1)) ?? Data()
            if data.isEmpty { return result }
            guard data.count <= limit - result.count else { throw ShelfFailure.tooLarge }
            result.append(data)
        }
    }

    static func copyBounded(
        from source: URL, to destination: URL, limit: Int,
        cancelled: () -> Bool = { false }
    ) throws -> Int {
        let input = try regularFileHandle(source)
        defer { try? input.close() }
        guard
            FileManager.default.createFile(
                atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw ShelfFailure.storeWrite
        }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count = 0
        while true {
            if cancelled() { throw ShelfFailure.cancelled }
            let data = try input.read(upToCount: min(ShelfLimits.chunkBytes, limit - count + 1)) ?? Data()
            if data.isEmpty { break }
            guard data.count <= limit - count else { throw ShelfFailure.tooLarge }
            try output.write(contentsOf: data)
            count += data.count
        }
        complete = true
        return count
    }

    static func checksum(
        _ url: URL, access: any ShelfFileAccess,
        cancelled: () -> Bool = { Task.isCancelled }
    ) throws -> String {
        let scoped = access.begin(url)
        defer { if scoped { access.end(url) } }
        switch access.state(of: url) {
        case .available(isDirectory: false): break
        case .available: throw ShelfFailure.unsupported
        case .missing: throw ShelfFailure.missing
        case .cloudOnly: throw ShelfFailure.cloudOnly
        case .inaccessible: throw ShelfFailure.inaccessible
        }
        let input = try regularFileHandle(url)
        defer { try? input.close() }
        var before = stat()
        guard fstat(input.fileDescriptor, &before) == 0 else { throw ShelfFailure.inaccessible }
        var digest = SHA256()
        var readCount = 0
        while true {
            if cancelled() { throw ShelfFailure.cancelled }
            let data = try input.read(upToCount: ShelfLimits.chunkBytes) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
            readCount += data.count
        }
        var after = stat()
        var current = stat()
        let statResult = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &current)
        }
        guard fstat(input.fileDescriptor, &after) == 0, statResult == 0,
            before.st_dev == current.st_dev, before.st_ino == current.st_ino,
            before.st_size == after.st_size, before.st_size == readCount,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw ShelfFailure.changedDuringRead
        }
        if cancelled() { throw ShelfFailure.cancelled }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func regularFileHandle(_ url: URL) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ShelfFailure.inaccessible }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw ShelfFailure.unsupported
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func validateImage(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw ShelfFailure.invalidImage
        }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0, frames <= 100 else { throw ShelfFailure.invalidImage }
        var remaining = ShelfLimits.imagePixels
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= remaining / height
            else {
                throw ShelfFailure.invalidImage
            }
            remaining -= width * height
        }
    }
}
