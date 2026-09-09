import AppKit
import Observation

nonisolated enum ShelfChecksumState: Equatable, Sendable {
    case calculating
    case value(String)
    case failed(String)
    case cancelled
}

@Observable
@MainActor
final class ShelfService {
    private(set) var items: [ShelfItem] = []
    private(set) var fileStates: [UUID: ShelfFileState] = [:]
    private(set) var checksums: [UUID: ShelfChecksumState] = [:]
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var isClearing = false
    private(set) var persistenceEnabled = false
    private(set) var defaultExpiry: ShelfExpiry = .quit
    private(set) var importCount = 0
    private(set) var message: String?
    private(set) var storeNeedsReset = false

    let store: ShelfStore
    @ObservationIgnored private let access: any ShelfFileAccess
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var scopes: [UUID: URL] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var hashTasks: [UUID: Task<String, Error>] = [:]
    @ObservationIgnored private var importTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var removingIDs: Set<UUID> = []
    @ObservationIgnored private let importer:
        @MainActor (NSItemProvider, ShelfStore) async throws -> ShelfImportedPayload
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var invalidReferenceIDs: Set<UUID> = []

    init(
        store: ShelfStore = .standard, access: any ShelfFileAccess = NativeShelfFileAccess(),
        now: @escaping @Sendable () -> Date = { Date() },
        importer: @escaping @MainActor (NSItemProvider, ShelfStore) async throws -> ShelfImportedPayload =
            ShelfDropImporter.load
    ) {
        self.store = store
        self.access = access
        self.now = now
        self.importer = importer
    }

    func start() {
        guard !isRunning, !isStopping else { return }
        if !loaded {
            loaded = true
            do {
                if let snapshot = try store.load() {
                    persistenceEnabled = true
                    defaultExpiry = snapshot.defaultExpiry
                    items = snapshot.items.filter { $0.expiry != .quit && !$0.hasExpired(at: now()) }
                    for index in items.indices {
                        if case .file(let original, let bookmark) = items[index].payload, let bookmark {
                            do { items[index].payload = .file(try access.resolve(bookmark), bookmark: bookmark) } catch
                            {
                                fileStates[items[index].id] = .inaccessible
                                invalidReferenceIDs.insert(items[index].id)
                                items[index].payload = .file(original, bookmark: bookmark)
                            }
                        }
                    }
                }
                try removeOrphanedCache()
            } catch {
                storeNeedsReset = true
                report(error)
            }
        }
        isRunning = true
        refresh()
        scheduleExpiry()
    }

    func pause() async {
        if let stopTask {
            await stopTask.value
            return
        }
        isStopping = true
        isRunning = false
        generation += 1
        expiryTask?.cancel()
        expiryTask = nil
        let drain = Task { [weak self] in
            guard let self else { return }
            await self.cancelWork()
            if let clearTask = self.clearTask { await clearTask.value }
            for url in self.scopes.values { self.access.end(url) }
            self.scopes.removeAll()
            self.isStopping = false
            self.stopTask = nil
        }
        stopTask = drain
        await drain.value
    }

    func shutdown() async {
        await pause()
        let removed = persistenceEnabled ? items.filter { $0.expiry == .quit || $0.hasExpired(at: now()) } : items
        for item in removed { removeOwnedContent(item) }
        let removedIDs = Set(removed.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        fileStates = fileStates.filter { !removedIDs.contains($0.key) }
        checksums = checksums.filter { !removedIDs.contains($0.key) }
        persist()
    }

    func refresh() {
        guard isRunning else { return }
        for item in items {
            guard let url = fileURL(for: item) else { continue }
            if scopes[item.id] == nil, access.begin(url) { scopes[item.id] = url }
            fileStates[item.id] = access.state(of: url)
        }
    }

    func addFile(_ url: URL) throws {
        try requireCapacity()
        guard url.isFileURL else { throw ShelfFailure.unsupported }
        let acquired = access.begin(url)
        var retained = false
        defer { if acquired && !retained { access.end(url) } }
        let bookmark = persistenceEnabled ? try access.bookmark(for: url) : nil
        let item = ShelfItem(
            name: url.lastPathComponent, payload: .file(url, bookmark: bookmark), now: now(), expiry: defaultExpiry)
        items.append(item)
        if acquired {
            scopes[item.id] = url
            retained = true
        }
        fileStates[item.id] = access.state(of: url)
        persist()
        scheduleExpiry()
    }

    func addText(_ text: String) throws {
        try requireCapacity()
        guard !text.isEmpty, text.utf8.count <= ShelfLimits.textBytes else { throw ShelfFailure.tooLarge }
        let firstLine = String(text.prefix(80)).split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
        items.append(ShelfItem(name: firstLine, payload: .text(text), now: now(), expiry: defaultExpiry))
        persist()
        scheduleExpiry()
    }

    func addLink(_ url: URL) throws {
        try requireCapacity()
        guard ShelfStore.isAllowedLink(url) else { throw ShelfFailure.unsupported }
        items.append(
            ShelfItem(name: url.host ?? url.absoluteString, payload: .link(url), now: now(), expiry: defaultExpiry))
        persist()
        scheduleExpiry()
    }

    func setDefaultExpiry(_ expiry: ShelfExpiry) {
        defaultExpiry = expiry
        persist()
    }

    func setExpiry(_ expiry: ShelfExpiry, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].expiry = expiry
        items[index].expiresAt = expiry.deadline(from: now())
        persist()
        scheduleExpiry()
    }

    func setPersistence(_ enabled: Bool) {
        guard !storeNeedsReset else {
            message = ShelfFailure.invalidStore.localizedDescription
            return
        }
        do {
            if enabled {
                guard invalidReferenceIDs.isEmpty else { throw ShelfFailure.inaccessible }
                var prepared = items
                for index in prepared.indices {
                    if case .file(let url, _) = prepared[index].payload {
                        prepared[index].payload = .file(url, bookmark: try access.bookmark(for: url))
                    }
                }
                try store.save(items: prepared.filter { $0.expiry != .quit }, expiry: defaultExpiry)
                items = prepared
            } else {
                try store.removeManifest()
            }
            persistenceEnabled = enabled
        } catch { report(error) }
    }

    func resetSavedData() async {
        await clear()
        do {
            try store.removeManifest()
            try removeOrphanedCache()
            storeNeedsReset = false
            persistenceEnabled = false
            message = nil
        } catch { report(error) }
    }

    func remove(_ id: UUID) async {
        await remove(id, onlyIfExpired: false)
    }

    private func remove(_ id: UUID, onlyIfExpired: Bool) async {
        removingIDs.insert(id)
        defer { removingIDs.remove(id) }
        let worker = hashTasks[id]
        worker?.cancel()
        if worker != nil { checksums[id] = .cancelled }
        _ = await worker?.result
        hashTasks[id] = nil
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard !onlyIfExpired || (!Task.isCancelled && item.hasExpired(at: now())) else { return }
        if let url = scopes.removeValue(forKey: id) { access.end(url) }
        removeOwnedContent(item)
        items.removeAll { $0.id == id }
        fileStates[id] = nil
        invalidReferenceIDs.remove(id)
        checksums[id] = nil
        persist()
        scheduleExpiry()
    }

    func clear() async {
        if let clearTask {
            await clearTask.value
            return
        }
        generation += 1
        isClearing = true
        let worker = Task { [weak self] in
            guard let self else { return }
            await self.cancelWork()
            for url in self.scopes.values { self.access.end(url) }
            self.scopes.removeAll()
            for item in self.items { self.removeOwnedContent(item) }
            self.items.removeAll()
            self.fileStates.removeAll()
            self.invalidReferenceIDs.removeAll()
            self.checksums.removeAll()
            self.persist()
            self.isClearing = false
            self.clearTask = nil
            self.scheduleExpiry()
        }
        clearTask = worker
        await worker.value
    }

    func expireItems() async {
        let ids = items.filter { $0.hasExpired(at: now()) }.map(\.id)
        for id in ids { await remove(id, onlyIfExpired: true) }
        scheduleExpiry()
    }

    func checksum(_ id: UUID) {
        guard isRunning, !isClearing, !isStopping, !removingIDs.contains(id), hashTasks[id] == nil,
            let item = items.first(where: { $0.id == id }),
            let url = fileURL(for: item)
        else { return }
        let access = access
        let currentGeneration = generation
        checksums[id] = .calculating
        let worker = Task.detached(priority: .utility) { try ShelfIO.checksum(url, access: access) }
        hashTasks[id] = worker
        Task { [weak self] in
            let result = await worker.result
            guard let self, self.generation == currentGeneration, self.hashTasks[id] != nil else { return }
            self.hashTasks[id] = nil
            guard self.items.contains(where: { $0.id == id }) else { return }
            switch result {
            case .success(let value): self.checksums[id] = .value(value)
            case .failure(let failure as ShelfFailure) where failure == .cancelled: self.checksums[id] = .cancelled
            case .failure(let error):
                self.checksums[id] = .failed(
                    (error as? ShelfFailure)?.localizedDescription
                        ?? "The checksum could not be calculated. Refresh the file and try again.")
                self.refresh()
            }
        }
    }

    func cancelChecksum(_ id: UUID) {
        hashTasks[id]?.cancel()
        checksums[id] = .cancelled
    }

    func importDrops(_ providers: [NSItemProvider]) -> Bool {
        guard isRunning, !isClearing, !isStopping, !storeNeedsReset else {
            report(ShelfFailure.stopped)
            return false
        }
        guard providers.count <= ShelfLimits.items - items.count - importTasks.count else {
            report(ShelfFailure.full)
            return false
        }
        let currentGeneration = generation
        guard importTasks.isEmpty else {
            message = "Wait for the current drop or cancel it before adding another."
            return false
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.importTasks[id] = nil
                self.importCount = 0
            }
            for provider in providers {
                guard !Task.isCancelled, self.isRunning, self.generation == currentGeneration else { return }
                do {
                    let payload = try await self.importer(provider, self.store)
                    guard !Task.isCancelled, self.isRunning, self.generation == currentGeneration else {
                        self.discardImported(payload)
                        return
                    }
                    try self.acceptImported(payload)
                } catch {
                    if error as? ShelfFailure != .cancelled { self.report(error) }
                }
                self.importCount = max(0, self.importCount - 1)
            }
        }
        importTasks[id] = task
        importCount = providers.count
        return true
    }

    func cancelImports() async {
        let workers = importTasks
        for task in workers.values { task.cancel() }
        for (id, task) in workers {
            await task.value
            importTasks[id] = nil
        }
    }

    func fileURL(for item: ShelfItem) -> URL? {
        guard !invalidReferenceIDs.contains(item.id) else { return nil }
        return switch item.payload {
        case .file(let url, _): url
        case .cachedFile(let name): try? store.cacheURL(named: name)
        case .link, .text: nil
        }
    }

    func prepareFileAction(_ item: ShelfItem, allowCloud: Bool = false) -> URL? {
        guard isRunning, let url = fileURL(for: item) else { return nil }
        let state = access.state(of: url)
        fileStates[item.id] = state
        if state.isAvailable || (allowCloud && state == .cloudOnly) { return url }
        message = state.message
        return nil
    }

    func dragWriter(for item: ShelfItem) -> NSPasteboardWriting? {
        guard isRunning, items.contains(where: { $0.id == item.id }) else { return nil }
        switch item.payload {
        case .file, .cachedFile:
            guard let url = prepareFileAction(item) else { return nil }
            return url as NSURL
        case .link(let url): return url as NSURL
        case .text(let text): return text as NSString
        }
    }

    func reveal(_ item: ShelfItem) {
        guard let url = prepareFileAction(item, allowCloud: true) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ item: ShelfItem) {
        guard let url = fileURL(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func copyContents(_ item: ShelfItem) {
        let value: String
        switch item.payload {
        case .text(let text): value = text
        case .link(let url): value = url.absoluteString
        case .file, .cachedFile: return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func dismissMessage() { message = nil }
    func report(_ error: Error) {
        message =
            (error as? ShelfFailure)?.localizedDescription
            ?? "The file operation failed. Check file access and available disk space."
    }

    private func requireCapacity() throws {
        guard isRunning, !isStopping, !isClearing else { throw ShelfFailure.stopped }
        guard !storeNeedsReset else { throw ShelfFailure.invalidStore }
        guard items.count < ShelfLimits.items else { throw ShelfFailure.full }
    }

    private func acceptImported(_ payload: ShelfImportedPayload) throws {
        switch payload {
        case .file(let url): try addFile(url)
        case .text(let text): try addText(text)
        case .link(let url): try addLink(url)
        case .cachedFile(let name):
            do {
                try requireCapacity()
                let cached = try store.cacheURL(named: name)
                let urls = items.compactMap { fileURL(for: $0) }.filter {
                    $0.deletingLastPathComponent() == store.cache
                }
                let size = try (urls + [cached]).reduce(0) { count, url in
                    count + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
                guard size <= ShelfLimits.cacheBytes else { throw ShelfFailure.tooLarge }
                let item = ShelfItem(
                    name: "Dropped image", payload: .cachedFile(name), now: now(), expiry: defaultExpiry)
                items.append(item)
                fileStates[item.id] = access.state(of: cached)
                persist()
                scheduleExpiry()
            } catch {
                discardImported(payload)
                throw error
            }
        }
    }

    private func discardImported(_ payload: ShelfImportedPayload) {
        if case .cachedFile(let name) = payload {
            do { try store.removeCachedFile(named: name) } catch { report(error) }
        }
    }

    private func cancelWork() async {
        await cancelImports()
        let workers = hashTasks
        for (id, task) in workers {
            task.cancel()
            checksums[id] = .cancelled
        }
        for (id, task) in workers {
            _ = await task.result
            hashTasks[id] = nil
        }
    }

    private func persist() {
        guard persistenceEnabled, !storeNeedsReset else { return }
        do {
            try store.save(
                items: items.filter { $0.expiry != .quit && !$0.hasExpired(at: now()) }, expiry: defaultExpiry)
        } catch { report(error) }
    }

    private func removeOwnedContent(_ item: ShelfItem) {
        if case .cachedFile(let name) = item.payload {
            do { try store.removeCachedFile(named: name) } catch { report(error) }
        }
    }

    private func removeOrphanedCache() throws {
        guard FileManager.default.fileExists(atPath: store.cache.path) else { return }
        let retained = Set(
            items.compactMap { item -> String? in
                if case .cachedFile(let name) = item.payload { name } else { nil }
            })
        for url in try FileManager.default.contentsOfDirectory(at: store.cache, includingPropertiesForKeys: nil) {
            guard !retained.contains(url.lastPathComponent), (try? store.cacheURL(named: url.lastPathComponent)) != nil
            else { continue }
            try store.removeCachedFile(named: url.lastPathComponent)
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard isRunning, let deadline = items.compactMap(\.expiresAt).min() else { return }
        let delay = min(86_400, max(0, deadline.timeIntervalSince(now())))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, self.isRunning else { return }
            await self.expireItems()
        }
    }
}
