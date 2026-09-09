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
    private(set) var stopFailure: ShelfFailure?
    private(set) var isClearing = false
    private(set) var persistenceEnabled = false
    private(set) var defaultExpiry: ShelfExpiry = .quit
    private(set) var importCount = 0
    private(set) var isChoosingFiles = false
    private(set) var message: String?
    private(set) var storeNeedsReset = false
    private var pendingImportCleanup: Set<String> = []
    private var importCleanupNeedsRetry = false
    private var importCancellationCount = 0

    var canClear: Bool {
        !items.isEmpty || !pendingImportCleanup.isEmpty || importCleanupNeedsRetry || imageCopy.needsCleanup
    }
    var canChooseFiles: Bool {
        isRunning && !isStopping && !isClearing && !storeNeedsReset && !isChoosingFiles
            && importCount == 0 && importCancellationCount == 0 && removingIDs.isEmpty
            && pendingImportCleanup.isEmpty && !importCleanupNeedsRetry && !imageCopy.isActive
            && items.count < ShelfLimits.items
    }

    let store: ShelfStore
    let imageCopy: ShelfImageCopySession
    @ObservationIgnored private let access: any ShelfFileAccess
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let waitForExpiry: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var expiryBlockedRequests: [UUID: UUID] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var scopes: [UUID: URL] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var hashTasks: [UUID: Task<String, Error>] = [:]
    @ObservationIgnored private var importTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clearGeneration = 0
    @ObservationIgnored private var clearTask: Task<Result<Void, ShelfFailure>, Never>?
    private var removingIDs: Set<UUID> = []
    @ObservationIgnored private let fileChooser: any ShelfFileChoosing
    @ObservationIgnored private let importer:
        @MainActor (NSItemProvider, ShelfStore) async throws -> ShelfImportedPayload
    @ObservationIgnored private var stopTask: Task<Result<Void, ShelfFailure>, Never>?
    @ObservationIgnored private var invalidReferenceIDs: Set<UUID> = []

    init(
        store: ShelfStore = .standard, access: any ShelfFileAccess = NativeShelfFileAccess(),
        now: @escaping @Sendable () -> Date = { Date() },
        waitForExpiry: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        fileChooser: any ShelfFileChoosing = NativeShelfFileChooser(),
        imageCopy: ShelfImageCopySession? = nil,
        importer: @escaping @MainActor (NSItemProvider, ShelfStore) async throws -> ShelfImportedPayload =
            ShelfDropImporter.load
    ) {
        self.store = store
        self.access = access
        self.now = now
        self.waitForExpiry = waitForExpiry
        self.fileChooser = fileChooser
        self.imageCopy = imageCopy ?? ShelfImageCopySession(access: access)
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

    @discardableResult
    func pause() async -> Result<Void, ShelfFailure> {
        if let stopTask { return await stopTask.value }
        imageCopy.stop()
        isStopping = true
        isRunning = false
        generation += 1
        expiryTask?.cancel()
        expiryTask = nil
        let drain = Task<Result<Void, ShelfFailure>, Never> { [weak self] in
            guard let self else { return .failure(.cancelled) }
            defer {
                self.isStopping = false
                self.stopTask = nil
            }
            let cleanup = await self.cancelWork()
            let clearResult = await self.clearTask?.value
            let failure: ShelfFailure?
            if case .failure(let error) = cleanup {
                failure = error
            } else if case .failure(let error) = clearResult {
                failure = error
            } else {
                failure = nil
            }
            if let failure {
                self.stopFailure = failure
                self.report(failure)
                self.isRunning = true
                self.scheduleExpiry()
                return .failure(failure)
            }
            for url in self.scopes.values { self.access.end(url) }
            self.scopes.removeAll()
            self.stopFailure = nil
            return .success(())
        }
        stopTask = drain
        return await drain.value
    }

    @discardableResult
    func shutdown() async -> Result<Void, ShelfFailure> {
        if case .failure(let failure) = await pause() { return .failure(failure) }
        let removed = persistenceEnabled ? items.filter { $0.expiry == .quit || $0.hasExpired(at: now()) } : items
        for item in removed {
            if case .failure(let failure) = removeOwnedContent(item) {
                stopFailure = failure
                isRunning = true
                refresh()
                scheduleExpiry()
                return .failure(failure)
            }
        }
        let removedIDs = Set(removed.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        fileStates = fileStates.filter { !removedIDs.contains($0.key) }
        checksums = checksums.filter { !removedIDs.contains($0.key) }
        expiryBlockedRequests = expiryBlockedRequests.filter { !removedIDs.contains($0.key) }
        persist()
        return .success(())
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
        guard !isClearing else {
            message = "Wait for Clear Shelf to finish before changing persistence."
            return
        }
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
        if let clearTask { _ = await clearTask.value }
        let neededReset = storeNeedsReset
        do {
            try store.removeManifest()
            storeNeedsReset = false
            persistenceEnabled = false
            try await clear().get()
            message = nil
        } catch {
            storeNeedsReset = neededReset
            report(error)
        }
    }

    func remove(_ id: UUID) async {
        await remove(id, onlyIfExpired: false)
    }

    private func remove(_ id: UUID, onlyIfExpired: Bool) async {
        guard !isClearing else { return }
        let removalClearGeneration = clearGeneration
        let imageRequest = imageCopy.request?.itemID == id ? imageCopy.request : nil
        if imageRequest != nil { imageCopy.stop() }
        removingIDs.insert(id)
        defer { removingIDs.remove(id) }
        if let imageRequest, case .failure(let failure) = await cancelImageCopy(requestID: imageRequest.id) {
            report(failure)
            return
        }
        let worker = hashTasks[id]
        worker?.cancel()
        if worker != nil { checksums[id] = .cancelled }
        _ = await worker?.result
        hashTasks[id] = nil
        guard clearGeneration == removalClearGeneration, !isClearing else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard !onlyIfExpired || (!Task.isCancelled && item.hasExpired(at: now())) else { return }
        if let url = scopes.removeValue(forKey: id) { access.end(url) }
        removeOwnedContent(item)
        items.removeAll { $0.id == id }
        expiryBlockedRequests[id] = nil
        fileStates[id] = nil
        invalidReferenceIDs.remove(id)
        checksums[id] = nil
        persist()
        scheduleExpiry()
    }

    @discardableResult
    func clear() async -> Result<Void, ShelfFailure> {
        if let clearTask {
            return await clearTask.value
        }
        imageCopy.stop()
        generation += 1
        clearGeneration += 1
        isClearing = true
        expiryTask?.cancel()
        expiryTask = nil
        let worker = Task<Result<Void, ShelfFailure>, Never> { [weak self] in
            guard let self else { return .failure(.cancelled) }
            defer {
                self.isClearing = false
                self.clearTask = nil
                self.scheduleExpiry()
            }
            if case .failure(let failure) = await self.cancelWork() {
                self.report(failure)
                return .failure(failure)
            }
            guard !self.storeNeedsReset else {
                self.report(ShelfFailure.invalidStore)
                return .failure(.invalidStore)
            }
            if self.persistenceEnabled {
                do {
                    try self.store.save(items: [], expiry: self.defaultExpiry)
                } catch {
                    self.report(ShelfFailure.storeWrite)
                    return .failure(.storeWrite)
                }
            }
            for item in self.items {
                if case .failure(let failure) = self.removeOwnedContent(item) {
                    self.report(failure)
                    return .failure(failure)
                }
            }
            for url in self.scopes.values { self.access.end(url) }
            self.scopes.removeAll()
            self.items.removeAll()
            self.expiryBlockedRequests.removeAll()
            self.fileStates.removeAll()
            self.invalidReferenceIDs.removeAll()
            self.checksums.removeAll()
            if self.message == ShelfFailure.storeWrite.localizedDescription
                || self.message == "Clear Shelf to retry temporary image cleanup before adding another drop."
                || self.message == "Wait for cancelled imports to finish cleaning up before adding another drop."
                || self.message == "Finish Resize a Copy or retry its cleanup before adding more items."
            {
                self.message = nil
            }
            return .success(())
        }
        clearTask = worker
        return await worker.value
    }

    func expireItems() async {
        guard !isClearing else { return }
        let ids = items.filter { $0.hasExpired(at: now()) && expiryBlockedRequests[$0.id] == nil }.map(\.id)
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

    @discardableResult
    func cancelImageCopy(requestID: UUID? = nil, retryCleanup: Bool = true) async -> Result<Void, ShelfFailure> {
        if let requestID, requestID != imageCopy.request?.id { return .success(()) }
        if !retryCleanup, imageCopy.needsCleanup { return .failure(.storeWrite) }
        let request = imageCopy.request
        let result = await imageCopy.cancel(requestID: requestID)
        if let request {
            switch result {
            case .success:
                if expiryBlockedRequests[request.itemID] == request.id {
                    expiryBlockedRequests[request.itemID] = nil
                    scheduleExpiry()
                }
            case .failure:
                if imageCopy.request?.id == request.id, imageCopy.needsCleanup {
                    expiryBlockedRequests[request.itemID] = request.id
                }
            }
        }
        return result
    }

    func canResizeImage(_ item: ShelfItem) -> Bool {
        isRunning && !isStopping && !isClearing && !storeNeedsReset && !imageCopy.isActive
            && importTasks.isEmpty && !isChoosingFiles && importCancellationCount == 0
            && pendingImportCleanup.isEmpty && !importCleanupNeedsRetry && removingIDs.isEmpty
            && items.contains(where: { $0.id == item.id })
            && fileStates[item.id] == .available(isDirectory: false)
    }

    func prepareImageCopy(_ item: ShelfItem) -> ShelfImageCopyRequest? {
        guard canResizeImage(item), let url = prepareFileAction(item) else { return nil }
        return imageCopy.begin(itemID: item.id, name: item.name, source: url)
    }

    @discardableResult
    func chooseFiles() -> Bool {
        guard removingIDs.isEmpty else {
            message = "Wait for the item removal to finish before choosing files."
            return false
        }
        guard admitImport(count: 1) else { return false }
        let currentGeneration = generation
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.importTasks[id] = nil
                self.importCount = 0
                self.isChoosingFiles = false
            }
            guard !Task.isCancelled, self.isRunning, self.generation == currentGeneration else { return }
            guard let urls = await self.fileChooser.chooseFiles() else { return }
            guard !Task.isCancelled, self.isRunning, self.generation == currentGeneration else { return }
            guard self.removingIDs.isEmpty else {
                self.message = "Wait for the item removal to finish before choosing files."
                return
            }
            guard urls.count <= ShelfLimits.items - self.items.count else {
                self.report(ShelfFailure.full)
                return
            }
            self.importCount = urls.count
            self.isChoosingFiles = false
            for url in urls {
                guard !Task.isCancelled, self.isRunning, self.generation == currentGeneration else { return }
                do { try self.acceptImported(.file(url)) } catch { self.report(error) }
                self.importCount = max(0, self.importCount - 1)
                if self.importCount > 0 { await Task.yield() }
            }
        }
        importTasks[id] = task
        isChoosingFiles = true
        return true
    }

    private func admitImport(count: Int) -> Bool {
        guard isRunning, !isClearing, !isStopping, !storeNeedsReset else {
            report(ShelfFailure.stopped)
            return false
        }
        guard importCancellationCount == 0 else {
            message = "Wait for cancelled imports to finish cleaning up before adding another drop."
            return false
        }
        guard pendingImportCleanup.isEmpty, !importCleanupNeedsRetry else {
            message = "Clear Shelf to retry temporary image cleanup before adding another drop."
            return false
        }
        guard count <= ShelfLimits.items - items.count - importTasks.count else {
            report(ShelfFailure.full)
            return false
        }
        guard !imageCopy.isActive else {
            message = "Finish Resize a Copy or retry its cleanup before adding more items."
            return false
        }
        guard importTasks.isEmpty, !isChoosingFiles else {
            message = "Finish or cancel the current selection or import before adding more items."
            return false
        }
        return true
    }

    func importDrops(_ providers: [NSItemProvider]) -> Bool {
        guard admitImport(count: providers.count) else { return false }
        let currentGeneration = generation
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
                    self.reconcileImportCleanup()
                }
                guard self.pendingImportCleanup.isEmpty, !self.importCleanupNeedsRetry else { return }
                self.importCount = max(0, self.importCount - 1)
            }
        }
        importTasks[id] = task
        importCount = providers.count
        return true
    }

    @discardableResult
    func cancelImports() async -> Result<Void, ShelfFailure> {
        importCancellationCount += 1
        defer { importCancellationCount -= 1 }
        if !storeNeedsReset {
            for name in Array(pendingImportCleanup) { discardImported(.cachedFile(name)) }
        }
        let workers = importTasks
        for task in workers.values { task.cancel() }
        if isChoosingFiles { fileChooser.cancel() }
        for (id, task) in workers {
            await task.value
            importTasks[id] = nil
        }
        reconcileImportCleanup()
        return pendingImportCleanup.isEmpty && !importCleanupNeedsRetry ? .success(()) : .failure(.storeWrite)
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

    @discardableResult
    private func discardImported(_ payload: ShelfImportedPayload) -> Result<Void, ShelfFailure> {
        if case .cachedFile(let name) = payload {
            do {
                try store.removeCachedFile(named: name)
                pendingImportCleanup.remove(name)
            } catch {
                pendingImportCleanup.insert(name)
                report(ShelfFailure.storeWrite)
                return .failure(.storeWrite)
            }
        }
        return .success(())
    }

    private func cancelWork() async -> Result<Void, ShelfFailure> {
        imageCopy.stop()
        let importCleanup = await cancelImports()
        let imageCleanup = await cancelImageCopy()
        let workers = hashTasks
        for (id, task) in workers {
            task.cancel()
            checksums[id] = .cancelled
        }
        for (id, task) in workers {
            _ = await task.result
            hashTasks[id] = nil
        }
        if case .failure = importCleanup { return importCleanup }
        return imageCleanup
    }

    private func reconcileImportCleanup() {
        guard !storeNeedsReset else { return }
        do {
            try removeOrphanedCache()
            importCleanupNeedsRetry = false
        } catch {
            importCleanupNeedsRetry = true
            report(ShelfFailure.storeWrite)
        }
    }

    private func persist() {
        guard persistenceEnabled, !storeNeedsReset else { return }
        do {
            try store.save(
                items: items.filter { $0.expiry != .quit && !$0.hasExpired(at: now()) }, expiry: defaultExpiry)
        } catch { report(error) }
    }

    @discardableResult
    private func removeOwnedContent(_ item: ShelfItem) -> Result<Void, ShelfFailure> {
        if case .cachedFile(let name) = item.payload {
            do { try store.removeCachedFile(named: name) } catch {
                report(error)
                return .failure(.storeWrite)
            }
        }
        return .success(())
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
        guard isRunning, !isClearing,
            let deadline = items.filter({ expiryBlockedRequests[$0.id] == nil }).compactMap(\.expiresAt).min()
        else { return }
        let delay = min(86_400, max(0, deadline.timeIntervalSince(now())))
        let waitForExpiry = waitForExpiry
        expiryTask = Task { [weak self] in
            do { try await waitForExpiry(delay) } catch { return }
            guard !Task.isCancelled, let self, self.isRunning else { return }
            await self.expireItems()
        }
    }
}
