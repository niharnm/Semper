import CoreGraphics
import Foundation
import Testing

@testable import Semper

@Suite("Workspace workflow requests", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WorkspaceWorkflowTests {
    typealias Fixture = WorkspaceTopologyPromptTests.Fixture

    private func withFixture(
        count: Int = 2, _ action: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await WorkspaceTopologyPromptTests().fixture(count: count)
        let directory = await fixture.store.url.deletingLastPathComponent()
        defer {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        await fixture.service.start()
        do { try await action(fixture) } catch {
            await fixture.backend.releaseWindows()
            await fixture.service.shutdown()
            throw error
        }
        await fixture.backend.releaseWindows()
        await fixture.service.shutdown()
    }

    @Test(
        "Commands preserve their workflow without reading or moving windows",
        arguments: [WorkspaceCommand.capture, .preview, .restore])
    func commandIntent(_ command: WorkspaceCommand) async throws {
        try await withFixture { f in
            let before = await f.backend.counts()
            guard case .openWorkspace(let workflow) = await f.service.handle(command) else {
                Issue.record("The command did not return a Workspace workflow")
                return
            }
            switch command {
            case .capture: #expect(workflow == .capture)
            case .preview: #expect(workflow == .preview)
            case .restore: #expect(workflow == .restore)
            case .undo: Issue.record("Undo was not part of the navigation cases")
            }
            #expect(await f.backend.counts() == before)
            #expect(f.service.selectedArrangementID == nil)
            #expect(f.service.preview.isEmpty)
        }
    }

    @Test("Workflow entry preserves choices and bindings without selecting another arrangement")
    func preservesChoices() async throws {
        try await withFixture { f in
            #expect(f.service.selectedArrangementID == nil)
            let chosen = f.arrangements[1]
            f.service.selectedArrangementID = chosen.id
            f.service.arrangementName = "Draft desk"
            f.service.selectedApplicationIDs = [f.backend.app.id]
            #expect(await f.service.makePreview())
            await f.service.bind(slotID: chosen.windows[0].id, to: f.windowID)
            await f.service.mapDisplay(f.backend.screen.id, to: f.backend.screen.id)
            let bindings = f.service.bindings
            let mappings = f.service.displayMappings
            let counts = await f.backend.counts()
            #expect(f.service.canRestore)

            for workflow in [WorkspaceWorkflow.capture, .preview, .restore] {
                #expect(f.service.beginWorkflow(.init(workflow: workflow)))
                #expect(f.service.selectedArrangementID == chosen.id)
                #expect(f.service.arrangementName == "Draft desk")
                #expect(f.service.selectedApplicationIDs == [f.backend.app.id])
                #expect(f.service.bindings == bindings)
                #expect(f.service.displayMappings == mappings)
                #expect(!f.service.canRestore)
            }
            #expect(await f.backend.counts() == counts)
            await f.service.pause()
            await f.service.start()
            #expect(f.service.selectedArrangementID == chosen.id)
            await f.service.removeArrangement(chosen.id)
            #expect(f.service.selectedArrangementID == nil)
            #expect(f.service.arrangements.count == 1)
        }
    }

    @Test("Each restore entry needs a new explicit preview and a separate restore action")
    func freshRestorePreview() async throws {
        try await withFixture { f in
            f.service.selectedArrangementID = f.arrangements[0].id
            let first = WorkspaceWorkflowRequest(workflow: .restore)
            #expect(f.service.beginWorkflow(first))
            #expect(await f.service.makePreview(requestID: first.id))
            await f.service.bind(slotID: f.arrangements[0].windows[0].id, to: f.windowID)
            #expect(f.service.canRestore)
            let second = WorkspaceWorkflowRequest(workflow: .restore)
            #expect(f.service.beginWorkflow(second))
            #expect(!f.service.canRestore)
            let prompts = await f.backend.prompts
            await f.service.restore()
            #expect(await f.backend.prompts == prompts)
            #expect(await f.backend.moves == 0)
            #expect(await f.service.makePreview(requestID: first.id) == false)
            #expect(!f.service.canRestore)
            #expect(await f.service.makePreview(requestID: second.id))
            #expect(f.service.canRestore)
            #expect(await f.backend.moves == 0)
            await f.service.restore()
            #expect(await f.backend.moves == 1)
        }
    }

    @Test(
        "A preview from an older request or arrangement cannot publish",
        arguments: [false, true])
    func discardsStalePreview(changesSelection: Bool) async throws {
        try await withFixture { f in
            f.service.selectedArrangementID = f.arrangements[0].id
            let first = WorkspaceWorkflowRequest(workflow: .restore)
            #expect(f.service.beginWorkflow(first))
            await f.backend.setHoldWindows()
            let pending = Task { await f.service.makePreview(requestID: first.id) }
            do {
                try await waitForWindowRead(f.backend)
                if changesSelection {
                    f.service.selectedArrangementID = f.arrangements[1].id
                } else {
                    #expect(f.service.beginWorkflow(.init(workflow: .restore)))
                }
                await f.backend.releaseWindows()
                #expect(await pending.value == false)
            } catch {
                await f.backend.releaseWindows()
                _ = await pending.value
                throw error
            }
            #expect(f.service.preview.isEmpty)
            #expect(f.service.candidates.isEmpty)
            #expect(!f.service.canRestore)
            #expect(await f.backend.moves == 0)
        }
    }

    @Test("Preview failure reports failure and cannot reuse an old plan")
    func failedPreview() async throws {
        try await withFixture { f in
            f.service.selectedArrangementID = f.arrangements[0].id
            #expect(await f.service.makePreview())
            await f.service.bind(slotID: f.arrangements[0].windows[0].id, to: f.windowID)
            #expect(f.service.canRestore)
            await f.backend.setAllowed(false)
            #expect(await f.service.makePreview() == false)
            #expect(!f.service.canRestore)
            #expect(f.service.preview.isEmpty)
        }
    }

    @Test("Busy and reserved Workspace refuses binding or display edits before mutation")
    func guardsBindingChanges() async throws {
        try await withFixture { f in
            f.service.selectedArrangementID = f.arrangements[0].id
            #expect(await f.service.makePreview())
            let slot = f.arrangements[0].windows[0].id
            await f.service.bind(slotID: slot, to: f.windowID)
            await f.service.mapDisplay(f.backend.screen.id, to: f.backend.screen.id)
            let bindings = f.service.bindings
            let mappings = f.service.displayMappings
            let plan = try f.service.makeRestorePlan(selectedSlotIDs: [slot])
            let token = UUID()
            try f.service.reserveForPresentation(plan, token: token)
            #expect(!f.service.beginWorkflow(.init(workflow: .restore)))
            #expect(await f.service.makePreview() == false)
            await f.service.bind(slotID: slot, to: nil)
            await f.service.mapDisplay(f.backend.screen.id, to: nil)
            #expect(f.service.bindings == bindings)
            #expect(f.service.displayMappings == mappings)
            try f.service.releasePresentationReservation(token)

            await f.backend.setHoldWindows()
            let pending = Task { await f.service.makePreview() }
            do {
                try await waitForWindowRead(f.backend)
                await f.service.bind(slotID: slot, to: nil)
                await f.service.mapDisplay(f.backend.screen.id, to: nil)
                #expect(f.service.bindings == bindings)
                #expect(f.service.displayMappings == mappings)
                await f.backend.releaseWindows()
                #expect(await pending.value)
            } catch {
                await f.backend.releaseWindows()
                _ = await pending.value
                throw error
            }
        }
    }

    @Test(
        "A new workflow preserves every window in an accepted restore",
        arguments: [WorkspaceRestoreBoundaryBackend.Boundary.permission, .firstMove])
    func preservesAcceptedRestore(_ boundary: WorkspaceRestoreBoundaryBackend.Boundary) async throws {
        let support = WorkspaceServiceTests()
        let ids = (0..<2).map { _ in WorkspaceWindowID(application: support.app, token: UUID()) }
        let windows = ids.enumerated().map { index, id in
            WorkspaceWindowSnapshot(
                id: id, application: support.app, ordinal: index + 1, frame: support.original, issue: nil)
        }
        let backend = WorkspaceTestBackend(apps: [support.app], screens: [support.screen], windows: windows)
        let heldBackend = WorkspaceRestoreBoundaryBackend(backend: backend)
        let gate = MutationAdmissionGate()
        let directory = FileManager.default.temporaryDirectory.appending(path: "workspace-restore-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let service = WorkspaceService(
            backend: heldBackend, store: WorkspaceStore(url: directory.appending(path: "arrangements-v1.json")),
            mutationAdmission: gate, topologyObserver: WorkspacePromptObserver(screens: [support.screen]))
        await support.capture(service)
        for id in ids { await backend.change(id, frame: support.displaced) }
        let first = WorkspaceWorkflowRequest(workflow: .restore)
        #expect(service.beginWorkflow(first))
        #expect(await service.makePreview(requestID: first.id))
        await heldBackend.hold(boundary)
        let restore = Task { await service.restore() }
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in heldBackend.events { return true }
                    return false
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    return false
                }
                defer { group.cancelAll() }
                try #require(try await group.next() == true)
            }
            #expect(service.isBusy)
            #expect(gate.activeSharedPermitCount == 1)
            #expect(service.beginWorkflow(.init(workflow: .restore)))
            #expect(service.preview.isEmpty)
            #expect(!service.canRestore)
            await heldBackend.release()
            await restore.value
            #expect(await backend.moves == ids)
            #expect(service.results.count == ids.count)
            #expect(service.results.allSatisfy { $0.succeeded })
            #expect(service.undoEntries.count == ids.count)
            #expect(gate.activeSharedPermitCount == 0)
            for id in ids { #expect(try await backend.current(id)?.frame == support.original) }
        } catch {
            await heldBackend.release()
            await restore.value
            await service.shutdown()
            throw error
        }
        await service.shutdown()
    }

    private func waitForWindowRead(_ backend: WorkspacePromptBackend) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in backend.windowEvents { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return false
            }
            defer { group.cancelAll() }
            try #require(try await group.next() == true)
        }
    }
}

actor WorkspaceRestoreBoundaryBackend: WorkspaceWindowBackend {
    enum Boundary: Sendable { case permission, firstMove }

    let backend: WorkspaceTestBackend
    let events: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var boundary: Boundary?
    private var waiter: CheckedContinuation<Void, Never>?

    init(backend: WorkspaceTestBackend) {
        self.backend = backend
        (events, signal) = AsyncStream.makeStream()
    }

    func hold(_ boundary: Boundary) { self.boundary = boundary }
    func release() {
        boundary = nil
        waiter?.resume()
        waiter = nil
    }
    private func wait(at boundary: Boundary) async {
        guard self.boundary == boundary else { return }
        self.boundary = nil
        signal.yield(())
        await withCheckedContinuation { waiter = $0 }
    }
    func permission(prompt: Bool) async -> Bool {
        await wait(at: .permission)
        return await backend.permission(prompt: prompt)
    }
    func applications() async -> [WorkspaceApplication] { await backend.applications() }
    func displays() async -> [WorkspaceDisplay] { await backend.displays() }
    func windows(in applications: [WorkspaceApplication]) async throws -> [WorkspaceWindowSnapshot] {
        try await backend.windows(in: applications)
    }
    func current(_ id: WorkspaceWindowID) async throws -> WorkspaceWindowSnapshot? {
        try await backend.current(id)
    }
    func move(_ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect) async throws -> WorkspaceMoveObservation {
        await wait(at: .firstMove)
        return try await backend.move(id, to: frame, expected: expected)
    }
    func shutdown() async { await backend.shutdown() }
}
