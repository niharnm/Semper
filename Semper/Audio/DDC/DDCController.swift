// Semper/Audio/DDC/DDCController.swift
// High-level DDC display enumeration, CoreAudio matching, and volume control

#if !APP_STORE

import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class DDCController {
    /// Set of CoreAudio AudioDeviceIDs that are backed by DDC volume control
    private(set) var ddcBackedDevices: Set<AudioDeviceID> = []

    /// Cached DDC volumes for each backed device (0-100)
    private(set) var cachedVolumes: [AudioDeviceID: Int] = [:]

    private var services: [AudioDeviceID: DDCService] = [:]
    private var deviceUIDs: [AudioDeviceID: String] = [:]  // For persistence keying
    private var debounceTimers: [AudioDeviceID: DispatchWorkItem] = [:]
    private var probeWorkItem: DispatchWorkItem?
    private var probeRequests = DDCProbeRequestState()
    private var displayChangeObserver: NSObjectProtocol?

    private let ddcQueue: DispatchQueue
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Semper", category: "DDCController")

    /// Callback when DDC probe completes (triggers device list refresh)
    var onProbeCompleted: (() -> Void)?

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
        for (_, item) in debounceTimers { item.cancel() }
        debounceTimers.removeAll()
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
        debounceTimers[deviceID]?.cancel()
        let service = services[deviceID]
        let logger = self.logger
        let item = DispatchWorkItem { @Sendable in
            do {
                try service?.setAudioVolume(clamped)
            } catch {
                logger.error("DDC write failed for device \(deviceID): \(error)")
            }
        }
        debounceTimers[deviceID] = item
        ddcQueue.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }

    /// Software mute: saves current volume, sets to 0.
    func mute(for deviceID: AudioDeviceID) {
        guard let uid = deviceUIDs[deviceID] else { return }
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
    func unmute(for deviceID: AudioDeviceID) {
        guard let uid = deviceUIDs[deviceID] else { return }
        let savedVolume = settingsManager.getDDCSavedVolume(for: uid) ?? 50
        settingsManager.setDDCMuteState(for: uid, to: false)
        setVolume(for: deviceID, to: savedVolume)
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
        for (_, item) in debounceTimers { item.cancel() }
        debounceTimers.removeAll()

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
        switch publication {
        case .unavailable:
            ddcBackedDevices = []
            services = [:]

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
            for (deviceID, volume) in volumePlan.cachedVolumes {
                cachedVolumes[deviceID] = volume
            }
            for (deviceID, volume) in volumePlan.restoreVolumes {
                guard let service = services[deviceID] else { continue }
                ddcQueue.async { @Sendable in
                    try? service.setAudioVolume(volume)
                }
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
