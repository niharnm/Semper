import CoreGraphics
import Foundation
import Testing

@testable import Semper

private actor WindowLayoutTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        for waiter in entryWaiters.values { waiter.resume() }
        entryWaiters = [:]
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }

    func waitUntilEntered() async throws {
        let id = UUID()
        try await withTaskCancellationHandler { () async throws -> Void in
            try Task.checkCancellation()
            if entered { return }
            if released { throw CancellationError() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    entryWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelEntryWaiter(id) }
        }
    }

    func release() {
        released = true
        for waiter in entryWaiters.values { waiter.resume(throwing: CancellationError()) }
        entryWaiters = [:]
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func cancelEntryWaiter(_ id: UUID) {
        entryWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor WindowLayoutTestBackend: WindowLayoutWindowBackend {
    let application: WorkspaceApplication
    let windowID: WorkspaceWindowID
    var state: WorkspaceWindowSnapshot?
    var screens: [WorkspaceDisplay]
    var allowed = true
    var permissionPrompts: [Bool] = []
    var focusedApplications: [WorkspaceApplication] = []
    var requestedFrames: [CGRect] = []
    var expectedDisplaySnapshots: [[WorkspaceDisplay]] = []
    var applicationScanCount = 0
    var shutdownCalls = 0
    var displayReads = 0
    var changedTopology: [WorkspaceDisplay]?
    var focusGate: WindowLayoutTestGate?
    var beforeWriteGate: WindowLayoutTestGate?
    var writeGate: WindowLayoutTestGate?
    var forcedFrame: CGRect?
    var frameBeforeWrite: CGRect?
    var missingReadback = false
    var failureAfterWrite: String?
    var processExists = true

    init(application: WorkspaceApplication, windowID: WorkspaceWindowID, frame: CGRect, screen: WorkspaceDisplay) {
        self.application = application
        self.windowID = windowID
        state = .init(id: windowID, application: application, ordinal: 1, frame: frame, issue: nil)
        screens = [screen]
    }

    func permission(prompt: Bool) -> Bool {
        permissionPrompts.append(prompt)
        return allowed
    }

    func applications() -> [WorkspaceApplication] {
        applicationScanCount += 1
        return processExists ? [application] : []
    }

    func displays() -> [WorkspaceDisplay] {
        displayReads += 1
        if displayReads > 1, let changedTopology { return changedTopology }
        return screens
    }

    func windows(in applications: [WorkspaceApplication]) -> [WorkspaceWindowSnapshot] {
        guard applications.contains(application), let state else { return [] }
        return [state]
    }

    func focusedWindow(in application: WorkspaceApplication) async throws -> WorkspaceWindowSnapshot? {
        focusedApplications.append(application)
        if let focusGate { await focusGate.hold() }
        try Task.checkCancellation()
        return processExists && application == self.application ? state : nil
    }

    func current(_ id: WorkspaceWindowID) throws -> WorkspaceWindowSnapshot? {
        guard allowed else { throw WorkspaceError.permission }
        return processExists && id == windowID ? state : nil
    }

    func move(_ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect) async throws -> WorkspaceMoveObservation {
        try Task.checkCancellation()
        if let frameBeforeWrite { setFrame(frameBeforeWrite) }
        guard let state = try current(id), let before = state.frame else { throw WorkspaceError.missing }
        guard before == expected, state.issue == nil else {
            return .init(before: before, after: before, failure: "The window changed before writing.", writeAttempted: false)
        }
        requestedFrames.append(frame)
        let after = forcedFrame ?? frame
        setFrame(after)
        if let writeGate { await writeGate.hold() }
        return .init(before: before, after: missingReadback ? nil : after, failure: failureAfterWrite, writeAttempted: true)
    }

    func move(
        _ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect, expectedDisplays: [WorkspaceDisplay]
    ) async throws -> WorkspaceMoveObservation {
        expectedDisplaySnapshots.append(expectedDisplays)
        if let beforeWriteGate { await beforeWriteGate.hold() }
        try Task.checkCancellation()
        guard let state = try current(id), let before = state.frame else { throw WorkspaceError.missing }
        guard WindowLayoutGeometry.topologyIdentity(displays())
            == WindowLayoutGeometry.topologyIdentity(expectedDisplays)
        else {
            return .init(
                before: before, after: before,
                failure: "The displays changed before the window layout was applied. Check the window and try again.",
                writeAttempted: false)
        }
        return try await move(id, to: frame, expected: expected)
    }

    func shutdown() {
        shutdownCalls += 1
        state = nil
    }

    func setPermission(_ value: Bool) { allowed = value }
    func setMissingReadback(_ value: Bool) { missingReadback = value }
    func setForcedFrame(_ value: CGRect?) { forcedFrame = value }
    func setFailure(_ value: String?) { failureAfterWrite = value }
    func setFrameBeforeWrite(_ value: CGRect?) { frameBeforeWrite = value }
    func setFocusGate(_ gate: WindowLayoutTestGate) { focusGate = gate }
    func setBeforeWriteGate(_ gate: WindowLayoutTestGate) { beforeWriteGate = gate }
    func setWriteGate(_ gate: WindowLayoutTestGate) { writeGate = gate }
    func setChangedTopology(_ value: [WorkspaceDisplay]) { changedTopology = value }
    func setScreens(_ value: [WorkspaceDisplay]) { screens = value }
    func setProcessExists(_ value: Bool) { processExists = value }
    func setState(_ value: WorkspaceWindowSnapshot?) { state = value }
    func setFrame(_ frame: CGRect) {
        guard let state else { return }
        self.state = .init(
            id: state.id, application: state.application, ordinal: state.ordinal, frame: frame, issue: state.issue)
    }
    func setIssue(_ issue: WorkspaceWindowIssue?) {
        guard let state else { return }
        self.state = .init(
            id: state.id, application: state.application, ordinal: state.ordinal, frame: state.frame, issue: issue)
    }
}

@Suite("Window Layout service", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WindowLayoutServiceTests {
    let app = WorkspaceApplication(
        pid: 432, bundleID: "test.layout", name: "Layout Test", launchDate: Date(timeIntervalSince1970: 42))
    let screen = WorkspaceDisplay(
        id: "layout-display", name: "Display", visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 700),
        fullScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let original = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func fixture(
        gate: MutationAdmissionGate? = nil,
        target: (@MainActor () -> WorkspaceApplication?)? = nil
    ) -> (WindowLayoutService, WindowLayoutTestBackend, MutationAdmissionGate) {
        let gate = gate ?? MutationAdmissionGate()
        let backend = WindowLayoutTestBackend(
            application: app, windowID: .init(application: app, token: UUID()), frame: original, screen: screen)
        let app = app
        let service = WindowLayoutService(
            backend: backend, mutationAdmission: gate, targetApplication: target ?? { app })
        service.start()
        return (service, backend, gate)
    }

    private func withHeldOperation(
        gate: WindowLayoutTestGate,
        operation: @escaping @MainActor () async throws -> Void,
        body: @MainActor (Task<Void, any Error>) async throws -> Void
    ) async throws {
        let task = Task { try await operation() }
        do {
            try await withTaskCancellationHandler {
                try await gate.waitUntilEntered()
                try await body(task)
            } onCancel: {
                task.cancel()
                Task { await gate.release() }
            }
        } catch {
            task.cancel()
            await gate.release()
            _ = await task.result
            throw error
        }
        task.cancel()
        await gate.release()
        _ = await task.result
    }

    @Test("Cancelling before gate arrival does not wait for an operation to arrive")
    func cancellationBeforeGateArrival() async {
        let gate = WindowLayoutTestGate()
        let waiting = Task { try await gate.waitUntilEntered() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await gate.release()
    }

    @Test("Start and pause make no permission request, app scan or window write")
    func noStartupPermission() async throws {
        let (service, backend, _) = fixture()
        #expect(service.permission == .notDetermined)
        #expect(await backend.permissionPrompts.isEmpty)
        #expect(await backend.applicationScanCount == 0)
        await service.pause()
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(await backend.permissionPrompts.isEmpty)
        #expect(await backend.requestedFrames.isEmpty)
        #expect(!service.isRunning && !service.isBusy)
    }

    @Test("Only an explicit action prompts once, and denial does not write")
    func deniedPermission() async {
        let (service, backend, gate) = fixture()
        await backend.setPermission(false)
        await #expect(throws: WorkspaceError.self) { try await service.perform(.leftHalf) }
        await #expect(throws: WorkspaceError.self) { try await service.perform(.center) }
        #expect(service.permission == .denied)
        #expect(await backend.permissionPrompts == [false, true, false])
        #expect(await backend.requestedFrames.isEmpty)
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("Each action rechecks permission and reports later revocation")
    func permissionRevocation() async throws {
        let (service, backend, _) = fixture()
        try await service.perform(.leftHalf)
        await backend.setPermission(false)
        await #expect(throws: WorkspaceError.self) { try await service.perform(.restore) }
        #expect(service.permission == .revoked)
        #expect(await backend.requestedFrames.count == 1)
    }

    @Test("Missing target asks for another app without prompting or scanning")
    func noTarget() async {
        let (service, backend, _) = fixture(target: { nil })
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(service.message?.contains("Select a window in another app") == true)
        #expect(await backend.permissionPrompts.isEmpty)
        #expect(await backend.applicationScanCount == 0)
    }

    @Test("Target identity is captured before asynchronous reads")
    func capturesTargetBeforeAwait() async throws {
        var target: WorkspaceApplication? = app
        let (service, backend, _) = fixture(target: { target })
        let gate = WindowLayoutTestGate()
        await backend.setFocusGate(gate)
        try await withHeldOperation(gate: gate, operation: { try await service.perform(.leftHalf) }) { task in
            target = WorkspaceApplication(pid: 433, bundleID: "test.other", name: "Other", launchDate: Date())
            await gate.release()
            try await task.value
        }
        #expect(await backend.focusedApplications == [app])
        #expect(await backend.applicationScanCount == 0)
    }

    @Test("Halves and maximize remain eligible for center and preceding-placement restore", arguments: [
        WindowLayoutAction.leftHalf, .rightHalf, .maximize,
    ])
    func chainedLayouts(_ first: WindowLayoutAction) async throws {
        let (service, backend, _) = fixture()
        try await service.perform(first)
        let firstFrame = try #require(await backend.state?.frame)
        try await service.perform(.center)
        let centered = try #require(await backend.state?.frame)
        try await service.perform(.restore)
        #expect(await backend.state?.frame == (centered == firstFrame ? original : firstFrame))
        #expect(!service.canRestore)
        #expect(!service.requiresPlacementReview)
    }

    @Test("Restore returns to only the immediately preceding verified placement")
    func singleStepHistory() async throws {
        let (service, backend, _) = fixture()
        try await service.perform(.leftHalf)
        let half = await backend.state?.frame
        try await service.perform(.rightHalf)
        try await service.perform(.restore)
        #expect(await backend.state?.frame == half)
        #expect(!service.canRestore)
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.restore) }
    }

    @Test("Unsupported, minimized and unknown windows are refused without writes", arguments: [
        WorkspaceWindowIssue.unsupported, .minimized, .unknownState, .unavailable, .manualAdjustmentRequired,
    ])
    func unsupportedStates(_ issue: WorkspaceWindowIssue) async {
        let (service, backend, _) = fixture()
        await backend.setIssue(issue)
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(await backend.requestedFrames.isEmpty)
        #expect(service.message != nil)
    }

    @Test("Focused-window failures keep their reason even without an identity", arguments: [
        WorkspaceWindowIssue.timedOut, .ambiguousIdentity,
    ])
    func failureWithoutIdentity(_ issue: WorkspaceWindowIssue) async {
        let (service, backend, _) = fixture()
        await backend.setState(.init(id: nil, application: app, ordinal: 1, frame: nil, issue: issue))
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(service.message == issue.message)
        #expect(await backend.requestedFrames.isEmpty)
    }

    @Test("Missing, replaced and relaunched windows are not restored", arguments: [0, 1, 2])
    func staleIdentity(_ kind: Int) async throws {
        let (service, backend, _) = fixture()
        try await service.perform(.leftHalf)
        let frame = await backend.state?.frame
        if kind == 0 {
            await backend.setState(nil)
        } else if kind == 1 {
            let replacement = WorkspaceWindowID(application: app, token: UUID())
            await backend.setState(.init(id: replacement, application: app, ordinal: 1, frame: frame, issue: nil))
        } else {
            await backend.setProcessExists(false)
        }
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.restore) }
        #expect(await backend.requestedFrames.count == 1)
        #expect(service.message?.contains("no longer available") == true)
    }

    @Test("Later external movement is preserved")
    func externalMovement() async throws {
        let (service, backend, _) = fixture()
        try await service.perform(.leftHalf)
        let external = CGRect(x: 222, y: 144, width: 333, height: 444)
        await backend.setFrame(external)
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.restore) }
        #expect(await backend.state?.frame == external)
        #expect(await backend.requestedFrames.count == 1)
        #expect(service.message?.contains("preserved") == true)
    }

    @Test("Backend expected-frame guard preserves a change immediately before writing")
    func changedBeforeWrite() async {
        let (service, backend, _) = fixture()
        let external = CGRect(x: 250, y: 130, width: 500, height: 350)
        await backend.setFrameBeforeWrite(external)
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(await backend.state?.frame == external)
        #expect(await backend.requestedFrames.isEmpty)
        #expect(!service.canRestore)
    }

    @Test("Topology changes before a write are refused")
    func changedTopologyBeforeWrite() async {
        let (service, backend, _) = fixture()
        await backend.setChangedTopology([])
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(await backend.requestedFrames.isEmpty)
        #expect(service.message?.contains("displays changed") == true)
    }

    @Test("Restore refuses a changed display arrangement")
    func changedTopologyBeforeRestore() async throws {
        let (service, backend, _) = fixture()
        try await service.perform(.leftHalf)
        await backend.setScreens([.init(id: screen.id, name: screen.name, visibleFrame: original)])
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.restore) }
        #expect(await backend.requestedFrames.count == 1)
    }

    @Test("Display changes during the backend's final suspension prevent layout and restore writes",
        arguments: [false, true], [0, 1, 2])
    func changedTopologyAtWriteBoundary(_ restoring: Bool, _ changedField: Int) async throws {
        let (service, backend, _) = fixture()
        if restoring { try await service.perform(.leftHalf) }
        let unchangedFrame = try #require(await backend.state?.frame)
        let initialWriteCount = await backend.requestedFrames.count
        let beforeWrite = WindowLayoutTestGate()
        await backend.setBeforeWriteGate(beforeWrite)
        let action: WindowLayoutAction = restoring ? .restore : .leftHalf
        try await withHeldOperation(gate: beforeWrite, operation: { try await service.perform(action) }) { task in
            let changed = WorkspaceDisplay(
                id: changedField == 0 ? "replaced-display" : screen.id, name: screen.name,
                visibleFrame: changedField == 1
                    ? CGRect(x: 40, y: 25, width: 960, height: 700) : screen.visibleFrame,
                fullScreenFrame: changedField == 2
                    ? CGRect(x: 0, y: 0, width: 1000, height: 850) : screen.fullScreenFrame)
            await backend.setScreens([changed])
            #expect(await backend.state?.frame == unchangedFrame)
            await beforeWrite.release()
            await #expect(throws: WindowLayoutError.self) { try await task.value }
        }
        #expect(await backend.requestedFrames.count == initialWriteCount)
        #expect(await backend.state?.frame == unchangedFrame)
        #expect(await backend.expectedDisplaySnapshots.last == WindowLayoutGeometry.topologyIdentity([screen]))
        #expect(service.message?.contains("displays changed before") == true)
        #expect(service.canRestore == restoring)
    }

    @Test("Display names and enumeration order may change without blocking layout or restore",
        arguments: [false, true])
    func displayNamesAndOrderAtWriteBoundary(_ restoring: Bool) async throws {
        let (service, backend, _) = fixture()
        let other = WorkspaceDisplay(
            id: "other-display", name: "Other", visibleFrame: CGRect(x: 1000, y: 25, width: 1000, height: 700),
            fullScreenFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        await backend.setScreens([screen, other])
        if restoring { try await service.perform(.leftHalf) }
        let beforeWrite = WindowLayoutTestGate()
        await backend.setBeforeWriteGate(beforeWrite)
        let action: WindowLayoutAction = restoring ? .restore : .leftHalf
        try await withHeldOperation(gate: beforeWrite, operation: { try await service.perform(action) }) { task in
            await backend.setScreens([
                .init(id: other.id, name: "Renamed other", visibleFrame: other.visibleFrame,
                    fullScreenFrame: other.fullScreenFrame),
                .init(id: screen.id, name: "Renamed display", visibleFrame: screen.visibleFrame,
                    fullScreenFrame: screen.fullScreenFrame),
            ])
            await beforeWrite.release()
            try await task.value
        }
        let halfFrame = try #require(WindowLayoutGeometry.target(.leftHalf, frame: original, display: screen))
        let expectedFrame = restoring ? original : halfFrame
        #expect(await backend.state?.frame == expectedFrame)
        #expect(await backend.requestedFrames.count == (restoring ? 2 : 1))
        #expect(await backend.expectedDisplaySnapshots.last == WindowLayoutGeometry.topologyIdentity([screen, other]))
    }

    @Test("Auto-hidden system bars refuse full-height targets while a smaller window can still center",
        arguments: [WindowLayoutAction.leftHalf, .rightHalf, .maximize])
    func autoHiddenBarsConservativeLimit(_ action: WindowLayoutAction) async throws {
        let (service, backend, _) = fixture()
        let fullFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        await backend.setScreens([
            .init(id: screen.id, name: screen.name, visibleFrame: fullFrame, fullScreenFrame: fullFrame),
        ])
        await #expect(throws: WindowLayoutError.self) { try await service.perform(action) }
        #expect(await backend.requestedFrames.isEmpty)
        #expect(await backend.state?.frame == original)
        #expect(service.message == WindowLayoutError.invalidPlacement.localizedDescription)
        try await service.perform(.center)
        #expect(await backend.requestedFrames.count == 1)
        #expect(await backend.state?.frame == CGRect(x: 300, y: 250, width: 400, height: 300))
        try await service.perform(.restore)
        #expect(await backend.state?.frame == original)
    }

    @Test("A previous placement outside usable displays is not restored")
    func offscreenPreviousPlacement() async throws {
        let (service, backend, _) = fixture()
        await backend.setFrame(CGRect(x: -100, y: 100, width: 400, height: 300))
        try await service.perform(.leftHalf)
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.restore) }
        #expect(await backend.requestedFrames.count == 1)
        #expect(service.message?.contains("does not fit") == true)
    }

    @Test("Constrained and partially failed writes retain the observed result for restore", arguments: [false, true])
    func observedPartialChange(_ failed: Bool) async throws {
        let (service, backend, _) = fixture()
        await backend.setForcedFrame(CGRect(x: 0, y: 25, width: 600, height: 700))
        if failed { await backend.setFailure("The app rejected its final size write.") }
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(service.canRestore)
        await backend.setForcedFrame(nil)
        await backend.setFailure(nil)
        try await service.perform(.restore)
        #expect(await backend.state?.frame == original)
        #expect(!service.canRestore)
    }

    @Test("A constrained restore remains retryable against its observed partial result")
    func constrainedRestore() async throws {
        let (service, backend, _) = fixture()
        try await service.perform(.leftHalf)
        await backend.setForcedFrame(CGRect(x: 100, y: 100, width: 450, height: 300))
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.restore) }
        #expect(service.canRestore)
        await backend.setForcedFrame(nil)
        try await service.perform(.restore)
        #expect(await backend.state?.frame == original)
    }

    @Test("Missing readback requires acknowledgement and survives pause")
    func unverifiedWriteReview() async throws {
        let (service, backend, _) = fixture()
        await backend.setMissingReadback(true)
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.leftHalf) }
        #expect(service.requiresPlacementReview && !service.canRestore)
        await #expect(throws: WindowLayoutError.self) { try await service.perform(.center) }
        await service.pause()
        service.keepCurrentPlacement()
        #expect(service.requiresPlacementReview)
        service.start()
        service.keepCurrentPlacement()
        #expect(!service.requiresPlacementReview && !service.canRestore)
        await backend.setMissingReadback(false)
        try await service.perform(.center)
        #expect(await backend.requestedFrames.count == 2)
    }

    @Test("Pause preserves preceding placement and shutdown forgets it after draining")
    func pauseAndRemoval() async throws {
        let (service, backend, gate) = fixture()
        try await service.perform(.leftHalf)
        await service.pause()
        #expect(!service.canRestore)
        #expect(await backend.shutdownCalls == 0)
        service.start()
        #expect(service.canRestore)
        try await service.perform(.restore)
        try await service.perform(.rightHalf)
        await service.shutdown()
        #expect(!service.canRestore && !service.requiresPlacementReview && !service.isRunning)
        #expect(await backend.shutdownCalls == 1)
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("Away and Workspace admission block layouts before permission work", arguments: [true, false])
    func admissionBlocked(_ away: Bool) async throws {
        let (service, backend, gate) = fixture()
        let permit = try gate.acquire(owner: away ? .awayMode : .workspaceWindow, mode: away ? .exclusive : .shared)
        await #expect(throws: MutationAdmissionError.self) { try await service.perform(.leftHalf) }
        #expect(await backend.permissionPrompts.isEmpty)
        #expect(await backend.requestedFrames.isEmpty)
        #expect(!service.isBusy)
        #expect(gate.release(permit))
        try await service.perform(.leftHalf)
    }

    @Test("Cancellation before the write makes no change and releases admission")
    func cancelBeforeWrite() async throws {
        let (service, backend, gate) = fixture()
        let focusGate = WindowLayoutTestGate()
        await backend.setFocusGate(focusGate)
        try await withHeldOperation(gate: focusGate, operation: { try await service.perform(.leftHalf) }) { task in
            service.cancel()
            await focusGate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(await backend.requestedFrames.isEmpty)
        #expect(gate.activeSharedPermitCount == 0)
        #expect(!service.isBusy)
    }

    @Test("Pause drains an in-flight write before releasing admission and preserves observed undo")
    func drainAfterWrite() async throws {
        let (service, backend, gate) = fixture()
        let writeGate = WindowLayoutTestGate()
        await backend.setWriteGate(writeGate)
        try await withHeldOperation(gate: writeGate, operation: { try await service.perform(.leftHalf) }) { task in
            #expect(gate.activeSharedPermitCount == 1)
            #expect(throws: MutationAdmissionError.self) { try gate.acquire(owner: .workspaceWindow, mode: .shared) }
            let lifecycle = try gate.acquire(owner: .manual, mode: .shared)
            defer { gate.release(lifecycle) }
            let release = Task { @MainActor in
                #expect(!service.isRunning && service.isBusy)
                #expect(gate.activeSharedPermitCount == 2)
                await writeGate.release()
            }
            await service.pause()
            await release.value
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!service.isBusy)
            #expect(gate.activeSharedPermitCount == 1)
        }
        #expect(gate.activeSharedPermitCount == 0)
        service.start()
        #expect(service.canRestore)
        try await service.perform(.restore)
        #expect(await backend.state?.frame == original)
    }

    @Test("Caller cancellation cancels the managed task and retains partial change")
    func callerCancellation() async throws {
        let (service, backend, gate) = fixture()
        let writeGate = WindowLayoutTestGate()
        await backend.setWriteGate(writeGate)
        try await withHeldOperation(gate: writeGate, operation: { try await service.perform(.leftHalf) }) { task in
            task.cancel()
            await writeGate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(service.canRestore)
        #expect(gate.activeSharedPermitCount == 0)
    }

    @Test("An unsupported frontmost app clears the previous target, while Semper preserves it")
    func targetTracking() {
        let tracker = WindowLayoutTargetTracker()
        tracker.recordActivation(app, isSemper: false)
        tracker.recordActivation(nil, isSemper: true)
        #expect(tracker.lastApplication == app)
        tracker.recordActivation(nil, isSemper: false)
        #expect(tracker.lastApplication == nil)
        tracker.recordActivation(app, isSemper: false)
        tracker.stop()
        #expect(tracker.lastApplication == nil)
    }
}
