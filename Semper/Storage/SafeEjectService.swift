import Foundation
import Observation

@Observable
@MainActor
final class SafeEjectService {
    enum State: Equatable {
        case paused
        case running
        case sleeping
        case shutDown
    }

    private(set) var state: State = .paused
    private(set) var volumes: [SafeEjectVolume] = []
    private(set) var inventoryFailure: SafeEjectFailure?
    private(set) var cleanupFailure: SafeEjectFailure?
    private(set) var activeVolumeID: SafeEjectVolumeID?
    private(set) var receipts: [SafeEjectReceipt] = []
    private(set) var pendingBatchConfirmation: SafeEjectBatchConfirmation?
    private(set) var batchProgress: SafeEjectBatchProgress?
    private(set) var lastBatchResult: SafeEjectBatchResult?
    private var operationID: UUID?
    private var operationStopReason: SafeEjectBatchStopReason?
    var isEjecting: Bool { operationID != nil }
    private var snapshot = SafeEjectInventory(volumes: [], hasUnidentifiedLocalVolumes: false)
    @ObservationIgnored private let backend: any SafeEjectBackend
    @ObservationIgnored private var mutationAdmission: MutationAdmissionGate?
    @ObservationIgnored private var mutationPermit: MutationAdmissionPermit?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopGeneration = UUID()
    @ObservationIgnored private var cleanupEpoch = UUID()
    @ObservationIgnored private var cleanupWait: Task<Result<Void, SafeEjectFailure>, Never>?

    init(
        backend: any SafeEjectBackend = DiskArbitrationSafeEjectBackend(),
        mutationAdmission: MutationAdmissionGate? = nil
    ) {
        self.backend = backend
        self.mutationAdmission = mutationAdmission
    }

    func installMutationAdmission(_ gate: MutationAdmissionGate) throws {
        guard state == .paused, operationID == nil, cleanupWait == nil, cleanupFailure == nil,
            mutationPermit == nil, mutationAdmission == nil || mutationAdmission === gate
        else { throw SafeEjectFailure.operationInProgress }
        mutationAdmission = gate
    }

    isolated deinit {
        backend.stop()
    }

    func start() {
        guard state == .paused, cleanupFailure == nil, cleanupWait == nil, operationID == nil else { return }
        do {
            try backend.start { [weak self] event in self?.receive(event) }
            state = .running
            refresh()
        } catch {
            backend.stop()
            if error as? SafeEjectFailure == .cleanupPending { cleanupFailure = .cleanupPending }
            inventoryFailure = cleanupFailure ?? .unavailable
        }
    }

    func pause() {
        guard state != .shutDown else { return }
        stopGeneration = UUID()
        invalidateOperation(reason: .paused)
        backend.stop()
        state = .paused
        volumes = []
        snapshot = SafeEjectInventory(volumes: [], hasUnidentifiedLocalVolumes: false)
        inventoryFailure = nil
    }

    func shutdown() {
        pause()
        state = .shutDown
        if operationID != nil { operationStopReason = .shutDown }
        receipts = []
        batchProgress = nil
        lastBatchResult = nil
    }

    @discardableResult
    func waitForCleanup() async -> Result<Void, SafeEjectFailure> {
        if let cleanupWait { return await cleanupWait.value }
        let task = Task { [self] () -> Result<Void, SafeEjectFailure> in
            var drainedStopGeneration = stopGeneration
            var result = await backend.drain()
            // A newer stop must drain any reader scheduled by an earlier active retry.
            while case .success = result, drainedStopGeneration != stopGeneration {
                drainedStopGeneration = stopGeneration
                result = await backend.drain()
            }
            switch result {
            case .success:
                cleanupEpoch = UUID()
                cleanupFailure = nil
                if inventoryFailure == .cleanupPending { inventoryFailure = nil }
            case .failure(let failure):
                cleanupFailure = failure
            }
            cleanupWait = nil
            if state == .running { refresh() }
            releaseMutationPermitIfFinished()
            return result
        }
        cleanupWait = task
        return await task.value
    }

    func refresh() {
        guard state == .running else { return }
        do {
            snapshot = try backend.inventory()
            volumes = snapshot.volumes.filter(\.isCandidate).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            inventoryFailure = snapshot.hasCompleteDeviceMapping ? nil : .incompleteInventory
        } catch {
            volumes = []
            snapshot = SafeEjectInventory(volumes: [], hasUnidentifiedLocalVolumes: true)
            if error as? SafeEjectFailure == .cleanupPending { cleanupFailure = .cleanupPending }
            inventoryFailure = cleanupFailure ?? .unavailable
        }
    }

    private var admissionFailure: SafeEjectFailure? {
        if let cleanupFailure { return cleanupFailure }
        guard state == .running else { return state == .sleeping ? .sleeping : .paused }
        guard operationID == nil, cleanupWait == nil else { return .operationInProgress }
        return nil
    }

    func refusal(for volume: SafeEjectVolume) -> SafeEjectFailure? {
        if let failure = admissionFailure { return failure }
        if inventoryFailure == .unavailable { return .unavailable }
        return snapshot.refusal(for: volume)
    }

    @discardableResult
    func prepareBatch() -> Result<SafeEjectBatchConfirmation, SafeEjectFailure> {
        if let failure = admissionFailure { return .failure(failure) }
        pendingBatchConfirmation = nil
        refresh()
        if let failure = cleanupFailure { return .failure(failure) }
        if inventoryFailure == .unavailable { return .failure(.unavailable) }
        guard volumes.count <= SafeEjectBatchConfirmation.maximumVolumes else { return .failure(.batchLimitExceeded) }
        guard Set(snapshot.volumes.map(\.id)).count == snapshot.volumes.count else {
            return .failure(.incompleteInventory)
        }
        var eligible: [SafeEjectVolume] = []
        var excluded: [SafeEjectBatchExclusion] = []
        for volume in volumes {
            if let reason = snapshot.refusal(for: volume) {
                excluded.append(SafeEjectBatchExclusion(volume: volume, reason: reason))
            } else {
                eligible.append(volume)
            }
        }
        let confirmation = SafeEjectBatchConfirmation(id: UUID(), eligible: eligible, excluded: excluded)
        pendingBatchConfirmation = confirmation
        return .success(confirmation)
    }

    func discardBatchConfirmation() { pendingBatchConfirmation = nil }

    func cancelBatch() {
        guard batchProgress != nil, let operationID else { return }
        cancelOperation(operationID)
    }

    @discardableResult
    func eject(_ selected: SafeEjectVolume) async -> SafeEjectOutcome {
        if let failure = refusal(for: selected) {
            return recordUnlessShutdown(.refused(failure), for: selected)
        }
        guard acquireMutationPermit() else {
            return recordUnlessShutdown(.refused(.operationInProgress), for: selected)
        }
        let operation = beginOperation()
        let cleanupEpoch = cleanupEpoch
        defer { finishOperation(operation) }
        return await withTaskCancellationHandler {
            let outcome = await performEject(selected, operation: operation, cleanupEpoch: cleanupEpoch)
            await finishCancelledOperation(operation, cleanupEpoch: cleanupEpoch)
            return recordUnlessShutdown(outcome, for: selected)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation(operation) }
        }
    }

    @discardableResult
    func ejectBatch(confirmationID: UUID) async -> Result<SafeEjectBatchResult, SafeEjectFailure> {
        if let failure = admissionFailure { return .failure(failure) }
        guard let confirmation = pendingBatchConfirmation, confirmation.id == confirmationID else {
            return .failure(.invalidConfirmation)
        }
        pendingBatchConfirmation = nil
        guard !confirmation.eligible.isEmpty else { return .failure(.noEligibleVolumes) }
        guard acquireMutationPermit() else { return .failure(.operationInProgress) }
        let operation = beginOperation()
        var cleanupEpoch = cleanupEpoch
        batchProgress = SafeEjectBatchProgress(
            confirmationID: confirmationID, total: confirmation.eligible.count, completedCount: 0, currentVolume: nil)
        defer { finishOperation(operation) }
        return await withTaskCancellationHandler {
            var items: [SafeEjectBatchItemResult] = []
            var stopped: SafeEjectBatchStopReason?
            for volume in confirmation.eligible {
                if let reason = stopped ?? stopReason(for: operation) {
                    items.append(.init(volume: volume, outcome: .notAttempted(reason)))
                    continue
                }
                batchProgress = SafeEjectBatchProgress(
                    confirmationID: confirmationID, total: confirmation.eligible.count,
                    completedCount: items.count, currentVolume: volume)
                cleanupEpoch = self.cleanupEpoch
                let outcome = await performEject(volume, operation: operation, cleanupEpoch: cleanupEpoch)
                items.append(.init(volume: volume, outcome: .completed(outcome)))
                _ = recordUnlessShutdown(outcome, for: volume)
                stopped = stopReason(for: operation) ?? batchStopReason(after: outcome)
                if state != .shutDown {
                    batchProgress = SafeEjectBatchProgress(
                        confirmationID: confirmationID, total: confirmation.eligible.count,
                        completedCount: items.count, currentVolume: nil, isCancelling: stopped != nil)
                }
            }
            await finishCancelledOperation(operation, cleanupEpoch: cleanupEpoch)
            let result = SafeEjectBatchResult(
                confirmationID: confirmationID, items: items, excluded: confirmation.excluded)
            if state != .shutDown { lastBatchResult = result }
            return .success(result)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation(operation) }
        }
    }

    private func performEject(
        _ selected: SafeEjectVolume, operation: UUID, cleanupEpoch: UUID
    ) async -> SafeEjectOutcome {
        guard stopReason(for: operation) == nil else { return .refused(.interrupted) }
        activeVolumeID = selected.id
        refresh()
        if let failure = cleanupFailure { return .refused(failure) }
        if inventoryFailure == .unavailable { return .refused(.unavailable) }
        if let failure = snapshot.refusal(for: selected) { return .refused(failure) }
        guard let deviceID = selected.deviceID else { return .refused(.unknownDevice) }
        let unmountResult = await backend.unmount(selected)
        if case .failure(.cleanupPending) = unmountResult, self.cleanupEpoch == cleanupEpoch {
            cleanupFailure = .cleanupPending
        }
        guard interruptionReason(for: operation) == nil else {
            return .unverified(.interrupted)
        }
        if case .failure(let failure) = unmountResult {
            refresh()
            return .unverified(failure)
        }
        refresh()
        if let cleanupFailure { return .unverified(cleanupFailure) }
        guard inventoryFailure != .unavailable else {
            return .unverified(.unavailable)
        }
        guard !snapshot.volumes.contains(where: { $0.id == selected.id }) else {
            return .unverified(.stillMounted)
        }
        if let failure = snapshot.conflict(with: deviceID) {
            return .unmountedOnly(failure)
        }
        switch backend.devicePresence(deviceID) {
        case .present: break
        case .absent:
            return .unmountedOnly(.changedVolume)
        case .unavailable:
            return .unmountedOnly(.unavailable)
        }
        let ejectResult = await backend.ejectDevice(containing: selected)
        if case .failure(.cleanupPending) = ejectResult, self.cleanupEpoch == cleanupEpoch {
            cleanupFailure = .cleanupPending
        }
        guard interruptionReason(for: operation) == nil else {
            return .unverified(.interrupted)
        }
        refresh()
        if case .failure(let failure) = ejectResult {
            return .unmountedOnly(failure)
        }
        if let cleanupFailure { return .unverified(cleanupFailure) }
        guard inventoryFailure != .unavailable else {
            return .unverified(.unavailable)
        }
        guard
            !snapshot.volumes.contains(where: {
                $0.deviceID == deviceID || $0.id.mountURL == selected.id.mountURL
            })
        else {
            return .unverified(.stillMounted)
        }
        if let failure = snapshot.conflict(with: deviceID) {
            return .unverified(failure)
        }
        switch backend.devicePresence(deviceID) {
        case .absent: break
        case .present:
            return .unmountedOnly(.deviceStillPresent)
        case .unavailable:
            return .unverified(.unavailable)
        }
        return .ejected
    }

    func clearResults() {
        receipts = []
        lastBatchResult = nil
    }

    private func receive(_ event: SafeEjectSystemEvent) {
        guard state == .running || state == .sleeping else { return }
        switch event {
        case .volumesChanged:
            refresh()
        case .willSleep:
            invalidateOperation(reason: .sleeping)
            state = .sleeping
            volumes = []
        case .didWake:
            generation = UUID()
            state = .running
            refresh()
        }
    }

    private func beginOperation() -> UUID {
        let id = UUID()
        operationID = id
        generation = id
        operationStopReason = nil
        pendingBatchConfirmation = nil
        return id
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operationStopReason = nil
        activeVolumeID = nil
        batchProgress = nil
        releaseMutationPermitIfFinished()
    }

    private func acquireMutationPermit() -> Bool {
        guard mutationPermit == nil else { return false }
        guard let mutationAdmission else { return true }
        do {
            mutationPermit = try mutationAdmission.acquire(owner: .manual, mode: .shared)
            return true
        } catch {
            return false
        }
    }

    private func releaseMutationPermitIfFinished() {
        guard operationID == nil, cleanupFailure == nil, cleanupWait == nil,
            let mutationPermit, let mutationAdmission
        else { return }
        mutationAdmission.release(mutationPermit)
        self.mutationPermit = nil
    }

    private func cancelOperation(_ id: UUID) {
        guard operationID == id else { return }
        if operationStopReason == nil { operationStopReason = .cancelled }
        generation = UUID()
        batchProgress?.isCancelling = true
        backend.cancelPendingOperation()
    }

    private func stopReason(for id: UUID) -> SafeEjectBatchStopReason? {
        if let reason = interruptionReason(for: id) { return reason }
        if let cleanupFailure { return .failure(cleanupFailure) }
        return nil
    }

    private func interruptionReason(for id: UUID) -> SafeEjectBatchStopReason? {
        if let reason = operationStopReason { return reason }
        switch state {
        case .paused: return .paused
        case .sleeping: return .sleeping
        case .shutDown: return .shutDown
        case .running: break
        }
        if Task.isCancelled || generation != id { return .cancelled }
        return nil
    }

    private func finishCancelledOperation(_ id: UUID, cleanupEpoch: UUID) async {
        guard stopReason(for: id) != nil, cleanupFailure == nil, self.cleanupEpoch == cleanupEpoch else { return }
        _ = await waitForCleanup()
    }

    private func batchStopReason(after outcome: SafeEjectOutcome) -> SafeEjectBatchStopReason? {
        let failure: SafeEjectFailure
        switch outcome {
        case .ejected: return nil
        case .refused(let reason), .unmountedOnly(let reason), .unverified(let reason): failure = reason
        }
        switch failure {
        case .unavailable, .incompleteInventory, .cleanupPending, .timedOut, .topologyTimedOut,
            .interrupted, .paused, .sleeping, .operationInProgress:
            return .failure(failure)
        default: return nil
        }
    }

    private func invalidateOperation(reason: SafeEjectBatchStopReason) {
        generation = UUID()
        pendingBatchConfirmation = nil
        if operationID != nil { operationStopReason = reason }
        activeVolumeID = nil
        backend.cancelPendingOperation()
    }

    private func recordUnlessShutdown(_ outcome: SafeEjectOutcome, for volume: SafeEjectVolume) -> SafeEjectOutcome {
        if state == .shutDown { return outcome }
        return record(outcome, for: volume)
    }

    private func record(_ outcome: SafeEjectOutcome, for volume: SafeEjectVolume) -> SafeEjectOutcome {
        receipts.insert(
            SafeEjectReceipt(id: UUID(), volumeID: volume.id, volumeName: volume.name, outcome: outcome), at: 0)
        if receipts.count > 20 { receipts.removeLast(receipts.count - 20) }
        return outcome
    }
}
