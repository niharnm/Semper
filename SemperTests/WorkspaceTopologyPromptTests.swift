import CoreGraphics
import Foundation
import Observation
import Testing

@testable import Semper

@MainActor
final class WorkspacePromptObserver: WorkspaceTopologyObserving {
    var screens: [WorkspaceDisplay]
    var callbacks: [@MainActor ([WorkspaceDisplay]) -> Void] = []
    var starts = 0
    var stops = 0
    var onStop: (@MainActor () -> Void)?
    let stopEvents: AsyncStream<Void>
    private let stopSignal: AsyncStream<Void>.Continuation

    init(screens: [WorkspaceDisplay]) {
        self.screens = screens
        (stopEvents, stopSignal) = AsyncStream.makeStream()
    }

    func start(onChange: @escaping @MainActor ([WorkspaceDisplay]) -> Void) -> [WorkspaceDisplay] {
        starts += 1
        callbacks.append(onChange)
        return screens
    }

    func stop() {
        stops += 1
        onStop?()
        stopSignal.yield(())
    }

    func emit(_ screens: [WorkspaceDisplay], callback: Int? = nil) {
        self.screens = screens
        callbacks[callback ?? callbacks.count - 1](screens)
    }
}

actor WorkspacePromptBackend: WorkspaceWindowBackend {
    var allowed = true
    var prompts: [Bool] = []
    var applicationReads = 0
    var displayReads = 0
    var windowReads = 0
    var currentReads = 0
    var moves = 0
    var holdWindows = false
    private var windowWaiter: CheckedContinuation<Void, Never>?
    let windowEvents: AsyncStream<Void>
    private let windowSignal: AsyncStream<Void>.Continuation
    let app: WorkspaceApplication
    let window: WorkspaceWindowSnapshot
    let screen: WorkspaceDisplay

    init(app: WorkspaceApplication, window: WorkspaceWindowSnapshot, screen: WorkspaceDisplay) {
        self.app = app
        self.window = window
        self.screen = screen
        (windowEvents, windowSignal) = AsyncStream.makeStream()
    }

    func permission(prompt: Bool) -> Bool {
        prompts.append(prompt)
        return allowed
    }
    func applications() -> [WorkspaceApplication] {
        applicationReads += 1
        return [app]
    }
    func displays() -> [WorkspaceDisplay] {
        displayReads += 1
        return [screen]
    }
    func windows(in applications: [WorkspaceApplication]) async throws -> [WorkspaceWindowSnapshot] {
        windowReads += 1
        if holdWindows {
            windowSignal.yield(())
            await withCheckedContinuation { windowWaiter = $0 }
        }
        try Task.checkCancellation()
        return applications.contains(app) ? [window] : []
    }
    func current(_ id: WorkspaceWindowID) -> WorkspaceWindowSnapshot? {
        currentReads += 1
        return id == window.id ? window : nil
    }
    func move(_ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect) throws -> WorkspaceMoveObservation {
        moves += 1
        throw WorkspaceError.missing
    }
    func shutdown() {}
    func setAllowed(_ allowed: Bool) { self.allowed = allowed }
    func setHoldWindows() { holdWindows = true }
    func releaseWindows() {
        holdWindows = false
        windowWaiter?.resume()
        windowWaiter = nil
    }
    func counts() -> [Int] {
        [prompts.count, applicationReads, displayReads, windowReads, currentReads, moves]
    }
}

@Suite("Workspace topology prompts", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WorkspaceTopologyPromptTests {
    let screen = WorkspaceDisplay(
        id: "screen-a", name: "Display A", visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 700))

    func changed(_ offset: CGFloat = 100) -> [WorkspaceDisplay] {
        [.init(id: screen.id, name: screen.name, visibleFrame: screen.visibleFrame.offsetBy(dx: offset, dy: 0))]
    }

    struct Fixture {
        let service: WorkspaceService
        let backend: WorkspacePromptBackend
        let observer: WorkspacePromptObserver
        let store: WorkspaceStore
        let gate: MutationAdmissionGate
        let windowID: WorkspaceWindowID
        let arrangements: [WorkspaceArrangement]
    }

    func fixture(count: Int = 1, savedPreference: Bool? = nil) async throws -> Fixture {
        let app = WorkspaceApplication(
            pid: 901, bundleID: "test.workspace-prompts", name: "Test App", launchDate: Date(timeIntervalSince1970: 10))
        let id = WorkspaceWindowID(application: app, token: UUID())
        let window = WorkspaceWindowSnapshot(
            id: id, application: app, ordinal: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 200), issue: nil)
        let backend = WorkspacePromptBackend(app: app, window: window, screen: screen)
        let observer = WorkspacePromptObserver(screens: [screen])
        let directory = FileManager.default.temporaryDirectory.appending(path: "workspace-prompts-\(UUID())")
        let store = WorkspaceStore(url: directory.appending(path: "arrangements-v1.json"))
        let arrangements = (0..<count).map { index in
            WorkspaceArrangement(
                id: UUID(), name: "Desk \(index + 1)", capturedAt: Date(timeIntervalSince1970: 10),
                windows: [
                    .init(
                        id: UUID(), applicationBundleID: app.bundleID, applicationName: app.name,
                        label: "Editor", displayID: screen.id, displayName: screen.name,
                        relativeFrame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
                ])
        }
        try await store.save(arrangements)
        if let savedPreference { try await store.saveTopologyPromptsEnabled(savedPreference) }
        let gate = MutationAdmissionGate()
        let service = WorkspaceService(
            backend: backend, store: store, mutationAdmission: gate, topologyObserver: observer)
        return Fixture(
            service: service, backend: backend, observer: observer, store: store,
            gate: gate, windowID: id, arrangements: arrangements)
    }

    func activate(_ f: Fixture) async {
        await f.service.start()
        f.service.selectedArrangementID = f.arrangements.first?.id
        await f.service.setTopologyPromptsEnabled(true)
    }

    @Test("Construction and default-off start do not observe displays or request access")
    func defaultOff() async throws {
        let f = try await fixture()
        #expect(f.observer.starts == 0)
        await f.service.start()
        #expect(!f.service.topologyPromptsEnabled)
        #expect(f.observer.starts == 0)
        #expect(await f.backend.counts() == [0, 1, 0, 0, 0, 0])
        await f.service.shutdown()
    }

    @Test("Preference persists while paused and observation starts only on activation")
    func persistedPreference() async throws {
        let f = try await fixture()
        await f.service.setTopologyPromptsEnabled(true)
        #expect(try await f.store.loadTopologyPromptsEnabled())
        #expect(f.observer.starts == 0)
        await f.service.start()
        #expect(f.observer.starts == 1)
        await f.service.pause()
        #expect(f.observer.stops == 1)
        #expect(f.service.topologyNotice == nil)
        await f.service.start()
        #expect(f.observer.starts == 2)
        #expect(f.service.topologyNotice == nil)
        await f.service.shutdown()
    }

    @Test("Events compare identities and geometry, ignoring ordering and names")
    func duplicateEventsAndNoWindowWork() async throws {
        let f = try await fixture()
        let other = WorkspaceDisplay(
            id: "screen-b", name: "Display B", visibleFrame: screen.visibleFrame.offsetBy(dx: -1000, dy: -500))
        f.observer.screens = [screen, other]
        await activate(f)
        let counts = await f.backend.counts()
        f.observer.emit([other, .init(id: screen.id, name: "Renamed", visibleFrame: screen.visibleFrame)])
        #expect(f.service.topologyNotice == nil)
        f.observer.emit(changed())
        let first = try #require(f.service.topologyNotice)
        #expect(first.arrangementID == f.arrangements[0].id)
        f.observer.emit(changed())
        #expect(f.service.topologyNotice == first)
        f.observer.emit(changed(200))
        let newest = try #require(f.service.topologyNotice)
        #expect(newest.id != first.id)
        f.service.dismissTopologyNotice(first.id)
        #expect(f.service.topologyNotice == newest)
        f.service.dismissTopologyNotice(newest.id)
        #expect(f.service.topologyNotice == nil)
        f.observer.emit(changed(200))
        #expect(f.service.topologyNotice == nil)
        #expect(await f.backend.counts() == counts)
        #expect(f.service.preview.isEmpty)
        await f.service.shutdown()
    }

    @Test("Full display geometry changes also notify")
    func fullFrameChanges() async throws {
        let f = try await fixture()
        await activate(f)
        f.observer.emit([
            .init(
                id: screen.id, name: screen.name, visibleFrame: screen.visibleFrame,
                fullScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 750))
        ])
        #expect(f.service.topologyNotice != nil)
        await f.service.shutdown()
    }

    @Test("No arrangements means no notice")
    func noArrangements() async throws {
        let f = try await fixture(count: 0)
        await activate(f)
        f.observer.emit(changed())
        #expect(f.service.topologyNotice == nil)
        #expect(await f.backend.prompts.isEmpty)
        await f.service.shutdown()
    }

    @Test("Selection and removal discard the prior arrangement notice")
    func selectionAndRemoval() async throws {
        let f = try await fixture(count: 2)
        await activate(f)
        f.observer.emit(changed())
        let old = try #require(f.service.topologyNotice)
        f.service.selectedArrangementID = f.arrangements[1].id
        #expect(f.service.topologyNotice == nil)
        await f.service.previewTopologyNotice(old.id)
        #expect(await f.backend.prompts.isEmpty)
        f.observer.emit(changed(200))
        #expect(f.service.topologyNotice?.arrangementID == f.arrangements[1].id)
        await f.service.removeArrangement(f.arrangements[1].id)
        #expect(f.service.topologyNotice == nil)
        await f.service.shutdown()
    }

    @Test("Disable stops synchronously before persistence and re-enable takes a fresh baseline")
    func disableAndQueuedCallbacks() async throws {
        let f = try await fixture()
        await activate(f)
        f.observer.emit(changed())
        let old = try #require(f.service.topologyNotice)
        var enabledAtStop: Bool?
        f.observer.onStop = {
            struct Preference: Decodable { let enabled: Bool }
            do {
                let data = try Data(contentsOf: f.store.topologyPreferenceURL)
                enabledAtStop = try JSONDecoder().decode(Preference.self, from: data).enabled
            } catch { Issue.record(error) }
        }
        await f.service.setTopologyPromptsEnabled(false)
        #expect(enabledAtStop == true)
        #expect(!f.service.topologyPromptsEnabled)
        #expect(f.observer.stops == 1)
        f.observer.onStop = nil
        f.observer.emit(changed(200), callback: 0)
        #expect(f.service.topologyNotice == nil)
        await f.service.previewTopologyNotice(old.id)
        #expect(await f.backend.prompts.isEmpty)
        await f.service.setTopologyPromptsEnabled(true)
        #expect(f.observer.starts == 2)
        #expect(f.service.topologyNotice == nil)
        f.observer.emit(changed(300), callback: 0)
        #expect(f.service.topologyNotice == nil)
        f.observer.emit(changed(200), callback: 1)
        #expect(f.service.topologyNotice == nil)
        f.observer.emit(changed(400), callback: 1)
        #expect(f.service.topologyNotice != nil)
        await f.service.shutdown()
    }

    @Test("Any shared or exclusive mutation owner hides and defers the notice")
    func mutationOwnership() async throws {
        let f = try await fixture()
        await activate(f)
        f.observer.emit(changed())
        let notice = try #require(f.service.topologyNotice)
        let shared = try f.gate.acquire(owner: .scene, mode: .shared)
        #expect(f.service.topologyNotice == nil)
        await f.service.previewTopologyNotice(notice.id)
        #expect(await f.backend.prompts.isEmpty)
        f.observer.emit(changed(200))
        #expect(f.service.topologyNotice == nil)
        #expect(f.gate.release(shared))
        let latest = try #require(f.service.topologyNotice)
        #expect(latest.id != notice.id)
        let exclusive = try f.gate.acquire(owner: .awayMode, mode: .exclusive)
        #expect(f.service.topologyNotice == nil)
        await f.service.previewTopologyNotice(latest.id)
        #expect(await f.backend.prompts.isEmpty)
        #expect(f.gate.release(exclusive))
        #expect(f.service.topologyNotice == latest)
        await f.service.shutdown()
    }

    @Test("Presentation keeps observation alive while deferring notices and refusing pause")
    func presentationReservation() async throws {
        let f = try await fixture()
        await activate(f)
        await f.service.makePreview()
        let slotID = f.arrangements[0].windows[0].id
        await f.service.bind(slotID: slotID, to: f.windowID)
        let plan = try f.service.makeRestorePlan(selectedSlotIDs: [slotID])
        let token = UUID()
        try f.service.reserveForPresentation(plan, token: token)
        let previewID = f.service.preview.first?.id
        let bound = f.service.bindings
        f.observer.emit(changed())
        #expect(f.service.topologyNotice == nil)
        await f.service.pause()
        #expect(f.service.isRunning)
        #expect(f.observer.stops == 0)
        #expect(f.service.preview.first?.id == previewID)
        #expect(f.service.bindings == bound)
        try f.service.releasePresentationReservation(token)
        #expect(f.service.topologyNotice != nil)
        try f.service.reserveForPresentation(plan, token: token)
        try f.service.releasePresentationReservation(token)
        await f.service.shutdown()
    }

    @Test("Only an explicit notice action creates a fresh preview")
    func explicitPreview() async throws {
        let f = try await fixture()
        await activate(f)
        f.observer.emit(changed())
        let notice = try #require(f.service.topologyNotice)
        #expect(await f.backend.prompts.isEmpty)
        await f.service.previewTopologyNotice(notice.id)
        #expect(await f.backend.prompts == [true])
        #expect(await f.backend.windowReads == 1)
        #expect(await f.backend.moves == 0)
        #expect(f.service.preview.count == 1)
        #expect(f.service.topologyNotice == nil)
        await f.service.shutdown()
    }

    @Test("Denied access retains a notice for an explicit retry")
    func deniedPreview() async throws {
        let f = try await fixture()
        await activate(f)
        await f.backend.setAllowed(false)
        f.observer.emit(changed())
        let notice = try #require(f.service.topologyNotice)
        await f.service.previewTopologyNotice(notice.id)
        #expect(f.service.permission == .denied)
        #expect(f.service.topologyNotice == notice)
        #expect(await f.backend.windowReads == 0)
        await f.backend.setAllowed(true)
        await f.service.previewTopologyNotice(notice.id)
        #expect(f.service.topologyNotice == nil)
        #expect(await f.backend.prompts == [true, false])
        await f.service.shutdown()
    }

    @Test("Newer topology survives a busy preview and stale action cannot consume it")
    func eventDuringPreview() async throws {
        let f = try await fixture()
        await activate(f)
        f.observer.emit(changed())
        let first = try #require(f.service.topologyNotice)
        await f.backend.setHoldWindows()
        let preview = Task { await f.service.previewTopologyNotice(first.id) }
        for await _ in f.backend.windowEvents { break }
        #expect(f.service.isBusy)
        #expect(f.service.topologyNotice == nil)
        f.observer.emit(changed(200))
        await f.service.previewTopologyNotice(first.id)
        #expect(await f.backend.prompts == [true])
        await f.backend.releaseWindows()
        #expect(await preview.value)
        let next = try #require(f.service.topologyNotice)
        #expect(next.id != first.id)
        #expect(f.service.preview.count == 1)
        await f.service.previewTopologyNotice(first.id)
        #expect(f.service.topologyNotice == next)
        #expect(await f.backend.windowReads == 1)
        await f.service.shutdown()
    }

    @Test("Pause removes observation before a pending preview drains")
    func pauseDuringPreview() async throws {
        let f = try await fixture()
        await activate(f)
        f.observer.emit(changed())
        let notice = try #require(f.service.topologyNotice)
        await f.backend.setHoldWindows()
        let preview = Task { await f.service.previewTopologyNotice(notice.id) }
        for await _ in f.backend.windowEvents { break }
        let pause = Task { await f.service.pause() }
        for await _ in f.observer.stopEvents { break }
        #expect(!f.service.isRunning)
        #expect(f.observer.stops == 1)
        f.observer.emit(changed(200), callback: 0)
        #expect(f.service.topologyNotice == nil)
        await f.backend.releaseWindows()
        #expect(await preview.value == false)
        await pause.value
        #expect(!f.service.isBusy)
        await f.service.start()
        #expect(f.observer.starts == 2)
        #expect(f.service.topologyNotice == nil)
        await f.service.shutdown()
    }

    @Test(
        "Invalid and newer preference files stay untouched",
        arguments: [
            "bad json", "{\"version\":2,\"enabled\":true}", "{\"version\":1}", String(repeating: "x", count: 4097),
        ])
    func invalidPreference(_ source: String) async throws {
        let f = try await fixture()
        let bytes = Data(source.utf8)
        try bytes.write(to: f.store.topologyPreferenceURL)
        await f.service.start()
        #expect(!f.service.topologyPromptsEnabled)
        #expect(f.service.errorMessage != nil)
        #expect(f.service.canSave)
        #expect(f.observer.starts == 0)
        await f.service.setTopologyPromptsEnabled(true)
        #expect(!f.service.topologyPromptsEnabled)
        #expect(try Data(contentsOf: f.store.topologyPreferenceURL) == bytes)
        #expect(f.service.errorMessage != nil)
        await f.service.resetSavedData()
        #expect(!FileManager.default.fileExists(atPath: f.store.topologyPreferenceURL.path))
        #expect(f.service.arrangements.isEmpty)
        #expect(try await f.store.load().isEmpty)
        await f.service.shutdown()
    }

    @Test("Preference is a versioned Boolean with private local permissions")
    func preferenceFormat() async throws {
        let f = try await fixture()
        let arrangementsURL = await f.store.url
        let original = try Data(contentsOf: arrangementsURL)
        await activate(f)
        let data = try Data(contentsOf: f.store.topologyPreferenceURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "enabled"])
        #expect(object["version"] as? Int == 1)
        #expect(object["enabled"] as? Bool == true)
        #expect(try Data(contentsOf: arrangementsURL) == original)
        let directory = try FileManager.default.attributesOfItem(
            atPath: arrangementsURL.deletingLastPathComponent().path)
        let file = try FileManager.default.attributesOfItem(atPath: f.store.topologyPreferenceURL.path)
        #expect(directory[.posixPermissions] as? Int == 0o700)
        #expect(file[.posixPermissions] as? Int == 0o600)
        await f.service.shutdown()
    }

    @Test("Failed opt-out persistence leaves observation off with an explicit session warning")
    func disableFailure() async throws {
        let f = try await fixture()
        await activate(f)
        let invalid = Data("{\"version\":2,\"enabled\":true}".utf8)
        try invalid.write(to: f.store.topologyPreferenceURL)
        await f.service.setTopologyPromptsEnabled(false)
        #expect(!f.service.topologyPromptsEnabled)
        #expect(f.observer.stops == 1)
        #expect(f.service.errorMessage?.contains("off for this active session") == true)
        #expect(f.service.errorMessage?.contains("starting Workspace again may enable prompts") == true)
        #expect(f.service.errorMessage?.contains("unsupported version") == true)
        #expect(try Data(contentsOf: f.store.topologyPreferenceURL) == invalid)
        await f.service.shutdown()
    }

    @available(macOS 26.0, *)
    @Test("Reset reserves preference admission before its managed operation starts")
    func resetAdmission() async throws {
        let f = try await fixture()
        await activate(f)
        var competingUpdate: Task<Void, Never>?
        var attempted = false
        withObservationTracking {
            _ = f.service.isBusy
        } onChange: {
            MainActor.assumeIsolated {
                attempted = true
                competingUpdate = Task.immediate { @MainActor in
                    await f.service.setTopologyPromptsEnabled(true)
                }
                #expect(!f.service.isUpdatingTopologyPreference)
            }
        }
        await f.service.resetSavedData()
        await competingUpdate?.value
        #expect(attempted)
        #expect(!f.service.topologyPromptsEnabled)
        #expect(!FileManager.default.fileExists(atPath: f.store.topologyPreferenceURL.path))
        #expect(f.observer.stops == 1)
        #expect(f.service.arrangements.isEmpty)
        await f.service.shutdown()
    }

    @Test("Delete all saved data stops observation and resets the preference")
    func resetStopsObservation() async throws {
        let f = try await fixture()
        await activate(f)
        f.observer.emit(changed())
        await f.service.resetSavedData()
        #expect(!f.service.topologyPromptsEnabled)
        #expect(f.service.topologyNotice == nil)
        #expect(f.observer.stops == 1)
        #expect(!FileManager.default.fileExists(atPath: f.store.topologyPreferenceURL.path))
        #expect(try await f.store.loadTopologyPromptsEnabled() == false)
        f.observer.emit(changed(200), callback: 0)
        #expect(f.service.topologyNotice == nil)
        await f.service.shutdown()
        await f.service.start()
        #expect(f.observer.starts == 1)
        await f.service.shutdown()
    }
}
