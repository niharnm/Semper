import Foundation

@MainActor
final class SafeEjectTopologyCache {
    private(set) var value: SafeEjectAPFSTopology?
    private(set) var failure: SafeEjectFailure?
    private var revision = UUID()
    private var active = false
    private var refreshRequested = false
    private var update: Task<Void, Never>?
    private var reader: Task<SafeEjectAPFSTopology, Error>?
    private var readerToken: UUID?
    private var preflightToken: UUID?
    private var preflightCancelled = false
    private let read: @Sendable () async throws -> SafeEjectAPFSTopology
    private var didChange: (@MainActor () -> Void)?

    init(
        read: @escaping @Sendable () async throws -> SafeEjectAPFSTopology = { try await SafeEjectAPFSReader().read() }
    ) {
        self.read = read
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
        failure = nil
        refreshRequested = false
        reader?.cancel()
        didChange = nil
    }

    func invalidate() {
        revision = UUID()
        value = nil
        failure = nil
        refreshRequested = active
        reader?.cancel()
        scheduleUpdate()
    }

    func cancelPreflight() {
        guard preflightToken != nil else { return }
        preflightCancelled = true
        reader?.cancel()
    }

    func drain() async {
        if let reader { _ = await reader.result }
        if let update { await update.value }
    }

    func fresh() async throws -> SafeEjectAPFSTopology {
        guard active else { throw SafeEjectFailure.paused }
        guard preflightToken == nil else { throw SafeEjectFailure.operationInProgress }
        let token = UUID()
        let revision = revision
        preflightToken = token
        preflightCancelled = false
        refreshRequested = false
        value = nil
        failure = nil
        reader?.cancel()
        defer {
            if preflightToken == token {
                preflightToken = nil
                scheduleUpdate()
            }
        }
        await finishReader()
        guard active, self.revision == revision, !preflightCancelled, !Task.isCancelled else {
            throw SafeEjectFailure.interrupted
        }
        let task = beginReader()
        let result = await withTaskCancellationHandler {
            await task.value.result
        } onCancel: {
            task.value.cancel()
        }
        releaseReader(token: task.token)
        guard active, self.revision == revision, !preflightCancelled,
            !Task.isCancelled, !task.value.isCancelled
        else { throw SafeEjectFailure.interrupted }
        let topology = try result.get()
        value = topology
        return topology
    }

    private func scheduleUpdate() {
        guard active, refreshRequested, update == nil, preflightToken == nil else { return }
        update = Task { [weak self] in
            guard let self else { return }
            while self.active, self.refreshRequested, self.preflightToken == nil {
                self.refreshRequested = false
                let revision = self.revision
                await self.finishReader()
                guard self.active, self.revision == revision, self.preflightToken == nil else { continue }
                let task = self.beginReader()
                let result = await task.value.result
                self.releaseReader(token: task.token)
                guard self.active, self.revision == revision, self.preflightToken == nil,
                    !task.value.isCancelled
                else { continue }
                switch result {
                case .success(let value): self.value = value
                case .failure: self.failure = .incompleteInventory
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
        _ = await reader.result
        releaseReader(token: token)
    }

    private func releaseReader(token: UUID) {
        guard readerToken == token else { return }
        reader = nil
        readerToken = nil
    }
}
