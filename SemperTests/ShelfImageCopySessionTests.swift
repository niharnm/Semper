import AppKit
import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import Observation
import Testing
import UniformTypeIdentifiers

@testable import Semper

nonisolated private final class ImageSessionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    var isResolved: Bool { lock.withLock { value != nil } }

    func resolve(_ value: Bool = true) {
        let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard self.value == nil else { return nil }
            self.value = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let value = lock.withLock { () -> Bool? in
                    if let value = self.value { return value }
                    self.continuation = continuation
                    return nil
                }
                if let value { continuation.resume(returning: value) }
            }
        } onCancel: {
            self.resolve(false)
        }
    }
}

nonisolated private final class ImageSessionGate: @unchecked Sendable {
    let entered = ImageSessionSignal()
    private let condition = NSCondition()
    private var released: Bool
    private var cancelled = false
    var observedCancellation: Bool { condition.withLock { cancelled } }

    init(held: Bool) { released = !held }
    func wait() {
        entered.resolve()
        condition.lock()
        while !released { condition.wait() }
        cancelled = Task.isCancelled
        condition.unlock()
    }
    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

nonisolated private final class ImageSessionAccess: ShelfFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var scopes: [URL: Int] = [:]
    var balanced: Bool { lock.withLock { scopes.values.allSatisfy { $0 == 0 } } }
    func active(_ url: URL) -> Int { lock.withLock { scopes[url, default: 0] } }
    func begin(_ url: URL) -> Bool {
        lock.withLock { scopes[url, default: 0] += 1 }
        return true
    }
    func end(_ url: URL) { lock.withLock { scopes[url, default: 0] -= 1 } }
    func state(of url: URL) -> ShelfFileState { .available(isDirectory: false) }
    func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) throws -> URL { URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)) }
}

nonisolated private final class ImageSessionCopier: ShelfImageCopying, @unchecked Sendable {
    let inspection: ImageSessionGate
    let writing: ImageSessionGate
    let plan: ShelfImageCopyPlan
    let temporary: ShelfImageTemporaryCopy
    private let lock = NSLock()
    private var writeCount = 0
    private var removed: [ShelfImageTemporaryCopy] = []
    private var cleanupFailure = false
    private var recoveryFailure = true
    private var recoveryCount = 0
    private var acknowledgementCount = 0
    let failWrite: Bool
    let uncertainPublication: Bool
    let recoveredOutput: URL
    var writes: Int { lock.withLock { writeCount } }
    var recoveries: Int { lock.withLock { recoveryCount } }
    var acknowledgements: Int { lock.withLock { acknowledgementCount } }
    var cleanupTokens: [ShelfImageTemporaryCopy] { lock.withLock { removed } }
    var failCleanup: Bool {
        get { lock.withLock { cleanupFailure } }
        set { lock.withLock { cleanupFailure = newValue } }
    }
    var failRecovery: Bool {
        get { lock.withLock { recoveryFailure } }
        set { lock.withLock { recoveryFailure = newValue } }
    }

    init(
        plan: ShelfImageCopyPlan, root: URL, holdInspect: Bool, holdWrite: Bool, failWrite: Bool,
        uncertainPublication: Bool
    ) {
        self.plan = plan
        inspection = ImageSessionGate(held: holdInspect)
        writing = ImageSessionGate(held: holdWrite)
        self.failWrite = failWrite
        self.uncertainPublication = uncertainPublication
        recoveredOutput = root.appendingPathComponent("relocated-copy.png")
        temporary = ShelfImageTemporaryCopy(
            url: root.appendingPathComponent(".semper-image-copy-\(UUID()).tmp"), device: 7, inode: 11,
            parentDevice: 7, parentInode: 13)
    }

    func inspect(_ source: URL, access: any ShelfFileAccess) throws -> ShelfImageCopyPlan {
        let scoped = access.begin(source)
        defer { if scoped { access.end(source) } }
        inspection.wait()
        return plan
    }

    func writeCopy(_ plan: ShelfImageCopyPlan, size: ShelfImageCopySize, to destination: URL) throws
        -> ShelfImageCopyReceipt
    {
        lock.withLock { writeCount += 1 }
        writing.wait()
        if failWrite {
            try Data("owned stage".utf8).write(to: temporary.url)
            throw ShelfImageCopyFailure.cleanupFailed(temporary)
        }
        if uncertainPublication {
            try Data("published copy".utf8).write(to: recoveredOutput)
            throw ShelfImageCopyFailure.publicationUncertain(
                ShelfImagePublishedCopy(requestedURL: destination, dimensions: plan.outputDimensions(for: size)))
        }
        try Data("published copy".utf8).write(to: destination)
        return ShelfImageCopyReceipt(url: destination, dimensions: plan.outputDimensions(for: size))
    }

    func recoverPublishedCopy(_ published: ShelfImagePublishedCopy) throws -> ShelfImageCopyReceipt {
        lock.withLock { recoveryCount += 1 }
        if failRecovery { throw ShelfImageCopyFailure.publicationUncertain(published) }
        return ShelfImageCopyReceipt(url: recoveredOutput, dimensions: published.dimensions)
    }

    func acknowledgeUnverifiedCopy(_ published: ShelfImagePublishedCopy) throws {
        lock.withLock { acknowledgementCount += 1 }
        if failCleanup { throw ShelfImageCopyFailure.publicationUncertain(published) }
    }

    func removeTemporaryCopy(_ temporary: ShelfImageTemporaryCopy) throws {
        lock.withLock { removed.append(temporary) }
        guard temporary == self.temporary else { throw ShelfImageCopyFailure.invalidTemporaryCopy }
        if failCleanup { throw ShelfImageCopyFailure.cleanupFailed(temporary) }
        try FileManager.default.removeItem(at: temporary.url)
    }
}

@MainActor
private final class ImageSessionChooser: ShelfImageDestinationChoosing {
    private(set) var calls = 0
    private(set) var cancellations = 0
    var destination: URL?
    var held = false
    var entered = ImageSessionSignal()
    var release = ImageSessionSignal()

    func chooseDestination(for plan: ShelfImageCopyPlan, size: ShelfImageCopySize) async -> URL? {
        calls += 1
        entered.resolve()
        if held {
            let release = release
            let waiting = Task.detached { await release.wait() }
            _ = await waiting.value
        }
        return destination
    }
    func cancel() { cancellations += 1 }
    func reset(destination: URL?, held: Bool) {
        self.destination = destination
        self.held = held
        entered = ImageSessionSignal()
        release = ImageSessionSignal()
    }
}

@MainActor
private final class ImageSessionIdle {
    let session: ShelfImageCopySession
    let finished = ImageSessionSignal()
    private var observing = true
    init(_ session: ShelfImageCopySession) { self.session = session }
    func wait() async -> Bool {
        observe()
        let value = await finished.wait()
        observing = false
        return value
    }
    private func observe() {
        guard observing else { return }
        let idle = withObservationTracking {
            !session.isWorking
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        if idle { finished.resolve() }
    }
}

nonisolated private final class ImageSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@MainActor
private final class ImageExpiryScheduler {
    private(set) var delays: [TimeInterval] = []
    private var releases: [ImageSessionSignal] = []
    private var observers: [(Int, ImageSessionSignal)] = []

    func wait(_ delay: TimeInterval) async throws {
        try Task.checkCancellation()
        let release = ImageSessionSignal()
        delays.append(delay)
        releases.append(release)
        for (count, signal) in observers where delays.count >= count { signal.resolve() }
        guard await release.wait(), !Task.isCancelled else { throw CancellationError() }
    }

    func scheduled(_ count: Int) async -> Bool {
        if delays.count >= count { return true }
        let signal = ImageSessionSignal()
        observers.append((count, signal))
        return await signal.wait()
    }

    func fire(_ index: Int) { releases[index].resolve() }
}

@Suite("Shelf image copy session", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ShelfImageCopySessionTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let output: URL
        let access: ImageSessionAccess
        let copier: ImageSessionCopier
        let chooser: ImageSessionChooser
        let session: ShelfImageCopySession
        let service: ShelfService
    }

    private func withFixture(
        holdInspect: Bool = false, holdWrite: Bool = false, failWrite: Bool = false,
        uncertainPublication: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() },
        waitForExpiry: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        body: (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-image-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let source = root.appendingPathComponent("source.png")
        let output = root.appendingPathComponent("copy.png")
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let destination = try #require(
            CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let access = ImageSessionAccess()
        let plan = try NativeShelfImageCopier().inspect(source, access: access)
        let copier = ImageSessionCopier(
            plan: plan, root: root, holdInspect: holdInspect, holdWrite: holdWrite, failWrite: failWrite,
            uncertainPublication: uncertainPublication)
        let chooser = ImageSessionChooser()
        chooser.destination = output
        let session = ShelfImageCopySession(access: access, copier: copier, destinationChooser: chooser)
        let service = ShelfService(
            store: ShelfStore(root: root.appendingPathComponent("store")),
            access: access, now: now, waitForExpiry: waitForExpiry, imageCopy: session)
        service.start()
        let fixture = Fixture(
            root: root, source: source, output: output, access: access,
            copier: copier, chooser: chooser, session: session, service: service)
        let original = try Data(contentsOf: source)
        do { try await body(fixture) } catch {
            await finish(fixture)
            throw error
        }
        await finish(fixture)
        #expect(access.balanced)
        #expect(try Data(contentsOf: source) == original)
    }

    private func finish(_ f: Fixture) async {
        f.copier.inspection.release()
        f.copier.writing.release()
        f.copier.failCleanup = false
        f.copier.failRecovery = false
        f.chooser.release.resolve()
        await f.service.shutdown()
        if f.session.needsReceiptAcknowledgement, let requestID = f.session.request?.id {
            #expect(f.service.acknowledgeImageCopyReceipt(requestID: requestID))
            await f.service.shutdown()
        }
        if case .failure(let error) = await f.session.cancel() { Issue.record(error) }
    }

    private func begin(_ f: Fixture) async throws -> ShelfImageCopyRequest {
        let request = try #require(f.session.begin(itemID: UUID(), name: "source.png", source: f.source))
        try #require(await ImageSessionIdle(f.session).wait())
        try #require(f.session.plan != nil)
        return request
    }

    @Test("A held inspection owns the request and drains before cancellation returns")
    func heldInspection() async throws {
        try await withFixture(holdInspect: true) { f in
            let request = try #require(f.session.begin(itemID: UUID(), name: "source.png", source: f.source))
            try #require(await f.copier.inspection.entered.wait())
            #expect(f.session.isActive && f.session.isWorking)
            #expect(f.session.begin(itemID: UUID(), name: "second", source: f.source) == nil)
            #expect(!f.session.save(size: .pixels1024))
            let entered = ImageSessionSignal()
            let finished = ImageSessionSignal()
            let cancellation = Task { @MainActor in
                entered.resolve()
                defer { finished.resolve() }
                return await f.session.cancel(requestID: request.id)
            }
            try #require(await entered.wait())
            #expect(!finished.isResolved)
            #expect(f.access.active(f.source) == 1)
            f.copier.inspection.release()
            try await cancellation.value.get()
            #expect(f.copier.inspection.observedCancellation)
            #expect(!f.session.isActive)
            #expect(f.session.plan == nil && f.session.request == nil)
            #expect(f.access.balanced)
        }
    }

    @Test("A cancelled held dialog drains and ignores a late selected URL")
    func heldDialog() async throws {
        try await withFixture { f in
            _ = try await begin(f)
            f.chooser.reset(destination: f.output, held: true)
            try #require(f.session.save(size: .pixels1024))
            try #require(await f.chooser.entered.wait())
            f.session.stop()
            let finished = ImageSessionSignal()
            let cancelling = Task { @MainActor in
                defer { finished.resolve() }
                return await f.session.cancel()
            }
            #expect(f.session.isWorking)
            #expect(f.chooser.cancellations > 0)
            #expect(!finished.isResolved)
            #expect(!f.session.save(size: .pixels2048))
            f.chooser.release.resolve()
            try await cancelling.value.get()
            #expect(f.copier.writes == 0)
            #expect(f.session.receipt == nil && !f.session.isActive)
            #expect(f.access.active(f.output) == 0)
        }
    }

    @Test("Save dialog cancellation is silent and preserves options for another save")
    func dialogRetry() async throws {
        try await withFixture { f in
            let request = try await begin(f)
            f.chooser.destination = nil
            try #require(f.session.save(size: .pixels1024))
            #expect(!f.session.save(size: .pixels2048))
            try #require(await ImageSessionIdle(f.session).wait())
            #expect(f.session.request?.id == request.id && f.session.plan != nil)
            #expect(f.session.message == nil && f.session.receipt == nil)
            f.chooser.destination = f.output
            try #require(f.session.save(size: .pixels2048))
            try #require(await ImageSessionIdle(f.session).wait())
            #expect(f.session.receipt?.url == f.output)
            #expect(!f.session.save(size: .pixels1024))
            await ShelfImageCopyView(service: f.service, request: request).closeAction()
            #expect(f.session.request == nil)
            #expect(try Data(contentsOf: f.output) == Data("published copy".utf8))
            #expect(f.copier.cleanupTokens.isEmpty)
        }
    }

    @Test("A late successful write keeps its receipt and published file after cancellation")
    func latePublication() async throws {
        try await withFixture(holdWrite: true) { f in
            _ = try await begin(f)
            try #require(f.session.save(size: .pixels1024))
            try #require(await f.copier.writing.entered.wait())
            f.session.stop()
            let entered = ImageSessionSignal()
            let finished = ImageSessionSignal()
            let cancelling = Task { @MainActor in
                entered.resolve()
                defer { finished.resolve() }
                return await f.session.cancel()
            }
            try #require(await entered.wait())
            #expect(!finished.isResolved && f.session.isWorking)
            #expect(f.access.active(f.output) == 1)
            f.copier.writing.release()
            try await cancelling.value.get()
            #expect(f.copier.writing.observedCancellation)
            #expect(f.session.receipt?.url == f.output)
            #expect(!f.session.isActive && f.access.balanced)
            try await f.session.cancel().get()
            #expect(try Data(contentsOf: f.output) == Data("published copy".utf8))
            #expect(f.copier.cleanupTokens.isEmpty)
        }
    }

    @Test("Cancelled write cleanup retains its exact token and scope until explicit retry succeeds")
    func cleanupRetry() async throws {
        try await withFixture(holdWrite: true, failWrite: true) { f in
            let request = try await begin(f)
            f.copier.failCleanup = true
            try #require(f.session.save(size: .pixels1024))
            try #require(await f.copier.writing.entered.wait())
            f.session.stop()
            let cancelling = Task { @MainActor in await f.session.cancel() }
            f.copier.writing.release()
            if case .failure(let failure) = await cancelling.value {
                #expect(failure == .storeWrite)
            } else {
                Issue.record("Cancellation succeeded despite a retained stage")
            }
            #expect(f.session.needsCleanup && f.session.isActive && !f.session.isWorking)
            #expect(f.session.request?.id == request.id && f.session.message != nil)
            #expect(f.session.begin(itemID: UUID(), name: "blocked", source: f.source) == nil)
            #expect(f.access.active(f.output) == 1)
            #expect(f.copier.cleanupTokens == [f.copier.temporary])
            #expect(FileManager.default.fileExists(atPath: f.copier.temporary.url.path))
            f.copier.failCleanup = false
            try await f.session.cancel(requestID: request.id).get()
            #expect(f.copier.cleanupTokens == [f.copier.temporary, f.copier.temporary])
            #expect(!f.session.isActive && !f.session.needsCleanup && f.access.balanced)
            #expect(!FileManager.default.fileExists(atPath: f.copier.temporary.url.path))
            #expect(!FileManager.default.fileExists(atPath: f.output.path))
        }
    }

    @Test("A stale request cannot close a newer session or its save dialog")
    func staleCancellation() async throws {
        try await withFixture { f in
            let first = try await begin(f)
            try await f.session.cancel(requestID: first.id).get()
            let second = try await begin(f)
            f.chooser.reset(destination: nil, held: true)
            try #require(f.session.save(size: .pixels1024))
            try #require(await f.chooser.entered.wait())
            let cancellations = f.chooser.cancellations
            try await f.session.cancel(requestID: first.id).get()
            #expect(f.session.request?.id == second.id && f.session.isWorking)
            #expect(f.chooser.cancellations == cancellations)
            f.chooser.release.resolve()
            try #require(await ImageSessionIdle(f.session).wait())
        }
    }

    @Test("Uncertain publication retains its scope and recovers the actual URL without publishing again")
    func publicationRecovery() async throws {
        try await withFixture(uncertainPublication: true) { f in
            let request = try await begin(f)
            try #require(f.session.save(size: .pixels1024))
            try #require(await ImageSessionIdle(f.session).wait())
            #expect(f.session.needsCleanup && f.session.receipt == nil)
            #expect(f.session.message?.contains("A copy was created") == true)
            #expect(f.access.active(f.output) == 1)
            #expect(!f.session.save(size: .pixels2048))
            if case .failure(let failure) = await f.session.cancel(requestID: request.id) {
                #expect(failure == .storeWrite)
            } else {
                Issue.record("Unverified publication was treated as recovered")
            }
            #expect(f.session.request?.id == request.id && f.session.needsCleanup)
            #expect(f.session.receipt == nil && f.access.active(f.output) == 1)
            #expect(f.copier.writes == 1 && f.copier.recoveries == 1)
            f.copier.failRecovery = false
            if case .failure(let failure) = await f.session.cancel(requestID: request.id) {
                #expect(failure == .recoveredCopyNeedsAcknowledgement)
            } else {
                Issue.record("Recovery dismissed its saved location before acknowledgement")
            }
            #expect(f.session.receipt?.url == f.copier.recoveredOutput)
            #expect(f.session.isActive && !f.session.needsCleanup && f.access.balanced)
            #expect(f.session.request?.id == request.id && f.session.needsReceiptAcknowledgement)
            #expect(!f.session.save(size: .pixels2048))
            #expect(f.session.begin(itemID: UUID(), name: "next", source: f.source) == nil)
            #expect(!f.service.acknowledgeImageCopyReceipt(requestID: UUID()))
            _ = await f.service.cancelImageCopy(requestID: request.id, retryCleanup: false)
            #expect(f.session.request?.id == request.id && f.session.receipt?.url == f.copier.recoveredOutput)
            #expect(f.copier.writes == 1 && f.copier.recoveries == 2)
            #expect(f.service.acknowledgeImageCopyReceipt(requestID: request.id))
            #expect(!f.session.isActive && !f.session.needsReceiptAcknowledgement)
            #expect(f.session.receipt?.url == f.copier.recoveredOutput)
            #expect(f.copier.cleanupTokens.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: f.output.path))
            #expect(try Data(contentsOf: f.copier.recoveredOutput) == Data("published copy".utf8))
        }
    }

    @Test("Previously rendered Cancel and Retry Cleanup actions cannot acknowledge a recovered receipt")
    func renderedCloseActionsRetainRecoveredReceipt() async throws {
        try await withFixture(uncertainPublication: true) { f in
            let request = try await begin(f)
            let view = ShelfImageCopyView(service: f.service, request: request)
            let cancel = view.closeAction
            try #require(f.session.save(size: .pixels1024))
            try #require(await ImageSessionIdle(f.session).wait())
            try #require(f.session.needsCleanup && f.session.receipt == nil)
            let retryCleanup = view.closeAction
            f.copier.failRecovery = false
            _ = await f.service.cancelImageCopy(requestID: request.id)
            try #require(f.session.needsReceiptAcknowledgement)
            for action in [cancel, retryCleanup] {
                await action()
                #expect(f.session.request?.id == request.id && f.session.needsReceiptAcknowledgement)
                #expect(f.session.receipt?.url == f.copier.recoveredOutput)
                #expect(f.copier.writes == 1 && f.copier.recoveries == 1 && f.copier.acknowledgements == 0)
            }
            let done = view.closeAction
            await done()
            #expect(f.session.request == nil && !f.session.needsReceiptAcknowledgement)
            #expect(f.session.receipt?.url == f.copier.recoveredOutput)
        }
    }

    @Test("Unverified acknowledgement requires private cleanup and creates no saved receipt", arguments: [false, true])
    func unverifiedPublicationAcknowledgement(deleted: Bool) async throws {
        try await withFixture(uncertainPublication: true) { f in
            let request = try await begin(f)
            try #require(f.session.save(size: .pixels1024))
            try #require(await ImageSessionIdle(f.session).wait())
            let changed = Data("user edited the fixture copy".utf8)
            if deleted {
                try FileManager.default.removeItem(at: f.copier.recoveredOutput)
            } else {
                try changed.write(to: f.copier.recoveredOutput)
            }
            _ = await f.session.cancel(requestID: request.id)
            #expect(f.session.hasUnverifiedPublishedCopy && f.session.receipt == nil)
            f.copier.failCleanup = true
            if case .success = await f.service.acknowledgeUnverifiedImageCopy(requestID: request.id) {
                Issue.record("Unverified acknowledgement discarded failed private cleanup")
            }
            #expect(f.session.request?.id == request.id && f.session.hasUnverifiedPublishedCopy)
            #expect(f.session.receipt == nil && f.access.active(f.output) == 1)
            _ = await f.service.cancelImageCopy(requestID: request.id, retryCleanup: false)
            #expect(f.copier.acknowledgements == 1 && f.copier.recoveries == 1)
            f.copier.failCleanup = false
            try await f.service.acknowledgeUnverifiedImageCopy(requestID: request.id).get()
            #expect(!f.session.isActive && !f.session.needsReceiptAcknowledgement)
            #expect(f.session.receipt == nil && f.access.balanced)
            #expect(f.copier.writes == 1 && f.copier.acknowledgements == 2 && f.copier.recoveries == 1)
            if deleted {
                #expect(!FileManager.default.fileExists(atPath: f.copier.recoveredOutput.path))
            } else {
                #expect(try Data(contentsOf: f.copier.recoveredOutput) == changed)
            }
        }
    }

    nonisolated enum StopAction: CaseIterable, Sendable { case clear, pause, remove, shutdown }
    nonisolated enum RetainedStopAction: CaseIterable, Sendable { case pause, shutdown }

    @Test(
        "Failed image cleanup retains Shelf state until a stop retry succeeds", arguments: RetainedStopAction.allCases)
    func serviceRetainsFailedStop(action: RetainedStopAction) async throws {
        try await withFixture(failWrite: true) { f in
            try f.service.addFile(f.source)
            let item = try #require(f.service.items.first)
            let request = try #require(f.service.prepareImageCopy(item))
            try #require(await ImageSessionIdle(f.session).wait())
            f.copier.failCleanup = true
            try #require(f.session.save(size: .pixels1024))
            try #require(await ImageSessionIdle(f.session).wait())
            let result = action == .pause ? await f.service.pause() : await f.service.shutdown()
            if case .failure(let failure) = result {
                #expect(failure == .storeWrite)
            } else {
                Issue.record("Stop succeeded despite retained image cleanup")
            }
            #expect(f.service.stopFailure == .storeWrite)
            #expect(f.service.isRunning && !f.service.isStopping)
            #expect(f.service.items.map(\.id) == [item.id])
            #expect(f.access.active(f.source) == 1 && f.access.active(f.output) == 1)
            #expect(f.session.needsCleanup && f.copier.cleanupTokens.count == 1)
            if case .success = await f.service.cancelImageCopy(requestID: request.id, retryCleanup: false) {
                Issue.record("Sheet dismissal cleared failed stop recovery")
            }
            #expect(f.session.needsCleanup && f.copier.cleanupTokens.count == 1)
            f.copier.failCleanup = false
            let retry = action == .pause ? await f.service.pause() : await f.service.shutdown()
            try retry.get()
            #expect(f.service.stopFailure == nil && !f.service.isRunning)
            #expect(f.access.balanced && !f.session.needsCleanup)
            #expect(f.service.items.count == (action == .pause ? 1 : 0))
            #expect(f.copier.cleanupTokens.count == 2)
        }
    }

    @Test("Shelf lifecycle waits for held inspection before releasing the source", arguments: StopAction.allCases)
    func serviceDrain(action: StopAction) async throws {
        try await withFixture(holdInspect: true) { f in
            try f.service.addFile(f.source)
            let item = try #require(f.service.items.first)
            try #require(f.service.canResizeImage(item))
            try #require(f.service.prepareImageCopy(item) != nil)
            try #require(await f.copier.inspection.entered.wait())
            #expect(!f.service.canChooseFiles && !f.service.chooseFiles())
            #expect(!f.service.importDrops([NSItemProvider()]))
            let entered = ImageSessionSignal()
            let finished = ImageSessionSignal()
            let stopping = Task { @MainActor in
                entered.resolve()
                defer { finished.resolve() }
                switch action {
                case .clear: return await f.service.clear()
                case .pause: await f.service.pause()
                case .remove: await f.service.remove(item.id)
                case .shutdown: await f.service.shutdown()
                }
                return Result<Void, ShelfFailure>.success(())
            }
            try #require(await entered.wait())
            #expect(!finished.isResolved)
            #expect(f.access.active(f.source) == 2)
            f.copier.inspection.release()
            try await stopping.value.get()
            #expect(f.copier.inspection.observedCancellation)
            #expect(f.session.plan == nil && !f.session.isActive)
            #expect(f.access.active(f.source) == 0)
        }
    }

    @Test("Shelf clear reports pending image cleanup and retries before removing source references")
    func serviceCleanupRetry() async throws {
        try await withFixture(failWrite: true) { f in
            try f.service.addFile(f.source)
            let item = try #require(f.service.items.first)
            try #require(f.service.prepareImageCopy(item) != nil)
            try #require(await ImageSessionIdle(f.session).wait())
            f.copier.failCleanup = true
            try #require(f.session.save(size: .pixels1024))
            try #require(await f.copier.writing.entered.wait())
            if case .failure(let failure) = await f.service.clear() {
                #expect(failure == .storeWrite)
            } else {
                Issue.record("Clear succeeded despite a retained stage")
            }
            #expect(f.service.items.map(\.id) == [item.id])
            #expect(f.service.canClear && f.session.needsCleanup)
            #expect(f.access.active(f.source) == 1)
            f.copier.failCleanup = false
            try await f.service.clear().get()
            #expect(f.service.items.isEmpty && !f.session.needsCleanup)
            #expect(f.access.balanced)
        }
    }

    @Test("Shelf clear retains a successfully published user copy")
    func serviceKeepsPublishedCopy() async throws {
        try await withFixture { f in
            try f.service.addFile(f.source)
            let item = try #require(f.service.items.first)
            try #require(f.service.prepareImageCopy(item) != nil)
            try #require(await ImageSessionIdle(f.session).wait())
            try #require(f.session.save(size: .pixels2048))
            try #require(await ImageSessionIdle(f.session).wait())
            #expect(f.session.receipt?.url == f.output)
            try await f.service.clear().get()
            #expect(f.service.items.isEmpty && !f.session.isActive)
            #expect(f.session.receipt?.url == f.output)
            #expect(try Data(contentsOf: f.output) == Data("published copy".utf8))
            #expect(f.copier.cleanupTokens.isEmpty)
        }
    }

    @Test("Failed image cleanup waits for explicit retry while unrelated items continue to expire")
    func failedCleanupSuspendsOnlyItsExpiry() async throws {
        let clock = ImageSessionClock()
        let scheduler = ImageExpiryScheduler()
        try await withFixture(failWrite: true, now: clock.now, waitForExpiry: scheduler.wait) {
            f in
            f.service.setDefaultExpiry(.fifteenMinutes)
            try f.service.addFile(f.source)
            let item = try #require(f.service.items.first)
            f.service.setDefaultExpiry(.oneHour)
            try f.service.addText("unrelated expiring item")
            try #require(await scheduler.scheduled(1))
            #expect(scheduler.delays == [900])
            let request = try #require(f.service.prepareImageCopy(item))
            try #require(await ImageSessionIdle(f.session).wait())
            f.copier.failCleanup = true
            try #require(f.session.save(size: .pixels1024))
            try #require(await ImageSessionIdle(f.session).wait())
            clock.advance(900)
            scheduler.fire(0)
            try #require(await scheduler.scheduled(2))
            #expect(f.copier.cleanupTokens == [f.copier.temporary])
            #expect(scheduler.delays == [900, 2700])
            #expect(f.session.needsCleanup && f.service.items.count == 2)
            clock.advance(2700)
            scheduler.fire(1)
            while f.service.items.count == 2, !Task.isCancelled { await Task.yield() }
            try #require(f.service.items.map(\.id) == [item.id])
            await f.service.expireItems()
            #expect(f.copier.cleanupTokens.count == 1)
            #expect(scheduler.delays.count == 2)
            f.copier.failCleanup = false
            try await f.service.cancelImageCopy(requestID: request.id).get()
            try #require(await scheduler.scheduled(3))
            #expect(scheduler.delays == [900, 2700, 0])
            scheduler.fire(2)
            while !f.service.items.isEmpty, !Task.isCancelled { await Task.yield() }
            #expect(f.service.items.isEmpty)
            #expect(f.copier.cleanupTokens.count == 2)
            #expect(!f.session.needsCleanup && f.access.balanced)
        }
    }

    @Test("A stale cancellation cannot release a newer image request's expiry block")
    func staleCancellationPreservesExpiryBlock() async throws {
        let clock = ImageSessionClock()
        let scheduler = ImageExpiryScheduler()
        try await withFixture(failWrite: true, now: clock.now, waitForExpiry: scheduler.wait) {
            f in
            f.service.setDefaultExpiry(.fifteenMinutes)
            try f.service.addFile(f.source)
            let item = try #require(f.service.items.first)
            try #require(await scheduler.scheduled(1))
            let first = try #require(f.service.prepareImageCopy(item))
            try #require(await ImageSessionIdle(f.session).wait())
            f.copier.failCleanup = true
            try #require(f.session.save(size: .pixels1024))
            try #require(await ImageSessionIdle(f.session).wait())
            clock.advance(900)
            await f.service.expireItems()
            #expect(f.copier.cleanupTokens.count == 1)
            f.copier.failCleanup = false
            try await f.service.cancelImageCopy(requestID: first.id).get()
            try #require(await scheduler.scheduled(2))

            let second = try #require(f.service.prepareImageCopy(item))
            try #require(await ImageSessionIdle(f.session).wait())
            f.copier.failCleanup = true
            try #require(f.session.save(size: .pixels1024))
            try #require(await ImageSessionIdle(f.session).wait())
            if case .success = await f.service.cancelImageCopy(requestID: second.id) {
                Issue.record("New request cleanup succeeded despite the fixture refusal")
            }
            #expect(f.copier.cleanupTokens.count == 3)
            try await f.service.cancelImageCopy(requestID: first.id).get()
            await f.service.expireItems()
            #expect(f.session.request?.id == second.id && f.session.needsCleanup)
            #expect(f.copier.cleanupTokens.count == 3)
            #expect(f.service.items.map(\.id) == [item.id])
            #expect(scheduler.delays == [900, 0])
            f.copier.failCleanup = false
            try await f.service.cancelImageCopy(requestID: second.id).get()
            try #require(await scheduler.scheduled(3))
            scheduler.fire(2)
            while !f.service.items.isEmpty, !Task.isCancelled { await Task.yield() }
            #expect(f.service.items.isEmpty && f.access.balanced)
            #expect(f.copier.cleanupTokens.count == 4)
        }
    }

}
