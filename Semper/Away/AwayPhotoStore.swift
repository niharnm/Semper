import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AwayManagedPhoto: Equatable, Sendable {
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
}

enum AwayPhotoStoreError: Error, Equatable, Sendable {
    case sourceNotRegularFile
    case emptyFile
    case fileTooLarge(maximumBytes: Int)
    case unsupportedType
    case invalidDimensions
    case decodeFailed
    case directoryCreationFailed
    case encodingFailed
    case writeFailed
    case invalidManagedFilename
}

protocol AwayPhotoStoring: Sendable {
    func importPhoto(from sourceURL: URL) throws -> AwayManagedPhoto
    func managedPhotoURL(for filename: String) throws -> URL
    func removePhoto(named filename: String) throws
    func removeUnreferencedPhotos(keeping filename: String?) throws
}

extension AwayPhotoStoring {
    func removeUnreferencedPhotos(keeping filename: String?) throws {}
}

struct AwayPhotoStore: AwayPhotoStoring, Sendable {
    static let maximumSourceBytes = 50 * 1_024 * 1_024
    static let maximumLongestEdge = 8_192
    static let maximumDecodedPixels = 32_000_000

    let directory: URL
    let maximumSourceBytes: Int
    let maximumLongestEdge: Int
    let maximumDecodedPixels: Int

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Semper/Away", isDirectory: true),
        maximumSourceBytes: Int = Self.maximumSourceBytes,
        maximumLongestEdge: Int = Self.maximumLongestEdge,
        maximumDecodedPixels: Int = Self.maximumDecodedPixels
    ) {
        self.directory = directory
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumLongestEdge = maximumLongestEdge
        self.maximumDecodedPixels = maximumDecodedPixels
    }

    func importPhoto(from sourceURL: URL) throws -> AwayManagedPhoto {
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        } catch {
            throw AwayPhotoStoreError.sourceNotRegularFile
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AwayPhotoStoreError.sourceNotRegularFile
        }
        guard let sourceSize = (attributes[.size] as? NSNumber)?.intValue, sourceSize > 0 else {
            throw AwayPhotoStoreError.emptyFile
        }
        guard sourceSize <= maximumSourceBytes else {
            throw AwayPhotoStoreError.fileTooLarge(maximumBytes: maximumSourceBytes)
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
            throw AwayPhotoStoreError.unsupportedType
        }
        guard let sourceType = CGImageSourceGetType(source), Self.allowedSourceTypes.contains(sourceType as String) else {
            throw AwayPhotoStoreError.unsupportedType
        }
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw AwayPhotoStoreError.invalidDimensions
        }

        guard let targetMaximumPixelSize = Self.targetMaximumPixelSize(
            width: width,
            height: height,
            maximumLongestEdge: maximumLongestEdge,
            maximumDecodedPixels: maximumDecodedPixels
        ) else {
            throw AwayPhotoStoreError.invalidDimensions
        }
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary),
              image.width > 0,
              image.height > 0,
              max(image.width, image.height) <= maximumLongestEdge,
              image.width <= maximumDecodedPixels / image.height else {
            throw AwayPhotoStoreError.decodeFailed
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw AwayPhotoStoreError.directoryCreationFailed
        }

        let identifier = UUID().uuidString.lowercased()
        let filename = "away-photo-\(identifier).jpg"
        let destinationURL = directory.appendingPathComponent(filename, isDirectory: false)
        let encodedData = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AwayPhotoStoreError.encodingFailed
        }
        let destinationOptions = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, destinationOptions)
        guard CGImageDestinationFinalize(destination) else {
            throw AwayPhotoStoreError.encodingFailed
        }

        do {
            try (encodedData as Data).write(to: destinationURL, options: .atomic)
        } catch {
            throw AwayPhotoStoreError.writeFailed
        }

        return AwayManagedPhoto(
            filename: filename,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    func managedPhotoURL(for filename: String) throws -> URL {
        guard Self.isManagedFilename(filename) else {
            throw AwayPhotoStoreError.invalidManagedFilename
        }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    func removePhoto(named filename: String) throws {
        let url = try managedPhotoURL(for: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw AwayPhotoStoreError.writeFailed
        }
    }

    func removeUnreferencedPhotos(keeping filename: String?) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw AwayPhotoStoreError.writeFailed
        }

        for url in contents {
            let candidate = url.lastPathComponent
            guard candidate != filename,
                  Self.isManagedFilename(candidate) else {
                continue
            }
            let isRegularFile: Bool
            do {
                isRegularFile = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            } catch {
                throw AwayPhotoStoreError.writeFailed
            }
            guard isRegularFile else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw AwayPhotoStoreError.writeFailed
            }
        }
    }

    private static let allowedSourceTypes: Set<String> = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.heic.identifier,
    ]

    static func targetMaximumPixelSize(
        width: Int,
        height: Int,
        maximumLongestEdge: Int,
        maximumDecodedPixels: Int
    ) -> Int? {
        guard width > 0,
              height > 0,
              maximumLongestEdge > 0,
              maximumDecodedPixels > 0 else {
            return nil
        }
        let longestEdge = max(width, height)
        let edgeScale = min(1, Double(maximumLongestEdge) / Double(longestEdge))
        let sourcePixels = Double(width) * Double(height)
        let pixelScale = min(1, sqrt(Double(maximumDecodedPixels) / sourcePixels))
        return max(1, Int((Double(longestEdge) * min(edgeScale, pixelScale)).rounded(.down)))
    }

    static func isManagedFilename(_ filename: String) -> Bool {
        let prefix = "away-photo-"
        let suffix = ".jpg"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return false }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(filename[start..<end])) != nil
    }
}

@MainActor
final class AwayPhotoImageCache {
    typealias DataLoader = @Sendable (URL) async throws -> Data

    private struct CachedImage {
        let url: URL
        let image: NSImage
    }

    private struct InFlightLoad {
        let id: UUID
        let url: URL
        let task: Task<Data, Error>
    }

    private let dataLoader: DataLoader
    private var cachedImage: CachedImage?
    private var inFlightLoad: InFlightLoad?
    private var retiredLoads: [UUID: Task<Data, Error>] = [:]

    var hasPendingLoads: Bool {
        inFlightLoad != nil || !retiredLoads.isEmpty
    }

    init(dataLoader: @escaping DataLoader = { url in
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }) {
        self.dataLoader = dataLoader
    }

    func image(at url: URL) async throws -> NSImage {
        if let cachedImage, cachedImage.url == url {
            return cachedImage.image
        }

        let load: InFlightLoad
        if let inFlightLoad, inFlightLoad.url == url {
            load = inFlightLoad
        } else {
            if let inFlightLoad {
                retire(inFlightLoad)
            }
            let id = UUID()
            let task = Task { try await dataLoader(url) }
            load = InFlightLoad(id: id, url: url, task: task)
            inFlightLoad = load
        }

        do {
            let data = try await load.task.value
            if let cachedImage, cachedImage.url == url {
                return cachedImage.image
            }
            guard inFlightLoad?.id == load.id else {
                throw CancellationError()
            }
            guard let image = NSImage(data: data) else {
                inFlightLoad = nil
                throw AwayPhotoStoreError.decodeFailed
            }
            cachedImage = CachedImage(url: url, image: image)
            inFlightLoad = nil
            return image
        } catch {
            if inFlightLoad?.id == load.id {
                inFlightLoad = nil
            }
            retiredLoads[load.id] = nil
            throw error
        }
    }

    func clear() {
        if let inFlightLoad {
            retire(inFlightLoad)
        }
        inFlightLoad = nil
        cachedImage = nil
    }

    func cancelAndDrain() async {
        clear()
        let loads = retiredLoads
        for (_, task) in loads {
            _ = await task.result
        }
        for id in loads.keys {
            retiredLoads[id] = nil
        }
    }

    private func retire(_ load: InFlightLoad) {
        load.task.cancel()
        retiredLoads[load.id] = load.task
    }
}
