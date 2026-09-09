import ApplicationServices
import Foundation
import Testing

@testable import Semper

@Suite("Workspace window handle store", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WorkspaceWindowHandleStoreTests {
    let app = WorkspaceApplication(
        pid: 704, bundleID: "test.handle-store", name: "Handle Test", launchDate: Date(timeIntervalSince1970: 40))

    private func requireID(_ id: WorkspaceWindowID?) throws -> WorkspaceWindowID {
        try #require(id)
    }

    @Test("Store-only baseline reaches the cap while bounded focused maintenance admits 4000 windows")
    func focusedChurnReplay() throws {
        var baseline = WorkspaceWindowHandleStore<Int>()
        var baselineAdmitted = 0
        var baselineRefused = 0
        for element in 0..<4_000 {
            let id = baseline.retain(
                element: element, application: app, ordinal: 1, policy: .windowLayout, equal: ==)
            if id == nil { baselineRefused += 1 } else { baselineAdmitted += 1 }
        }
        #expect(baselineAdmitted == 2_000)
        #expect(baselineRefused == 2_000)
        #expect(baseline.entries.count == 2_000)

        var maintained = WorkspaceWindowHandleStore<Int>()
        let activeElements: Set<Int> = [-3, -2, -1]
        var receiptIDs: [Int: WorkspaceWindowID] = [:]
        for element in activeElements.sorted() {
            receiptIDs[element] = try requireID(
                maintained.retain(
                    element: element, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        }
        var admittedIDs: Set<WorkspaceWindowID> = []
        var peakRetainedCount = maintained.entries.count
        var maxProbeCount = 0
        for element in 0..<4_000 {
            let candidates = maintained.nextWindowLayoutProbeCandidates()
            maxProbeCount = max(maxProbeCount, candidates.count)
            for candidate in candidates {
                maintained.recordProbe(
                    activeElements.contains(candidate.element) ? .success : .invalidUIElement, for: candidate.id)
            }
            let id = try requireID(
                maintained.retain(
                    element: element, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
            admittedIDs.insert(id)
            peakRetainedCount = max(peakRetainedCount, maintained.entries.count)
        }
        #expect(admittedIDs.count == 4_000)
        #expect(maxProbeCount <= 4)
        #expect(peakRetainedCount == activeElements.count + 1)
        for (element, id) in receiptIDs {
            #expect(maintained[id]?.element == element)
            #expect(
                maintained.retain(
                    element: element, application: app, ordinal: 1, policy: .windowLayout, equal: ==) == id)
        }
        #expect(maintained.entries.count == activeElements.count + 1)
    }

    @Test(
        "Transient probe results preserve live receipt identity",
        arguments: [
            AXError.success, .cannotComplete, .apiDisabled, .noValue, .failure, .attributeUnsupported,
        ])
    func transientProbeResults(_ result: AXError) throws {
        var store = WorkspaceWindowHandleStore<Int>()
        let id = try requireID(
            store.retain(
                element: 11, application: app, ordinal: 2, policy: .windowLayout, equal: ==))
        store.recordProbe(result, for: id)
        #expect(store[id]?.element == 11)
        #expect(store[id]?.ordinal == 2)
        #expect(store.entries.count == 1)
        #expect(store.nextWindowLayoutProbeCandidates().map(\.id) == [id])
        #expect(store.retain(element: 11, application: app, ordinal: 3, policy: .windowLayout, equal: ==) == id)
        #expect(store[id]?.ordinal == 3)
        #expect(store.windowLayoutCount == 1)
        #expect(store.nextWindowLayoutProbeCandidates().map(\.id) == [id])
    }

    @Test("Only a confirmed invalid element is removed, and stale results cannot remove its replacement")
    func invalidProbeAndRecreation() throws {
        var store = WorkspaceWindowHandleStore<Int>()
        let oldID = try requireID(
            store.retain(
                element: 12, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        let survivor = try requireID(
            store.retain(
                element: 13, application: app, ordinal: 2, policy: .windowLayout, equal: ==))
        store.recordProbe(.invalidUIElement, for: oldID)
        #expect(store[oldID] == nil)
        #expect(store[survivor] != nil)
        #expect(store.nextWindowLayoutProbeCandidates().map(\.id) == [survivor])
        let replacement = try requireID(
            store.retain(
                element: 12, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        #expect(replacement != oldID)
        store.recordProbe(.invalidUIElement, for: oldID)
        #expect(store[replacement]?.element == 12)
        #expect(store[survivor]?.element == 13)
    }

    @Test("Probe batches are bounded and fair while a partial pass resumes at the next unprobed handle")
    func boundedProbeRotation() throws {
        var store = WorkspaceWindowHandleStore<Int>()
        let workspaceID = try requireID(
            store.retain(
                element: -1, application: app, ordinal: 1, policy: .workspaceRestore, equal: ==))
        var ids: [WorkspaceWindowID] = []
        for element in 0..<13 {
            ids.append(
                try requireID(
                    store.retain(
                        element: element, application: app, ordinal: element + 1, policy: .windowLayout, equal: ==)))
        }
        #expect(store.windowLayoutCount == 13)
        #expect(store.nextWindowLayoutProbeCandidates(limit: 0).isEmpty)
        #expect(store.nextWindowLayoutProbeCandidates(limit: 1).map(\.id) == [ids[0]])
        #expect(store.nextWindowLayoutProbeCandidates().map(\.id) == Array(ids[1...4]))
        var seen: Set<WorkspaceWindowID> = []
        var largestBatch = 0
        for _ in 0..<4 {
            let candidates = store.nextWindowLayoutProbeCandidates()
            largestBatch = max(largestBatch, candidates.count)
            #expect(Set(candidates.map(\.id)).count == candidates.count)
            seen.formUnion(candidates.map(\.id))
        }
        #expect(largestBatch == 4)
        #expect(seen == Set(ids))
        #expect(!seen.contains(workspaceID))
        store.remove(ids[5])
        let remaining = store.nextWindowLayoutProbeCandidates(limit: 100)
        #expect(remaining.count == 12)
        #expect(Set(remaining.map(\.id)) == Set(ids.filter { $0 != ids[5] }))
    }

    @Test("The shared cap preserves existing identities across both policies and refuses new valid handles")
    func sharedCap() throws {
        var store = WorkspaceWindowHandleStore<Int>()
        var layoutIDs: [WorkspaceWindowID] = []
        var workspaceIDs: [WorkspaceWindowID] = []
        for element in 0..<1_000 {
            workspaceIDs.append(
                try requireID(
                    store.retain(
                        element: element, application: app, ordinal: element + 1, policy: .workspaceRestore, equal: ==))
            )
            layoutIDs.append(
                try requireID(
                    store.retain(
                        element: element, application: app, ordinal: element + 1, policy: .windowLayout, equal: ==)))
        }
        #expect(store.entries.count == 2_000)
        #expect(store.windowLayoutCount == 1_000)
        #expect(
            store.retain(
                element: 1_001, application: app, ordinal: 1, policy: .windowLayout, equal: ==) == nil)
        #expect(
            store.retain(
                element: 1_001, application: app, ordinal: 1, policy: .workspaceRestore, equal: ==) == nil)
        #expect(
            store.retain(
                element: 0, application: app, ordinal: 99, policy: .windowLayout, equal: ==) == layoutIDs[0])
        #expect(
            store.retain(
                element: 0, application: app, ordinal: 88, policy: .workspaceRestore, equal: ==) == workspaceIDs[0])
        #expect(store[layoutIDs[0]]?.ordinal == 99)
        #expect(store[workspaceIDs[0]]?.ordinal == 88)
        #expect(store.entries.count == 2_000)
        store.remove(layoutIDs[999])
        let replacement = try requireID(
            store.retain(
                element: 1_001, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        #expect(store[replacement]?.element == 1_001)
        #expect(store[workspaceIDs[999]]?.element == 999)
        #expect(store.entries.count == 2_000)
    }

    @Test("Workspace enumeration prunes only its own missing handles for the selected app")
    func policyAndEnumerationIsolation() throws {
        var store = WorkspaceWindowHandleStore<Int>()
        let otherApp = WorkspaceApplication(
            pid: 705, bundleID: "test.other-handles", name: "Other", launchDate: app.launchDate)
        let workspace = try requireID(
            store.retain(
                element: 7, application: app, ordinal: 1, policy: .workspaceRestore, equal: ==))
        let layout = try requireID(
            store.retain(
                element: 7, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        let workspaceSurvivor = try requireID(
            store.retain(
                element: 8, application: app, ordinal: 2, policy: .workspaceRestore, equal: ==))
        let otherWorkspace = try requireID(
            store.retain(
                element: 7, application: otherApp, ordinal: 1, policy: .workspaceRestore, equal: ==))
        let otherLayout = try requireID(
            store.retain(
                element: 7, application: otherApp, ordinal: 1, policy: .windowLayout, equal: ==))
        #expect(workspace != layout)
        #expect(layout != otherLayout)
        #expect(store[workspace]?.policy == .workspaceRestore)
        #expect(store[layout]?.policy == .windowLayout)
        store.retainWorkspaceWindows(in: app, elements: [8], equal: ==)
        #expect(store[workspace] == nil)
        #expect(store[workspaceSurvivor]?.element == 8)
        #expect(store[layout]?.element == 7)
        #expect(store[otherWorkspace]?.element == 7)
        #expect(store[otherLayout]?.element == 7)
        store.retainWorkspaceWindows(in: app, elements: [], equal: ==)
        #expect(store[workspaceSurvivor] == nil)
        #expect(Set(store.nextWindowLayoutProbeCandidates().map(\.id)) == [layout, otherLayout])
        #expect(store[otherWorkspace] != nil)
    }

    @Test("Explicit stale processes are removed by PID, bundle and launch date without deleting newer or live handles")
    func processIdentityPruning() throws {
        var store = WorkspaceWindowHandleStore<Int>()
        let newLaunch = WorkspaceApplication(
            pid: app.pid, bundleID: app.bundleID, name: "New launch",
            launchDate: app.launchDate.addingTimeInterval(60))
        let changedBundle = WorkspaceApplication(
            pid: app.pid, bundleID: "test.reused-pid", name: "Reused PID", launchDate: app.launchDate)
        let changedPID = WorkspaceApplication(
            pid: 707, bundleID: app.bundleID, name: app.name, launchDate: app.launchDate)
        let renamedLive = WorkspaceApplication(
            pid: 706, bundleID: "test.live", name: "Renamed live app", launchDate: app.launchDate)
        let oldLayout = try requireID(
            store.retain(
                element: 1, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        let oldWorkspace = try requireID(
            store.retain(
                element: 1, application: app, ordinal: 1, policy: .workspaceRestore, equal: ==))
        let newer = try requireID(
            store.retain(
                element: 1, application: newLaunch, ordinal: 1, policy: .windowLayout, equal: ==))
        let reused = try requireID(
            store.retain(
                element: 1, application: changedBundle, ordinal: 1, policy: .windowLayout, equal: ==))
        let differentProcess = try requireID(
            store.retain(
                element: 1, application: changedPID, ordinal: 1, policy: .windowLayout, equal: ==))
        let live = try requireID(
            store.retain(
                element: 1, application: renamedLive, ordinal: 1, policy: .windowLayout, equal: ==))
        let renamedStaleSnapshot = WorkspaceApplication(
            pid: app.pid, bundleID: app.bundleID, name: "Old process with a different name", launchDate: app.launchDate)
        store.removeProcesses([renamedStaleSnapshot])
        #expect(store[oldLayout] == nil)
        #expect(store[oldWorkspace] == nil)
        #expect(store[newer]?.application == newLaunch)
        #expect(store[reused]?.application == changedBundle)
        #expect(store[differentProcess]?.application == changedPID)
        #expect(store[live]?.application == renamedLive)
        #expect(Set(store.nextWindowLayoutProbeCandidates().map(\.id)) == [newer, reused, differentProcess, live])
        store.removeProcesses([])
        #expect(store.entries.count == 4)
    }

    @Test("Shutdown empties both handle policies and resets the probe queue")
    func shutdownClearsQueue() throws {
        var store = WorkspaceWindowHandleStore<Int>()
        let oldLayout = try requireID(
            store.retain(
                element: 4, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        _ = try requireID(
            store.retain(
                element: 5, application: app, ordinal: 1, policy: .workspaceRestore, equal: ==))
        #expect(store.nextWindowLayoutProbeCandidates(limit: 1).map(\.id) == [oldLayout])
        store.removeAll()
        #expect(store.entries.isEmpty)
        #expect(store.windowLayoutCount == 0)
        #expect(store.nextWindowLayoutProbeCandidates().isEmpty)
        let newLayout = try requireID(
            store.retain(
                element: 4, application: app, ordinal: 1, policy: .windowLayout, equal: ==))
        #expect(newLayout != oldLayout)
        #expect(store.nextWindowLayoutProbeCandidates().map(\.id) == [newLayout])
        store.recordProbe(.invalidUIElement, for: oldLayout)
        #expect(store[newLayout]?.element == 4)
    }
}
