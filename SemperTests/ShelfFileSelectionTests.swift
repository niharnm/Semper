import AppKit
import Foundation
import Observation
import Testing

@testable import Semper

nonisolated private final class ShelfSelectionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    var isResolved: Bool { lock.withLock { result != nil } }

    func resolve(_ value: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }

    func wait() async -> Bool {
        let watchdog = DispatchWorkItem { self.resolve(false) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        return await withCheckedContinuation { waiting in
            let existing: Bool? = lock.withLock {
                if let result { return result }
                continuation = waiting
                return nil
            }
            if let existing { waiting.resume(returning: existing) }
        }
    }
}

@MainActor
private final class ShelfSelectionChooser: ShelfFileChoosing {
    var selection: [URL]?
    private(set) var calls = 0
    let entered = ShelfSelectionSignal()
    let cancelled = ShelfSelectionSignal()
    let release = ShelfSelectionSignal()

    func chooseFiles() async -> [URL]? {
        calls += 1
        entered.resolve(true)
        guard await release.wait() else { return nil }
        return selection
    }

    func cancel() { cancelled.resolve(true) }
}

nonisolated private final class ShelfSelectionAccess: ShelfFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var beginCount = 0
    private var endCount = 0
    private var bookmarkCount = 0
    private var resolveCount = 0
    let folder: URL
    let overrideState: ShelfFileState?
    let failBookmarks: Bool
    var begins: Int { lock.withLock { beginCount } }
    var balanced: Bool { lock.withLock { beginCount == endCount } }
    var bookmarks: Int { lock.withLock { bookmarkCount } }
    var resolutions: Int { lock.withLock { resolveCount } }

    init(folder: URL, state: ShelfFileState?, failBookmarks: Bool) {
        self.folder = folder
        overrideState = state
        self.failBookmarks = failBookmarks
    }

    func begin(_ url: URL) -> Bool {
        lock.withLock { beginCount += 1 }
        return true
    }
    func end(_ url: URL) { lock.withLock { endCount += 1 } }
    func state(of url: URL) -> ShelfFileState { overrideState ?? .available(isDirectory: url == folder) }
    func bookmark(for url: URL) throws -> Data {
        lock.withLock { bookmarkCount += 1 }
        if failBookmarks { throw ShelfFailure.inaccessible }
        return Data(url.absoluteString.utf8)
    }
    func resolve(_ bookmark: Data) throws -> URL {
        lock.withLock { resolveCount += 1 }
        guard let string = String(data: bookmark, encoding: .utf8), let url = URL(string: string), url.isFileURL else {
            throw ShelfFailure.inaccessible
        }
        return url
    }
}

@MainActor
private final class ShelfSelectionCompletion {
    private let service: ShelfService
    private let finished = ShelfSelectionSignal()
    private var active = true

    init(_ service: ShelfService) { self.service = service }

    func wait() async -> Bool {
        observe()
        let result = await finished.wait()
        active = false
        return result
    }

    private func observe() {
        guard active else { return }
        let complete = withObservationTracking {
            let choosing = service.isChoosingFiles
            let count = service.importCount
            return !choosing && count == 0
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        if complete { finished.resolve(true) }
    }
}

@Suite("Shelf Choose Files", .timeLimit(.minutes(1)))
@MainActor
struct ShelfFileSelectionTests {
    private struct Fixture {
        let root: URL
        let file: URL
        let secondFile: URL
        let folder: URL
        let store: ShelfStore
        let access: ShelfSelectionAccess
        let chooser: ShelfSelectionChooser
        let service: ShelfService
        let dropEntered: ShelfSelectionSignal
        let dropRelease: ShelfSelectionSignal
    }

    private func withFixture(
        state: ShelfFileState? = nil, failBookmarks: Bool = false,
        body: (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let file = root.appendingPathComponent("original.txt")
        let secondFile = root.appendingPathComponent("second.txt")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try Data("original bytes".utf8).write(to: file)
        try Data("second bytes".utf8).write(to: secondFile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ShelfStore(root: root.appendingPathComponent("store", isDirectory: true))
        let chooser = ShelfSelectionChooser()
        let access = ShelfSelectionAccess(folder: folder, state: state, failBookmarks: failBookmarks)
        let dropEntered = ShelfSelectionSignal()
        let dropRelease = ShelfSelectionSignal()
        let service = ShelfService(
            store: store, access: access, fileChooser: chooser,
            importer: { _, _ in
                dropEntered.resolve(true)
                guard await dropRelease.wait() else { throw ShelfFailure.cancelled }
                return .text("Late drop")
            })
        let fixture = Fixture(
            root: root, file: file, secondFile: secondFile, folder: folder, store: store,
            access: access, chooser: chooser, service: service, dropEntered: dropEntered, dropRelease: dropRelease)
        service.start()
        do { try await body(fixture) } catch {
            chooser.release.resolve(true)
            dropRelease.resolve(true)
            await service.shutdown()
            throw error
        }
        chooser.release.resolve(true)
        dropRelease.resolve(true)
        await service.shutdown()
        #expect(access.balanced)
        #expect(try Data(contentsOf: file) == Data("original bytes".utf8))
        #expect(try Data(contentsOf: secondFile) == Data("second bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    private func select(_ urls: [URL]?, in f: Fixture) async throws {
        f.chooser.selection = urls
        try #require(f.service.chooseFiles())
        try #require(await f.chooser.entered.wait())
        f.chooser.release.resolve(true)
        try #require(await ShelfSelectionCompletion(f.service).wait())
    }

    @Test("Selected files and folders remain references; optional bookmarks reload", arguments: [false, true])
    func referencesAndPersistence(persistent: Bool) async throws {
        try await withFixture { f in
            if persistent {
                f.service.setDefaultExpiry(.oneHour)
                f.service.setPersistence(true)
                try #require(f.service.persistenceEnabled)
            }
            let urls = [f.file, f.secondFile, f.folder]
            try await select(urls, in: f)
            #expect(f.service.items.map { f.service.fileURL(for: $0) } == urls.map(Optional.some))
            #expect(
                f.service.items.map { f.service.fileStates[$0.id] } == [
                    .available(isDirectory: false), .available(isDirectory: false), .available(isDirectory: true),
                ])
            #expect(f.access.begins == 3)
            #expect(f.access.bookmarks == (persistent ? 3 : 0))
            #expect(f.service.importCount == 0)
            #expect(!f.service.isChoosingFiles)
            #expect(f.service.canChooseFiles)
            #expect(f.service.message == nil)
            for item in f.service.items {
                guard case .file(_, let bookmark) = item.payload else {
                    Issue.record("Selection must retain file references.")
                    continue
                }
                #expect((bookmark != nil) == persistent)
            }
            if persistent {
                let saved = f.service.items
                await f.service.shutdown()
                let restored = ShelfService(store: f.store, access: f.access, fileChooser: ShelfSelectionChooser())
                restored.start()
                #expect(restored.items == saved)
                #expect(f.access.resolutions == 3)
                #expect(restored.items.map { restored.fileURL(for: $0) } == urls.map(Optional.some))
                await restored.shutdown()
            } else {
                #expect(!FileManager.default.fileExists(atPath: f.store.manifest.path))
            }
        }
    }

    @Test("Cancelling the picker is silent and adds no references")
    func silentCancellation() async throws {
        try await withFixture { f in
            try await select(nil, in: f)
            #expect(f.service.items.isEmpty)
            #expect(f.service.message == nil)
            #expect(f.service.canChooseFiles)
            #expect(f.access.begins == 0)
        }
    }

    @Test("Capacity is checked before opening and before accepting the entire selection", arguments: [99, 100])
    func capacity(count: Int) async throws {
        try await withFixture { f in
            for index in 0..<count { try f.service.addText("Item \(index)") }
            let original = f.service.items
            if count == ShelfLimits.items {
                #expect(!f.service.canChooseFiles)
                #expect(!f.service.chooseFiles())
                #expect(f.chooser.calls == 0)
            } else {
                try await select([f.file, f.secondFile], in: f)
            }
            #expect(f.service.items == original)
            #expect(f.service.message == ShelfFailure.full.localizedDescription)
            #expect(f.access.begins == 0)
        }
    }

    @Test("An active picker rejects a second picker and dropped imports")
    func repeatedSelection() async throws {
        try await withFixture { f in
            f.chooser.selection = [f.file]
            try #require(f.service.chooseFiles())
            try #require(await f.chooser.entered.wait())
            #expect(!f.service.canChooseFiles)
            #expect(!f.service.chooseFiles())
            #expect(!f.service.importDrops([NSItemProvider()]))
            #expect(f.chooser.calls == 1)
            f.chooser.release.resolve(true)
            try #require(await ShelfSelectionCompletion(f.service).wait())
            #expect(f.service.items.count == 1)
        }
    }

    @Test("An active drop blocks file selection")
    func activeDrop() async throws {
        try await withFixture { f in
            try #require(f.service.importDrops([NSItemProvider()]))
            try #require(await f.dropEntered.wait())
            #expect(!f.service.canChooseFiles)
            #expect(!f.service.chooseFiles())
            #expect(f.chooser.calls == 0)
            f.dropRelease.resolve(true)
            try await f.service.cancelImports().get()
            #expect(f.service.items.isEmpty)
            #expect(f.service.canChooseFiles)
        }
    }

    nonisolated enum StopAction: CaseIterable, Sendable { case cancelImports, clear, pause, shutdown }

    @Test("Lifecycle cancellation drains the picker and rejects late selections", arguments: StopAction.allCases)
    func lifecycle(action: StopAction) async throws {
        try await withFixture { f in
            f.chooser.selection = [f.file, f.folder]
            try #require(f.service.chooseFiles())
            try #require(await f.chooser.entered.wait())
            let finished = ShelfSelectionSignal()
            let stopping = Task { @MainActor in
                defer { finished.resolve(true) }
                switch action {
                case .cancelImports: return await f.service.cancelImports()
                case .clear: return await f.service.clear()
                case .pause:
                    await f.service.pause()
                    return Result<Void, ShelfFailure>.success(())
                case .shutdown:
                    await f.service.shutdown()
                    return Result<Void, ShelfFailure>.success(())
                }
            }
            let cancelled = await f.chooser.cancelled.wait()
            if !cancelled { f.chooser.release.resolve(true) }
            #expect(cancelled)
            #expect(!finished.isResolved)
            #expect(!f.service.canChooseFiles)
            #expect(!f.service.chooseFiles())
            f.chooser.release.resolve(true)
            try await stopping.value.get()
            #expect(f.service.items.isEmpty)
            #expect(f.service.importCount == 0)
            #expect(!f.service.isChoosingFiles)
            #expect(f.access.begins == 0)
            #expect(f.service.isRunning == (action == .cancelImports || action == .clear))
        }
    }

    @Test(
        "Unavailable selected references use the same state and action rules as addFile",
        arguments: [
            ShelfFileState.missing, .cloudOnly, .inaccessible,
        ])
    func unavailableReferences(state: ShelfFileState) async throws {
        try await withFixture(state: state) { f in
            try await select([f.file], in: f)
            let selected = try #require(f.service.items.first)
            #expect(f.service.fileStates[selected.id] == state)
            #expect(f.service.prepareFileAction(selected) == nil)
            let selectedMessage = f.service.message
            try f.service.addFile(f.file)
            let direct = try #require(f.service.items.last)
            #expect(selected.payload == direct.payload)
            #expect(f.service.fileStates[direct.id] == state)
            #expect(f.service.prepareFileAction(direct) == nil)
            #expect(f.service.message == selectedMessage)
        }
    }

    @Test("A selected file bookmark failure is reported and releases its acquired scope")
    func bookmarkFailure() async throws {
        try await withFixture(failBookmarks: true) { f in
            f.service.setDefaultExpiry(.oneHour)
            f.service.setPersistence(true)
            try #require(f.service.persistenceEnabled)
            try await select([f.file], in: f)
            #expect(f.service.items.isEmpty)
            #expect(f.service.message == ShelfFailure.inaccessible.localizedDescription)
            #expect(f.access.begins == 1)
            #expect(f.access.balanced)
            #expect(try f.store.load()?.items.isEmpty == true)
        }
    }
}
