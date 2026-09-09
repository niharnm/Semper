import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated struct ShelfImageCopyRequest: Identifiable, Sendable {
    let id: UUID
    let itemID: UUID
    let name: String
}

@MainActor
protocol ShelfImageDestinationChoosing: AnyObject {
    func chooseDestination(for plan: ShelfImageCopyPlan, size: ShelfImageCopySize) async -> URL?
    func cancel()
}

@MainActor
final class NativeShelfImageDestinationChooser: ShelfImageDestinationChoosing {
    private var panel: NSSavePanel?

    func chooseDestination(for plan: ShelfImageCopyPlan, size: ShelfImageCopySize) async -> URL? {
        guard panel == nil, !Task.isCancelled else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [plan.format == .jpeg ? .jpeg : .png]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = plan.suggestedFilename(for: size)
        panel.prompt = "Save Copy"
        panel.message = "Choose a new filename. Existing files and the original image will not be replaced."
        self.panel = panel
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                Task { @MainActor in
                    if self.panel === panel { self.panel = nil }
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
    }

    func cancel() { panel?.cancel(nil) }
}

@Observable
@MainActor
final class ShelfImageCopySession {
    private(set) var request: ShelfImageCopyRequest?
    private(set) var plan: ShelfImageCopyPlan?
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var receipt: ShelfImageCopyReceipt?

    var isActive: Bool { request != nil || isWorking || needsCleanup }
    var needsCleanup: Bool { pendingCleanup != nil }
    var recoveryLocations: [URL] {
        switch pendingCleanup?.copy {
        case .temporary(let stage): stage.recoveryLocations
        case .published(let copy): copy.recoveryLocations
        case nil: []
        }
    }

    private enum PendingCopy: Sendable {
        case temporary(ShelfImageTemporaryCopy)
        case published(ShelfImagePublishedCopy)
    }

    private struct PendingCleanup {
        let copy: PendingCopy
        let destination: URL
        let scoped: Bool
    }

    private let access: any ShelfFileAccess
    private let copier: any ShelfImageCopying
    private let destinationChooser: any ShelfImageDestinationChoosing
    private var pendingCleanup: PendingCleanup?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancellation: Task<Result<Void, ShelfFailure>, Never>?
    @ObservationIgnored private var cancellationRequested = false

    init(
        access: any ShelfFileAccess = NativeShelfFileAccess(),
        copier: any ShelfImageCopying = NativeShelfImageCopier(),
        destinationChooser: any ShelfImageDestinationChoosing = NativeShelfImageDestinationChooser()
    ) {
        self.access = access
        self.copier = copier
        self.destinationChooser = destinationChooser
    }

    @discardableResult
    func begin(itemID: UUID, name: String, source: URL) -> ShelfImageCopyRequest? {
        guard !isActive, work == nil, cancellation == nil, activeID == nil else { return nil }
        let request = ShelfImageCopyRequest(id: UUID(), itemID: itemID, name: name)
        activeID = request.id
        cancellationRequested = false
        work = Task { await inspect(source, requestID: request.id) }
        isWorking = true
        plan = nil
        receipt = nil
        message = nil
        self.request = request
        return request
    }

    @discardableResult
    func save(size: ShelfImageCopySize) -> Bool {
        guard let request, let plan, activeID == request.id, !isWorking,
            work == nil, cancellation == nil, !cancellationRequested, !needsCleanup, receipt == nil
        else { return false }
        work = Task { await save(plan, size: size, requestID: request.id) }
        isWorking = true
        message = nil
        return true
    }

    func stop() {
        guard activeID != nil || work != nil || cancellation != nil || needsCleanup else { return }
        cancellationRequested = true
        work?.cancel()
        destinationChooser.cancel()
        isWorking = true
    }

    func cancel(requestID: UUID? = nil) async -> Result<Void, ShelfFailure> {
        if let requestID, requestID != activeID { return .success(()) }
        if let cancellation { return await cancellation.value }
        guard activeID != nil || work != nil || needsCleanup else { return .success(()) }
        cancellationRequested = true
        let currentWork = work
        let cancellation = Task { @MainActor in
            await currentWork?.value
            let result = await self.retryCleanup()
            if case .success = result {
                self.activeID = nil
                self.request = nil
                self.plan = nil
                self.message = nil
                self.cancellationRequested = false
            }
            self.cancellation = nil
            self.isWorking = false
            return result
        }
        self.cancellation = cancellation
        currentWork?.cancel()
        destinationChooser.cancel()
        isWorking = true
        return await cancellation.value
    }

    private func inspect(_ source: URL, requestID: UUID) async {
        defer { finishWork(requestID: requestID) }
        guard !Task.isCancelled, !cancellationRequested else { return }
        let copier = copier
        let access = access
        let worker = Task.detached(priority: .userInitiated) { try copier.inspect(source, access: access) }
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
        }
        guard activeID == requestID, !Task.isCancelled, !cancellationRequested else { return }
        switch result {
        case .success(let plan): self.plan = plan
        case .failure(let error): report(error)
        }
    }

    private func save(_ plan: ShelfImageCopyPlan, size: ShelfImageCopySize, requestID: UUID) async {
        defer { finishWork(requestID: requestID) }
        guard !Task.isCancelled, !cancellationRequested,
            let destination = await destinationChooser.chooseDestination(for: plan, size: size),
            !Task.isCancelled, !cancellationRequested, activeID == requestID
        else { return }
        let scoped = access.begin(destination)
        let copier = copier
        let worker = Task.detached(priority: .userInitiated) {
            try copier.writeCopy(plan, size: size, to: destination)
        }
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
        }
        switch result {
        case .success(let receipt):
            if scoped { access.end(destination) }
            self.receipt = receipt
        case .failure(let error):
            if let failure = error as? ShelfImageCopyFailure {
                let recovery: PendingCopy?
                switch failure {
                case .cleanupFailed(let stage): recovery = .temporary(stage)
                case .publicationUncertain(let copy): recovery = .published(copy)
                default: recovery = nil
                }
                if let recovery {
                    pendingCleanup = PendingCleanup(copy: recovery, destination: destination, scoped: scoped)
                    message = failure.localizedDescription
                    return
                }
            }
            if scoped { access.end(destination) }
            if !Task.isCancelled, !cancellationRequested { report(error) }
        }
    }

    private func finishWork(requestID: UUID) {
        guard activeID == requestID else { return }
        work = nil
        if !cancellationRequested, cancellation == nil { isWorking = false }
    }

    private func retryCleanup() async -> Result<Void, ShelfFailure> {
        guard let pendingCleanup else { return .success(()) }
        let copier = copier
        let copy = pendingCleanup.copy
        let worker = Task<ShelfImageCopyReceipt?, Error>.detached(priority: .utility) {
            switch copy {
            case .temporary(let stage):
                try copier.removeTemporaryCopy(stage)
                return nil
            case .published(let published):
                return try copier.recoverPublishedCopy(published)
            }
        }
        switch await worker.result {
        case .success(let receipt):
            if let receipt { self.receipt = receipt }
            if pendingCleanup.scoped { access.end(pendingCleanup.destination) }
            self.pendingCleanup = nil
            return .success(())
        case .failure(let error):
            message = error.localizedDescription
            return .failure(.storeWrite)
        }
    }

    private func report(_ error: any Error) {
        if error is CancellationError || error as? ShelfFailure == .cancelled { return }
        message = error.localizedDescription
    }
}
