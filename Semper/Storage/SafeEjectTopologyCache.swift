import Foundation

@MainActor
final class SafeEjectTopologyCache {
    private(set) var value: SafeEjectAPFSTopology?
    private(set) var failure: SafeEjectFailure?
    private(set) var cleanupFailure: SafeEjectFailure?
    private var revision = UUID()
    private var active = false
    private var refreshRequested = false
    private var update: Task<Void, Never>?
    private var cleanup: Task<Result<Void, SafeEjectFailure>, Never>?
    private var reader: Task<SafeEjectAPFSTopology, Error>?
    private var readerToken: UUID?
    private var preflightToken: UUID?
    private var preflightCancelled = false
    private let retryCleanup: @Sendable () async throws -> Void
    private let read: @Sendable () async throws -> SafeEjectAPFSTopology
    private var didChange: (@MainActor () -> Void)?

    init(
        read: @escaping @Sendable () async throws -> SafeEjectAPFSTopology,
        retryCleanup: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.read = read
        self.retryCleanup = retryCleanup
    }

    convenience init() {
        let reader = SafeEjectAPFSReader()
        self.init(
            read: { try await reader.read() },
            retryCleanup: { try await reader.retryCleanup() }
        )
    }

    func start(didChange: @escaping @MainActor () -> Void) {
        active = true
        self.didChange = didChange
        invalidate()
    }

    func stop() {
        active = false
        revision = UUID()
        value = nil
        failure = cleanupFailure
        refreshRequested = false
        reader?.cancel()
        didChange = nil
    }

    func invalidate() {
        revision = UUID()
        value = nil
        failure = cleanupFailure
        refreshRequested = active
        reader?.cancel()
        scheduleUpdate()
    }

    func cancelPreflight() {
        guard preflightToken != nil else { return }
        preflightCancelled = true
        reader?.cancel()
    }

    func drain() async -> Result<Void, SafeEjectFailure> {
        if let cleanup { return await cleanup.value }
        let task = Task { [self] () -> Result<Void, SafeEjectFailure> in
            reader?.cancel()
            await finishReader()
            if let update { await update.value }
            let result: Result<Void, SafeEjectFailure>
            do {
                try await retryCleanup()
                cleanupFailure = nil
                refreshRequested = active
                if failure == .cleanupPending { failure = nil }
                result = .success(())
            } catch {
                cleanupFailure = .cleanupPending
                failure = .cleanupPending
                result = .failure(.cleanupPending)
            }
            cleanup = nil
            if active { didChange?() }
            scheduleUpdate()
            return result
        }
        cleanup = task
        return await task.value
    }

    func fresh() async throws -> SafeEjectAPFSTopology {
        guard cleanupFailure == nil else { throw SafeEjectFailure.cleanupPending }
        guard active else { throw SafeEjectFailure.paused }
        guard cleanup == nil else { throw SafeEjectFailure.operationInProgress }
        guard preflightToken == nil else { throw SafeEjectFailure.operationInProgress }
        let token = UUID()
        let revision = revision
        preflightToken = token
        preflightCancelled = false
        refreshRequested = false
        value = nil
        failure = cleanupFailure
        reader?.cancel()
        defer {
            if preflightToken == token {
                preflightToken = nil
                scheduleUpdate()
            }
        }
        await finishReader()
        guard cleanupFailure == nil else { throw SafeEjectFailure.cleanupPending }
        guard active, self.revision == revision, !preflightCancelled, !Task.isCancelled else {
            throw SafeEjectFailure.interrupted
        }
        guard cleanup == nil else { throw SafeEjectFailure.operationInProgress }
        let task = beginReader()
        let result = await withTaskCancellationHandler {
            await task.value.result
        } onCancel: {
            task.value.cancel()
        }
        releaseReader(token: task.token, result: result)
        guard cleanupFailure == nil else { throw SafeEjectFailure.cleanupPending }
        guard active, self.revision == revision, !preflightCancelled,
            !Task.isCancelled, !task.value.isCancelled
        else { throw SafeEjectFailure.interrupted }
        let topology = try result.get()
        value = topology
        return topology
    }

    private func scheduleUpdate() {
        guard active, refreshRequested, update == nil, preflightToken == nil,
            cleanup == nil, cleanupFailure == nil
        else { return }
        update = Task { [weak self] in
            guard let self else { return }
            while self.active, self.refreshRequested, self.preflightToken == nil,
                self.cleanup == nil, self.cleanupFailure == nil
            {
                self.refreshRequested = false
                let revision = self.revision
                await self.finishReader()
                guard self.active, self.revision == revision, self.preflightToken == nil,
                    self.cleanup == nil, self.cleanupFailure == nil
                else { continue }
                let task = self.beginReader()
                let result = await task.value.result
                self.releaseReader(token: task.token, result: result)
                guard self.active, self.revision == revision, self.preflightToken == nil,
                    !task.value.isCancelled
                else { continue }
                switch result {
                case .success(let value): self.value = value
                case .failure: self.failure = self.cleanupFailure ?? .incompleteInventory
                }
                self.didChange?()
            }
            self.update = nil
            self.scheduleUpdate()
        }
    }

    private func beginReader() -> (token: UUID, value: Task<SafeEjectAPFSTopology, Error>) {
        let read = read
        let task = Task { try await read() }
        let token = UUID()
        reader = task
        readerToken = token
        return (token, task)
    }

    private func finishReader() async {
        guard let reader, let token = readerToken else { return }
        let result = await reader.result
        releaseReader(token: token, result: result)
    }

    private func releaseReader(token: UUID, result: Result<SafeEjectAPFSTopology, Error>) {
        guard readerToken == token else { return }
        if case .failure(let error) = result, error as? SafeEjectAPFSError == .cleanupFailed {
            cleanupFailure = .cleanupPending
            failure = .cleanupPending
            value = nil
            if active { didChange?() }
        }
        reader = nil
        readerToken = nil
    }
}
