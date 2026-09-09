// Semper/Audio/DDC/DDCController.swift
// High-level DDC display enumeration, CoreAudio matching, and volume control

#if !APP_STORE

import AppKit
import AudioToolbox
import os

enum DDCWriteResult: Sendable {
    case applied(Int)
    case failed(restoredVolume: Int?, restoredMute: Bool?)
}

struct DDCWriteLedger {
    enum Resolution: Equatable {
        case applied(Int)
        case failed(restoredVolume: Int?)
    }

    private(set) var confirmedVolumes: [AudioDeviceID: Int] = [:]
    private var currentGenerations: [AudioDeviceID: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    private var minimumConfirmationGeneration: UInt64 = 0

    mutating func replaceConfirmedVolumes(_ volumes: [AudioDeviceID: Int]) {
        confirmedVolumes = volumes
        minimumConfirmationGeneration = nextGeneration &+ 1
    }

    mutating func beginWrite(for deviceID: AudioDeviceID) -> UInt64 {
        nextGeneration &+= 1
        currentGenerations[deviceID] = nextGeneration
        return nextGeneration
    }

    mutating func finishWrite(
        for deviceID: AudioDeviceID,
        generation: UInt64,
        requestedVolume: Int,
        succeeded: Bool
    ) -> Resolution? {
        if succeeded, generation >= minimumConfirmationGeneration {
            confirmedVolumes[deviceID] = requestedVolume
        }

        guard currentGenerations[deviceID] == generation else { return nil }
        currentGenerations.removeValue(forKey: deviceID)
        if succeeded {
            return .applied(requestedVolume)
        }
        return .failed(restoredVolume: confirmedVolumes[deviceID])
    }

    mutating func cancelWrite(for deviceID: AudioDeviceID, generation: UInt64) -> Resolution? {
        guard currentGenerations[deviceID] == generation else { return nil }
        currentGenerations.removeValue(forKey: deviceID)
        return .failed(restoredVolume: confirmedVolumes[deviceID])
    }
}

private final class DDCWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelledStorage = false

    var isCancelled: Bool {
        lock.withLock { isCancelledStorage }
    }

    func cancel() {
        lock.withLock { isCancelledStorage = true }
    }
}

final class DDCSerializedOperationContext: @unchecked Sendable {
    private enum State {
        case pending
        case mutationClaimed
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state: State = .pending

    func claimMutation() throws {
        try lock.withLock {
            switch state {
            case .pending:
                state = .mutationClaimed
            case .mutationClaimed:
                return
            case .cancelled, .completed:
                throw CancellationError()
            }
        }
    }

    fileprivate func cancel() {
        lock.withLock {
            if case .pending = state {
                state = .cancelled
            }
        }
    }

    fileprivate func start() throws {
        try lock.withLock {
            if case .cancelled = state {
                throw CancellationError()
            }
        }
    }

    fileprivate func complete() throws {
        try lock.withLock {
            if case .cancelled = state {
                state = .completed
                throw CancellationError()
            }
            state = .completed
        }
    }

    fileprivate func resolvedError(_ error: Error) -> Error {
        lock.withLock {
            defer { state = .completed }
            if case .cancelled = state {
                return CancellationError()
            }
            return error
        }
    }
}

@Observable
@MainActor
final class DDCController {
    /// Set of CoreAudio AudioDeviceIDs that are backed by DDC volume control
    private(set) var ddcBackedDevices: Set<AudioDeviceID> = []

    /// Cached DDC volumes for each backed device (0-100)
    private(set) var cachedVolumes: [AudioDeviceID: Int] = [:]

    private var services: [AudioDeviceID: DDCService] = [:]
    private var deviceUIDs: [AudioDeviceID: String] = [:]  // For persistence keying
    private struct PendingWrite {
        let deviceID: AudioDeviceID
        let generation: UInt64
        let context: DDCSerializedOperationContext
        let admissionGate: MutationAdmissionGate?
        let admissionPermit: MutationAdmissionPermit?
    }
    private enum QueuedWriteOutcome: Sendable {
        case completed(succeeded: Bool)
        case cancelled
    }

    private var pendingWrites: [UUID: PendingWrite] = [:]
    private var latestWriteIDs: [AudioDeviceID: UUID] = [:]
    private var pendingMuteRestores: [AudioDeviceID: Bool] = [:]
    private var writeLedger = DDCWriteLedger()
    private var serviceWritesCancellation = DDCWriteCancellation()
    private var probeWorkItem: DispatchWorkItem?
    private var probeRequests = DDCProbeRequestState()
    private var displayChangeObserver: NSObjectProtocol?
    private var mutationAdmission: MutationAdmissionGate?
    private var acceptsWrites = true
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private let ddcQueue: DispatchQueue
    private let settingsManager: SettingsManager
    private let writeScheduler: (@Sendable (DispatchQueue, sending DispatchWorkItem) -> Void)?
    private let volumeWrite: (@Sendable (DDCService?, Int) throws -> Void)?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Semper", category: "DDCController")

    /// Callback when DDC probe completes (triggers device list refresh)
    var onProbeCompleted: (() -> Void)?
    var onWriteResult: ((AudioDeviceID, DDCWriteResult) -> Void)?

    init(
        settingsManager: SettingsManager,
        ddcQueue: DispatchQueue = DispatchQueue(label: "com.semper.ddc", qos: .utility),
        writeScheduler: (@Sendable (DispatchQueue, sending DispatchWorkItem) -> Void)? = nil,
        volumeWrite: (@Sendable (DDCService?, Int) throws -> Void)? = nil
    ) {
        self.settingsManager = settingsManager
        self.ddcQueue = ddcQueue
        self.writeScheduler = writeScheduler
        self.volumeWrite = volumeWrite
    }

    // MARK: - Lifecycle

    func start() {
        guard drainWaiters.isEmpty else { return }
        acceptsWrites = true
        probe()
        setupDisplayChangeObserver()
    }

    func stop() {
        acceptsWrites = false
        if let obs = displayChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            displayChangeObserver = nil
        }
        probeWorkItem?.cancel()
        probeWorkItem = nil
        probeRequests.cancel()
        serviceWritesCancellation.cancel()
        cancelPendingWrites()
    }

    func stopAndDrain() async {
        stop()
        guard !pendingWrites.isEmpty else { return }

        await withCheckedContinuation { continuation in
            if pendingWrites.isEmpty {
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
            }
        }
    }

    @discardableResult
    func installMutationAdmission(_ gate: MutationAdmissionGate) -> Bool {
        if mutationAdmission === gate { return true }
        guard pendingWrites.isEmpty else { return false }
        mutationAdmission = gate
        return true
    }

    /// Executes display-control work on the same serial queue as audio DDC traffic.
    func performSerialized<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await performSerialized { _ in
            try operation()
        }
    }

    /// Executes mutating work with cancellation arbitration at the hardware boundary.
    func performSerialized<T: Sendable>(
        _ operation: @escaping @Sendable (DDCSerializedOperationContext) throws -> T
    ) async throws -> T {
        let queue = ddcQueue
        let context = DDCSerializedOperationContext()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try context.start()
                        let value = try operation(context)
                        try context.complete()
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: context.resolvedError(error))
                    }
                }
            }
        } onCancel: {
            context.cancel()
        }
    }

    // MARK: - Public API

    /// Whether this CoreAudio device has DDC volume control.
    func isDDCBacked(_ deviceID: AudioDeviceID) -> Bool {
        ddcBackedDevices.contains(deviceID)
    }

    /// Gets the cached DDC volume for a device (0-100), or nil if not DDC-backed.
    func getVolume(for deviceID: AudioDeviceID) -> Int? {
        cachedVolumes[deviceID]
    }

    /// Returns the last volume confirmed by a completed DDC write or probe.
    func getConfirmedVolume(for deviceID: AudioDeviceID) -> Int? {
        writeLedger.confirmedVolumes[deviceID]
    }

    /// Sets the DDC volume for a device (0-100). Debounced to avoid I2C bus spam.
    @discardableResult
    func setVolume(for deviceID: AudioDeviceID, to volume: Int) -> Bool {
        scheduleVolume(for: deviceID, to: volume) {}
    }

    private func scheduleVolume(
        for deviceID: AudioDeviceID,
        to volume: Int,
        preparation: () -> Void
    ) -> Bool {
        guard acceptsWrites else { return false }

        let admissionGate = mutationAdmission
        let admissionPermit: MutationAdmissionPermit?
        if let admissionGate {
            do {
                admissionPermit = try admissionGate.acquire(owner: .manual, mode: .shared)
            } catch {
                return false
            }
        } else {
            admissionPermit = nil
        }

        let clamped = max(0, min(100, volume))
        preparation()
        if let latestWriteID = latestWriteIDs[deviceID] {
            pendingWrites[latestWriteID]?.context.cancel()
        }
        let generation = writeLedger.beginWrite(for: deviceID)
        cachedVolumes[deviceID] = clamped

        // Persist
        if let uid = deviceUIDs[deviceID] {
            settingsManager.setDDCVolume(for: uid, to: clamped)
        }

        let operationID = UUID()
        let context = DDCSerializedOperationContext()
        let serviceWritesCancellation = self.serviceWritesCancellation
        let service = services[deviceID]
        let volumeWrite = self.volumeWrite
        let logger = self.logger
        let completion: @MainActor @Sendable (QueuedWriteOutcome) -> Void = { [self] outcome in
            handleWriteCompletion(
                operationID: operationID,
                requestedVolume: clamped,
                outcome: outcome
            )
        }
        let item = DispatchWorkItem { @Sendable in
            let outcome: QueuedWriteOutcome
            do {
                if serviceWritesCancellation.isCancelled {
                    context.cancel()
                }
                try context.start()
                if let volumeWrite {
                    try context.claimMutation()
                    try volumeWrite(service, clamped)
                } else {
                    guard let service else { throw DDCWriteError.missingService }
                    try context.claimMutation()
                    try service.setAudioVolume(clamped)
                }
                try context.complete()
                outcome = .completed(succeeded: true)
            } catch {
                let resolvedError = context.resolvedError(error)
                if resolvedError is CancellationError {
                    outcome = .cancelled
                } else {
                    logger.error("DDC write failed for device \(deviceID): \(resolvedError)")
                    outcome = .completed(succeeded: false)
                }
            }
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
        pendingWrites[operationID] = PendingWrite(
            deviceID: deviceID,
            generation: generation,
            context: context,
            admissionGate: admissionGate,
            admissionPermit: admissionPermit
        )
        latestWriteIDs[deviceID] = operationID
        if let writeScheduler {
            writeScheduler(ddcQueue, item)
        } else {
            ddcQueue.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
        }
        return true
    }

    private func handleWriteCompletion(
        operationID: UUID,
        requestedVolume: Int,
        outcome: QueuedWriteOutcome
    ) {
        guard let pending = pendingWrites[operationID] else { return }
        let deviceID = pending.deviceID
        let resolution: DDCWriteLedger.Resolution?
        switch outcome {
        case .completed(let succeeded):
            resolution = writeLedger.finishWrite(
                for: deviceID,
                generation: pending.generation,
                requestedVolume: requestedVolume,
                succeeded: succeeded
            )
        case .cancelled:
            resolution = writeLedger.cancelWrite(
                for: deviceID,
                generation: pending.generation
            )
        }

        if let resolution {
            switch resolution {
            case .applied(let volume):
                cachedVolumes[deviceID] = volume
                if let uid = deviceUIDs[deviceID] {
                    settingsManager.setDDCVolume(for: uid, to: volume)
                }
                pendingMuteRestores.removeValue(forKey: deviceID)
                onWriteResult?(deviceID, .applied(volume))
            case .failed(let restoredVolume):
                publishFailedWrite(for: deviceID, restoredVolume: restoredVolume)
            }
        }

        if latestWriteIDs[deviceID] == operationID {
            latestWriteIDs.removeValue(forKey: deviceID)
        }
        if let admissionGate = pending.admissionGate,
           let admissionPermit = pending.admissionPermit {
            _ = admissionGate.release(admissionPermit)
        }
        pendingWrites.removeValue(forKey: operationID)
        resumeDrainWaitersIfNeeded()
    }

    private func cancelPendingWrites() {
        for pending in pendingWrites.values {
            pending.context.cancel()
        }
    }

    private func resumeDrainWaitersIfNeeded() {
        guard pendingWrites.isEmpty, !drainWaiters.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func publishFailedWrite(for deviceID: AudioDeviceID, restoredVolume: Int?) {
        if let restoredVolume {
            cachedVolumes[deviceID] = restoredVolume
            if let uid = deviceUIDs[deviceID] {
                settingsManager.setDDCVolume(for: uid, to: restoredVolume)
            }
        } else {
            cachedVolumes.removeValue(forKey: deviceID)
        }

        let restoredMute = pendingMuteRestores.removeValue(forKey: deviceID)
        if let restoredMute, let uid = deviceUIDs[deviceID] {
            settingsManager.setDDCMuteState(for: uid, to: restoredMute)
        }
        onWriteResult?(
            deviceID,
            .failed(restoredVolume: restoredVolume, restoredMute: restoredMute)
        )
    }

    private enum DDCWriteError: Error {
        case missingService
    }

    /// Software mute: saves current volume, sets to 0.
    @discardableResult
    func mute(for deviceID: AudioDeviceID) -> Bool {
        guard let uid = deviceUIDs[deviceID] else { return false }
        let restoredMute = pendingMuteRestores[deviceID]
            ?? settingsManager.getDDCMuteState(for: uid)
        let currentVolume = cachedVolumes[deviceID] ?? 50
        return scheduleVolume(for: deviceID, to: 0) {
            pendingMuteRestores[deviceID] = restoredMute
            if currentVolume > 0 {
                settingsManager.setDDCSavedVolume(for: uid, to: currentVolume)
            }
            settingsManager.setDDCMuteState(for: uid, to: true)
            // Flush immediately so pre-mute volume survives a crash
            settingsManager.flushSync()
        }
    }

    /// Software unmute: restores saved volume.
    @discardableResult
    func unmute(for deviceID: AudioDeviceID, maximumVolume: Int? = nil) -> Bool {
        guard let uid = deviceUIDs[deviceID] else { return false }
        let restoredMute = pendingMuteRestores[deviceID]
            ?? settingsManager.getDDCMuteState(for: uid)
        let savedVolume = settingsManager.getDDCSavedVolume(for: uid) ?? 50
        let restoredVolume = Self.restoredVolume(savedVolume, maximumVolume: maximumVolume)
        return scheduleVolume(for: deviceID, to: restoredVolume) {
            pendingMuteRestores[deviceID] = restoredMute
            settingsManager.setDDCMuteState(for: uid, to: false)
        }
    }

    nonisolated static func restoredVolume(_ savedVolume: Int, maximumVolume: Int?) -> Int {
        max(0, min(100, min(savedVolume, maximumVolume ?? savedVolume)))
    }

    /// Returns software mute state.
    func isMuted(for deviceID: AudioDeviceID) -> Bool {
        guard let uid = deviceUIDs[deviceID] else { return false }
        return settingsManager.getDDCMuteState(for: uid)
    }

    // MARK: - Display Probing

    /// Probes for DDC-capable displays on a background queue, then matches to CoreAudio devices.
    func probe(
        operation: @escaping DDCProbeRunner.Operation = DDCProbeWorker.run
    ) {
        serviceWritesCancellation.cancel()
        cancelPendingWrites()

        let input = probeRequests.begin()
        let completion: @MainActor @Sendable (DDCProbeResult) -> Void = { [weak self] result in
            self?.receiveProbeResult(result)
        }
        DDCProbeRunner.submit(
            on: ddcQueue,
            input: input,
            operation: operation,
            completion: completion
        )
    }

    private func receiveProbeResult(_ result: DDCProbeResult) {
        guard probeRequests.accept(result) else { return }

        for record in result.logs {
            switch record {
            case .info(let message):
                logger.info("\(message, privacy: .private)")
            case .error(let message):
                logger.error("\(message, privacy: .private)")
            }
        }

        applyProbePublication(result.publication)
    }

    func applyProbePublication(_ publication: DDCProbePublication) {
        serviceWritesCancellation.cancel()
        cancelPendingWrites()
        serviceWritesCancellation = DDCWriteCancellation()
        switch publication {
        case .unavailable:
            ddcBackedDevices = []
            services = [:]
            writeLedger.replaceConfirmedVolumes([:])

        case .matched(let services, let deviceUIDs, let readVolumes):
            self.services = services
            self.deviceUIDs = deviceUIDs
            ddcBackedDevices = Set(services.keys)

            var savedVolumes: [AudioDeviceID: Int] = [:]
            for (deviceID, uid) in deviceUIDs {
                savedVolumes[deviceID] = settingsManager.getDDCVolume(for: uid)
            }
            let volumePlan = DDCProbeVolumePlan.make(
                deviceIDs: Array(deviceUIDs.keys),
                readVolumes: readVolumes,
                savedVolumes: savedVolumes
            )
            cachedVolumes = volumePlan.cachedVolumes
            writeLedger.replaceConfirmedVolumes(readVolumes)
            for (deviceID, volume) in volumePlan.restoreVolumes {
                setVolume(for: deviceID, to: volume)
            }

            logger.info("DDC probe complete: \(services.count) display(s) matched")
        }

        onProbeCompleted?()
    }

    // MARK: - Display Change Observer

    private func setupDisplayChangeObserver() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.probeRequests.cancel()
                self.probeWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.logger.debug("Display configuration changed, re-probing DDC (after delay)")
                        self.probe()
                    }
                }
                self.probeWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
            }
        }
    }
}

#endif
