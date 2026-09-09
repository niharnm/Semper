import Foundation
import IOKit
import IOKit.storage

struct SafeEjectMediaTopology: Sendable {
    let bsdName: String?
    let registryID: UInt64?
    let isWhole: Bool?
    let providerIsBlockStorageDriver: Bool
    let deviceIsBlockStorageDevice: Bool
    let physicalInterconnect: String?
    var physicalLocation: String? = nil

    var physicalDeviceID: SafeEjectDeviceID? {
        let transports = [
            kIOPropertyPhysicalInterconnectTypeATA, kIOPropertyPhysicalInterconnectTypeSerialATA,
            kIOPropertyPhysicalInterconnectTypeSerialAttachedSCSI, kIOPropertyPhysicalInterconnectTypeATAPI,
            kIOPropertyPhysicalInterconnectTypeUSB, kIOPropertyPhysicalInterconnectTypeFireWire,
            kIOPropertyPhysicalInterconnectTypeSecureDigital, kIOPropertyPhysicalInterconnectTypeSCSIParallel,
            kIOPropertyPhysicalInterconnectTypeFibreChannel, kIOPropertyPhysicalInterconnectTypePCI,
            kIOPropertyPhysicalInterconnectTypePCIExpress, kIOPropertyPhysicalInterconnectTypeAppleFabric,
        ]
        guard isWhole == true, providerIsBlockStorageDriver, deviceIsBlockStorageDevice,
            let bsdName, let registryID, let physicalInterconnect, transports.contains(physicalInterconnect),
            physicalLocation == kIOPropertyInternalKey || physicalLocation == kIOPropertyExternalKey
        else { return nil }
        return SafeEjectDeviceID(bsdName: bsdName, registryID: registryID)
    }
}

struct SafeEjectRegistryNode: Equatable, Sendable {
    let id: UInt64
    var parents: [UInt64] = []
    var bsdName: String? = nil
    var mediaUUID: UUID? = nil
    var isMedia = false
    var isWhole: Bool? = nil
    var isBlockStorageDriver = false
    var isBlockStorageDevice = false
    var physicalInterconnect: String? = nil
    var physicalLocation: String? = nil
}

struct SafeEjectResolvedTopology: Equatable, Sendable {
    let deviceID: SafeEjectDeviceID
    let isInternal: Bool
    let nodes: [SafeEjectRegistryNode]
    let containers: [SafeEjectAPFSTopology.Container]
}

struct SafeEjectRegistryGraph: Equatable, Sendable {
    let rootID: UInt64
    let nodes: [SafeEjectRegistryNode]
    let isComplete: Bool

    func resolve(apfs: SafeEjectAPFSTopology?) -> SafeEjectResolvedTopology? {
        guard isComplete, !nodes.isEmpty, nodes.count <= 128,
            Set(nodes.map(\.id)).count == nodes.count
        else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var ancestorsByID: [UInt64: Set<UInt64>] = [:]
        func ancestorIDs(_ id: UInt64, path: Set<UInt64> = []) -> Set<UInt64>? {
            guard path.count < 64, !path.contains(id), let node = byID[id] else { return nil }
            if let cached = ancestorsByID[id] { return cached }
            var path = path
            path.insert(id)
            var result: Set<UInt64> = [id]
            for parent in node.parents {
                guard let ancestors = ancestorIDs(parent, path: path) else { return nil }
                result.formUnion(ancestors)
            }
            ancestorsByID[id] = result
            return result
        }
        guard ancestorIDs(rootID) == Set(byID.keys) else { return nil }

        var mediaByID: [UInt64: Set<UInt64>] = [:]
        func firstMediaAncestors(_ id: UInt64) -> Set<UInt64>? {
            guard let node = byID[id] else { return nil }
            if let cached = mediaByID[id] { return cached }
            if node.isMedia { return [id] }
            guard !node.parents.isEmpty else { return nil }
            var result: Set<UInt64> = []
            for parent in node.parents {
                guard let media = firstMediaAncestors(parent) else { return nil }
                result.formUnion(media)
            }
            mediaByID[id] = result
            return result
        }
        var visited: Set<UInt64> = []
        var usedContainers: [SafeEjectAPFSTopology.Container] = []
        var physical: [SafeEjectDeviceID: Bool] = [:]

        func visit(_ id: UInt64, path: Set<UInt64>) -> Bool {
            guard path.count < 64, !path.contains(id), let node = byID[id] else { return false }
            if visited.contains(id) { return true }
            var path = path
            path.insert(id)
            if node.isMedia && node.isWhole == true {
                if node.parents.count == 1, let driver = byID[node.parents[0]], driver.parents.count == 1,
                    let device = byID[driver.parents[0]],
                    let physicalID = SafeEjectMediaTopology(
                        bsdName: node.bsdName, registryID: node.id, isWhole: node.isWhole,
                        providerIsBlockStorageDriver: driver.isBlockStorageDriver,
                        deviceIsBlockStorageDevice: device.isBlockStorageDevice,
                        physicalInterconnect: device.physicalInterconnect,
                        physicalLocation: device.physicalLocation
                    ).physicalDeviceID
                {
                    physical[physicalID] = device.physicalLocation == kIOPropertyInternalKey
                    visited.insert(id)
                    return true
                }
                // A logical whole node needs an explicit, UUID-checked APFS store association.
                guard let apfs, let name = node.bsdName, let uuid = node.mediaUUID,
                    let container = apfs.containers.first(where: { $0.bsdName == name && $0.uuid == uuid }),
                    container.stores.count == 1, let store = container.stores.first
                else { return false }
                var backingMedia: Set<UInt64> = []
                for parent in node.parents {
                    guard let media = firstMediaAncestors(parent) else { return false }
                    backingMedia.formUnion(media)
                }
                guard backingMedia.count == 1, let storeID = backingMedia.first,
                    byID[storeID]?.bsdName == store.bsdName, byID[storeID]?.mediaUUID == store.uuid
                else { return false }
                let sourceVolumes = container.volumes.filter { volume in
                    nodes.contains { candidate in
                        candidate.bsdName == volume.bsdName && candidate.mediaUUID == volume.uuid
                            && ancestorIDs(candidate.id)?.contains(node.id) == true
                    }
                }
                guard sourceVolumes.count == 1 else { return false }
                usedContainers.append(container)
            }
            guard !node.parents.isEmpty,
                node.parents.allSatisfy({ visit($0, path: path) })
            else { return false }
            visited.insert(id)
            return true
        }
        guard visit(rootID, path: []), physical.count == 1, let entry = physical.first else { return nil }
        return SafeEjectResolvedTopology(
            deviceID: entry.key, isInternal: entry.value,
            nodes: nodes.sorted { $0.id < $1.id },
            containers: usedContainers.sorted { $0.bsdName < $1.bsdName }
        )
    }
}

@MainActor
extension SafeEjectRegistryGraph {
    static func read(media: io_registry_entry_t) -> Self {
        var nodes: [SafeEjectRegistryNode] = []
        var visited: Set<UInt64> = []
        var complete = true
        var rootID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &rootID) == KERN_SUCCESS else {
            return Self(rootID: 0, nodes: [], isComplete: false)
        }
        func visit(_ entry: io_registry_entry_t, depth: Int) {
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else {
                complete = false
                return
            }
            if visited.contains(id) { return }
            guard depth < 64, visited.count < 128 else {
                complete = false
                return
            }
            visited.insert(id)
            var node = SafeEjectRegistryNode(id: id)
            node.isMedia = IOObjectConformsTo(entry, "IOMedia") != 0
            node.isBlockStorageDriver = IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0
            node.isBlockStorageDevice = IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0
            func property(_ key: String) -> CFTypeRef? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if node.isMedia {
                node.bsdName = property(kIOBSDNameKey) as? String
                node.mediaUUID = (property(kIOMediaUUIDKey) as? String).flatMap(UUID.init(uuidString:))
                node.isWhole = property(kIOMediaWholeKey) as? Bool
                if node.isWhole == nil { complete = false }
            }
            if node.isBlockStorageDevice {
                let characteristics = property(kIOPropertyProtocolCharacteristicsKey) as? [String: Any]
                node.physicalInterconnect = characteristics?[kIOPropertyPhysicalInterconnectTypeKey] as? String
                node.physicalLocation = characteristics?[kIOPropertyPhysicalInterconnectLocationKey] as? String
            }
            var iterator: io_iterator_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
                complete = false
                nodes.append(node)
                return
            }
            defer { IOObjectRelease(iterator) }
            var parent = IOIteratorNext(iterator)
            while parent != IO_OBJECT_NULL {
                var parentID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(parent, &parentID) == KERN_SUCCESS {
                    node.parents.append(parentID)
                    visit(parent, depth: depth + 1)
                } else {
                    complete = false
                }
                IOObjectRelease(parent)
                if node.parents.count >= 128 {
                    complete = false
                    break
                }
                parent = IOIteratorNext(iterator)
            }
            if IOIteratorIsValid(iterator) == 0 { complete = false }
            node.parents.sort()
            nodes.append(node)
        }
        visit(media, depth: 0)
        return Self(rootID: rootID, nodes: nodes, isComplete: complete)
    }
}
