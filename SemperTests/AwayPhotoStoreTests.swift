import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Semper

@Suite("Away photo store", .serialized)
struct AwayPhotoStoreTests {
    @Test(
        "PNG, JPEG, and HEIC inputs are accepted",
        arguments: [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier]
    )
    func acceptedTypes(typeIdentifier: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeImage(
            width: 8,
            height: 6,
            typeIdentifier: typeIdentifier,
            in: directory
        )
        let managedDirectory = directory.appendingPathComponent("managed", isDirectory: true)
        let store = AwayPhotoStore(directory: managedDirectory)

        let result = try store.importPhoto(from: source)

        #expect(result.pixelWidth == 8)
        #expect(result.pixelHeight == 6)
        let output = try store.managedPhotoURL(for: result.filename)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let outputSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(outputSource) as String? == UTType.jpeg.identifier)
    }

    @Test("The source size limit runs before image parsing")
    func sourceSizeLimit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("oversized.bin")
        try Data(repeating: 0, count: 5).write(to: source)
        let store = AwayPhotoStore(
            directory: directory.appendingPathComponent("managed"),
            maximumSourceBytes: 4
        )

        #expect(throws: AwayPhotoStoreError.fileTooLarge(maximumBytes: 4)) {
            try store.importPhoto(from: source)
        }
    }

    @Test("Empty and unsupported files report distinct errors")
    func invalidInputs() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        let text = directory.appendingPathComponent("text.png")
        try Data("not an image".utf8).write(to: text)
        let store = AwayPhotoStore(directory: directory.appendingPathComponent("managed"))

        #expect(throws: AwayPhotoStoreError.emptyFile) {
            try store.importPhoto(from: empty)
        }
        #expect(throws: AwayPhotoStoreError.unsupportedType) {
            try store.importPhoto(from: text)
        }
    }

    @Test("Unsupported image formats are rejected by detected type")
    func unsupportedImageType() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeImage(
            width: 8,
            height: 6,
            typeIdentifier: UTType.gif.identifier,
            in: directory
        )
        let store = AwayPhotoStore(directory: directory.appendingPathComponent("managed"))

        #expect(throws: AwayPhotoStoreError.unsupportedType) {
            try store.importPhoto(from: source)
        }
    }

    @Test("The managed image longest edge is capped at 8192 pixels")
    func dimensionCap() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeImage(
            width: 9_000,
            height: 2,
            typeIdentifier: UTType.png.identifier,
            in: directory
        )
        let store = AwayPhotoStore(directory: directory.appendingPathComponent("managed"))

        let result = try store.importPhoto(from: source)

        #expect(max(result.pixelWidth, result.pixelHeight) == AwayPhotoStore.maximumLongestEdge)
    }

    @Test("Square images are capped by total decoded pixels")
    func decodedPixelCap() {
        let target = AwayPhotoStore.targetMaximumPixelSize(
            width: 8_192,
            height: 8_192,
            maximumLongestEdge: AwayPhotoStore.maximumLongestEdge,
            maximumDecodedPixels: AwayPhotoStore.maximumDecodedPixels
        )

        #expect(target == 5_656)
        #expect((target ?? Int.max) <= AwayPhotoStore.maximumLongestEdge)
        #expect((target ?? Int.max) <= AwayPhotoStore.maximumDecodedPixels / (target ?? 1))
    }

    @MainActor
    @Test("Photo image cache shares one in-flight decode across displays")
    func sharedImageCache() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeImage(
            width: 8,
            height: 6,
            typeIdentifier: UTType.png.identifier,
            in: directory
        )
        let data = try Data(contentsOf: source)
        let loader = AwayPhotoDataLoaderProbe(data: data)
        let cache = AwayPhotoImageCache { _ in
            await loader.load()
        }

        let firstTask = Task { @MainActor in try await cache.image(at: source) }
        await Task.yield()
        let secondTask = Task { @MainActor in try await cache.image(at: source) }
        let first = try await firstTask.value
        let second = try await secondTask.value

        #expect(first === second)
        #expect(await loader.loadCount() == 1)
    }

    @Test("Source metadata is absent from the managed image")
    func metadataRemoval() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceProperties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "private-note",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 12.34,
                kCGImagePropertyGPSLatitudeRef: "N",
            ],
        ]
        let source = try writeImage(
            width: 8,
            height: 6,
            typeIdentifier: UTType.jpeg.identifier,
            properties: sourceProperties,
            in: directory
        )
        let store = AwayPhotoStore(directory: directory.appendingPathComponent("managed"))

        let result = try store.importPhoto(from: source)
        let output = try store.managedPhotoURL(for: result.filename)
        let outputSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let outputProperties = try #require(
            CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        )
        let gps = outputProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let exif = outputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]

        #expect(gps == nil || gps?.isEmpty == true)
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(!String(decoding: try Data(contentsOf: output), as: UTF8.self).contains("private-note"))
    }

    @Test("Managed filenames cannot escape the Away directory")
    func filenameValidation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AwayPhotoStore(directory: directory)

        for filename in ["../photo.jpg", "/tmp/photo.jpg", "photo.jpg", "away-photo-bad.jpg"] {
            #expect(throws: AwayPhotoStoreError.invalidManagedFilename) {
                try store.managedPhotoURL(for: filename)
            }
        }
    }

    @Test("Managed photos can be removed and repeated removal is harmless")
    func removal() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeImage(
            width: 8,
            height: 6,
            typeIdentifier: UTType.png.identifier,
            in: directory
        )
        let store = AwayPhotoStore(directory: directory.appendingPathComponent("managed"))
        let result = try store.importPhoto(from: source)
        let output = try store.managedPhotoURL(for: result.filename)

        try store.removePhoto(named: result.filename)
        try store.removePhoto(named: result.filename)

        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Cleanup removes only unreferenced managed photos")
    func unreferencedCleanup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeImage(
            width: 8,
            height: 6,
            typeIdentifier: UTType.png.identifier,
            in: directory
        )
        let managedDirectory = directory.appendingPathComponent("managed")
        let store = AwayPhotoStore(directory: managedDirectory)
        let kept = try store.importPhoto(from: source)
        let removed = try store.importPhoto(from: source)
        let unrelated = managedDirectory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)

        try store.removeUnreferencedPhotos(keeping: kept.filename)

        let keptURL = try store.managedPhotoURL(for: kept.filename)
        let removedURL = try store.managedPhotoURL(for: removed.filename)
        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(!FileManager.default.fileExists(atPath: removedURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperAwayPhotoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeImage(
        width: Int,
        height: Int,
        typeIdentifier: String,
        properties: [CFString: Any] = [:],
        in directory: URL
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "image"
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).\(fileExtension)")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            typeIdentifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

private actor AwayPhotoDataLoaderProbe {
    private let data: Data
    private var count = 0

    init(data: Data) {
        self.data = data
    }

    func load() async -> Data {
        count += 1
        await Task.yield()
        return data
    }

    func loadCount() -> Int {
        count
    }
}
