import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Semper

nonisolated private final class ShelfAccessSpy: ShelfFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var beginCount = 0
    private var endCount = 0
    private var overrideState: ShelfFileState?
    var begins: Int { lock.withLock { beginCount } }
    var ends: Int { lock.withLock { endCount } }
    func setState(_ state: ShelfFileState?) { lock.withLock { overrideState = state } }
    func begin(_ url: URL) -> Bool {
        lock.withLock { beginCount += 1 }
        return true
    }
    func end(_ url: URL) { lock.withLock { endCount += 1 } }
    func state(of url: URL) -> ShelfFileState {
        lock.withLock { overrideState } ?? NativeShelfFileAccess().state(of: url)
    }
    func bookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ bookmark: Data) throws -> URL {
        guard let string = String(data: bookmark, encoding: .utf8), let url = URL(string: string), url.isFileURL else {
            throw ShelfFailure.inaccessible
        }
        return url
    }
}

nonisolated private final class ShelfClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    func read() -> Date { lock.withLock { current } }
    func advance(_ interval: TimeInterval) { lock.withLock { current = current.addingTimeInterval(interval) } }
}

private actor ShelfAsyncGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        ready?.resume()
        ready = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { ready = $0 }
    }
    func resume() {
        waiting?.resume()
        waiting = nil
    }
}

nonisolated private final class ShelfBlockingAccess: ShelfFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let cancelled = DispatchSemaphore(value: 0)
    private var count = 0
    private var ended = 0
    var balanced: Bool { lock.withLock { count == ended } }
    func begin(_ url: URL) -> Bool {
        let shouldBlock = lock.withLock {
            count += 1
            return count > 1
        }
        if shouldBlock {
            entered.signal()
            var reportedCancellation = false
            while release.wait(timeout: .now() + 0.005) == .timedOut {
                if Task.isCancelled, !reportedCancellation {
                    reportedCancellation = true
                    cancelled.signal()
                }
            }
        }
        return true
    }
    func waitUntilBlocked() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func waitUntilCancelled() -> Bool { cancelled.wait(timeout: .now() + 5) == .success }
    func resume() { release.signal() }
    func end(_ url: URL) { lock.withLock { ended += 1 } }
    func state(of url: URL) -> ShelfFileState { NativeShelfFileAccess().state(of: url) }
    func bookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ bookmark: Data) throws -> URL { throw ShelfFailure.inaccessible }
}

nonisolated private struct ShelfFixture {
    let root: URL
    let store: ShelfStore
    let file: URL
    init(bytes: Data = Data("abc".utf8)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ShelfStore(root: root.appendingPathComponent("store", isDirectory: true))
        file = root.appendingPathComponent("original.txt")
        try bytes.write(to: file)
    }
    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Fixture cleanup failed") }
    }
}

@Suite("File Shelf")
@MainActor
struct ShelfTests {
    @Test func expiryBoundaries() {
        let date = Date(timeIntervalSince1970: 1_000)
        let item = ShelfItem(name: "Text", payload: .text("A"), now: date, expiry: .fifteenMinutes)
        #expect(!item.hasExpired(at: date.addingTimeInterval(899)))
        #expect(item.hasExpired(at: date.addingTimeInterval(900)))
        #expect(ShelfExpiry.quit.deadline(from: date) == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(ShelfExpiry.endOfDay.deadline(from: date, calendar: calendar) == Date(timeIntervalSince1970: 86_400))
    }

    @Test func expiryRemovesEntriesAndPreservesOriginal() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let clock = ShelfClock()
        let service = ShelfService(store: fixture.store, now: { clock.read() })
        service.start()
        service.setDefaultExpiry(.fifteenMinutes)
        try service.addFile(fixture.file)
        try service.addText("Expires")
        clock.advance(900)
        await service.expireItems()
        #expect(service.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
        await service.shutdown()
    }

    @Test func extendingExpiryDuringChecksumDrainPreservesOwnedImage() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let clock = ShelfClock()
        let access = ShelfBlockingAccess()
        try fixture.store.prepareCache()
        let name = "shelf-item-\(UUID().uuidString).png"
        let cached = try fixture.store.cacheURL(named: name)
        let image = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jA7sAAAAASUVORK5CYII="))
        try image.write(to: cached)
        let item = ShelfItem(
            name: "Expiring image", payload: .cachedFile(name), now: clock.read(), expiry: .fifteenMinutes)
        try fixture.store.save(items: [item], expiry: .fifteenMinutes)
        let service = ShelfService(store: fixture.store, access: access, now: { clock.read() })
        service.start()
        service.checksum(item.id)
        let blocked = await Task.detached { access.waitUntilBlocked() }.value
        #expect(blocked)
        clock.advance(900)
        let expiration = Task { await service.expireItems() }
        let draining = await Task.detached { access.waitUntilCancelled() }.value
        #expect(draining)
        service.setExpiry(.oneHour, for: item.id)
        access.resume()
        await expiration.value
        #expect(service.items.count == 1)
        #expect(service.items.first?.expiry == .oneHour)
        #expect(service.checksums[item.id] == .cancelled)
        #expect(FileManager.default.fileExists(atPath: cached.path))
        if FileManager.default.fileExists(atPath: cached.path) {
            #expect(try Data(contentsOf: cached) == image)
        }
        await service.shutdown()
        #expect(access.balanced)
    }

    @Test func storeLoadPrunesExpiredAndOrphanedOwnedCopies() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        try fixture.store.prepareCache()
        let name = "shelf-item-\(UUID().uuidString).png"
        let cached = try fixture.store.cacheURL(named: name)
        try Data("expired owned copy".utf8).write(to: cached)
        let expired = ShelfItem(
            name: "Expired", payload: .cachedFile(name), now: Date().addingTimeInterval(-901), expiry: .fifteenMinutes)
        try fixture.store.save(items: [expired], expiry: .fifteenMinutes)
        let service = ShelfService(store: fixture.store)
        service.start()
        #expect(service.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
        await service.shutdown()
    }

    @Test func sessionOnlyAndScopeCleanup() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        #expect(!service.isRunning)
        service.start()
        try service.addFile(fixture.file)
        try service.addText("Temporary")
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
        #expect(access.begins == 1)
        await service.shutdown()
        #expect(service.items.isEmpty)
        #expect(access.ends == access.begins)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
    }

    @Test func persistenceRequiresOptInAndQuitStillClears() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        service.setDefaultExpiry(.oneHour)
        try service.addFile(fixture.file)
        try service.addText("Saved")
        #expect(try fixture.store.load() == nil)
        service.setPersistence(true)
        #expect(service.persistenceEnabled)
        #expect(try fixture.store.load()?.items.count == 2)
        service.setDefaultExpiry(.quit)
        try service.addText("Quit only")
        await service.shutdown()
        #expect(service.items.count == 2)
        let restored = ShelfService(store: fixture.store, access: access)
        restored.start()
        #expect(restored.items.count == 2)
        #expect(restored.persistenceEnabled)
        restored.setPersistence(false)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
        await restored.shutdown()
        #expect(access.begins == access.ends)
    }

    @Test func corruptedAndNewerStoreNeverOverwrittenByImports() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        try fixture.store.prepareCache()
        let original = Data("{\"version\":2,\"persistenceEnabled\":true,\"defaultExpiry\":\"quit\",\"items\":[]}".utf8)
        try original.write(to: fixture.store.manifest)
        let service = ShelfService(store: fixture.store)
        service.start()
        #expect(service.storeNeedsReset)
        #expect(throws: ShelfFailure.invalidStore) { try service.addText("Never saved") }
        service.setPersistence(true)
        service.setDefaultExpiry(.oneHour)
        await service.shutdown()
        #expect(try Data(contentsOf: fixture.store.manifest) == original)
        await service.resetSavedData()
        #expect(!service.storeNeedsReset)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
    }

    @Test func failedBookmarkDoesNotUseOldPath() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let item = ShelfItem(
            name: "Reference", payload: .file(fixture.file, bookmark: Data([0])), now: Date(), expiry: .oneHour)
        try fixture.store.save(items: [item], expiry: .oneHour)
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        #expect(service.fileStates[item.id] == .inaccessible)
        #expect(service.fileURL(for: item) == nil)
        #expect(service.dragWriter(for: item) == nil)
        #expect(access.begins == 0)
        await service.shutdown()
    }

    @Test func textAndItemLimits() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let service = ShelfService(store: fixture.store)
        service.start()
        #expect(throws: ShelfFailure.tooLarge) {
            try service.addText(String(repeating: "x", count: ShelfLimits.textBytes + 1))
        }
        #expect(throws: ShelfFailure.unsupported) { try service.addLink(URL(string: "javascript:alert(1)")!) }
        for _ in 0..<ShelfLimits.items { try service.addText("Item") }
        #expect(throws: ShelfFailure.full) { try service.addText("One too many") }
        await service.shutdown()
    }

    @Test func boundedReadsRejectExcessAndSpecialFiles() throws {
        let fixture = try ShelfFixture(bytes: Data(repeating: 0x42, count: ShelfLimits.chunkBytes * 2))
        defer { fixture.remove() }
        #expect(throws: ShelfFailure.tooLarge) { try ShelfIO.readBounded(fixture.file, limit: 100) }
        let output = fixture.root.appendingPathComponent("partial")
        #expect(throws: ShelfFailure.tooLarge) { try ShelfIO.copyBounded(from: fixture.file, to: output, limit: 100) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let fifo = fixture.root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ShelfFailure.unsupported) { try ShelfIO.readBounded(fifo, limit: 100) }
        #expect(throws: ShelfFailure.unsupported) { try ShelfIO.checksum(fifo, access: NativeShelfFileAccess()) }
    }

    @Test func streamingChecksumAndCancellationBalanceAccess() throws {
        let fixture = try ShelfFixture(bytes: Data(repeating: 0x42, count: ShelfLimits.chunkBytes * 3 + 7))
        defer { fixture.remove() }
        let access = ShelfAccessSpy()
        let expected = SHA256.hash(data: try Data(contentsOf: fixture.file)).map { String(format: "%02x", $0) }.joined()
        #expect(try ShelfIO.checksum(fixture.file, access: access) == expected)
        var calls = 0
        #expect(throws: ShelfFailure.cancelled) {
            try ShelfIO.checksum(fixture.file, access: access) {
                calls += 1
                return calls > 1
            }
        }
        #expect(access.begins == 2)
        #expect(access.ends == 2)
    }

    @Test func checksumDetectsReplacementDuringRead() throws {
        let fixture = try ShelfFixture(bytes: Data(repeating: 0x41, count: ShelfLimits.chunkBytes * 3))
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent("replacement")
        try Data(repeating: 0x41, count: ShelfLimits.chunkBytes * 3).write(to: replacement)
        var count = 0
        #expect(throws: ShelfFailure.changedDuringRead) {
            try ShelfIO.checksum(fixture.file, access: NativeShelfFileAccess()) {
                count += 1
                if count == 2 { #expect(rename(replacement.path, fixture.file.path) == 0) }
                return false
            }
        }
    }

    @Test func missingAndCloudStatesBlockDragAndChecksum() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        try service.addFile(fixture.file)
        let item = try #require(service.items.first)
        #expect(service.dragWriter(for: item) != nil)
        access.setState(.cloudOnly)
        #expect(service.dragWriter(for: item) == nil)
        #expect(service.fileStates[item.id] == .cloudOnly)
        #expect(throws: ShelfFailure.cloudOnly) { try ShelfIO.checksum(fixture.file, access: access) }
        access.setState(nil)
        try FileManager.default.removeItem(at: fixture.file)
        #expect(service.prepareFileAction(item) == nil)
        #expect(service.fileStates[item.id] == .missing)
        await service.shutdown()
        #expect(access.begins == access.ends)
    }

    @Test func concurrentPauseAndShutdownDrainChecksum() async throws {
        let fixture = try ShelfFixture(bytes: Data(repeating: 0, count: 8 * 1024 * 1024))
        defer { fixture.remove() }
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        try service.addFile(fixture.file)
        let item = try #require(service.items.first)
        service.checksum(item.id)
        async let first: Void = service.pause()
        async let second: Void = service.shutdown()
        _ = await (first, second)
        #expect(!service.isRunning)
        #expect(!service.isStopping)
        #expect(service.items.isEmpty)
        #expect(access.begins == access.ends)
    }

    @Test func pauseClearsCalculatingStateAndRestartBalancesScope() async throws {
        let fixture = try ShelfFixture(bytes: Data(repeating: 0, count: 1024 * 1024))
        defer { fixture.remove() }
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        try service.addFile(fixture.file)
        let item = try #require(service.items.first)
        service.checksum(item.id)
        await service.pause()
        #expect(service.checksums[item.id] != .calculating)
        #expect(access.begins == access.ends)
        service.start()
        #expect(service.items.count == 1)
        await service.shutdown()
        #expect(access.begins == access.ends)
    }

    @Test func missingCacheRemainsAVisibleMissingItem() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let name = "shelf-item-\(UUID().uuidString).png"
        _ = try fixture.store.cacheURL(named: name)
        let item = ShelfItem(name: "Missing image", payload: .cachedFile(name), now: Date(), expiry: .oneHour)
        try fixture.store.save(items: [item], expiry: .oneHour)
        try FileManager.default.removeItem(at: fixture.store.cache)
        let service = ShelfService(store: fixture.store)
        service.start()
        #expect(!service.storeNeedsReset)
        #expect(service.items.count == 1)
        #expect(service.fileStates[item.id] == .missing)
        await service.shutdown()
    }

    @Test func storePermissionsAndTraversal() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        try fixture.store.save(items: [], expiry: .oneHour)
        let rootMode =
            try FileManager.default.attributesOfItem(atPath: fixture.store.root.path)[.posixPermissions] as? Int
        let fileMode =
            try FileManager.default.attributesOfItem(atPath: fixture.store.manifest.path)[.posixPermissions] as? Int
        #expect(rootMode == 0o700)
        #expect(fileMode == 0o600)
        #expect(throws: ShelfFailure.invalidStore) { try fixture.store.cacheURL(named: "../original.txt") }
    }

    @Test func realFoundationFileURLRoundTrip() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let provider = NSItemProvider(object: fixture.file as NSURL)
        let result = try await ShelfDropImporter.load(provider, store: fixture.store)
        guard case .file(let url) = result else {
            Issue.record("File drop did not retain a file reference")
            return
        }
        #expect(url == fixture.file)
        #expect(try Data(contentsOf: url) == Data("abc".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.cache.path))
    }

    @Test func realFoundationLinkAndTextRoundTrip() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let link = URL(string: "https://example.com/shelf")!
        let linkResult = try await ShelfDropImporter.load(NSItemProvider(object: link as NSURL), store: fixture.store)
        guard case .link(let result) = linkResult else {
            Issue.record("Link drop was not a link")
            return
        }
        #expect(result == link)
        let textResult = try await ShelfDropImporter.load(
            NSItemProvider(object: "A short note" as NSString), store: fixture.store)
        guard case .text(let text) = textResult else {
            Issue.record("Text drop was not text")
            return
        }
        #expect(text == "A short note")
    }

    @Test func imageRepresentationAndFrameBound() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let pixels = [UInt8](repeating: 0xFF, count: 4 * 4 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.data?.copyMemory(from: pixels, byteCount: pixels.count)
        let image = try #require(context.makeImage())
        let png = fixture.root.appendingPathComponent("image.png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all)
        { completion in
            completion(png, false, nil)
            return nil
        }
        let result = try await ShelfDropImporter.load(provider, store: fixture.store)
        guard case .cachedFile(let name) = result else {
            Issue.record("Image drop did not create an owned copy")
            return
        }
        let cached = try fixture.store.cacheURL(named: name)
        #expect(try Data(contentsOf: cached) == Data(contentsOf: png))
        let gif = fixture.root.appendingPathComponent("animated.gif")
        let animation = try #require(
            CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 101, nil))
        for _ in 0..<101 { CGImageDestinationAddImage(animation, image, nil) }
        #expect(CGImageDestinationFinalize(animation))
        #expect(throws: ShelfFailure.invalidImage) { try ShelfIO.validateImage(at: gif) }
    }

    @Test func cancelImportsThenShutdownWaitsForRunningImport() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let gate = ShelfAsyncGate()
        let name = "shelf-item-\(UUID().uuidString).png"
        try fixture.store.prepareCache()
        let cached = try fixture.store.cacheURL(named: name)
        let service = ShelfService(
            store: fixture.store,
            importer: { _, store in
                try store.prepareCache()
                try Data("controlled import".utf8).write(to: cached)
                await gate.wait()
                return .cachedFile(name)
            })
        service.start()
        #expect(service.importDrops([NSItemProvider()]))
        await gate.waitUntilEntered()
        let cancel = Task { await service.cancelImports() }
        await Task.yield()
        var stopped = false
        let shutdown = Task {
            await service.shutdown()
            stopped = true
        }
        await Task.yield()
        await Task.yield()
        #expect(!stopped)
        #expect(FileManager.default.fileExists(atPath: cached.path))
        await gate.resume()
        await cancel.value
        await shutdown.value
        #expect(stopped)
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(service.items.isEmpty)
    }

    @Test func clearBlocksNewImportsAndPauseJoinsClear() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let gate = ShelfAsyncGate()
        let service = ShelfService(
            store: fixture.store,
            importer: { _, _ in
                await gate.wait()
                return .text("Late result")
            })
        service.start()
        #expect(service.importDrops([NSItemProvider()]))
        await gate.waitUntilEntered()
        let clear = Task { await service.clear() }
        await Task.yield()
        #expect(service.isClearing)
        #expect(!service.importDrops([NSItemProvider()]))
        #expect(throws: ShelfFailure.stopped) { try service.addText("Concurrent add") }
        var paused = false
        let pause = Task {
            await service.pause()
            paused = true
        }
        await Task.yield()
        #expect(!paused)
        await gate.resume()
        await clear.value
        await pause.value
        #expect(service.items.isEmpty)
        #expect(!service.isClearing)
        #expect(!service.isRunning)
        await service.shutdown()
    }

    @Test func removingHashKeepsWorkerVisibleToPause() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let access = ShelfBlockingAccess()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        try service.addFile(fixture.file)
        let item = try #require(service.items.first)
        service.checksum(item.id)
        let blocked = await Task.detached { access.waitUntilBlocked() }.value
        #expect(blocked)
        let removal = Task { await service.remove(item.id) }
        await Task.yield()
        var paused = false
        let pause = Task {
            await service.pause()
            paused = true
        }
        await Task.yield()
        await Task.yield()
        #expect(!paused)
        access.resume()
        await removal.value
        await pause.value
        #expect(paused)
        #expect(access.balanced)
        #expect(service.items.isEmpty)
        await service.shutdown()
    }

    @Test func cancellingWaitingProviderFinishesWithoutCallback() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all)
        { _ in Progress(totalUnitCount: 1) }
        let service = ShelfService(store: fixture.store)
        service.start()
        #expect(service.importDrops([provider]))
        await Task.yield()
        await service.pause()
        #expect(service.importCount == 0)
        #expect(service.items.isEmpty)
        #expect(!service.isRunning)
        await service.shutdown()
    }
}
