// Semper/Views/MenuBar/PopupKeyboardNavModel.swift
import Foundation

@MainActor
@Observable
final class PopupKeyboardNavModel {
    enum RowID: Hashable {
        case device(uid: String)
        case app(target: AudioAppCommandTarget)

        static func app(persistenceID: String) -> RowID {
            .app(target: .persisted(persistenceID))
        }
    }

    private(set) var orderedRowIDs: [RowID] = []

    func syncOrder(
        activeDevices: [AudioDevice],
        appTargets: [AudioAppCommandTarget],
        isEditingPriority: Bool
    ) {
        guard !isEditingPriority else {
            orderedRowIDs = []
            return
        }
        var next: [RowID] = []
        next.reserveCapacity(activeDevices.count + appTargets.count)
        for device in activeDevices {
            next.append(.device(uid: device.uid))
        }
        for target in appTargets {
            next.append(.app(target: target))
        }
        orderedRowIDs = next
    }

    func syncOrder(
        activeDevices: [AudioDevice],
        appPersistenceIDs: [String],
        isEditingPriority: Bool
    ) {
        syncOrder(
            activeDevices: activeDevices,
            appTargets: appPersistenceIDs.map(AudioAppCommandTarget.persisted),
            isEditingPriority: isEditingPriority
        )
    }

    func next(after current: RowID?) -> RowID? {
        guard !orderedRowIDs.isEmpty else { return nil }
        guard let current else { return orderedRowIDs.first }
        guard let index = orderedRowIDs.firstIndex(of: current) else {
            return orderedRowIDs.first
        }
        let nextIndex = index + 1
        return nextIndex < orderedRowIDs.count ? orderedRowIDs[nextIndex] : nil
    }

    func previous(before current: RowID?) -> RowID? {
        guard !orderedRowIDs.isEmpty else { return nil }
        guard let current else { return nil }
        guard let index = orderedRowIDs.firstIndex(of: current) else {
            return nil
        }
        return index > 0 ? orderedRowIDs[index - 1] : nil
    }

    func defaultFocus(defaultOutputUID: String?) -> RowID? {
        guard !orderedRowIDs.isEmpty else { return nil }
        if let uid = defaultOutputUID {
            let candidate = RowID.device(uid: uid)
            if orderedRowIDs.contains(candidate) {
                return candidate
            }
        }
        return orderedRowIDs.first
    }
}
