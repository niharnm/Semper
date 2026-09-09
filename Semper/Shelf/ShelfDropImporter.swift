import Foundation
import UniformTypeIdentifiers

nonisolated enum ShelfImportedPayload: Sendable {
    case file(URL)
    case text(String)
    case link(URL)
    case cachedFile(String)
}

@MainActor
enum ShelfDropImporter {
    static let types = [
        UTType.fileURL.identifier, UTType.url.identifier, UTType.image.identifier, UTType.plainText.identifier,
    ]

    static func load(_ provider: NSItemProvider, store: ShelfStore) async throws -> ShelfImportedPayload {
        let type: String
        let kind: ShelfRepresentationKind
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            type = UTType.fileURL.identifier
            kind = .fileURL
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            type = UTType.url.identifier
            kind = .link
        } else if let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            type = imageType
            kind = .image(UTType(imageType)?.preferredFilenameExtension ?? "image")
        } else if let textType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .plainText) == true
        }) {
            type = textType
            kind = .text
        } else {
            throw ShelfFailure.unsupported
        }
        let request = ShelfProviderRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard request.beginProcessing() else { return }
                    let result: Result<ShelfImportedPayload, Error>
                    if let url, error == nil {
                        result = Result {
                            try readRepresentation(url, kind: kind, store: store, cancelled: { request.isCancelled })
                        }
                    } else {
                        result = .failure(ShelfFailure.unsupported)
                    }
                    request.finish(result, store: store)
                }
                request.install(progress)
            }
        } onCancel: {
            request.cancel()
        }
    }

    nonisolated static func readRepresentation(
        _ url: URL, kind: ShelfRepresentationKind,
        store: ShelfStore, cancelled: () -> Bool
    ) throws -> ShelfImportedPayload {
        switch kind {
        case .fileURL, .link:
            let data = try ShelfIO.readBounded(url, limit: ShelfLimits.urlBytes, cancelled: cancelled)
            guard let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                let value = URL(string: string)
            else { throw ShelfFailure.unsupported }
            if case .fileURL = kind {
                guard value.isFileURL else { throw ShelfFailure.unsupported }
                return .file(value)
            }
            guard ShelfStore.isAllowedLink(value) else { throw ShelfFailure.unsupported }
            return .link(value)
        case .text:
            let data = try ShelfIO.readBounded(url, limit: ShelfLimits.textBytes, cancelled: cancelled)
            guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
                !string.isEmpty, string.utf8.count <= ShelfLimits.textBytes
            else { throw ShelfFailure.unsupported }
            return .text(string)
        case .image(let suppliedExtension):
            let ext =
                ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"].contains(suppliedExtension)
                ? suppliedExtension : "image"
            let name = "shelf-item-\(UUID().uuidString).\(ext)"
            try store.prepareCache()
            let destination = try store.cacheURL(named: name)
            do {
                _ = try ShelfIO.copyBounded(
                    from: url, to: destination, limit: ShelfLimits.importBytes, cancelled: cancelled)
                if cancelled() { throw ShelfFailure.cancelled }
                try ShelfIO.validateImage(at: destination)
                return .cachedFile(name)
            } catch {
                try store.removeCachedFile(named: name)
                throw error
            }
        }
    }
}

nonisolated enum ShelfRepresentationKind: Sendable {
    case fileURL, link, text
    case image(String)
}

// NSItemProvider callbacks can race cancellation. The lock protects all request state.
nonisolated final class ShelfProviderRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShelfImportedPayload, Error>?
    private var progress: Progress?
    private var cancelled = false
    private var processing = false
    private var finished = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func install(_ continuation: CheckedContinuation<ShelfImportedPayload, Error>) -> Bool {
        let accepted = lock.withLock {
            if cancelled || finished { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(throwing: ShelfFailure.cancelled) }
        return accepted
    }

    func install(_ progress: Progress) {
        let shouldCancel = lock.withLock {
            self.progress = progress
            return cancelled
        }
        if shouldCancel { progress.cancel() }
    }

    func beginProcessing() -> Bool {
        lock.withLock {
            guard !cancelled, !finished, !processing else { return false }
            processing = true
            return true
        }
    }

    func cancel() {
        let state = lock.withLock { () -> (Progress?, CheckedContinuation<ShelfImportedPayload, Error>?) in
            cancelled = true
            guard !processing, !finished else { return (progress, nil) }
            finished = true
            let pending = continuation
            continuation = nil
            return (progress, pending)
        }
        state.0?.cancel()
        state.1?.resume(throwing: ShelfFailure.cancelled)
    }

    func finish(_ result: Result<ShelfImportedPayload, Error>, store: ShelfStore) {
        let state = lock.withLock { () -> (Bool, CheckedContinuation<ShelfImportedPayload, Error>?) in
            processing = false
            finished = true
            let pending = continuation
            continuation = nil
            return (cancelled, pending)
        }
        if state.0 {
            if case .success(.cachedFile(let name)) = result {
                do { try store.removeCachedFile(named: name) } catch {
                    state.1?.resume(throwing: ShelfFailure.storeWrite)
                    return
                }
            }
            state.1?.resume(throwing: ShelfFailure.cancelled)
        } else {
            state.1?.resume(with: result)
        }
    }
}
