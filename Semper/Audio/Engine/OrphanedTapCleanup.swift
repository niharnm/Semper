// Semper/Audio/Engine/OrphanedTapCleanup.swift
import AudioToolbox
import os

private let logger = Logger(subsystem: "systems.semper.Semper", category: "OrphanedTapCleanup")

/// Scans CoreAudio for orphaned Semper aggregate devices and destroys them.
/// Orphans occur when Semper crashes or is force-killed (`kill -9`), leaving
/// aggregate devices with `.mutedWhenTapped` process taps that silently mute apps.
enum OrphanedTapCleanup {
    /// Destroys any aggregate devices named "Semper-*" left over from a previous session.
    /// Call on startup before creating any new taps.
    @discardableResult
    static func destroyOrphanedDevices(
        logDeviceDetails: Bool = false
    ) -> OrphanedTapCleanupResult {
        let devices: [AudioDeviceID]
        do {
            devices = try AudioObjectID.readDeviceList()
        } catch {
            logger.error("[CLEANUP] Failed to read the audio device list")
            return OrphanedTapCleanupResult(failedCount: 1)
        }

        var result = OrphanedTapCleanupResult()

        for device in devices {
            let transportType = device.readTransportType()
            guard transportType == .aggregate else { continue }
            result.scannedAggregateCount += 1

            guard let name = try? device.readDeviceName(),
                  name.hasPrefix("Semper-") else { continue }
            result.matchedCount += 1

            let err = AudioHardwareDestroyAggregateDevice(device)
            if err == noErr {
                result.destroyedCount += 1
                if logDeviceDetails {
                    logger.info("[CLEANUP] Destroyed orphaned aggregate device: \(name) (ID \(device))")
                }
            } else {
                result.failedCount += 1
                if logDeviceDetails {
                    logger.error("[CLEANUP] Failed to destroy \(name) (ID \(device)): OSStatus \(err)")
                }
            }
        }

        if result.matchedCount == 0 {
            logger.info("[CLEANUP] No orphaned Semper devices found")
        } else if result.failedCount == 0 {
            logger.info("[CLEANUP] Destroyed \(result.destroyedCount) orphaned device(s)")
        } else {
            logger.error("[CLEANUP] \(result.failedCount) orphaned device(s) remain")
        }
        return result
    }
}
