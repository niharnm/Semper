// Semper/Audio/DDC/DDCController.swift
// High-level DDC display enumeration, CoreAudio matching, and volume control

#if !APP_STORE

import AppKit
import AudioToolbox
import IOKit
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

struct DDCProbeLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isRunning = false

    mutating func start() {
        generation &+= 1
        isRunning = true
    }

    mutating func beginProbe() -> UInt64? {
        guard isRunning else { return nil }
        generation &+= 1
        return generation
    }

    mutating func stop() {
        generation &+= 1
        isRunning = false
    }

    func permitsPublication(for candidate: UInt64) -> Bool {
        isRunning && candidate == generation
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
    private var probeLifecycle = DDCProbeLifecycle()
    private var serviceWritesCancellation = DDCWriteCancellation()
    private var probeWorkItem: DispatchWorkItem?
    private var displayChangeObserver: NSObjectProtocol?

    private let ddcQueue = DispatchQueue(label: "com.semper.ddc", qos: .utility)
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Semper", category: "DDCController")

    /// Callback when DDC probe completes (triggers device list refresh)
    var onProbeCompleted: (() -> Void)?
    var onWriteResult: ((AudioDeviceID, DDCWriteResult) -> Void)?

    /// EDID identifiers read directly from a monitor over I2C.
    private struct DisplayEDID: Sendable {
        let vendorID: UInt32
        let productID: UInt32
        let serialNumber: UInt32
    }

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    // MARK: - Lifecycle

    func start() {
        probeLifecycle.start()
        probe()
        setupDisplayChangeObserver()
    }

    func stop() {
        probeLifecycle.stop()
        if let obs = displayChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            displayChangeObserver = nil
        }
        probeWorkItem?.cancel()
        probeWorkItem = nil
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
    func unmute(for deviceID: AudioDeviceID) {
        guard let uid = deviceUIDs[deviceID] else { return }
        pendingMuteRestores[deviceID] = pendingMuteRestores[deviceID]
            ?? settingsManager.getDDCMuteState(for: uid)
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
    private func probe() {
        guard let probeGeneration = probeLifecycle.beginProbe() else { return }
        // Services are about to be replaced, so pending writes must reject first.
        serviceWritesCancellation.cancel()
        cancelPendingWrites()
        guard probeLifecycle.permitsPublication(for: probeGeneration) else { return }

        // TODO(Swift 6): This closure captures @MainActor self and runs on ddcQueue.
        // Currently safe because accessed properties are nonisolated or dispatched
        // to @MainActor via Task { @MainActor in }.
        let logger = self.logger
        ddcQueue.async { [weak self, logger] in
            guard let self else { return }

            // 1. Discover all DCPAVServiceProxy entries and create DDC services
            let discovered = DDCService.discoverServices()
            logger.info("DDC probe: found \(discovered.count) DCPAVServiceProxy entries")
            guard !discovered.isEmpty else {
                Task { @MainActor [weak self] in
                    self?.publishEmptyProbe(generation: probeGeneration)
                }
                return
            }

            // 2. Probe each service for audio volume support (VCP 0x62)
            //    Read EDID via I2C (address 0x50) directly from each monitor.
            //    The IORegistry parent walk from DCPAVServiceProxy does NOT work on Apple
            //    Silicon: IODisplay nodes are siblings of DCPAVServiceProxy, not ancestors,
            //    so getDisplayName/getDisplayEDID via IORegistry return "External Display"/nil
            //    for both entries, making name matching and IOKit-EDID matching fail.
            //    I2C EDID reads from the same physical bus as DDC commands, guaranteeing
            //    the EDID belongs to the exact monitor this DDCService controls.
            var audioCapable: [(entry: io_service_t, service: DDCService, displayName: String, edid: DisplayEDID?)] = []
            for (index, (entry, service)) in discovered.enumerated() {
                let name = Self.getDisplayName(for: entry)

                // Read EDID directly from the monitor over I2C
                let edid: DisplayEDID? = {
                    guard let raw = service.readEDID() else { return nil }
                    return DisplayEDID(vendorID: raw.vendorID, productID: raw.productID, serialNumber: raw.serialNumber)
                }()

                logger.info("DDC probe: display \(index + 1) '\(name)' EDID(\(edid != nil ? "I2C" : "none")): \(edid.map { "v\($0.vendorID) p\($0.productID) s\($0.serialNumber)" } ?? "–")")
                if service.supportsAudioVolume() {
                    audioCapable.append((entry: entry, service: service, displayName: name, edid: edid))
                    logger.info("DDC audio-capable display: '\(name)'")
                } else {
                    logger.info("DDC probe: '\(name)' does not support VCP 0x62")
                    IOObjectRelease(entry)
                }
            }

            guard !audioCapable.isEmpty else {
                logger.info("DDC probe: no audio-capable displays found")
                // Entries that failed supportsAudioVolume() were already released above
                Task { @MainActor [weak self] in
                    self?.publishEmptyProbe(generation: probeGeneration)
                }
                return
            }

            // 3. Get all CoreAudio output devices (candidates for DDC matching)
            let coreAudioDevices = self.getCoreAudioOutputDevices()
            for ca in coreAudioDevices {
                logger.info("DDC probe: CoreAudio candidate: '\(ca.name)' (uid: \(ca.uid))")
            }

            // 4. Match DDC displays to CoreAudio devices
            var matched: [AudioDeviceID: DDCService] = [:]
            var matchedUIDs: [AudioDeviceID: String] = [:]
            var volumes: [AudioDeviceID: Int] = [:]
            var matchedDDCIndices = Set<Int>()

            // 4a. First pass: match by display name (fuzzy: case-insensitive, trimmed, substring)
            for caDevice in coreAudioDevices {
                for (i, ddcDisplay) in audioCapable.enumerated() where !matchedDDCIndices.contains(i) {
                    if Self.namesMatch(caDevice.name, ddcDisplay.displayName) {
                        matched[caDevice.id] = ddcDisplay.service
                        matchedUIDs[caDevice.id] = caDevice.uid
                        matchedDDCIndices.insert(i)

                        if let vol = try? ddcDisplay.service.getAudioVolume() {
                            volumes[caDevice.id] = vol.current
                        }

                        logger.info("Matched CoreAudio '\(caDevice.name)' → DDC '\(ddcDisplay.displayName)' (by name)")
                        break
                    }
                }
            }

            // 4b. Second pass: match by I2C EDID vendor+product prefix embedded in the CoreAudio UID.
            //     On Apple Silicon, CoreAudio UIDs for HDMI/DP monitors encode the EDID vendor and
            //     product IDs as the first 8 hex characters: "{vendor:04x}{product:04x}-..."
            //     Example: "1E6D5077-0000-0000-071F-..." → vendor=0x1E6D, product=0x5077.
            //     Reading the same values from the monitor via I2C gives a guaranteed 1:1 mapping.
            for (i, ddcDisplay) in audioCapable.enumerated() where !matchedDDCIndices.contains(i) {
                guard let edid = ddcDisplay.edid else { continue }

                for caDevice in coreAudioDevices where !matched.keys.contains(caDevice.id) {
                    if Self.edidMatchesUID(edid, uid: caDevice.uid) {
                        matched[caDevice.id] = ddcDisplay.service
                        matchedUIDs[caDevice.id] = caDevice.uid
                        matchedDDCIndices.insert(i)

                        if let vol = try? ddcDisplay.service.getAudioVolume() {
                            volumes[caDevice.id] = vol.current
                        }

                        logger.info("Matched CoreAudio '\(caDevice.name)' → DDC '\(ddcDisplay.displayName)' (by I2C EDID uid prefix v\(edid.vendorID) p\(edid.productID))")
                        break
                    }
                }
            }

            // 4c. Third pass: transport fallback for any remaining unmatched entries
            //     (HDMI, DisplayPort, Thunderbolt — these are monitor connections)
            let displayTransports: Set<TransportType> = [.hdmi, .displayPort, .thunderbolt]
            let unmatchedDisplayDevices = coreAudioDevices.filter { ca in
                !matched.keys.contains(ca.id) && displayTransports.contains(ca.transport)
            }
            let unmatchedDDC = audioCapable.enumerated().filter { !matchedDDCIndices.contains($0.offset) }

            for (i, ddcDisplay) in unmatchedDDC {
                for caDevice in unmatchedDisplayDevices where !matched.keys.contains(caDevice.id) {
                    matched[caDevice.id] = ddcDisplay.service
                    matchedUIDs[caDevice.id] = caDevice.uid
                    matchedDDCIndices.insert(i)

                    if let vol = try? ddcDisplay.service.getAudioVolume() {
                        volumes[caDevice.id] = vol.current
                    }

                    logger.info("Matched CoreAudio '\(caDevice.name)' → DDC '\(ddcDisplay.displayName)' (by transport fallback: \(caDevice.transport))")
                    break
                }
            }

            // Release IOKit entries
            for item in audioCapable {
                IOObjectRelease(item.entry)
            }

            // 5. Publish results on main thread
            let matchedSnapshot = matched
            let matchedUIDsSnapshot = matchedUIDs
            let volumesSnapshot = volumes
            Task { @MainActor [weak self] in
                self?.publishProbe(
                    generation: probeGeneration,
                    services: matchedSnapshot,
                    deviceUIDs: matchedUIDsSnapshot,
                    volumes: volumesSnapshot
                )
            }
        }
    }

    private func publishEmptyProbe(generation: UInt64) {
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        cancelPendingWrites()
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        ddcBackedDevices = []
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        services = [:]
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        deviceUIDs = [:]
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        cachedVolumes = [:]
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        writeLedger.replaceConfirmedVolumes([:])
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        serviceWritesCancellation = DDCWriteCancellation()
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        onProbeCompleted?()
    }

    private func publishProbe(
        generation: UInt64,
        services discoveredServices: [AudioDeviceID: DDCService],
        deviceUIDs discoveredDeviceUIDs: [AudioDeviceID: String],
        volumes discoveredVolumes: [AudioDeviceID: Int]
    ) {
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        cancelPendingWrites()
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        services = discoveredServices
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        deviceUIDs = discoveredDeviceUIDs
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        ddcBackedDevices = Set(discoveredServices.keys)
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        cachedVolumes = discoveredVolumes
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        writeLedger.replaceConfirmedVolumes(discoveredVolumes)
        guard probeLifecycle.permitsPublication(for: generation) else { return }
        serviceWritesCancellation = DDCWriteCancellation()

        // Use persisted volumes if available, otherwise use read values
        for (deviceID, uid) in discoveredDeviceUIDs {
            guard probeLifecycle.permitsPublication(for: generation) else { return }
            if let savedVolume = settingsManager.getDDCVolume(for: uid) {
                setVolume(for: deviceID, to: savedVolume)
            }
        }

        guard probeLifecycle.permitsPublication(for: generation) else { return }
        logger.info("DDC probe complete: \(discoveredServices.count) display(s) matched")
        onProbeCompleted?()
    }

    // MARK: - CoreAudio Device Discovery

    private struct CoreAudioDeviceInfo: Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: TransportType
    }

    /// Gets all CoreAudio output devices as candidates for DDC matching.
    /// Includes devices both with and without CoreAudio volume control,
    /// since some monitors report having volume control that doesn't actually work.
    private nonisolated func getCoreAudioOutputDevices() -> [CoreAudioDeviceInfo] {
        guard let deviceIDs = try? AudioObjectID.readDeviceList() else { return [] }

        var results: [CoreAudioDeviceInfo] = []
        for deviceID in deviceIDs {
            guard !deviceID.isAggregateDevice(),
                  !deviceID.isVirtualDevice(),
                  deviceID.hasOutputStreams() else { continue }

            guard let uid = try? deviceID.readDeviceUID(),
                  let name = try? deviceID.readDeviceName() else { continue }

            results.append(CoreAudioDeviceInfo(id: deviceID, uid: uid, name: name, transport: deviceID.readTransportType()))
        }
        return results
    }

    // MARK: - Matching Helpers

    /// Returns true if the EDID vendor+product IDs match the prefix encoded in a CoreAudio UID.
    /// On Apple Silicon, HDMI/DP UIDs have the format "{vendor:04x}{product:04x}-..." (case-insensitive).
    /// The vendor (bytes 8-9) is big-endian in EDID and matches directly.
    /// The product (bytes 10-11) is little-endian in EDID but the UID encodes the raw bytes
    /// big-endian ({byte10:02x}{byte11:02x}), so we swap before comparing.
    private nonisolated static func edidMatchesUID(_ edid: DisplayEDID, uid: String) -> Bool {
        let productSwapped = ((edid.productID & 0xFF) << 8) | ((edid.productID >> 8) & 0xFF)
        let prefix = String(format: "%04x%04x", edid.vendorID, productSwapped)
        return uid.lowercased().hasPrefix(prefix)
    }

    /// Fuzzy name matching: case-insensitive, trimmed, with substring fallback.
    /// CoreAudio device names and IOKit display names both come from EDID but may
    /// differ in casing, whitespace, or truncation.
    private nonisolated static func namesMatch(_ a: String, _ b: String) -> Bool {
        let normA = a.trimmingCharacters(in: .whitespaces).lowercased()
        let normB = b.trimmingCharacters(in: .whitespaces).lowercased()
        if normA == normB { return true }
        // Substring fallback: one contains the other
        if normA.contains(normB) || normB.contains(normA) { return true }
        return false
    }

    // MARK: - Display Name from IOKit

    /// Gets the display product name from the IORegistry entry or its parent framebuffer.
    private nonisolated static func getDisplayName(for entry: io_service_t) -> String {
        // Walk up to find a parent with display info
        var current = entry
        IOObjectRetain(current)

        // Try up to 10 levels of parents to find display info
        // `needsRelease` tracks whether `current` holds an unreleased io_service_t
        var needsRelease = true
        for _ in 0..<10 {
            if let name = displayNameFromEntry(current) {
                IOObjectRelease(current)
                return name
            }

            var next: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &next)
            IOObjectRelease(current)
            guard kr == kIOReturnSuccess else {
                needsRelease = false  // `current` was already released above
                break
            }
            current = next
        }

        // Release the final `current` if the loop exhausted all 10 levels
        if needsRelease {
            IOObjectRelease(current)
        }

        // No display name found in registry hierarchy
        return "External Display"
    }

    private nonisolated static func displayNameFromEntry(_ entry: io_service_t) -> String? {
        guard let info = IODisplayCreateInfoDictionary(entry, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any],
              let names = info[kDisplayProductName] as? [String: String],
              let name = names.values.first else {
            return nil
        }
        return name
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
