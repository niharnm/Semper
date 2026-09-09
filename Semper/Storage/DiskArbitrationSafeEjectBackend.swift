import AppKit
import DiskArbitration
import IOKit
import IOKit.storage

@MainActor
final class DiskArbitrationSafeEjectBackend: SafeEjectBackend {
    private var session: DASession?
    private var observers: [NSObjectProtocol] = []
    private var pendingToken: UInt?
    private var timeout: Task<Void, Never>?
    private let topologyCache = SafeEjectTopologyCache()
    private var checking = false
    private var preparedVolume: SafeEjectVolume?

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
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    switch event {
                    case .willSleep: self?.topologyCache.stop()
                    case .didWake: self?.topologyCache.start { onEvent(.volumesChanged) }
                    case .volumesChanged: self?.topologyCache.invalidate()
                    }
                    onEvent(event)
                }
            }
        }
        topologyCache.start { onEvent(.volumesChanged) }
    }

    func stop() {
        topologyCache.stop()
        cancelPendingOperation()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        if let session { DASessionSetDispatchQueue(session, nil) }
        session = nil
    }

    func drain() async {
        await topologyCache.drain()
    }

    func cancelPendingOperation() {
        topologyCache.cancelPreflight()
        preparedVolume = nil
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
            let topology = registryGraph(of: disk)?.resolve(apfs: topologyCache.value)
            let deviceID = topology?.deviceID
            let physicalDisk = deviceID.flatMap { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0.bsdName) }
            let physicalDescription = physicalDisk.flatMap { DADiskCopyDescription($0) } as NSDictionary?
            volumes.append(
                SafeEjectVolume(
                    id: SafeEjectVolumeID(
                        bsdName: String(cString: bsd), registryID: volumeRegistryID,
                        volumeUUID: values.volumeUUIDString, mountURL: url.standardizedFileURL
                    ),
                    name: values.volumeName ?? "Unnamed volume",
                    deviceID: deviceID,
                    isInternal: topology?.isInternal ?? values.volumeIsInternal,
                    isRemovable: physicalDescription?[kDADiskDescriptionMediaRemovableKey] as? Bool
                        ?? values.volumeIsRemovable,
                    isEjectable: physicalDescription?[kDADiskDescriptionMediaEjectableKey] as? Bool
                        ?? values.volumeIsEjectable,
                    isRoot: url.standardizedFileURL.path == "/",
                    topology: topology
                ))
        }
        return SafeEjectInventory(volumes: volumes, hasUnidentifiedLocalVolumes: unidentified)
    }

    func unmount(_ volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        guard session != nil else { return .failure(.paused) }
        guard !checking, pendingToken == nil else { return .failure(.operationInProgress) }
        checking = true
        defer { checking = false }
        preparedVolume = nil
        do {
            _ = try await topologyCache.fresh()
            guard !Task.isCancelled, let session else { return .failure(.interrupted) }
            let snapshot = try inventory()
            if let failure = snapshot.refusal(for: volume) { return .failure(failure) }
            guard volume.topology != nil, volume.id.volumeUUID.flatMap(UUID.init(uuidString:)) != nil,
                let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume.id.mountURL as CFURL),
                registryID(of: disk) == volume.id.registryID,
                volumeUUID(of: disk) == volume.id.volumeUUID.flatMap(UUID.init(uuidString:))
            else { return .failure(.changedVolume) }
            let result = await perform { context in
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), Self.completed, context)
            }
            if case .success = result {
                _ = try await topologyCache.fresh()
                guard !Task.isCancelled, self.session != nil else { return .failure(.interrupted) }
                preparedVolume = volume
            }
            return result
        } catch let failure as SafeEjectFailure {
            return .failure(failure)
        } catch SafeEjectAPFSError.cancelled {
            return .failure(.interrupted)
        } catch SafeEjectAPFSError.timedOut {
            return .failure(.topologyTimedOut)
        } catch is CancellationError {
            return .failure(.interrupted)
        } catch {
            return .failure(.incompleteInventory)
        }
    }

    func ejectDevice(containing volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        guard session != nil else { return .failure(.paused) }
        guard !checking, pendingToken == nil else { return .failure(.operationInProgress) }
        guard preparedVolume == volume, let expected = volume.topology, let id = volume.deviceID else {
            return .failure(.changedVolume)
        }
        checking = true
        defer {
            checking = false
            preparedVolume = nil
        }
        do {
            let apfs = try await topologyCache.fresh()
            guard !Task.isCancelled, let session else { return .failure(.interrupted) }
            guard let source = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume.id.bsdName),
                registryID(of: source) == volume.id.registryID,
                volumeUUID(of: source) == volume.id.volumeUUID.flatMap(UUID.init(uuidString:)),
                registryGraph(of: source)?.resolve(apfs: apfs) == expected
            else { return .failure(.changedVolume) }
            let snapshot = try inventory()
            if let failure = snapshot.conflict(with: id) { return .failure(failure) }
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, id.bsdName),
                registryID(of: disk) == id.registryID
            else { return .failure(.changedVolume) }
            let result = await perform { context in
                DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), Self.completed, context)
            }
            if case .success = result { _ = try await topologyCache.fresh() }
            return result
        } catch let failure as SafeEjectFailure {
            return .failure(failure)
        } catch SafeEjectAPFSError.cancelled {
            return .failure(.interrupted)
        } catch SafeEjectAPFSError.timedOut {
            return .failure(.topologyTimedOut)
        } catch is CancellationError {
            return .failure(.interrupted)
        } catch {
            return .failure(.incompleteInventory)
        }
    }

    func devicePresence(_ id: SafeEjectDeviceID) -> SafeEjectDevicePresence {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let status = IOServiceGetMatchingServices(
            kIOMainPortDefault, IORegistryEntryIDMatching(id.registryID), &iterator)
        guard status == KERN_SUCCESS else { return .unavailable }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != IO_OBJECT_NULL else { return IOIteratorIsValid(iterator) != 0 ? .absent : .unavailable }
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

    private func volumeUUID(of disk: DADisk) -> UUID? {
        guard let description = DADiskCopyDescription(disk) as NSDictionary?,
            let value = description[kDADiskDescriptionVolumeUUIDKey] as AnyObject?,
            CFGetTypeID(value) == CFUUIDGetTypeID()
        else { return nil }
        // The documented CFUUID value needs its exact type checked before the Core Foundation bridge.
        let uuid = value as! CFUUID
        guard let text = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String? else { return nil }
        return UUID(uuidString: text)
    }

    private func registryGraph(of disk: DADisk) -> SafeEjectRegistryGraph? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        return SafeEjectRegistryGraph.read(media: media)
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
