import ApplicationServices
import Foundation

nonisolated struct WorkspaceWindowHandleStore<Element> {
    enum Policy { case workspaceRestore, windowLayout }

    struct Handle {
        let element: Element
        let application: WorkspaceApplication
        let ordinal: Int
        let policy: Policy
    }

    private(set) var entries: [WorkspaceWindowID: Handle] = [:]
    private var probeOrder: [WorkspaceWindowID] = []
    var windowLayoutCount: Int { probeOrder.count }

    subscript(id: WorkspaceWindowID) -> Handle? { entries[id] }

    mutating func retain(
        element: Element, application: WorkspaceApplication, ordinal: Int, policy: Policy,
        equal: (Element, Element) -> Bool
    ) -> WorkspaceWindowID? {
        if let id = entries.first(where: {
            $0.value.policy == policy && $0.value.application == application && equal($0.value.element, element)
        })?.key {
            entries[id] = Handle(element: element, application: application, ordinal: ordinal, policy: policy)
            return id
        }
        guard entries.count < 2_000 else { return nil }
        let id = WorkspaceWindowID(application: application, token: UUID())
        entries[id] = Handle(element: element, application: application, ordinal: ordinal, policy: policy)
        if policy == .windowLayout { probeOrder.append(id) }
        return id
    }

    mutating func remove(_ id: WorkspaceWindowID) {
        entries[id] = nil
        probeOrder.removeAll { $0 == id }
    }

    mutating func removeProcesses(_ stale: [WorkspaceApplication]) {
        entries = entries.filter { entry in
            !stale.contains {
                $0.pid == entry.value.application.pid && $0.bundleID == entry.value.application.bundleID
                    && $0.launchDate == entry.value.application.launchDate
            }
        }
        probeOrder.removeAll { entries[$0] == nil }
    }

    mutating func retainWorkspaceWindows(
        in application: WorkspaceApplication, elements: [Element], equal: (Element, Element) -> Bool
    ) {
        entries = entries.filter { entry in
            entry.value.policy != .workspaceRestore || entry.value.application != application
                || elements.contains { equal(entry.value.element, $0) }
        }
    }

    mutating func nextWindowLayoutProbeCandidates(limit: Int = 4) -> [(id: WorkspaceWindowID, element: Element)] {
        let ids = Array(probeOrder.prefix(limit))
        probeOrder.removeFirst(ids.count)
        probeOrder.append(contentsOf: ids)
        return ids.compactMap { id in entries[id].map { (id, $0.element) } }
    }

    mutating func recordProbe(_ result: AXError, for id: WorkspaceWindowID) {
        if result == .invalidUIElement { remove(id) }
    }

    mutating func removeAll() {
        entries.removeAll()
        probeOrder.removeAll()
    }
}
