import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ShelfImageCopySize: Int, CaseIterable, Identifiable, Sendable {
    case pixels1024 = 1024
    case pixels2048 = 2048
    var id: Int { rawValue }
}

nonisolated struct ShelfImageDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

nonisolated enum ShelfImageCopyFormat: Sendable {
    case jpeg, png
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    fileprivate var identifier: CFString {
        (self == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString
    }
}

nonisolated struct ShelfImageCopyPlan: Sendable {
    let sourceURL: URL
    let format: ShelfImageCopyFormat
    let dimensions: ShelfImageDimensions
    fileprivate let encoded: Data
    fileprivate let sourcePath: String
    fileprivate let color: ShelfImageColorSignature
    fileprivate let hasAlpha: Bool
    fileprivate let smallDimensions: ShelfImageDimensions
    fileprivate let largeDimensions: ShelfImageDimensions

    func outputDimensions(for size: ShelfImageCopySize) -> ShelfImageDimensions {
        size == .pixels1024 ? smallDimensions : largeDimensions
    }

    func suggestedFilename(for size: ShelfImageCopySize) -> String {
        let stem = String(sourceURL.deletingPathExtension().lastPathComponent.prefix(160))
        return "\(stem.isEmpty ? "Image" : stem)-\(size.rawValue)px.\(format.fileExtension)"
    }
}

nonisolated struct ShelfImageCopyReceipt: Sendable {
    let url: URL
    let dimensions: ShelfImageDimensions
}

nonisolated enum ShelfImageCopyFailure: Error, Equatable, LocalizedError, Sendable {
    case unsupported, animated, invalidImage, tooLarge, changedSource, colorProfile, transparency
    case destinationExists, invalidDestination, writeFailed, verificationFailed, invalidTemporaryCopy
    case cleanupFailed(ShelfImageTemporaryCopy)
    case cloningUnsupported, destinationChanged
    case publicationUncertain(ShelfImagePublishedCopy)

    var errorDescription: String? {
        switch self {
        case .unsupported: "Resize a Copy supports local JPEG and PNG images."
        case .animated: "Animated images cannot be resized with Resize a Copy."
        case .invalidImage: "The image could not be read completely."
        case .tooLarge: "Resize a Copy supports images up to 32 MB, 40 megapixels, and 16,384 pixels per side."
        case .changedSource: "The source changed while it was being read. Choose the image again."
        case .colorProfile: "This image's color profile cannot be preserved. No copy was saved."
        case .transparency: "This image's transparency cannot be preserved. No copy was saved."
        case .destinationExists: "An item already exists at that destination. Choose a different name."
        case .invalidDestination: "Choose a new JPEG or PNG filename in a writable folder."
        case .writeFailed: "The resized copy could not be written. Check folder access and available disk space."
        case .verificationFailed: "The resized copy did not pass verification. No copy was saved."
        case .invalidTemporaryCopy: "The temporary image path is not owned by Resize a Copy."
        case .cleanupFailed: "Temporary image cleanup needs recovery. Retry recovery before resizing another image."
        case .cloningUnsupported:
            "This location does not support Resize a Copy. Choose another location."
        case .destinationChanged: "The destination folder changed. Choose the save location again."
        case .publicationUncertain:
            "A copy was created, but its location or temporary cleanup needs recovery. Do not save again."
        }
    }
}

nonisolated protocol ShelfImageCopying: Sendable {
    func inspect(_ source: URL, access: any ShelfFileAccess) throws -> ShelfImageCopyPlan
    func writeCopy(_ plan: ShelfImageCopyPlan, size: ShelfImageCopySize, to destination: URL) throws
        -> ShelfImageCopyReceipt
    func removeTemporaryCopy(_ temporary: ShelfImageTemporaryCopy) throws
    func recoverPublishedCopy(_ published: ShelfImagePublishedCopy) throws -> ShelfImageCopyReceipt
}

nonisolated struct NativeShelfImageCopier: ShelfImageCopying {
    let fileOperations: ShelfImageFileOperations

    init(fileOperations: ShelfImageFileOperations = .native) { self.fileOperations = fileOperations }

    func inspect(_ source: URL, access: any ShelfFileAccess) throws -> ShelfImageCopyPlan {
        try Self.checkCancellation()
        guard source.isFileURL else { throw ShelfImageCopyFailure.unsupported }
        let scoped = access.begin(source)
        defer { if scoped { access.end(source) } }
        switch access.state(of: source) {
        case .available(isDirectory: false): break
        case .available: throw ShelfImageCopyFailure.unsupported
        case .cloudOnly: throw ShelfFailure.cloudOnly
        case .missing: throw ShelfFailure.missing
        case .inaccessible: throw ShelfFailure.inaccessible
        }
        var pathInfo = stat()
        let pathResult = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &pathInfo)
        }
        guard pathResult == 0 else { throw ShelfFailure.inaccessible }
        guard pathInfo.st_flags & UInt32(SF_DATALESS) == 0 else { throw ShelfFailure.cloudOnly }
        let input = try ShelfIO.regularFileHandle(source)
        defer { try? input.close() }
        var before = stat()
        guard fstat(input.fileDescriptor, &before) == 0 else { throw ShelfFailure.inaccessible }
        guard before.st_flags & UInt32(SF_DATALESS) == 0 else { throw ShelfFailure.cloudOnly }
        guard before.st_size > 0, before.st_size <= ShelfLimits.importBytes else {
            throw ShelfImageCopyFailure.tooLarge
        }
        let data = try Self.readBounded(input)
        var after = stat()
        var current = stat()
        let currentResult = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &current)
        }
        guard fstat(input.fileDescriptor, &after) == 0, currentResult == 0,
            Self.sameFile(before, after), Self.sameFile(before, current), before.st_size == data.count
        else { throw ShelfImageCopyFailure.changedSource }
        return try autoreleasepool {
            if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
                try Self.validatePNG(data)
            } else if !data.starts(with: [0xFF, 0xD8]) {
                throw ShelfImageCopyFailure.unsupported
            }
            let imageSource = try Self.imageSource(data)
            let format = try Self.format(imageSource)
            guard CGImageSourceGetCount(imageSource) == 1 else { throw ShelfImageCopyFailure.animated }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0
            else { throw ShelfImageCopyFailure.invalidImage }
            guard width <= 16_384, height <= 16_384, width <= ShelfLimits.imagePixels / height else {
                throw ShelfImageCopyFailure.tooLarge
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
            guard (1...8).contains(orientation) else { throw ShelfImageCopyFailure.invalidImage }
            let dimensions = ShelfImageDimensions(
                width: orientation >= 5 ? height : width, height: orientation >= 5 ? width : height)
            let uncached =
                [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
            guard let original = CGImageSourceCreateImageAtIndex(imageSource, 0, uncached),
                original.width == width, original.height == height
            else { throw ShelfImageCopyFailure.invalidImage }
            let color = try ShelfImageColorSignature(original)
            let alpha = Self.hasAlpha(original)
            let small = try Self.thumbnailDimensions(imageSource, dimensions, .pixels1024, color, alpha)
            let large = try Self.thumbnailDimensions(imageSource, dimensions, .pixels2048, color, alpha)
            try Self.checkCancellation()
            return ShelfImageCopyPlan(
                sourceURL: source, format: format, dimensions: dimensions, encoded: data,
                sourcePath: source.resolvingSymlinksInPath().standardizedFileURL.path,
                color: color, hasAlpha: alpha, smallDimensions: small, largeDimensions: large)
        }
    }

    func writeCopy(_ plan: ShelfImageCopyPlan, size: ShelfImageCopySize, to destination: URL) throws
        -> ShelfImageCopyReceipt
    {
        try Self.checkCancellation()
        guard destination.isFileURL,
            destination.standardizedFileURL != plan.sourceURL.standardizedFileURL,
            destination.resolvingSymlinksInPath().standardizedFileURL.path != plan.sourcePath,
            [plan.format.fileExtension, plan.format == .jpeg ? "jpeg" : "png"].contains(
                destination.pathExtension.lowercased())
        else { throw ShelfImageCopyFailure.invalidDestination }
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty, !destinationName.contains("\0"), destinationName != ".", destinationName != ".."
        else { throw ShelfImageCopyFailure.invalidDestination }
        let owner = try ShelfImageFileOwner(destination: destination, operations: fileOperations)
        let descriptor = owner.stageDescriptor
        do {
            try owner.validateForWriting()
            try autoreleasepool {
                let source = try Self.imageSource(plan.encoded)
                let image = try Self.thumbnail(source, plan.dimensions, size)
                guard Self.dimensions(image) == plan.outputDimensions(for: size) else {
                    throw ShelfImageCopyFailure.verificationFailed
                }
                try Self.verifyColorAndAlpha(image, color: plan.color, alpha: plan.hasAlpha)
                try Self.encode(image, format: plan.format, descriptor: descriptor)
            }
            try Self.checkCancellation()
            guard fsync(descriptor) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw ShelfImageCopyFailure.writeFailed
            }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            // ImageIO adds EXIF dimension tags even when the input is a fresh CGImage.
            let cleaned = try Self.withoutAncillaryMetadata(Self.readBounded(output), format: plan.format)
            guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw ShelfImageCopyFailure.writeFailed
            }
            let sink = ShelfImageOutputSink(descriptor: descriptor)
            try cleaned.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress, sink.write(base, buffer.count) == buffer.count else {
                    throw sink.error ?? ShelfImageCopyFailure.writeFailed
                }
            }
            guard fsync(descriptor) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw ShelfImageCopyFailure.writeFailed
            }
            let encoded = try Self.readBounded(output)
            try autoreleasepool { try Self.verifyOutput(encoded, plan: plan, size: size) }
            try Self.checkCancellation()
            return try owner.publish(encoded: encoded, dimensions: plan.outputDimensions(for: size))
        } catch {
            if owner.hasPublished { throw ShelfImageCopyFailure.publicationUncertain(owner.publishedCopy) }
            try owner.cleanUp()
            throw error
        }
    }

    func removeTemporaryCopy(_ temporary: ShelfImageTemporaryCopy) throws {
        guard let owner = temporary.owner else { throw ShelfImageCopyFailure.invalidTemporaryCopy }
        try owner.cleanUp()
    }

    func recoverPublishedCopy(_ published: ShelfImagePublishedCopy) throws -> ShelfImageCopyReceipt {
        guard let owner = published.owner else { throw ShelfImageCopyFailure.publicationUncertain(published) }
        return try owner.recoverPublication()
    }

    private static func readBounded(_ file: FileHandle) throws -> Data {
        var data = Data()
        while true {
            try checkCancellation()
            let chunk: Data
            do {
                chunk =
                    try file.read(upToCount: min(ShelfLimits.chunkBytes, ShelfLimits.importBytes - data.count + 1))
                    ?? Data()
            } catch { throw ShelfImageCopyFailure.invalidImage }
            if chunk.isEmpty { return data }
            guard chunk.count <= ShelfLimits.importBytes - data.count else { throw ShelfImageCopyFailure.tooLarge }
            data.append(chunk)
        }
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func imageSource(_ data: Data) throws -> CGImageSource {
        try checkCancellation()
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetStatus(source) == .statusComplete
        else { throw ShelfImageCopyFailure.invalidImage }
        return source
    }

    private static func format(_ source: CGImageSource) throws -> ShelfImageCopyFormat {
        switch CGImageSourceGetType(source) as String? {
        case UTType.jpeg.identifier: return .jpeg
        case UTType.png.identifier: return .png
        default: throw ShelfImageCopyFailure.unsupported
        }
    }

    private static func withoutAncillaryMetadata(_ data: Data, format: ShelfImageCopyFormat) throws -> Data {
        var result = Data()
        if format == .png {
            try validatePNG(data)
            result.append(data.prefix(8))
            var cursor = 8
            let permitted = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "cHRM", "gAMA", "iCCP", "sRGB", "cICP"]
            while cursor < data.count {
                try checkCancellation()
                let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[cursor + $1]) }
                let end = cursor + length + 12
                let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                if permitted.contains(type) { result.append(data[cursor..<end]) }
                cursor = end
            }
            return result
        }

        guard data.starts(with: [0xFF, 0xD8]) else { throw ShelfImageCopyFailure.verificationFailed }
        result.append(data.prefix(2))
        var cursor = 2
        var segments = 0
        while cursor < data.count {
            try checkCancellation()
            segments += 1
            guard segments <= 16_384, cursor + 1 < data.count, data[cursor] == 0xFF else {
                throw ShelfImageCopyFailure.verificationFailed
            }
            let start = cursor
            while cursor < data.count, data[cursor] == 0xFF { cursor += 1 }
            guard cursor < data.count else { throw ShelfImageCopyFailure.verificationFailed }
            let marker = data[cursor]
            cursor += 1
            if marker == 0xD9 {
                guard cursor == data.count else { throw ShelfImageCopyFailure.verificationFailed }
                result.append(data[start..<cursor])
                return result
            }
            guard marker != 0, marker != 0xD8, !(0xD0...0xD7).contains(marker), cursor + 2 <= data.count else {
                throw ShelfImageCopyFailure.verificationFailed
            }
            let length = Int(data[cursor]) * 256 + Int(data[cursor + 1])
            guard length >= 2, length <= data.count - cursor else { throw ShelfImageCopyFailure.verificationFailed }
            let end = cursor + length
            let ancillary = (0xE0...0xEF).contains(marker) || marker == 0xFE
            if !ancillary || marker == 0xE0 || marker == 0xE2 || marker == 0xEE {
                result.append(data[start..<end])
            }
            cursor = end
            if marker == 0xDA {
                let scanStart = cursor
                while cursor + 1 < data.count {
                    if cursor % ShelfLimits.chunkBytes == 0 { try checkCancellation() }
                    if data[cursor] != 0xFF {
                        cursor += 1
                    } else if data[cursor + 1] == 0 || (0xD0...0xD7).contains(data[cursor + 1]) {
                        cursor += 2
                    } else {
                        break
                    }
                }
                result.append(data[scanStart..<cursor])
            }
        }
        throw ShelfImageCopyFailure.verificationFailed
    }

    private static func validatePNG(_ data: Data) throws {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ShelfImageCopyFailure.invalidImage }
        var cursor = 8
        var chunks = 0
        while cursor <= data.count - 12 {
            try checkCancellation()
            chunks += 1
            guard chunks <= 16_384 else { throw ShelfImageCopyFailure.tooLarge }
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[cursor + $1]) }
            guard length <= data.count - cursor - 12 else { throw ShelfImageCopyFailure.invalidImage }
            let type = Array(data[(cursor + 4)..<(cursor + 8)])
            if chunks == 1 {
                guard type == Array("IHDR".utf8), length == 13 else { throw ShelfImageCopyFailure.invalidImage }
                let width = (0..<4).reduce(0) { ($0 << 8) | Int(data[cursor + 8 + $1]) }
                let height = (0..<4).reduce(0) { ($0 << 8) | Int(data[cursor + 12 + $1]) }
                guard width > 0, height > 0 else { throw ShelfImageCopyFailure.invalidImage }
                guard width <= 16_384, height <= 16_384, width <= ShelfLimits.imagePixels / height else {
                    throw ShelfImageCopyFailure.tooLarge
                }
            }
            if type == Array("acTL".utf8) || type == Array("fcTL".utf8) || type == Array("fdAT".utf8) {
                throw ShelfImageCopyFailure.animated
            }
            cursor += length + 12
            if type == Array("IEND".utf8) {
                guard length == 0, cursor == data.count else { throw ShelfImageCopyFailure.invalidImage }
                return
            }
        }
        throw ShelfImageCopyFailure.invalidImage
    }

    private static func thumbnail(
        _ source: CGImageSource, _ dimensions: ShelfImageDimensions, _ size: ShelfImageCopySize
    )
        throws -> CGImage
    {
        try checkCancellation()
        let maximum = min(size.rawValue, max(dimensions.width, dimensions.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShelfImageCopyFailure.invalidImage
        }
        try checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= maximum, image.height <= maximum,
            image.width <= dimensions.width, image.height <= dimensions.height,
            abs(image.width * dimensions.height - image.height * dimensions.width)
                <= max(dimensions.width, dimensions.height)
        else { throw ShelfImageCopyFailure.verificationFailed }
        return image
    }

    private static func thumbnailDimensions(
        _ source: CGImageSource, _ dimensions: ShelfImageDimensions, _ size: ShelfImageCopySize,
        _ color: ShelfImageColorSignature, _ alpha: Bool
    ) throws -> ShelfImageDimensions {
        try autoreleasepool {
            let image = try thumbnail(source, dimensions, size)
            try verifyColorAndAlpha(image, color: color, alpha: alpha)
            return Self.dimensions(image)
        }
    }

    private static func dimensions(_ image: CGImage) -> ShelfImageDimensions {
        ShelfImageDimensions(width: image.width, height: image.height)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        default: false
        }
    }

    private static func verifyColorAndAlpha(_ image: CGImage, color: ShelfImageColorSignature, alpha: Bool) throws {
        guard try ShelfImageColorSignature(image) == color else { throw ShelfImageCopyFailure.colorProfile }
        guard hasAlpha(image) == alpha else { throw ShelfImageCopyFailure.transparency }
    }

    private static func encode(_ image: CGImage, format: ShelfImageCopyFormat, descriptor: Int32) throws {
        let sink = ShelfImageOutputSink(descriptor: descriptor)
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { pointer, buffer, count in
                guard let pointer else { return 0 }
                return Unmanaged<ShelfImageOutputSink>.fromOpaque(pointer).takeUnretainedValue().write(buffer, count)
            },
            releaseConsumer: { pointer in
                if let pointer { Unmanaged<ShelfImageOutputSink>.fromOpaque(pointer).release() }
            })
        let retained = Unmanaged.passRetained(sink)
        guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else {
            retained.release()
            throw ShelfImageCopyFailure.writeFailed
        }
        guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, format.identifier, 1, nil) else {
            throw ShelfImageCopyFailure.writeFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImageDestinationEmbedThumbnail: false,
            kCGImageDestinationOptimizeColorForSharing: false,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        let finalized = CGImageDestinationFinalize(destination)
        if let error = sink.error { throw error }
        guard finalized else { throw ShelfImageCopyFailure.writeFailed }
        try checkCancellation()
    }

    private static func verifyOutput(_ data: Data, plan: ShelfImageCopyPlan, size: ShelfImageCopySize) throws {
        let source = try imageSource(data)
        guard try format(source) == plan.format, CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
            dimensions(image) == plan.outputDimensions(for: size),
            (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        else { throw ShelfImageCopyFailure.verificationFailed }
        try verifyColorAndAlpha(image, color: plan.color, alpha: plan.hasAlpha)
        let forbidden = [
            kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary,
        ]
        let tags = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCopyTags($0) }
        guard forbidden.allSatisfy({ properties[$0] == nil }), tags.map({ CFArrayGetCount($0) == 0 }) ?? true
        else { throw ShelfImageCopyFailure.verificationFailed }
        if plan.format == .png {
            try validatePNG(data)
            let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
            let permitted = [
                kCGImagePropertyPNGGamma, kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGsRGBIntent,
                kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGXPixelsPerMeter,
                kCGImagePropertyPNGYPixelsPerMeter,
            ]
            guard png.keys.allSatisfy({ permitted.contains($0) }) else {
                throw ShelfImageCopyFailure.verificationFailed
            }
        }
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw ShelfFailure.cancelled }
    }
}

nonisolated private struct ShelfImageColorSignature: Equatable, Sendable {
    let profile: Data?
    let name: String?
    let model: Int

    init(_ image: CGImage) throws {
        guard var space = image.colorSpace else { throw ShelfImageCopyFailure.colorProfile }
        if space.model == .indexed {
            guard let base = space.baseColorSpace else { throw ShelfImageCopyFailure.colorProfile }
            space = base
        }
        guard space.model == .rgb || space.model == .monochrome else { throw ShelfImageCopyFailure.colorProfile }
        profile = space.copyICCData() as Data?
        name = profile == nil ? space.name as String? : nil
        model = Int(space.model.rawValue)
        guard profile != nil || name != nil else { throw ShelfImageCopyFailure.colorProfile }
    }
}

nonisolated private final class ShelfImageOutputSink {
    private let descriptor: Int32
    private let lock = NSLock()
    private var byteCount = 0
    private var failure: (any Error)?
    var error: (any Error)? { lock.withLock { failure } }

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        lock.withLock {
            guard failure == nil else { return 0 }
            guard count <= ShelfLimits.importBytes - byteCount else {
                failure = ShelfImageCopyFailure.tooLarge
                return 0
            }
            var written = 0
            while written < count {
                if Task.isCancelled {
                    failure = ShelfFailure.cancelled
                    return written
                }
                let result = Darwin.write(
                    descriptor, buffer.advanced(by: written), min(count - written, ShelfLimits.chunkBytes))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    failure = ShelfImageCopyFailure.writeFailed
                    return written
                }
                written += result
                byteCount += result
            }
            return written
        }
    }
}
