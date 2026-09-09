import AppKit
import DiskArbitration
import IOKit

@MainActor
final class DiskArbitrationSafeEjectBackend: SafeEjectBackend {
    private var session: DASession?
    private var observers: [NSObjectProtocol] = []
    private var pendingToken: UInt?
    private var timeout: Task<Void, Never>?

    isolated deinit {
        stop()
    }

    func start(onEvent: @escaping @MainActor (SafeEjectSystemEvent) -> Void) throws {
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw SafeEjectFailure.unavailable
        }
        self.session = session
        DASessionSetDispatchQueue(session, .main)
        let notifications: [(Notification.Name, SafeEjectSystemEvent)] = [
            (NSWorkspace.didMountNotification, .volumesChanged),
            (NSWorkspace.didUnmountNotification, .volumesChanged),
            (NSWorkspace.didRenameVolumeNotification, .volumesChanged),
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
        ]
        observers = notifications.map { name, event in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onEvent(event) }
            }
        }
    }

    func stop() {
        cancelPendingOperation()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        if let session { DASessionSetDispatchQueue(session, nil) }
        session = nil
    }

    func cancelPendingOperation() {
        guard let pendingToken else { return }
        finish(pendingToken, result: .failure(.interrupted))
    }

    func inventory() throws -> SafeEjectInventory {
        guard let session else { throw SafeEjectFailure.paused }
        guard
            let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [
                    .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                    .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeUUIDStringKey,
                ], options: [])
        else { throw SafeEjectFailure.unavailable }
        var volumes: [SafeEjectVolume] = []
        var unidentified = false
        for url in urls {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                    .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeUUIDStringKey,
                ])
            } catch {
                unidentified = true
                continue
            }
            if values.volumeIsLocal == false { continue }
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                let bsd = DADiskGetBSDName(disk),
                let volumeRegistryID = registryID(of: disk)
            else {
                unidentified = true
                continue
            }
            let wholeDisk = DADiskCopyWholeDisk(disk)
            let wholeDescription = wholeDisk.flatMap { DADiskCopyDescription($0) } as NSDictionary?
            let description = DADiskCopyDescription(disk) as NSDictionary?
            var deviceID: SafeEjectDeviceID?
            if let wholeDisk, let wholeBSD = DADiskGetBSDName(wholeDisk),
                let wholeRegistryID = registryID(of: wholeDisk),
                (wholeDescription?[kDADiskDescriptionMediaWholeKey] as? Bool) == true
            {
                deviceID = SafeEjectDeviceID(bsdName: String(cString: wholeBSD), registryID: wholeRegistryID)
            }
            volumes.append(
                SafeEjectVolume(
                    id: SafeEjectVolumeID(
                        bsdName: String(cString: bsd), registryID: volumeRegistryID,
                        volumeUUID: values.volumeUUIDString, mountURL: url.standardizedFileURL
                    ),
                    name: values.volumeName ?? "Unnamed volume",
                    deviceID: deviceID,
                    isInternal: wholeDescription?[kDADiskDescriptionDeviceInternalKey] as? Bool
                        ?? description?[kDADiskDescriptionDeviceInternalKey] as? Bool ?? values.volumeIsInternal,
                    isRemovable: wholeDescription?[kDADiskDescriptionMediaRemovableKey] as? Bool
                        ?? values.volumeIsRemovable,
                    isEjectable: wholeDescription?[kDADiskDescriptionMediaEjectableKey] as? Bool
                        ?? values.volumeIsEjectable,
                    isRoot: url.standardizedFileURL.path == "/"
                ))
        }
        return SafeEjectInventory(volumes: volumes, hasUnidentifiedLocalVolumes: unidentified)
    }

    func unmount(_ volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        guard let session else { return .failure(.paused) }
        do {
            let snapshot = try inventory()
            if let failure = snapshot.refusal(for: volume) { return .failure(failure) }
        } catch {
            return .failure(.unavailable)
        }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume.id.mountURL as CFURL),
            registryID(of: disk) == volume.id.registryID
        else { return .failure(.changedVolume) }
        return await perform { context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), Self.completed, context)
        }
    }

    func ejectDevice(containing volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        guard let session else { return .failure(.paused) }
        guard let id = volume.deviceID else { return .failure(.unknownDevice) }
        do {
            let snapshot = try inventory()
            guard snapshot.hasCompleteDeviceMapping else { return .failure(.incompleteInventory) }
            guard !snapshot.volumes.contains(where: { $0.deviceID == id }) else {
                return .failure(.otherMountedVolumes)
            }
        } catch {
            return .failure(.unavailable)
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, id.bsdName),
            registryID(of: disk) == id.registryID
        else { return .failure(.changedVolume) }
        return await perform { context in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), Self.completed, context)
        }
    }

    func devicePresence(_ id: SafeEjectDeviceID) -> SafeEjectDevicePresence {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let status = IOServiceGetMatchingServices(
            kIOMainPortDefault, IORegistryEntryIDMatching(id.registryID), &iterator)
        guard status == KERN_SUCCESS else { return .unavailable }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != IO_OBJECT_NULL else { return .absent }
        IOObjectRelease(entry)
        return .present
    }

    static func failure(for status: Int32) -> SafeEjectFailure {
        switch status {
        case Int32(truncatingIfNeeded: kDAReturnBusy), Int32(truncatingIfNeeded: kDAReturnExclusiveAccess): .busy
        case Int32(truncatingIfNeeded: kDAReturnNotPermitted), Int32(truncatingIfNeeded: kDAReturnNotPrivileged):
            .denied
        case Int32(truncatingIfNeeded: kDAReturnUnsupported): .unsupported
        case Int32(truncatingIfNeeded: kDAReturnNotFound), Int32(truncatingIfNeeded: kDAReturnNotMounted):
            .changedVolume
        default: .system(status)
        }
    }

    private func registryID(of disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS else { return nil }
        return id
    }

    private func perform(_ submit: (UnsafeMutableRawPointer?) -> Void) async -> Result<Void, SafeEjectFailure> {
        guard pendingToken == nil else { return .failure(.operationInProgress) }
        let token = SafeEjectCallbacks.nextToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.interrupted))
                    return
                }
                pendingToken = token
                SafeEjectCallbacks.completions[token] = { result in continuation.resume(returning: result) }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.finish(token, result: .failure(.timedOut))
                }
                SafeEjectCallbacks.systemCompletions[token] = { [weak self] status in
                    self?.finish(token, result: status.map { .failure(Self.failure(for: $0)) } ?? .success(()))
                }
                submit(UnsafeMutableRawPointer(bitPattern: token))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(token, result: .failure(.interrupted))
            }
        }
    }

    private func finish(_ token: UInt, result: Result<Void, SafeEjectFailure>) {
        guard pendingToken == token else { return }
        pendingToken = nil
        timeout?.cancel()
        timeout = nil
        SafeEjectCallbacks.systemCompletions.removeValue(forKey: token)
        SafeEjectCallbacks.completions.removeValue(forKey: token)?(result)
    }

    nonisolated private static let completed: DADiskUnmountCallback = { _, dissenter, context in
        guard let context else { return }
        let token = UInt(bitPattern: context)
        let status = dissenter.map { DADissenterGetStatus($0) }
        MainActor.assumeIsolated {
            SafeEjectCallbacks.systemCompletions[token]?(status)
        }
    }
}

// Opaque integer tokens let late C callbacks be ignored without dereferencing a released owner.
@MainActor
private enum SafeEjectCallbacks {
    static var sequence: UInt = 0
    static var completions: [UInt: (Result<Void, SafeEjectFailure>) -> Void] = [:]
    static var systemCompletions: [UInt: (Int32?) -> Void] = [:]

    static func nextToken() -> UInt {
        sequence += 1
        return sequence
    }
}
