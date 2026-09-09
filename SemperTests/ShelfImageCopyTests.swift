import CoreFoundation
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Semper

nonisolated private final class ShelfImageAccessSpy: ShelfFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    private var closed = 0
    let fileState: ShelfFileState
    let cancelOnState: Bool
    var balanced: Bool { lock.withLock { opened == closed } }
    var beginCount: Int { lock.withLock { opened } }

    init(state: ShelfFileState = .available(isDirectory: false), cancelOnState: Bool = false) {
        fileState = state
        self.cancelOnState = cancelOnState
    }
    func begin(_ url: URL) -> Bool {
        lock.withLock { opened += 1 }
        return true
    }
    func end(_ url: URL) { lock.withLock { closed += 1 } }
    func state(of url: URL) -> ShelfFileState {
        if cancelOnState { withUnsafeCurrentTask { $0?.cancel() } }
        return fileState
    }
    func bookmark(for url: URL) throws -> Data { throw ShelfFailure.unsupported }
    func resolve(_ bookmark: Data) throws -> URL { throw ShelfFailure.unsupported }
}

@Suite("Shelf image copies", .serialized, .timeLimit(.minutes(1)))
struct ShelfImageCopyTests {
    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-image-copy-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func remove() {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
    }

    private func image(
        width: Int, height: Int, colorSpace: CFString = CGColorSpace.sRGB, alpha: Bool = false
    ) throws -> CGImage {
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        let opacity: [UInt8] = alpha ? [255, 128, 0, 192] : [255, 255, 255, 255]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let quadrant = (y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)
                let offset = (y * width + x) * 4
                bytes[offset] = colors[quadrant][0]
                bytes[offset + 1] = colors[quadrant][1]
                bytes[offset + 2] = colors[quadrant][2]
                bytes[offset + 3] = opacity[quadrant]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let space = try #require(CGColorSpace(name: colorSpace))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func encode(
        _ image: CGImage, to url: URL, type: UTType, orientation: Int = 1, privateMetadata: Bool = false
    ) throws {
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ]
        if privateMetadata {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06",
                kCGImagePropertyExifUserComment: "PRIVATE-EXIF-MARKER",
                kCGImagePropertyExifMakerNote: Data("PRIVATE-MAKER-MARKER".utf8),
            ]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.25, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.5, kCGImagePropertyGPSLongitudeRef: "W",
            ]
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCaptionAbstract: "PRIVATE-IPTC-MARKER"]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFArtist: "PRIVATE-ARTIST-MARKER"]
            if type == .png {
                properties[kCGImagePropertyPNGDictionary] = [
                    kCGImagePropertyPNGAuthor: "PRIVATE-PNG-MARKER",
                    kCGImagePropertyPNGTitle: "PRIVATE-TITLE-MARKER",
                    kCGImagePropertyPNGDescription: "PRIVATE-TEXT-MARKER",
                ]
            }
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func source(_ url: URL) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
    }
    private func decoded(_ url: URL) throws -> CGImage {
        try #require(CGImageSourceCreateImageAtIndex(try source(url), 0, nil))
    }
    private func properties(_ url: URL) throws -> [CFString: Any] {
        try #require(CGImageSourceCopyPropertiesAtIndex(try source(url), 0, nil) as? [CFString: Any])
    }
    private func digest(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    private func pixel(_ image: CGImage, x: Double, y: Double) throws -> [UInt8] {
        let crop = try #require(
            image.cropping(
                to: CGRect(
                    x: Int(Double(image.width) * x), y: Int(Double(image.height) * y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setBlendMode(.copy)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func corners(_ image: CGImage) throws -> [[UInt8]] {
        try [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)].map { try pixel(image, x: $0.0, y: $0.1) }
    }

    private func bigEndian(_ number: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: number >> 24), UInt8(truncatingIfNeeded: number >> 16),
            UInt8(truncatingIfNeeded: number >> 8), UInt8(truncatingIfNeeded: number),
        ])
    }

    private func pngChunk(_ name: String, payload: Data) -> Data {
        let body = Data(name.utf8) + payload
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320 }
        }
        return bigEndian(UInt32(payload.count)) + body + bigEndian(crc ^ 0xFFFF_FFFF)
    }

    @Test(
        "Both formats honor both longest-edge limits, odd aspect ratios, and no enlargement",
        arguments: [ShelfImageCopyFormat.jpeg, .png], [ShelfImageCopySize.pixels1024, .pixels2048])
    func dimensions(format: ShelfImageCopyFormat, size: ShelfImageCopySize) throws {
        let f = try Fixture()
        defer { f.remove() }
        let copier = NativeShelfImageCopier()
        let access = ShelfImageAccessSpy()
        for (width, height) in [(2303, 1301), (317, 113)] {
            let input = f.url("source-\(width).dat")
            try encode(try image(width: width, height: height), to: input, type: format == .jpeg ? .jpeg : .png)
            let original = try digest(input)
            let plan = try copier.inspect(input, access: access)
            #expect(plan.sourceURL == input)
            #expect(plan.format == format)
            #expect(plan.dimensions == ShelfImageDimensions(width: width, height: height))
            let expected = plan.outputDimensions(for: size)
            let edge = min(width, size.rawValue)
            #expect(expected.width == edge)
            #expect(abs(Double(expected.height) - Double(height) * Double(edge) / Double(width)) <= 1)
            let suggested = plan.suggestedFilename(for: size)
            #expect((suggested as NSString).pathExtension == format.fileExtension)
            #expect(!suggested.contains("/"))
            let output = f.url(suggested)
            let receipt = try copier.writeCopy(plan, size: size, to: output)
            #expect(receipt.url == output)
            #expect(receipt.dimensions == expected)
            let actual = try decoded(output)
            #expect(actual.width == expected.width && actual.height == expected.height)
            #expect(
                CGImageSourceGetType(try source(output)) as String? == (format == .jpeg ? UTType.jpeg : .png).identifier
            )
            #expect(try digest(input) == original)
        }
        #expect(access.balanced)
    }

    @Test("Every EXIF orientation preserves displayed corner positions", arguments: Array(1...8))
    func orientations(orientation: Int) throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("oriented.jpg")
        try encode(try image(width: 80, height: 48), to: input, type: .jpeg, orientation: orientation)
        #expect(try properties(input)[kCGImagePropertyOrientation] as? Int == orientation)
        let original = try digest(input)
        let rawCorners = try corners(decoded(input))
        let mappings = [
            [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
            [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2],
        ]
        let copier = NativeShelfImageCopier()
        let plan = try copier.inspect(input, access: ShelfImageAccessSpy())
        let expected = orientation >= 5 ? ShelfImageDimensions(width: 48, height: 80) : .init(width: 80, height: 48)
        #expect(plan.dimensions == expected)
        let output = f.url("copy.jpg")
        let receipt = try copier.writeCopy(plan, size: .pixels1024, to: output)
        #expect(receipt.dimensions == expected)
        let actual = try decoded(output)
        #expect(actual.width == expected.width && actual.height == expected.height)
        let actualCorners = try corners(actual)
        for index in 0..<4 {
            let expectedPixel = rawCorners[mappings[orientation - 1][index]]
            for channel in 0..<3 {
                #expect(abs(Int(actualCorners[index][channel]) - Int(expectedPixel[channel])) <= 20)
            }
        }
        let outputOrientation = try properties(output)[kCGImagePropertyOrientation] as? Int
        #expect(outputOrientation == nil || outputOrientation == 1)
        #expect(try digest(input) == original)
    }

    @Test(
        "Tagged color profiles and PNG transparency survive fresh encoding",
        arguments: [ShelfImageCopyFormat.jpeg, .png], ["sRGB", "Display P3"])
    func profilesAndAlpha(format: ShelfImageCopyFormat, profile: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("tagged.\(format.fileExtension)")
        try encode(
            try image(
                width: 80, height: 48, colorSpace: profile == "sRGB" ? CGColorSpace.sRGB : CGColorSpace.displayP3,
                alpha: format == .png), to: input, type: format == .jpeg ? .jpeg : .png)
        let sourceSpace = try #require(try decoded(input).colorSpace)
        let sourceICC = try #require(sourceSpace.copyICCData()) as Data
        let copier = NativeShelfImageCopier()
        let plan = try copier.inspect(input, access: ShelfImageAccessSpy())
        let output = f.url("copy.\(format.fileExtension)")
        _ = try copier.writeCopy(plan, size: .pixels2048, to: output)
        let result = try decoded(output)
        let outputSpace = try #require(result.colorSpace)
        #expect(try #require(outputSpace.copyICCData()) as Data == sourceICC)
        if format == .png {
            let sourcePixels = try corners(decoded(input))
            let outputPixels = try corners(result)
            #expect(sourcePixels.map { $0[3] } == [255, 128, 0, 192])
            #expect(outputPixels.map { $0[3] } == sourcePixels.map { $0[3] })
        }
    }

    @Test("Fresh output omits private metadata and XMP", arguments: [ShelfImageCopyFormat.jpeg, .png])
    func metadata(format: ShelfImageCopyFormat) throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("private.\(format.fileExtension)")
        try encode(
            try image(width: 80, height: 48), to: input, type: format == .jpeg ? .jpeg : .png, privateMetadata: true)
        let packet = Data(
            ("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF "
                + "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description "
                + "xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:CreatorTool=\"PRIVATE-XMP-MARKER\"/>"
                + "</rdf:RDF></x:xmpmeta>").utf8)
        var encoded = try Data(contentsOf: input)
        if format == .jpeg {
            let payload = Data("http://ns.adobe.com/xap/1.0/\0".utf8) + packet
            let length = payload.count + 2
            encoded.insert(contentsOf: Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 255)]) + payload, at: 2)
        } else {
            let payload = Data("XML:com.adobe.xmp\0\0\0\0\0".utf8) + packet
            encoded.insert(contentsOf: pngChunk("iTXt", payload: payload), at: 33)
        }
        try encoded.write(to: input)
        let inputProperties = try properties(input)
        try #require(String(describing: inputProperties).contains("PRIVATE-"))
        if format == .jpeg {
            try #require(inputProperties[kCGImagePropertyGPSDictionary] != nil)
            try #require(inputProperties[kCGImagePropertyIPTCDictionary] != nil)
            let inputExif = try #require(inputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            try #require(inputExif[kCGImagePropertyExifDateTimeOriginal] != nil)
            try #require(inputExif[kCGImagePropertyExifUserComment] != nil)
        } else {
            let inputPNG = try #require(inputProperties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
            try #require(inputPNG[kCGImagePropertyPNGAuthor] != nil)
        }
        try #require(encoded.range(of: Data("PRIVATE-XMP-MARKER".utf8)) != nil)
        let original = try digest(input)
        let copier = NativeShelfImageCopier()
        let plan = try copier.inspect(input, access: ShelfImageAccessSpy())
        let output = f.url("copy.\(format.fileExtension)")
        _ = try copier.writeCopy(plan, size: .pixels1024, to: output)
        let values = try properties(output)
        #expect(!String(describing: values).contains("PRIVATE-"))
        #expect(try Data(contentsOf: output).range(of: Data("PRIVATE-".utf8)) == nil)
        #expect(values[kCGImagePropertyGPSDictionary] == nil)
        #expect(values[kCGImagePropertyIPTCDictionary] == nil)
        #expect(values[kCGImagePropertyExifDictionary] == nil)
        let tags = CGImageSourceCopyMetadataAtIndex(try source(output), 0, nil).flatMap { CGImageMetadataCopyTags($0) }
        #expect(tags.map { CFArrayGetCount($0) } ?? 0 == 0)
        let exif = values[kCGImagePropertyExifDictionary] as? [CFString: Any]
        for key in [
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifUserComment, kCGImagePropertyExifMakerNote,
        ] {
            #expect(exif?[key] == nil)
        }
        #expect(try digest(input) == original)
    }

    @Test("Existing destinations, the source, and source aliases are never replaced")
    func destinationRefusal() throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("source.png")
        try encode(try image(width: 32, height: 24), to: input, type: .png)
        let original = try digest(input)
        let existing = f.url("existing.png")
        let marker = Data("existing destination".utf8)
        try marker.write(to: existing)
        let symlink = f.url("alias.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        let hardlink = f.url("hardlink.png")
        try FileManager.default.linkItem(at: input, to: hardlink)
        let copier = NativeShelfImageCopier()
        let plan = try copier.inspect(input, access: ShelfImageAccessSpy())
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        for destination in [existing, input, symlink, hardlink] {
            #expect(throws: ShelfImageCopyFailure.self) {
                try copier.writeCopy(plan, size: .pixels1024, to: destination)
            }
            #expect(try digest(input) == original)
            #expect(try Data(contentsOf: existing) == marker)
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == before)
        }
    }

    @Test("Unsupported, corrupt, animated PNG, and excessive encoded input are rejected")
    func rejectedInputs() throws {
        let f = try Fixture()
        defer { f.remove() }
        let copier = NativeShelfImageCopier()
        let access = ShelfImageAccessSpy()
        let gif = f.url("static.gif")
        try encode(try image(width: 16, height: 12), to: gif, type: .gif)
        let corrupt = f.url("broken.png")
        try Data("not an image".utf8).write(to: corrupt)
        let png = f.url("static.png")
        try encode(try image(width: 16, height: 12), to: png, type: .png)
        let apng = f.url("single-frame.png")
        var animated = try Data(contentsOf: png)
        let control =
            bigEndian(0) + bigEndian(16) + bigEndian(12) + bigEndian(0) + bigEndian(0)
            + Data([0, 1, 0, 10, 0, 0])
        animated.insert(
            contentsOf:
                pngChunk("acTL", payload: bigEndian(1) + bigEndian(0)) + pngChunk("fcTL", payload: control), at: 33)
        try animated.write(to: apng)
        #expect(CGImageSourceGetCount(try source(apng)) == 1)
        let oversized = f.url("large.png")
        try Data(contentsOf: png).write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ShelfLimits.importBytes + 1))
        try handle.close()
        for input in [gif, corrupt, apng, oversized] {
            #expect(throws: ShelfImageCopyFailure.self) { try copier.inspect(input, access: access) }
        }
        #expect(access.balanced)
    }

    @Test("Oversized dimensions are rejected from small encoded headers", arguments: [(16385, 1), (8192, 8192)])
    func oversizedDimensions(dimensions: (Int, Int)) throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("dimensions.png")
        try encode(try image(width: 16, height: 12), to: input, type: .png)
        var data = try Data(contentsOf: input)
        var header = Data(data[16..<29])
        header.replaceSubrange(0..<8, with: bigEndian(UInt32(dimensions.0)) + bigEndian(UInt32(dimensions.1)))
        data.replaceSubrange(8..<33, with: pngChunk("IHDR", payload: header))
        try data.write(to: input)
        #expect(data[16..<20] == bigEndian(UInt32(dimensions.0)))
        #expect(data[20..<24] == bigEndian(UInt32(dimensions.1)))
        #expect(data.count < 4096)
        #expect(throws: ShelfImageCopyFailure.tooLarge) {
            try NativeShelfImageCopier().inspect(input, access: ShelfImageAccessSpy())
        }
    }

    @Test(
        "Unavailable files are refused without retaining access",
        arguments: [
            ShelfFileState.inaccessible, .missing, .cloudOnly, .available(isDirectory: true),
        ])
    func unavailable(state: ShelfFileState) throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("source.png")
        try encode(try image(width: 16, height: 12), to: input, type: .png)
        let access = ShelfImageAccessSpy(state: state)
        switch state {
        case .inaccessible:
            #expect(throws: ShelfFailure.inaccessible) { try NativeShelfImageCopier().inspect(input, access: access) }
        case .missing:
            #expect(throws: ShelfFailure.missing) { try NativeShelfImageCopier().inspect(input, access: access) }
        case .cloudOnly:
            #expect(throws: ShelfFailure.cloudOnly) { try NativeShelfImageCopier().inspect(input, access: access) }
        case .available:
            #expect(throws: ShelfImageCopyFailure.unsupported) {
                try NativeShelfImageCopier().inspect(input, access: access)
            }
        }
        #expect(access.balanced)
    }

    @MainActor
    @Test("Cancellation before inspection or writing leaves files and access untouched")
    func cancellationBeforeWork() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("source.png")
        try encode(try image(width: 16, height: 12), to: input, type: .png)
        let original = try digest(input)
        let access = ShelfImageAccessSpy()
        let copier = NativeShelfImageCopier()
        let inspection = Task { @MainActor in try copier.inspect(input, access: access) }
        inspection.cancel()
        switch await inspection.result {
        case .success: Issue.record("Cancelled inspection returned a plan")
        case .failure(let error): #expect(error as? ShelfFailure == .cancelled)
        }
        #expect(access.beginCount == 0)
        let plan = try copier.inspect(input, access: access)
        let output = f.url("copy.png")
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        let writing = Task { @MainActor in try copier.writeCopy(plan, size: .pixels1024, to: output) }
        writing.cancel()
        switch await writing.result {
        case .success: Issue.record("Cancelled write returned a receipt")
        case .failure(let error): #expect(error as? ShelfFailure == .cancelled)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == before)
        #expect(try digest(input) == original)
        #expect(access.balanced)
    }

    @Test("Cancellation after scope acquisition closes access and preserves the original")
    func cancellationAfterScopeAcquisition() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.url("source.png")
        try encode(try image(width: 16, height: 12), to: input, type: .png)
        let original = try digest(input)
        let access = ShelfImageAccessSpy(cancelOnState: true)
        let operation = Task.detached { try NativeShelfImageCopier().inspect(input, access: access) }
        switch await operation.result {
        case .success: Issue.record("Cancelled inspection returned a plan")
        case .failure(let error): #expect(error as? ShelfFailure == .cancelled)
        }
        #expect(access.beginCount == 1)
        #expect(access.balanced)
        #expect(try digest(input) == original)
    }

    @Test("Cleanup retains failures and refuses a replacement at the recorded temporary path")
    func cleanupRetainsIdentity() throws {
        let f = try Fixture()
        defer { f.remove() }
        let temporary = f.url(".semper-image-copy-\(UUID()).tmp")
        let retained = f.url("retained-owned-copy.tmp")
        let original = Data("owned temporary image".utf8)
        try original.write(to: temporary)
        var info = stat()
        try #require(lstat(temporary.path, &info) == 0)
        var parentInfo = stat()
        try #require(stat(temporary.deletingLastPathComponent().path, &parentInfo) == 0)
        let token = ShelfImageTemporaryCopy(
            url: temporary, device: info.st_dev, inode: info.st_ino,
            parentDevice: parentInfo.st_dev, parentInode: parentInfo.st_ino)
        let copier = NativeShelfImageCopier()
        try FileManager.default.moveItem(at: temporary, to: retained)
        let replacement = Data("replacement file".utf8)
        try replacement.write(to: temporary)
        #expect(throws: ShelfImageCopyFailure.cleanupFailed(token)) { try copier.removeTemporaryCopy(token) }
        #expect(try Data(contentsOf: temporary) == replacement)
        #expect(try Data(contentsOf: retained) == original)
        try FileManager.default.removeItem(at: temporary)
        try FileManager.default.moveItem(at: retained, to: temporary)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: temporary.path)
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do {
                    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: temporary.path)
                } catch { Issue.record(error) }
            }
        }
        #expect(throws: ShelfImageCopyFailure.cleanupFailed(token)) { try copier.removeTemporaryCopy(token) }
        #expect(try Data(contentsOf: temporary) == original)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: temporary.path)
        try copier.removeTemporaryCopy(token)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        try copier.removeTemporaryCopy(token)
    }

    @Test(
        "Cleanup retains a renamed or replaced parent until its original directory returns", arguments: [false, true])
    func cleanupRetainsUnavailableParent(replaced: Bool) throws {
        let f = try Fixture()
        defer { f.remove() }
        let parent = f.url("destination")
        let moved = f.url("moved-destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let temporary = parent.appendingPathComponent(".semper-image-copy-\(UUID()).tmp")
        let original = Data("owned temporary image".utf8)
        try original.write(to: temporary)
        var info = stat()
        try #require(lstat(temporary.path, &info) == 0)
        var parentInfo = stat()
        try #require(stat(temporary.deletingLastPathComponent().path, &parentInfo) == 0)
        let token = ShelfImageTemporaryCopy(
            url: temporary, device: info.st_dev, inode: info.st_ino,
            parentDevice: parentInfo.st_dev, parentInode: parentInfo.st_ino)
        let copier = NativeShelfImageCopier()
        try FileManager.default.moveItem(at: parent, to: moved)
        if replaced { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false) }
        #expect(throws: ShelfImageCopyFailure.cleanupFailed(token)) { try copier.removeTemporaryCopy(token) }
        #expect(try Data(contentsOf: moved.appendingPathComponent(temporary.lastPathComponent)) == original)
        if replaced {
            #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
            try FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.moveItem(at: moved, to: parent)
        try copier.removeTemporaryCopy(token)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test("Cleanup accepts a missing child in its available original parent")
    func cleanupAcceptsMissingChild() throws {
        let f = try Fixture()
        defer { f.remove() }
        let temporary = f.url(".semper-image-copy-\(UUID()).tmp")
        try Data("owned temporary image".utf8).write(to: temporary)
        var info = stat()
        try #require(lstat(temporary.path, &info) == 0)
        var parentInfo = stat()
        try #require(stat(temporary.deletingLastPathComponent().path, &parentInfo) == 0)
        let token = ShelfImageTemporaryCopy(
            url: temporary, device: info.st_dev, inode: info.st_ino,
            parentDevice: parentInfo.st_dev, parentInode: parentInfo.st_ino)
        try FileManager.default.removeItem(at: temporary)
        try NativeShelfImageCopier().removeTemporaryCopy(token)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }

}
