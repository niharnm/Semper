import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Observation
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

nonisolated private final class ShelfAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func resolve(_ result: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: result)
    }

    func wait(timeout: DispatchTimeInterval = .seconds(30)) async -> Bool {
        let watchdog = DispatchWorkItem { self.resolve(false) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        let received = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result: Bool? = lock.withLock {
                    if let result = self.result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(returning: result) }
            }
        } onCancel: {
            self.resolve(false)
        }
        return received && !Task.isCancelled
    }
}

nonisolated private final class ShelfBlockingAccess: ShelfFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = ShelfAsyncSignal()
    private let release = DispatchSemaphore(value: 0)
    private let cancelled = ShelfAsyncSignal()
    private var watchdog: DispatchWorkItem?
    private var released = false
    private var expired = false
    private var count = 0
    private var ended = 0
    var balanced: Bool { lock.withLock { count == ended } }
    var timedOut: Bool { lock.withLock { expired } }

    init(timeout: DispatchTimeInterval = .seconds(30)) {
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let shouldExpire = self.lock.withLock {
                guard !self.released else { return false }
                self.expired = true
                return true
            }
            if shouldExpire { self.resume() }
        }
        self.watchdog = watchdog
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    }

    func begin(_ url: URL) -> Bool {
        let shouldBlock = lock.withLock {
            count += 1
            return count > 1
        }
        if shouldBlock {
            entered.resolve(true)
            var reportedCancellation = false
            while !lock.withLock({ released }) {
                _ = release.wait(timeout: .now() + 0.005)
                if Task.isCancelled, !reportedCancellation {
                    reportedCancellation = true
                    cancelled.resolve(true)
                }
            }
        }
        return true
    }
    func waitUntilBlocked() async -> Bool {
        await withTaskCancellationHandler {
            await entered.wait()
        } onCancel: {
            self.resume()
        }
    }
    func waitUntilCancelled() async -> Bool {
        await withTaskCancellationHandler {
            await cancelled.wait()
        } onCancel: {
            self.resume()
        }
    }
    func resume() {
        watchdog?.cancel()
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        entered.resolve(false)
        cancelled.resolve(false)
        if shouldRelease { release.signal() }
    }
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
    @Test func checksumSignalRetainsArrivalBeforeWaiting() async {
        let signal = ShelfAsyncSignal()
        signal.resolve(true)
        signal.resolve(false)
        #expect(await signal.wait())
    }

    @Test func checksumSignalHandlesCancellationBeforeWaiting() async {
        let signal = ShelfAsyncSignal()
        let waiting = Task { await signal.wait() }
        waiting.cancel()
        #expect(!(await waiting.value))
        signal.resolve(true)
        #expect(!(await signal.wait()))
    }

    @Test func checksumSignalTimesOutWithoutArrival() async {
        let signal = ShelfAsyncSignal()
        #expect(!(await signal.wait(timeout: .nanoseconds(0))))
        signal.resolve(true)
        #expect(!(await signal.wait()))
    }

    @Test func checksumWatchdogReleasesLateFileAccess() async {
        let access = ShelfBlockingAccess(timeout: .nanoseconds(0))
        defer { access.resume() }
        #expect(!(await access.waitUntilBlocked()))
        #expect(!(await access.waitUntilCancelled()))
        #expect(access.timedOut)
        let completed = ShelfAsyncSignal()
        DispatchQueue.global().async {
            let file = URL(fileURLWithPath: "/unused-shelf-fixture")
            for _ in 0..<3 {
                if access.begin(file) { access.end(file) }
            }
            completed.resolve(true)
        }
        #expect(await completed.wait())
        #expect(access.balanced)
    }

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
        defer { access.resume() }
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
        var expiration: Task<Void, Never>?
        do {
            service.checksum(item.id)
            let blocked = await access.waitUntilBlocked()
            try #require(blocked)
            clock.advance(900)
            let drainingExpiration = Task { await service.expireItems() }
            expiration = drainingExpiration
            let draining = await access.waitUntilCancelled()
            try #require(draining)
            service.setExpiry(.oneHour, for: item.id)
            access.resume()
            await drainingExpiration.value
            #expect(service.items.count == 1)
            #expect(service.items.first?.expiry == .oneHour)
            #expect(service.checksums[item.id] == .cancelled)
            #expect(FileManager.default.fileExists(atPath: cached.path))
            if FileManager.default.fileExists(atPath: cached.path) {
                #expect(try Data(contentsOf: cached) == image)
            }
        } catch {
            access.resume()
            await expiration?.value
            await service.shutdown()
            #expect(access.balanced)
            throw error
        }
        await service.shutdown()
        #expect(access.balanced)
        #expect(!access.timedOut)
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
        let cached = try fixture.store.cacheURL(named: "shelf-item-\(UUID().uuidString).png")
        let ownedImage = Data("image retained with unreadable manifest".utf8)
        try ownedImage.write(to: cached)
        let service = ShelfService(store: fixture.store)
        service.start()
        #expect(service.storeNeedsReset)
        #expect(throws: ShelfFailure.invalidStore) { try service.addText("Never saved") }
        service.setPersistence(true)
        service.setDefaultExpiry(.oneHour)
        _ = await service.cancelImports()
        let clear = await service.clear()
        #expect(throws: ShelfFailure.invalidStore) { try clear.get() }
        await service.pause()
        #expect(try Data(contentsOf: cached) == ownedImage)
        await service.shutdown()
        #expect(try Data(contentsOf: fixture.store.manifest) == original)
        #expect(try Data(contentsOf: cached) == ownedImage)
        await service.resetSavedData()
        #expect(!service.storeNeedsReset)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
        #expect(!FileManager.default.fileExists(atPath: cached.path))
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
        async let first = service.pause()
        async let second = service.shutdown()
        let results = await (first, second)
        try results.0.get()
        try results.1.get()
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
        if case .failure(let error) = await cancel.value { Issue.record(error) }
        await shutdown.value
        #expect(stopped)
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(service.items.isEmpty)
    }

    @Test(arguments: [false, true])
    func clearRetainsItemsWhenManifestWriteFails(throughCommand: Bool) async throws {
        let fixture = try ShelfFixture()
        defer {
            if FileManager.default.fileExists(atPath: fixture.store.manifest.path) {
                do {
                    try FileManager.default.setAttributes(
                        [.immutable: false], ofItemAtPath: fixture.store.manifest.path)
                } catch { Issue.record(error) }
            }
            fixture.remove()
        }
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        service.setDefaultExpiry(.oneHour)
        try service.addText("Retained note")
        try service.addLink(try #require(URL(string: "https://example.com/retained")))
        try service.addFile(fixture.file)
        service.setPersistence(true)
        try #require(service.persistenceEnabled)
        let retained = service.items
        let manifest = try Data(contentsOf: fixture.store.manifest)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fixture.store.manifest.path)

        var opened = false
        let handler = ShelfCommandHandler(service: service, openDetail: { opened = true })
        let result = throughCommand ? await handler.execute(.clear) : await service.clear()

        #expect(throws: ShelfFailure.storeWrite) { try result.get() }
        #expect(!opened)
        #expect(service.items == retained)
        #expect(!service.isClearing)
        #expect(try Data(contentsOf: fixture.store.manifest) == manifest)
        #expect(try Data(contentsOf: fixture.file) == Data("abc".utf8))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.store.manifest.path)
        let reloaded = ShelfService(store: fixture.store, access: access)
        reloaded.start()
        #expect(reloaded.items == retained)
        await reloaded.shutdown()
        service.report(ShelfFailure.missing)
        try await handler.execute(.clear).get()
        #expect(service.message == ShelfFailure.missing.localizedDescription)
        #expect(service.items.isEmpty)
        #expect(try fixture.store.load()?.items.isEmpty == true)
        #expect(try Data(contentsOf: fixture.file) == Data("abc".utf8))
        try await handler.execute(.open).get()
        #expect(opened)
        await service.shutdown()
        #expect(access.begins == access.ends)
    }

    @Test func clearSessionOnlyDoesNotCreateManifest() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        try service.addFile(fixture.file)
        try service.addText("Session note")
        try await service.clear().get()
        #expect(service.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
        #expect(try Data(contentsOf: fixture.file) == Data("abc".utf8))
        await service.shutdown()
        #expect(access.begins == access.ends)
    }

    @Test func failedSavedDataResetRemainsAvailable() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        try fixture.store.prepareCache()
        try Data("invalid manifest".utf8).write(to: fixture.store.manifest)
        try FileManager.default.removeItem(at: fixture.store.cache)
        try Data("cache obstacle".utf8).write(to: fixture.store.cache)
        let service = ShelfService(store: fixture.store)
        service.start()
        try #require(service.storeNeedsReset)
        let result = await service.clear()
        #expect(throws: ShelfFailure.invalidStore) { try result.get() }
        #expect(try Data(contentsOf: fixture.store.manifest) == Data("invalid manifest".utf8))
        await service.resetSavedData()
        #expect(service.storeNeedsReset)
        #expect(service.message != nil)
        try FileManager.default.removeItem(at: fixture.store.cache)
        try fixture.store.prepareCache()
        await service.resetSavedData()
        #expect(!service.storeNeedsReset)
        #expect(service.message == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
        await service.shutdown()
    }

    @Test func clearReportsOwnedCopyRemovalFailure() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let name = "shelf-item-\(UUID().uuidString).png"
        let cached = try fixture.store.cacheURL(named: name)
        let item = ShelfItem(name: "Owned image", payload: .cachedFile(name), now: Date(), expiry: .oneHour)
        let firstName = "shelf-item-\(UUID().uuidString).png"
        let firstCached = try fixture.store.cacheURL(named: firstName)
        let firstItem = ShelfItem(name: "First image", payload: .cachedFile(firstName), now: Date(), expiry: .oneHour)
        try fixture.store.save(items: [firstItem, item], expiry: .oneHour)
        try Data("first image".utf8).write(to: firstCached)
        try Data("owned image".utf8).write(to: cached)
        let access = ShelfAccessSpy()
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        try FileManager.default.removeItem(at: cached)
        try FileManager.default.createSymbolicLink(at: cached, withDestinationURL: fixture.file)
        let result = await service.clear()
        #expect(throws: ShelfFailure.storeWrite) { try result.get() }
        #expect(service.items == [firstItem, item])
        #expect(!FileManager.default.fileExists(atPath: firstCached.path))
        #expect(access.ends == 0)
        #expect(!service.isClearing)
        #expect(try Data(contentsOf: fixture.file) == Data("abc".utf8))
        try FileManager.default.removeItem(at: cached)
        try Data("owned image".utf8).write(to: cached)
        try await service.clear().get()
        #expect(service.message == nil)
        #expect(service.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        await service.shutdown()
        #expect(access.begins == access.ends)
    }

    @Test func coalescedClearReturnsSharedFailureAfterCancelledWaiter() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let entered = ShelfAsyncSignal()
        let release = ShelfAsyncSignal()
        let importerHold = Task.detached { await release.wait() }
        defer { release.resolve(true) }
        let service = ShelfService(
            store: fixture.store,
            importer: { _, _ in
                entered.resolve(true)
                _ = await importerHold.value
                return .text("Cancelled import")
            })
        service.start()
        service.setDefaultExpiry(.oneHour)
        try service.addText("Retained note")
        service.setPersistence(true)
        let retained = service.items
        try FileManager.default.removeItem(at: fixture.store.cache)
        try Data("cache obstacle".utf8).write(to: fixture.store.cache)
        #expect(service.importDrops([NSItemProvider()]))
        let arrived = await entered.wait()
        if !arrived {
            release.resolve(true)
            await service.shutdown()
        }
        try #require(arrived)
        let firstEntered = ShelfAsyncSignal()
        let first = Task {
            firstEntered.resolve(true)
            return await service.clear()
        }
        #expect(await firstEntered.wait())
        let secondEntered = ShelfAsyncSignal()
        let second = Task {
            secondEntered.resolve(true)
            return await ShelfCommandHandler(service: service, openDetail: {}).execute(.clear)
        }
        #expect(await secondEntered.wait())
        #expect(service.isClearing)
        service.setPersistence(false)
        #expect(service.persistenceEnabled)
        await service.remove(retained[0].id)
        #expect(service.items == retained)
        first.cancel()
        release.resolve(true)
        #expect(await importerHold.value)
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(throws: ShelfFailure.storeWrite) { try firstResult.get() }
        #expect(throws: ShelfFailure.storeWrite) { try secondResult.get() }
        #expect(service.items == retained)
        #expect(!service.isClearing)
        #expect(service.importCount == 0)
        try FileManager.default.removeItem(at: fixture.store.cache)
        try fixture.store.prepareCache()
        await service.resetSavedData()
        #expect(service.items.isEmpty)
        #expect(!service.persistenceEnabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.manifest.path))
        await service.shutdown()
    }

    @Test(arguments: [false, true])
    func clearRetriesFailedCancelledImageImportCleanup(withExistingItems: Bool) async throws {
        let fixture = try ShelfFixture()
        let name = "shelf-item-\(UUID().uuidString).png"
        let cached = try fixture.store.cacheURL(named: name)
        defer {
            if FileManager.default.fileExists(atPath: cached.path) {
                do {
                    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: cached.path)
                } catch { Issue.record(error) }
            }
            fixture.remove()
        }
        let entered = ShelfAsyncSignal()
        let release = ShelfAsyncSignal()
        let importerHold = Task.detached { await release.wait() }
        defer { release.resolve(true) }
        let image = Data("held image".utf8)
        let access = ShelfBlockingAccess()
        defer { access.resume() }
        let service = ShelfService(
            store: fixture.store, access: access,
            importer: { _, store in
                try store.prepareCache()
                try image.write(to: cached)
                try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: cached.path)
                entered.resolve(true)
                _ = await importerHold.value
                return .cachedFile(name)
            })
        service.start()
        if withExistingItems {
            service.setDefaultExpiry(.oneHour)
            try service.addText("Retained note")
            try service.addFile(fixture.file)
            service.setPersistence(true)
            let file = try #require(service.items.last)
            service.checksum(file.id)
            let blocked = await access.waitUntilBlocked()
            if !blocked {
                access.resume()
                await service.shutdown()
            }
            try #require(blocked)
        }
        let retained = service.items
        let manifest = withExistingItems ? try Data(contentsOf: fixture.store.manifest) : nil
        #expect(service.importDrops([NSItemProvider()]))
        let arrived = await entered.wait()
        if !arrived {
            release.resolve(true)
            access.resume()
            await service.shutdown()
        }
        try #require(arrived)
        let handler = ShelfCommandHandler(service: service, openDetail: {})
        let clearEntered = ShelfAsyncSignal()
        let clear = Task {
            clearEntered.resolve(true)
            return await handler.execute(.clear)
        }
        #expect(await clearEntered.wait())
        release.resolve(true)
        #expect(await importerHold.value)
        if withExistingItems {
            #expect(await access.waitUntilCancelled())
            access.resume()
        }
        let failed = await clear.value
        #expect(throws: ShelfFailure.storeWrite) { try failed.get() }
        #expect(service.items == retained)
        #expect(service.canClear)
        #expect(service.importCount == 0)
        #expect(try Data(contentsOf: cached) == image)
        if let manifest { #expect(try Data(contentsOf: fixture.store.manifest) == manifest) }
        #expect(!service.importDrops([NSItemProvider()]))
        let retryFailed = await handler.execute(.clear)
        #expect(throws: ShelfFailure.storeWrite) { try retryFailed.get() }
        #expect(service.canClear)
        #expect(!service.importDrops([NSItemProvider()]))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: cached.path)
        try await handler.execute(.clear).get()
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(!service.canClear)
        #expect(service.items.isEmpty)
        #expect(service.message == nil)
        if withExistingItems { #expect(try fixture.store.load()?.items.isEmpty == true) }
        await service.shutdown()
        #expect(access.balanced)
    }

    @Test(arguments: [false, true])
    func clearFindsFailedProviderCopyWithoutReturnedPayload(cancelBeforeFinish: Bool) async throws {
        let fixture = try ShelfFixture()
        var cached: URL?
        defer {
            if let cached, FileManager.default.fileExists(atPath: cached.path) {
                do {
                    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: cached.path)
                } catch { Issue.record(error) }
            }
            fixture.remove()
        }
        let finished = ShelfAsyncSignal()
        var fixtureFailure: Error?
        let service = ShelfService(
            store: fixture.store,
            importer: { _, store in
                let request = ShelfProviderRequest()
                return try await withCheckedThrowingContinuation { continuation in
                    guard request.install(continuation), request.beginProcessing() else { return }
                    var checks = 0
                    let result = Result {
                        try ShelfDropImporter.readRepresentation(
                            fixture.file, kind: .image("png"), store: store,
                            cancelled: {
                                checks += 1
                                if checks == 2 {
                                    do {
                                        let files = try FileManager.default.contentsOfDirectory(
                                            at: store.cache, includingPropertiesForKeys: nil)
                                        let copy = try #require(files.first)
                                        cached = copy
                                        try FileManager.default.setAttributes(
                                            [.immutable: true], ofItemAtPath: copy.path)
                                    } catch { fixtureFailure = error }
                                }
                                return false
                            })
                    }
                    if cancelBeforeFinish { request.cancel() }
                    request.finish(result, store: store)
                    finished.resolve(true)
                }
            })
        service.start()
        #expect(service.importDrops([NSItemProvider()]))
        #expect(await finished.wait())
        let drained = await service.cancelImports()
        #expect(fixtureFailure == nil)
        #expect(throws: ShelfFailure.storeWrite) { try drained.get() }
        let copy = try #require(cached)
        #expect(try Data(contentsOf: copy) == Data("abc".utf8))
        #expect(service.items.isEmpty)
        #expect(service.canClear)
        let handler = ShelfCommandHandler(service: service, openDetail: {})
        let failed = await handler.execute(.clear)
        #expect(throws: ShelfFailure.storeWrite) { try failed.get() }
        #expect(FileManager.default.fileExists(atPath: copy.path))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: copy.path)
        try await handler.execute(.clear).get()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(!service.canClear)
        await service.shutdown()
    }

    @Test func overlappingImportCancellationBlocksDropWhenWorkerFinishes() async throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let entered = ShelfAsyncSignal()
        let release = ShelfAsyncSignal()
        let importerHold = Task.detached { await release.wait() }
        defer { release.resolve(true) }
        let service = ShelfService(
            store: fixture.store,
            importer: { _, _ in
                entered.resolve(true)
                _ = await importerHold.value
                return .text("Cancelled import")
            })
        service.start()
        #expect(service.importDrops([NSItemProvider()]))
        let arrived = await entered.wait()
        if !arrived {
            release.resolve(true)
            await service.shutdown()
        }
        try #require(arrived)
        let firstEntered = ShelfAsyncSignal()
        let first = Task {
            firstEntered.resolve(true)
            return await service.cancelImports()
        }
        #expect(await firstEntered.wait())
        let secondEntered = ShelfAsyncSignal()
        let second = Task {
            secondEntered.resolve(true)
            return await service.cancelImports()
        }
        #expect(await secondEntered.wait())
        let attempted = ShelfAsyncSignal()
        let accepted = ShelfAsyncSignal()
        withObservationTracking {
            _ = service.importCount
        } onChange: {
            MainActor.assumeIsolated {
                accepted.resolve(service.importDrops([NSItemProvider()]))
                attempted.resolve(true)
            }
        }
        release.resolve(true)
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(await importerHold.value)
        #expect(await attempted.wait())
        #expect(!(await accepted.wait()))
        try firstResult.get()
        try secondResult.get()
        #expect(service.importCount == 0)
        #expect(service.importDrops([NSItemProvider()]))
        try await service.cancelImports().get()
        await service.shutdown()
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
        if case .failure(let error) = await clear.value { Issue.record(error) }
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
        defer { access.resume() }
        let service = ShelfService(store: fixture.store, access: access)
        service.start()
        var removal: Task<Void, Never>?
        var pause: Task<Void, Never>?
        do {
            try service.addFile(fixture.file)
            let item = try #require(service.items.first)
            service.checksum(item.id)
            let blocked = await access.waitUntilBlocked()
            try #require(blocked)
            let drainingRemoval = Task { await service.remove(item.id) }
            removal = drainingRemoval
            let draining = await access.waitUntilCancelled()
            try #require(draining)
            let pauseEntered = ShelfAsyncSignal()
            var paused = false
            let drainingPause = Task {
                pauseEntered.resolve(true)
                await service.pause()
                paused = true
            }
            pause = drainingPause
            let pausing = await pauseEntered.wait()
            try #require(pausing)
            #expect(!paused)
            access.resume()
            await drainingRemoval.value
            await drainingPause.value
            #expect(paused)
            #expect(access.balanced)
            #expect(service.items.isEmpty)
        } catch {
            access.resume()
            await removal?.value
            await pause?.value
            await service.shutdown()
            #expect(access.balanced)
            throw error
        }
        await service.shutdown()
        #expect(!access.timedOut)
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
