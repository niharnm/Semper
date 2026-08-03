// Semper/Audio/DDC/DDCController.swift
// High-level DDC display enumeration, CoreAudio matching, and volume control

#if !APP_STORE

import AppKit
import AudioToolbox
import IOKit
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
    private var displayChangeObserver: NSObjectProtocol?

    private let ddcQueue = DispatchQueue(label: "com.semper.ddc", qos: .utility)
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Semper", category: "DDCController")

    /// Callback when DDC probe completes (triggers device list refresh)
    var onProbeCompleted: (() -> Void)?

    private struct DDCProbeDisplay {
        let entry: io_service_t
        let service: DDCService
        let candidate: DDCDisplayCandidate
    }

    private struct CoreAudioProbeDevice {
        let id: AudioDeviceID
        let candidate: CoreAudioDisplayCandidate
    }

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
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
    private func probe() {
        // Cancel pending debounced DDC writes — services will be replaced by re-probe
        for (_, item) in debounceTimers { item.cancel() }
        debounceTimers.removeAll()

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
                    self?.ddcBackedDevices = []
                    self?.services = [:]
                    self?.onProbeCompleted?()
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
            var audioCapable: [DDCProbeDisplay] = []
            for (index, (entry, service)) in discovered.enumerated() {
                let name = Self.getDisplayName(for: entry)

                // Read EDID directly from the monitor over I2C
                let edid: DDCDisplayEDID? = {
                    guard let raw = service.readEDID() else { return nil }
                    return DDCDisplayEDID(
                        vendorID: raw.vendorID,
                        productID: raw.productID,
                        serialNumber: raw.serialNumber
                    )
                }()

                logger.info("DDC probe: display \(index + 1) '\(name)' EDID(\(edid != nil ? "I2C" : "none")): \(edid.map { "v\($0.vendorID) p\($0.productID) s\($0.serialNumber)" } ?? "–")")
                if service.supportsAudioVolume() {
                    audioCapable.append(DDCProbeDisplay(
                        entry: entry,
                        service: service,
                        candidate: DDCDisplayCandidate(
                            id: Self.displayCandidateID(for: entry),
                            name: name,
                            edid: edid
                        )
                    ))
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
                    self?.ddcBackedDevices = []
                    self?.services = [:]
                    self?.onProbeCompleted?()
                }
                return
            }

            // 3. Get all CoreAudio output devices (candidates for DDC matching)
            let coreAudioDevices = self.getCoreAudioOutputDevices()
            for ca in coreAudioDevices {
                logger.info("DDC probe: CoreAudio candidate: '\(ca.candidate.name)' (uid: \(ca.candidate.id?.rawValue ?? "unavailable"))")
            }

            // 4. Match DDC displays to CoreAudio devices
            var matched: [AudioDeviceID: DDCService] = [:]
            var matchedUIDs: [AudioDeviceID: String] = [:]
            var volumes: [AudioDeviceID: Int] = [:]
            let matchResult = DDCDisplayMatcher.match(
                displays: audioCapable.map(\.candidate),
                coreAudioDevices: coreAudioDevices.map(\.candidate)
            )

            var displaysByID: [DDCDisplayCandidate.ID: DDCProbeDisplay] = [:]
            var duplicateDisplayIDs = Set<DDCDisplayCandidate.ID>()
            for display in audioCapable {
                guard let id = display.candidate.id else { continue }
                if displaysByID.updateValue(display, forKey: id) != nil {
                    duplicateDisplayIDs.insert(id)
                }
            }
            for id in duplicateDisplayIDs {
                displaysByID.removeValue(forKey: id)
            }

            var coreAudioByID: [CoreAudioDisplayCandidate.ID: CoreAudioProbeDevice] = [:]
            var duplicateCoreAudioIDs = Set<CoreAudioDisplayCandidate.ID>()
            for device in coreAudioDevices {
                guard let id = device.candidate.id else { continue }
                if coreAudioByID.updateValue(device, forKey: id) != nil {
                    duplicateCoreAudioIDs.insert(id)
                }
            }
            for id in duplicateCoreAudioIDs {
                coreAudioByID.removeValue(forKey: id)
            }

            for diagnostic in matchResult.identityDiagnostics {
                logger.error("DDC match identity diagnostic: \(String(describing: diagnostic))")
            }
            for unmatched in matchResult.unmatchedDisplays {
                logger.info("DDC display \(unmatched.id.rawValue) unmatched: \(String(describing: unmatched.reasons))")
            }
            for unmatched in matchResult.unmatchedCoreAudioDevices {
                logger.info("CoreAudio device '\(unmatched.id.rawValue)' unmatched for DDC: \(String(describing: unmatched.reasons))")
            }

            for match in matchResult.matches {
                guard let ddcDisplay = displaysByID[match.displayID],
                      let caDevice = coreAudioByID[match.coreAudioID] else {
                    logger.error("DDC matcher returned unresolved candidate identities")
                    continue
                }

                matched[caDevice.id] = ddcDisplay.service
                matchedUIDs[caDevice.id] = match.coreAudioID.rawValue

                if let vol = try? ddcDisplay.service.getAudioVolume() {
                    volumes[caDevice.id] = vol.current
                }

                logger.info("Matched CoreAudio '\(caDevice.candidate.name)' to DDC '\(ddcDisplay.candidate.name)' using \(String(describing: match.method))")
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
                guard let self else { return }
                self.services = matchedSnapshot
                self.deviceUIDs = matchedUIDsSnapshot
                self.ddcBackedDevices = Set(matchedSnapshot.keys)

                // Use persisted volumes if available, otherwise use read values
                for (deviceID, uid) in matchedUIDsSnapshot {
                    if let savedVolume = self.settingsManager.getDDCVolume(for: uid) {
                        self.cachedVolumes[deviceID] = savedVolume
                        // Restore saved volume to the display
                        let service = matchedSnapshot[deviceID]
                        self.ddcQueue.async {
                            try? service?.setAudioVolume(savedVolume)
                        }
                    } else if let readVolume = volumesSnapshot[deviceID] {
                        self.cachedVolumes[deviceID] = readVolume
                    }
                }

                self.logger.info("DDC probe complete: \(matchedSnapshot.count) display(s) matched")
                self.onProbeCompleted?()
            }
        }
    }

    // MARK: - CoreAudio Device Discovery

    /// Gets all CoreAudio output devices as candidates for DDC matching.
    /// Includes devices both with and without CoreAudio volume control,
    /// since some monitors report having volume control that doesn't actually work.
    private nonisolated func getCoreAudioOutputDevices() -> [CoreAudioProbeDevice] {
        guard let deviceIDs = try? AudioObjectID.readDeviceList() else { return [] }

        var results: [CoreAudioProbeDevice] = []
        for deviceID in deviceIDs {
            guard !deviceID.isAggregateDevice(),
                  !deviceID.isVirtualDevice(),
                  deviceID.hasOutputStreams() else { continue }

            guard let name = try? deviceID.readDeviceName() else { continue }
            let uid = try? deviceID.readDeviceUID()
            let candidateID = uid.flatMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : CoreAudioDisplayCandidate.ID(rawValue: value)
            }
            results.append(CoreAudioProbeDevice(
                id: deviceID,
                candidate: CoreAudioDisplayCandidate(
                    id: candidateID,
                    name: name,
                    transport: deviceID.readTransportType()
                )
            ))
        }
        return results
    }

    private nonisolated static func displayCandidateID(for entry: io_service_t) -> DDCDisplayCandidate.ID? {
        var rawValue: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &rawValue) == KERN_SUCCESS else { return nil }
        return DDCDisplayCandidate.ID(rawValue: rawValue)
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
