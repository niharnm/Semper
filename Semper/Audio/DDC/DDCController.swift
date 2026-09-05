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
        let generation: UInt64
        let cancellation: DDCWriteCancellation
        let workItem: DispatchWorkItem
    }
    private var pendingWrites: [AudioDeviceID: PendingWrite] = [:]
    private var pendingMuteRestores: [AudioDeviceID: Bool] = [:]
    private var writeLedger = DDCWriteLedger()
    private var serviceWritesCancellation = DDCWriteCancellation()
    private var probeWorkItem: DispatchWorkItem?
    private var probeRequests = DDCProbeRequestState()
    private var displayChangeObserver: NSObjectProtocol?

    private let ddcQueue: DispatchQueue
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Semper", category: "DDCController")

    /// Callback when DDC probe completes (triggers device list refresh)
    var onProbeCompleted: (() -> Void)?
    var onWriteResult: ((AudioDeviceID, DDCWriteResult) -> Void)?

    init(
        settingsManager: SettingsManager,
        ddcQueue: DispatchQueue = DispatchQueue(label: "com.semper.ddc", qos: .utility)
    ) {
        self.settingsManager = settingsManager
        self.ddcQueue = ddcQueue
    }

    // MARK: - Lifecycle

    func start() {
        probe()
        setupDisplayChangeObserver()
    }

    func stop() {
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
    func setVolume(for deviceID: AudioDeviceID, to volume: Int) {
        let clamped = max(0, min(100, volume))
        cachedVolumes[deviceID] = clamped

        // Persist
        if let uid = deviceUIDs[deviceID] {
            settingsManager.setDDCVolume(for: uid, to: clamped)
        }

        // Keep the work item @Sendable and avoid `self`; otherwise it inherits
        // @MainActor isolation here and traps when run on `ddcQueue`.
        pendingWrites[deviceID]?.cancellation.cancel()
        pendingWrites[deviceID]?.workItem.cancel()
        let generation = writeLedger.beginWrite(for: deviceID)
        let cancellation = DDCWriteCancellation()
        let serviceWritesCancellation = self.serviceWritesCancellation
        let service = services[deviceID]
        let logger = self.logger
        let item = DispatchWorkItem { @Sendable [weak self] in
            guard !cancellation.isCancelled, !serviceWritesCancellation.isCancelled else { return }
            let succeeded: Bool
            do {
                guard let service else { throw DDCWriteError.missingService }
                try service.setAudioVolume(clamped)
                succeeded = true
            } catch {
                logger.error("DDC write failed for device \(deviceID): \(error)")
                succeeded = false
            }
            DispatchQueue.main.async { [weak self] in
                self?.handleWriteCompletion(
                    for: deviceID,
                    generation: generation,
                    requestedVolume: clamped,
                    succeeded: succeeded
                )
            }
        }
        pendingWrites[deviceID] = PendingWrite(
            generation: generation,
            cancellation: cancellation,
            workItem: item
        )
        ddcQueue.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }

    private func handleWriteCompletion(
        for deviceID: AudioDeviceID,
        generation: UInt64,
        requestedVolume: Int,
        succeeded: Bool
    ) {
        let resolution = writeLedger.finishWrite(
            for: deviceID,
            generation: generation,
            requestedVolume: requestedVolume,
            succeeded: succeeded
        )
        guard let resolution else { return }
        if pendingWrites[deviceID]?.generation == generation {
            pendingWrites.removeValue(forKey: deviceID)
        }

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

    private func cancelPendingWrites() {
        let writes = pendingWrites
        pendingWrites.removeAll()
        for (deviceID, pending) in writes {
            pending.cancellation.cancel()
            pending.workItem.cancel()
            guard case .failed(let restoredVolume) = writeLedger.cancelWrite(
                for: deviceID,
                generation: pending.generation
            ) else {
                continue
            }
            publishFailedWrite(for: deviceID, restoredVolume: restoredVolume)
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
    func mute(for deviceID: AudioDeviceID) {
        guard let uid = deviceUIDs[deviceID] else { return }
        pendingMuteRestores[deviceID] = pendingMuteRestores[deviceID]
            ?? settingsManager.getDDCMuteState(for: uid)
        let currentVolume = cachedVolumes[deviceID] ?? 50
        if currentVolume > 0 {
            settingsManager.setDDCSavedVolume(for: uid, to: currentVolume)
        }
        settingsManager.setDDCMuteState(for: uid, to: true)
        // Flush immediately so pre-mute volume survives a crash
        settingsManager.flushSync()
        setVolume(for: deviceID, to: 0)
    }

    /// Software unmute: restores saved volume.
    func unmute(for deviceID: AudioDeviceID, maximumVolume: Int? = nil) {
        guard let uid = deviceUIDs[deviceID] else { return }
        pendingMuteRestores[deviceID] = pendingMuteRestores[deviceID]
            ?? settingsManager.getDDCMuteState(for: uid)
        let savedVolume = settingsManager.getDDCSavedVolume(for: uid) ?? 50
        let restoredVolume = Self.restoredVolume(savedVolume, maximumVolume: maximumVolume)
        settingsManager.setDDCMuteState(for: uid, to: false)
        setVolume(for: deviceID, to: restoredVolume)
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
