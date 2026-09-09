import CoreGraphics
import Foundation
import Testing

@testable import Semper

actor WorkspaceTestBackend: WorkspaceWindowBackend {
    var allowed = true
    var permissionPrompts: [Bool] = []
    var apps: [WorkspaceApplication]
    var screens: [WorkspaceDisplay]
    var states: [WorkspaceWindowID: WorkspaceWindowSnapshot]
    var moves: [WorkspaceWindowID] = []
    var constrained = false
    var failingMoves: Set<WorkspaceWindowID> = []
    var delay = false
    var stopped = false
    var moveAttempts = 0
    var pauseBeforeAttempt: Int?
    var pauseAfterAttempt: Int?
    var missingReadback = false
    var shutdownWaiter: CheckedContinuation<Void, Never>?
    var holdShutdown = false
    var shutdownCalls = 0
    var frameBeforeNextGuard: CGRect?
    var holdMoveReturn = false
    var moveReturnWaiter: CheckedContinuation<Void, Never>?

    init(apps: [WorkspaceApplication], screens: [WorkspaceDisplay], windows: [WorkspaceWindowSnapshot]) {
        self.apps = apps
        self.screens = screens
        states = Dictionary(uniqueKeysWithValues: windows.compactMap { window in window.id.map { ($0, window) } })
    }
    func permission(prompt: Bool) -> Bool {
        permissionPrompts.append(prompt)
        return allowed
    }
    func applications() -> [WorkspaceApplication] { apps }
    func displays() -> [WorkspaceDisplay] { screens }
    func windows(in applications: [WorkspaceApplication]) async throws -> [WorkspaceWindowSnapshot] {
        if delay { try await Task.sleep(for: .seconds(20)) }
        return states.values.filter { applications.contains($0.application) }.sorted { $0.ordinal < $1.ordinal }
    }
    func current(_ id: WorkspaceWindowID) throws -> WorkspaceWindowSnapshot? {
        if !allowed { throw WorkspaceError.permission }
        return states[id]
    }
    func move(_ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect) async throws -> WorkspaceMoveObservation {
        moveAttempts += 1
        if pauseBeforeAttempt == moveAttempts { try await Task.sleep(for: .seconds(20)) }
        if failingMoves.contains(id) { throw WorkspaceError.missing }
        if let frameBeforeNextGuard {
            change(id, frame: frameBeforeNextGuard)
            self.frameBeforeNextGuard = nil
        }
        guard let state = states[id], let before = state.frame else { throw WorkspaceError.missing }
        guard state.issue == nil, before == expected else {
            return .init(
                before: before, after: before, failure: "Window changed or is unsupported.", writeAttempted: false)
        }
        moves.append(id)
        let after =
            constrained ? CGRect(x: frame.minX, y: frame.minY, width: frame.width + 80, height: frame.height) : frame
        states[id] = .init(id: id, application: state.application, ordinal: state.ordinal, frame: after, issue: nil)
        if holdMoveReturn { await withCheckedContinuation { moveReturnWaiter = $0 } }
        var failure: String?
        if pauseAfterAttempt == moveAttempts {
            do { try await Task.sleep(for: .seconds(20)) } catch is CancellationError {
                failure = "Cancelled after write."
            }
        }
        return .init(before: before, after: missingReadback ? nil : after, failure: failure, writeAttempted: true)
    }
    func shutdown() async {
        shutdownCalls += 1
        if holdShutdown { await withCheckedContinuation { shutdownWaiter = $0 } }
        stopped = true
    }
    func setMovePauses(before: Int? = nil, after: Int? = nil) {
        pauseBeforeAttempt = before
        pauseAfterAttempt = after
    }
    func setFrameBeforeNextGuard(_ frame: CGRect) { frameBeforeNextGuard = frame }
    func setHoldMoveReturn(_ value: Bool) { holdMoveReturn = value }
    func releaseMoveReturn() {
        moveReturnWaiter?.resume()
        moveReturnWaiter = nil
    }
    func setMissingReadback(_ value: Bool) { missingReadback = value }
    func setHoldShutdown(_ value: Bool) { holdShutdown = value }
    func releaseShutdown() {
        shutdownWaiter?.resume()
        shutdownWaiter = nil
    }
    func setPermission(_ value: Bool) { allowed = value }
    func setScreens(_ value: [WorkspaceDisplay]) { screens = value }
    func setConstrained(_ value: Bool) { constrained = value }
    func setFailingMoves(_ value: Set<WorkspaceWindowID>) { failingMoves = value }
    func setDelay(_ value: Bool) { delay = value }
    func change(_ id: WorkspaceWindowID, frame: CGRect? = nil, issue: WorkspaceWindowIssue? = nil) {
        guard let old = states[id] else { return }
        states[id] = .init(
            id: id, application: old.application, ordinal: old.ordinal, frame: frame ?? old.frame, issue: issue)
    }
    func remove(_ id: WorkspaceWindowID) { states[id] = nil }
    func add(_ window: WorkspaceWindowSnapshot) { if let id = window.id { states[id] = window } }
}

@Suite("Workspace Restore", .serialized)
@MainActor
struct WorkspaceServiceTests {
    let app = WorkspaceApplication(
        pid: 901, bundleID: "test.workspace", name: "Test App", launchDate: Date(timeIntervalSince1970: 10))
    let screen = WorkspaceDisplay(
        id: "display-a", name: "Test Display", visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 700))
    let original = CGRect(x: 100, y: 100, width: 400, height: 300)
    let displaced = CGRect(x: 300, y: 200, width: 500, height: 400)

    func fixture(count: Int = 1) -> (WorkspaceService, WorkspaceTestBackend, [WorkspaceWindowID], URL) {
        let ids = (0..<count).map { _ in WorkspaceWindowID(application: app, token: UUID()) }
        let windows = ids.enumerated().map { index, id in
            WorkspaceWindowSnapshot(id: id, application: app, ordinal: index + 1, frame: original, issue: nil)
        }
        let backend = WorkspaceTestBackend(apps: [app], screens: [screen], windows: windows)
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "workspace-tests-\(UUID())", directoryHint: .isDirectory)
        let url = directory.appending(path: "arrangements-v1.json")
        return (WorkspaceService(backend: backend, store: WorkspaceStore(url: url)), backend, ids, url)
    }
    func capture(_ service: WorkspaceService) async {
        await service.start()
        service.selectedApplicationIDs = [app.id]
        service.arrangementName = "Desk"
        await service.capture()
    }

    @Test("Start and pause do not request Accessibility or move windows")
    func lifecycle() async {
        let (service, backend, _, _) = fixture()
        await service.start()
        #expect(await backend.permissionPrompts.isEmpty)
        await service.pause()
        await service.capture()
        #expect(await backend.permissionPrompts.isEmpty)
        #expect(await backend.moves.isEmpty)
        #expect(!service.isRunning && !service.isBusy)
        await service.shutdown()
        #expect(await backend.stopped)
    }

    @Test("Capture is selected and denied access does not save")
    func denial() async {
        let (service, backend, _, _) = fixture()
        await backend.setPermission(false)
        await capture(service)
        #expect(service.arrangements.isEmpty)
        #expect(service.permission == .denied)
        #expect(await backend.permissionPrompts == [true])
        await service.capture()
        #expect(await backend.permissionPrompts == [true, false])
    }

    @Test("Preview never moves, restore verifies, undo keeps later manual changes")
    func restoreAndManualChange() async throws {
        let (service, backend, ids, _) = fixture(count: 2)
        await capture(service)
        for id in ids { await backend.change(id, frame: displaced) }
        await service.makePreview()
        #expect(await backend.moves.isEmpty)
        #expect(service.preview.allSatisfy { $0.canRestore })
        await service.restore()
        #expect(service.results.count == 2 && service.results.allSatisfy(\.succeeded))
        #expect(service.undoEntries.count == 2)
        let manual = CGRect(x: 444, y: 150, width: 400, height: 300)
        await backend.change(ids[0], frame: manual)
        await service.undo()
        #expect(try await backend.current(ids[0])?.frame == manual)
        #expect(try await backend.current(ids[1])?.frame == displaced)
        #expect(service.results.contains { $0.message.contains("preserved") })
    }

    @Test("Minimized and full-screen windows are reported and untouched")
    func windowStates() async {
        let (service, backend, ids, _) = fixture(count: 3)
        await capture(service)
        await backend.change(ids[0], issue: .minimized)
        await backend.change(ids[1], issue: .manualAdjustmentRequired)
        await backend.remove(ids[2])
        await service.makePreview()
        #expect(service.preview.count == 3)
        #expect(service.preview.allSatisfy { !$0.canRestore })
        await service.restore()
        #expect(await backend.moves.isEmpty)
        #expect(service.results.count == 3)
    }

    @Test("Constrained results retain observed frame for undo")
    func constrained() async throws {
        let (service, backend, ids, _) = fixture()
        await capture(service)
        await backend.change(ids[0], frame: displaced)
        await backend.setConstrained(true)
        await service.makePreview()
        await service.restore()
        #expect(service.results.first?.succeeded == false)
        #expect(service.undoEntries.count == 1)
        await backend.setConstrained(false)
        await service.undo()
        #expect(try await backend.current(ids[0])?.frame == displaced)
    }

    @Test("A recreated window requires an explicit rebind")
    func recreation() async throws {
        let (service, backend, ids, _) = fixture()
        await capture(service)
        let slot = try #require(service.selectedArrangement?.windows.first)
        await backend.remove(ids[0])
        let newID = WorkspaceWindowID(application: app, token: UUID())
        await backend.add(.init(id: newID, application: app, ordinal: 1, frame: displaced, issue: nil))
        await service.makePreview()
        #expect(service.preview.first?.canRestore == false)
        await service.restore()
        #expect(await backend.moves.isEmpty)
        await service.makePreview()
        await service.bind(slotID: slot.id, to: newID)
        #expect(service.preview.first?.canRestore == true)
        #expect(await backend.moves.isEmpty)
        await service.restore()
        #expect(await backend.moves == [newID])
    }

    @Test("Reload preserves saved slots but never live bindings")
    func reload() async throws {
        let (service, backend, ids, url) = fixture()
        await capture(service)
        let slot = try #require(service.selectedArrangement?.windows.first)
        let data = try String(contentsOf: url, encoding: .utf8)
        #expect(!data.contains(ids[0].token.uuidString))
        #expect(!data.contains("launchDate") && !data.contains("\"pid\""))
        let reloaded = WorkspaceService(backend: backend, store: WorkspaceStore(url: url))
        await reloaded.start()
        #expect(reloaded.selectedArrangementID == nil)
        reloaded.selectedArrangementID = service.selectedArrangementID
        #expect(reloaded.selectedArrangement?.windows.first?.id == slot.id)
        await reloaded.makePreview()
        #expect(reloaded.preview.first?.canRestore == false)
        await reloaded.bind(slotID: slot.id, to: ids[0])
        #expect(reloaded.preview.first?.canRestore == true)
        #expect(await backend.moves.isEmpty)
    }

    @Test("Missing display requires explicit remapping and changes invalidate preview")
    func displayRemapping() async throws {
        let (service, backend, ids, _) = fixture()
        await capture(service)
        let other = WorkspaceDisplay(
            id: "display-b", name: "Other", visibleFrame: CGRect(x: -1200, y: -800, width: 1200, height: 775))
        await backend.setScreens([other])
        await backend.change(ids[0], frame: displaced)
        await service.makePreview()
        #expect(service.preview.first?.canRestore == false)
        await service.mapDisplay(screen.id, to: other.id)
        #expect(service.preview.first?.canRestore == true)
        #expect(await backend.moves.isEmpty)
        let target = try #require(service.preview.first?.targetFrame)
        #expect(other.visibleFrame.contains(target))
        await backend.setScreens([screen])
        await service.restore()
        #expect(await backend.moves.isEmpty)
        #expect(service.results.first?.message.contains("Displays changed") == true)
    }

    @Test("Duplicate bindings are unresolved")
    func duplicateBindings() async throws {
        let (service, backend, ids, _) = fixture(count: 2)
        await capture(service)
        let slots = try #require(service.selectedArrangement?.windows)
        await service.makePreview()
        await service.bind(slotID: slots[1].id, to: ids[0])
        #expect(service.preview.allSatisfy { !$0.canRestore })
        await service.restore()
        #expect(await backend.moves.isEmpty)
    }

    @Test("Revocation stops the next operation without requesting again")
    func revocation() async {
        let (service, backend, _, _) = fixture()
        await capture(service)
        await backend.setPermission(false)
        await service.makePreview()
        #expect(service.permission == .revoked)
        #expect(service.preview.isEmpty)
        #expect(await backend.permissionPrompts == [true, false])
    }

    @Test("A manual change after preview is preserved")
    func stalePreview() async throws {
        let (service, backend, ids, _) = fixture()
        await capture(service)
        await backend.change(ids[0], frame: displaced)
        await service.makePreview()
        let manual = CGRect(x: 150, y: 175, width: 450, height: 350)
        await backend.change(ids[0], frame: manual)
        await service.restore()
        #expect(await backend.moves.isEmpty)
        #expect(try await backend.current(ids[0])?.frame == manual)
    }

    @Test("Undo continues after a window vanishes during a write")
    func undoRace() async throws {
        let (service, backend, ids, _) = fixture(count: 2)
        await capture(service)
        for id in ids { await backend.change(id, frame: displaced) }
        await service.makePreview()
        await service.restore()
        await backend.setFailingMoves([ids[1]])
        await service.undo()
        #expect(service.results.count == 2)
        #expect(try await backend.current(ids[0])?.frame == displaced)
    }

    @Test("Pause drains cancellation and prevents late capture writes")
    func cancellation() async {
        let (service, backend, _, _) = fixture()
        await service.start()
        service.arrangementName = "Desk"
        service.selectedApplicationIDs = [app.id]
        await backend.setDelay(true)
        let task = Task { await service.capture() }
        while !service.isBusy { await Task.yield() }
        await service.pause()
        await task.value
        #expect(service.arrangements.isEmpty)
        #expect(!service.isBusy && !service.isRunning)
        #expect(await backend.moves.isEmpty)
    }

    @Test("Unsupported persisted versions cannot be overwritten by Capture")
    func unsupportedStore() async throws {
        let (service, _, _, url) = fixture()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data("{\"version\":99,\"arrangements\":[]}".utf8)
        try contents.write(to: url)
        await capture(service)
        #expect(!service.canSave)
        #expect(try Data(contentsOf: url) == contents)
        await service.resetSavedData()
        #expect(service.canSave)
        #expect(try await WorkspaceStore(url: url).load().isEmpty)
    }

    @Test("Undo refuses a previous frame on a disconnected display")
    func undoDisplayChange() async {
        let (service, backend, ids, _) = fixture()
        await capture(service)
        await backend.change(ids[0], frame: displaced)
        await service.makePreview()
        await service.restore()
        await backend.setScreens([
            WorkspaceDisplay(id: "small", name: "Small", visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200))
        ])
        await service.undo()
        #expect(await backend.moves.count == 1)
        #expect(service.results.first?.message.contains("no longer fits") == true)
    }

    @Test("Failed store writes preserve the in-memory arrangement list")
    func failedSave() async throws {
        let (service, _, _, url) = fixture()
        await capture(service)
        let before = service.arrangements
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try Data("occupied".utf8).write(to: url.deletingLastPathComponent())
        service.arrangementName = "Second"
        await service.capture()
        #expect(service.arrangements == before)
        #expect(service.errorMessage != nil)
    }

    @Test("Oversized stores are refused before decode")
    func oversizedStore() async throws {
        let (_, _, _, url) = fixture()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 32, count: 1_048_577).write(to: url)
        await #expect(throws: WorkspaceError.self) { try await WorkspaceStore(url: url).load() }
    }

    @Test("Full-height and tiled geometry are refused without claiming fullscreen state")
    func fullScreenGeometry() {
        let display = WorkspaceDisplay(
            id: "notched", name: "Display", visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 675),
            fullScreenFrame: CGRect(x: 0, y: 25, width: 1000, height: 700))
        #expect(WorkspaceGeometry.excludedByDisplayBounds(CGRect(x: 0, y: 25, width: 1000, height: 700), on: [display]))
        #expect(
            WorkspaceGeometry.excludedByDisplayBounds(CGRect(x: 500, y: 25, width: 500, height: 700), on: [display]))
        #expect(!WorkspaceGeometry.excludedByDisplayBounds(original, on: [display]))
    }

    @Test("A maximized window may be conservatively refused without a fullscreen claim")
    func maximizedRefusal() {
        let display = WorkspaceDisplay(
            id: "auto-hide", name: "Display", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            fullScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let issue = WorkspaceWindowRules.issue(
            standard: true, minimized: false, frame: display.visibleFrame,
            displays: [display], movable: true, resizable: true)
        #expect(issue == .manualAdjustmentRequired)
        #expect(issue?.message.contains("cannot be restored automatically") == true)
        #expect(issue?.message.contains("Full screen") == false)
    }

    @Test("Missing capability or minimized-state reads never permit movement")
    func missingCapabilities() {
        #expect(
            WorkspaceWindowRules.issue(
                standard: true, minimized: false, frame: original,
                displays: [screen], movable: nil, resizable: true) == .unknownState)
        #expect(
            WorkspaceWindowRules.issue(
                standard: true, minimized: nil, frame: original,
                displays: [screen], movable: true, resizable: true) == .unknownState)
        #expect(
            WorkspaceWindowRules.issue(
                standard: true, minimized: false, frame: original,
                displays: [screen], movable: true, resizable: false) == .unsupported)
    }

    @Test("Undo preserves a manual half-point change")
    func subpointManualChange() async throws {
        let (service, backend, ids, _) = fixture()
        await capture(service)
        await backend.change(ids[0], frame: displaced)
        await service.makePreview()
        await service.restore()
        let manual = CGRect(x: original.minX + 0.5, y: original.minY, width: original.width, height: original.height)
        await backend.change(ids[0], frame: manual)
        await service.undo()
        #expect(try await backend.current(ids[0])?.frame == manual)
        #expect(await backend.moves.count == 1)
        await service.makePreview()
        await service.restore()
        #expect(service.undoEntries.count == 1)
        await service.undo()
        #expect(try await backend.current(ids[0])?.frame == manual)
    }

    @Test("AppKit coordinates convert for displays above and left of primary")
    func coordinates() {
        let above = CGRect(x: -500, y: 900, width: 1500, height: 975)
        #expect(
            AccessibilityWorkspaceBackend.accessibilityFrame(above, primaryHeight: 900)
                == CGRect(x: -500, y: -975, width: 1500, height: 975))
        let shiftedPrimary = AccessibilityWorkspaceBackend.accessibilityFrame(above, primaryHeight: 1200)
        #expect(shiftedPrimary.origin.y == -675)
        let relative = WorkspaceGeometry.relative(original, in: screen.visibleFrame)
        #expect(
            WorkspaceGeometry.approximatelyEqual(WorkspaceGeometry.target(relative, in: screen.visibleFrame), original))
    }
}
