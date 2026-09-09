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
    private var snapshot = SafeEjectInventory(volumes: [], hasUnidentifiedLocalVolumes: false)
    @ObservationIgnored private let backend: any SafeEjectBackend
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cleanupEpoch = UUID()
    @ObservationIgnored private var cleanupWait: Task<Result<Void, SafeEjectFailure>, Never>?

    init(backend: any SafeEjectBackend = DiskArbitrationSafeEjectBackend()) {
        self.backend = backend
    }

    isolated deinit {
        backend.stop()
    }

    func start() {
        guard state == .paused, cleanupFailure == nil, cleanupWait == nil else { return }
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
        invalidateOperation()
        backend.stop()
        state = .paused
        volumes = []
        snapshot = SafeEjectInventory(volumes: [], hasUnidentifiedLocalVolumes: false)
        inventoryFailure = nil
    }

    func shutdown() {
        pause()
        state = .shutDown
        receipts = []
    }

    @discardableResult
    func waitForCleanup() async -> Result<Void, SafeEjectFailure> {
        if let cleanupWait { return await cleanupWait.value }
        let task = Task { [self] () -> Result<Void, SafeEjectFailure> in
            let result = await backend.drain()
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

    func refusal(for volume: SafeEjectVolume) -> SafeEjectFailure? {
        if let cleanupFailure { return cleanupFailure }
        guard state == .running else { return state == .sleeping ? .sleeping : .paused }
        guard activeVolumeID == nil else { return .operationInProgress }
        if inventoryFailure == .unavailable { return .unavailable }
        return snapshot.refusal(for: volume)
    }

    @discardableResult
    func eject(_ selected: SafeEjectVolume) async -> SafeEjectOutcome {
        if let failure = refusal(for: selected) {
            return record(.refused(failure), for: selected)
        }
        refresh()
        if let failure = refusal(for: selected) {
            return record(.refused(failure), for: selected)
        }
        guard let deviceID = selected.deviceID else {
            return record(.refused(.unknownDevice), for: selected)
        }
        let operation = UUID()
        let cleanupEpoch = cleanupEpoch
        generation = operation
        activeVolumeID = selected.id
        defer {
            if generation == operation { activeVolumeID = nil }
        }
        let unmountResult = await backend.unmount(selected)
        if case .failure(.cleanupPending) = unmountResult, self.cleanupEpoch == cleanupEpoch {
            cleanupFailure = .cleanupPending
        }
        guard state == .running, generation == operation, !Task.isCancelled else {
            return recordUnlessShutdown(.unverified(.interrupted), for: selected)
        }
        if case .failure(let failure) = unmountResult {
            refresh()
            return record(.unverified(failure), for: selected)
        }
        refresh()
        guard inventoryFailure != .unavailable else {
            return record(.unverified(.unavailable), for: selected)
        }
        guard !snapshot.volumes.contains(where: { $0.id == selected.id }) else {
            return record(.unverified(.stillMounted), for: selected)
        }
        if let failure = snapshot.conflict(with: deviceID) {
            return record(.unmountedOnly(failure), for: selected)
        }
        switch backend.devicePresence(deviceID) {
        case .present: break
        case .absent:
            return record(.unmountedOnly(.changedVolume), for: selected)
        case .unavailable:
            return record(.unmountedOnly(.unavailable), for: selected)
        }
        let ejectResult = await backend.ejectDevice(containing: selected)
        if case .failure(.cleanupPending) = ejectResult, self.cleanupEpoch == cleanupEpoch {
            cleanupFailure = .cleanupPending
        }
        guard state == .running, generation == operation, !Task.isCancelled else {
            return recordUnlessShutdown(.unverified(.interrupted), for: selected)
        }
        refresh()
        if case .failure(let failure) = ejectResult {
            return record(.unmountedOnly(failure), for: selected)
        }
        guard inventoryFailure != .unavailable else {
            return record(.unverified(.unavailable), for: selected)
        }
        guard
            !snapshot.volumes.contains(where: {
                $0.deviceID == deviceID || $0.id.mountURL == selected.id.mountURL
            })
        else {
            return record(.unverified(.stillMounted), for: selected)
        }
        if let failure = snapshot.conflict(with: deviceID) {
            return record(.unverified(failure), for: selected)
        }
        switch backend.devicePresence(deviceID) {
        case .absent: break
        case .present:
            return record(.unmountedOnly(.deviceStillPresent), for: selected)
        case .unavailable:
            return record(.unverified(.unavailable), for: selected)
        }
        return record(.ejected, for: selected)
    }

    func clearResults() {
        receipts = []
    }

    private func receive(_ event: SafeEjectSystemEvent) {
        guard state == .running || state == .sleeping else { return }
        switch event {
        case .volumesChanged:
            refresh()
        case .willSleep:
            invalidateOperation()
            state = .sleeping
            volumes = []
        case .didWake:
            generation = UUID()
            state = .running
            refresh()
        }
    }

    private func invalidateOperation() {
        generation = UUID()
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
