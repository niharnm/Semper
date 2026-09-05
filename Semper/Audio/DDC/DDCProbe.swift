// Semper/Audio/DDC/DDCProbe.swift
// Background DDC discovery and CoreAudio matching

#if !APP_STORE

import AudioToolbox
import Dispatch
import Foundation
import IOKit
import Synchronization

nonisolated final class DDCProbeCancellation: Sendable {
    private let state = Mutex(false)

    var isCancelled: Bool {
        state.withLock { $0 }
    }

    func cancel() {
        state.withLock { $0 = true }
    }
}

nonisolated struct DDCProbeInput: Sendable {
    let id: UInt64
    private let cancellation: DDCProbeCancellation

    init(id: UInt64, cancellation: DDCProbeCancellation = DDCProbeCancellation()) {
        self.id = id
        self.cancellation = cancellation
    }

    var isCancelled: Bool {
        cancellation.isCancelled
    }

    func cancel() {
        cancellation.cancel()
    }
}

nonisolated struct DDCProbeRequestState {
    private var nextID: UInt64 = 0
    private var activeInput: DDCProbeInput?

    mutating func begin() -> DDCProbeInput {
        cancel()
        nextID &+= 1
        let input = DDCProbeInput(id: nextID)
        activeInput = input
        return input
    }

    mutating func cancel() {
        activeInput?.cancel()
        activeInput = nil
    }

    mutating func accept(_ result: DDCProbeResult) -> Bool {
        guard let activeInput,
              activeInput.id == result.id,
              !activeInput.isCancelled else {
            return false
        }
        self.activeInput = nil
        return true
    }
}

nonisolated enum DDCProbeLogRecord: Sendable {
    case info(String)
    case error(String)
}

nonisolated enum DDCProbePublication: Sendable {
    case unavailable
    case matched(
        services: [AudioDeviceID: DDCService],
        deviceUIDs: [AudioDeviceID: String],
        readVolumes: [AudioDeviceID: Int]
    )
}

nonisolated struct DDCProbeResult: Sendable {
    let id: UInt64
    let publication: DDCProbePublication
    let logs: [DDCProbeLogRecord]
}

nonisolated struct DDCProbeVolumePlan: Equatable, Sendable {
    let cachedVolumes: [AudioDeviceID: Int]
    let restoreVolumes: [AudioDeviceID: Int]

    static func make(
        deviceIDs: [AudioDeviceID],
        readVolumes: [AudioDeviceID: Int],
        savedVolumes: [AudioDeviceID: Int]
    ) -> DDCProbeVolumePlan {
        var cachedVolumes: [AudioDeviceID: Int] = [:]
        var restoreVolumes: [AudioDeviceID: Int] = [:]

        for deviceID in deviceIDs {
            if let savedVolume = savedVolumes[deviceID] {
                cachedVolumes[deviceID] = savedVolume
                restoreVolumes[deviceID] = savedVolume
            } else if let readVolume = readVolumes[deviceID] {
                cachedVolumes[deviceID] = readVolume
            }
        }

        return DDCProbeVolumePlan(
            cachedVolumes: cachedVolumes,
            restoreVolumes: restoreVolumes
        )
    }
}

nonisolated enum DDCProbeRunner {
    typealias Operation = @Sendable (DDCProbeInput) -> DDCProbeResult?

    static func submit(
        on queue: DispatchQueue,
        input: DDCProbeInput,
        operation: @escaping Operation = DDCProbeWorker.run,
        completion: @escaping @MainActor @Sendable (DDCProbeResult) -> Void
    ) {
        queue.async { @Sendable in
            guard let result = execute(input: input, operation: operation) else { return }
            Task { @MainActor in
                completion(result)
            }
        }
    }

    static func execute(
        input: DDCProbeInput,
        operation: Operation
    ) -> DDCProbeResult? {
        guard !input.isCancelled else { return nil }
        guard let result = operation(input), !input.isCancelled else { return nil }
        return result
    }
}

nonisolated enum DDCProbeWorker {
    private struct ProbeDisplay {
        let service: DDCService
        let candidate: DDCDisplayCandidate
    }

    private struct CoreAudioProbeDevice {
        let id: AudioDeviceID
        let candidate: CoreAudioDisplayCandidate
    }

    static func run(input: DDCProbeInput) -> DDCProbeResult? {
        guard !input.isCancelled else { return nil }

        var logs: [DDCProbeLogRecord] = []
        let discovered = DDCService.discoverServices()
        defer {
            for (entry, _) in discovered {
                IOObjectRelease(entry)
            }
        }

        guard !input.isCancelled else { return nil }
        logs.append(.info("DDC probe: found \(discovered.count) DCPAVServiceProxy entries"))
        guard !discovered.isEmpty else {
            return DDCProbeResult(id: input.id, publication: .unavailable, logs: logs)
        }

        var audioCapable: [ProbeDisplay] = []
        for (index, (entry, service)) in discovered.enumerated() {
            guard !input.isCancelled else { return nil }
            let name = getDisplayName(for: entry)

            let edid: DDCDisplayEDID? = {
                guard let raw = service.readEDID() else { return nil }
                return DDCDisplayEDID(
                    vendorID: raw.vendorID,
                    productID: raw.productID,
                    serialNumber: raw.serialNumber
                )
            }()

            guard !input.isCancelled else { return nil }
            let edidDescription = edid.map {
                "v\($0.vendorID) p\($0.productID) s\($0.serialNumber)"
            } ?? "-"
            logs.append(.info(
                "DDC probe: display \(index + 1) '\(name)' EDID(\(edid != nil ? "I2C" : "none")): \(edidDescription)"
            ))

            let supportsAudioVolume = service.supportsAudioVolume()
            guard !input.isCancelled else { return nil }
            if supportsAudioVolume {
                audioCapable.append(ProbeDisplay(
                    service: service,
                    candidate: DDCDisplayCandidate(
                        id: displayCandidateID(for: entry),
                        name: name,
                        edid: edid
                    )
                ))
                logs.append(.info("DDC audio-capable display: '\(name)'"))
            } else {
                logs.append(.info("DDC probe: '\(name)' does not support VCP 0x62"))
            }
        }

        guard !input.isCancelled else { return nil }
        guard !audioCapable.isEmpty else {
            logs.append(.info("DDC probe: no audio-capable displays found"))
            return DDCProbeResult(id: input.id, publication: .unavailable, logs: logs)
        }

        let coreAudioDevices = getCoreAudioOutputDevices()
        guard !input.isCancelled else { return nil }
        for device in coreAudioDevices {
            logs.append(.info(
                "DDC probe: CoreAudio candidate: '\(device.candidate.name)' "
                    + "(uid: \(device.candidate.id?.rawValue ?? "unavailable"))"
            ))
        }

        let matchResult = DDCDisplayMatcher.match(
            displays: audioCapable.map(\.candidate),
            coreAudioDevices: coreAudioDevices.map(\.candidate)
        )
        guard !input.isCancelled else { return nil }

        var displaysByID: [DDCDisplayCandidate.ID: ProbeDisplay] = [:]
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
            logs.append(.error(
                "DDC match identity diagnostic: \(String(describing: diagnostic))"
            ))
        }
        for unmatched in matchResult.unmatchedDisplays {
            logs.append(.info(
                "DDC display \(unmatched.id.rawValue) unmatched: "
                    + "\(String(describing: unmatched.reasons))"
            ))
        }
        for unmatched in matchResult.unmatchedCoreAudioDevices {
            logs.append(.info(
                "CoreAudio device '\(unmatched.id.rawValue)' unmatched for DDC: "
                    + "\(String(describing: unmatched.reasons))"
            ))
        }

        var matched: [AudioDeviceID: DDCService] = [:]
        var matchedUIDs: [AudioDeviceID: String] = [:]
        var volumes: [AudioDeviceID: Int] = [:]
        for match in matchResult.matches {
            guard !input.isCancelled else { return nil }
            guard let ddcDisplay = displaysByID[match.displayID],
                  let coreAudioDevice = coreAudioByID[match.coreAudioID] else {
                logs.append(.error("DDC matcher returned unresolved candidate identities"))
                continue
            }

            matched[coreAudioDevice.id] = ddcDisplay.service
            matchedUIDs[coreAudioDevice.id] = match.coreAudioID.rawValue

            if let volume = try? ddcDisplay.service.getAudioVolume() {
                guard !input.isCancelled else { return nil }
                volumes[coreAudioDevice.id] = volume.current
            }

            logs.append(.info(
                "Matched CoreAudio '\(coreAudioDevice.candidate.name)' to DDC "
                    + "'\(ddcDisplay.candidate.name)' using \(String(describing: match.method))"
            ))
        }

        guard !input.isCancelled else { return nil }
        return DDCProbeResult(
            id: input.id,
            publication: .matched(
                services: matched,
                deviceUIDs: matchedUIDs,
                readVolumes: volumes
            ),
            logs: logs
        )
    }

    private static func getCoreAudioOutputDevices() -> [CoreAudioProbeDevice] {
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

    private static func displayCandidateID(
        for entry: io_service_t
    ) -> DDCDisplayCandidate.ID? {
        var rawValue: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &rawValue) == KERN_SUCCESS else {
            return nil
        }
        return DDCDisplayCandidate.ID(rawValue: rawValue)
    }

    private static func getDisplayName(for entry: io_service_t) -> String {
        var current = entry
        IOObjectRetain(current)

        var needsRelease = true
        for _ in 0..<10 {
            if let name = displayNameFromEntry(current) {
                IOObjectRelease(current)
                return name
            }

            var next: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &next)
            IOObjectRelease(current)
            guard result == kIOReturnSuccess else {
                needsRelease = false
                break
            }
            current = next
        }

        if needsRelease {
            IOObjectRelease(current)
        }
        return "External Display"
    }

    private static func displayNameFromEntry(_ entry: io_service_t) -> String? {
        guard let info = IODisplayCreateInfoDictionary(
            entry,
            IOOptionBits(kIODisplayOnlyPreferredName)
        )?.takeRetainedValue() as? [String: Any],
            let names = info[kDisplayProductName] as? [String: String],
            let name = names.values.first else {
            return nil
        }
        return name
    }
}

#endif
