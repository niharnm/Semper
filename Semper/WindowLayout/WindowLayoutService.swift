import CoreGraphics
import Foundation
import Observation

enum WindowLayoutError: LocalizedError {
    case stopped, busy, noTarget, noRestore, placementReview, missingWindow, changedWindow, changedDisplays
    case invalidPlacement, unsupported(WorkspaceWindowIssue), unverifiedWrite, fullHeightReadback, constrained
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .stopped: "Add and enable Window Layout before arranging a window."
        case .busy: "Wait for the current window action to finish, or cancel it."
        case .noTarget: "Select a window in another app, then return to Semper and try again."
        case .noRestore: "There is no previous placement to restore in this session."
        case .placementReview:
            "Check the window in its original app, then choose Keep Current Placement before another action."
        case .missingWindow: "The original app or window is no longer available. No replacement window was chosen."
        case .changedWindow: "The window changed since the last action. Its later placement was preserved."
        case .changedDisplays: "The displays changed. Check the window and try a new layout action."
        case .invalidPlacement:
            "This placement does not fit the usable display area or reaches the display's full height. Try Center with a smaller window."
        case .unsupported(let issue):
            switch issue {
            case .unsupported:
                "This must be a standard window that allows moving and resizing."
            case .unknownState:
                "The app did not provide readable window geometry or move and resize capabilities."
            case .minimized: "Unminimize the window in its app before arranging it."
            default: issue.message
            }
        case .unverifiedWrite:
            "The window change could not be verified. Check the window in its original app, then choose Keep Current Placement."
        case .fullHeightReadback:
            "The app returned a full-height window that cannot be restored automatically. Check or adjust the window in its app, then choose Keep Current Placement."
        case .constrained: "The app constrained the placement. The observed change can be restored."
        case .writeFailed(let reason): reason
        }
    }
}

@Observable
@MainActor
final class WindowLayoutService {
    struct PreviousPlacement: Equatable {
        let windowID: WorkspaceWindowID
        let before: CGRect
        let after: CGRect
        let displays: [WorkspaceDisplay]
    }

    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var permission: ModulePermissionState = .notDetermined
    private(set) var message: String?
    private(set) var requiresPlacementReview = false
    var canRestore: Bool { isRunning && !isBusy && previousPlacement != nil && !requiresPlacementReview }

    private let backend: any WindowLayoutWindowBackend
    private let mutationAdmission: MutationAdmissionGate
    private let targetApplication: @MainActor () -> WorkspaceApplication?
    private let targetTracker: WindowLayoutTargetTracker?
    private(set) var previousPlacement: PreviousPlacement?
    private var operation: Task<Void, any Error>?
    private var pauseTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var prompted = false
    private var isStopping = false
    private var isShuttingDown = false

    init(
        backend: any WindowLayoutWindowBackend = AccessibilityWorkspaceBackend(),
        mutationAdmission: MutationAdmissionGate,
        targetApplication: (@MainActor () -> WorkspaceApplication?)? = nil
    ) {
        self.backend = backend
        self.mutationAdmission = mutationAdmission
        if let targetApplication {
            self.targetApplication = targetApplication
            targetTracker = nil
        } else {
            let tracker = WindowLayoutTargetTracker()
            targetTracker = tracker
            self.targetApplication = { tracker.targetApplication() }
        }
    }

    isolated deinit {
        targetTracker?.stop()
        operation?.cancel()
    }

    func start() {
        guard !isRunning, !isStopping, !isShuttingDown, operation == nil else { return }
        isRunning = true
        targetTracker?.start()
    }

    func pause() async {
        if let pauseTask {
            await pauseTask.value
            return
        }
        isStopping = true
        isRunning = false
        targetTracker?.stop()
        let pending = operation
        pending?.cancel()
        let task = Task { @MainActor in
            _ = await pending?.result
            self.pauseTask = nil
            self.isStopping = false
        }
        pauseTask = task
        await task.value
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        let task = Task { @MainActor in
            await self.pause()
            await self.backend.shutdown()
            self.previousPlacement = nil
            self.requiresPlacementReview = false
            self.message = nil
            self.shutdownTask = nil
            self.isShuttingDown = false
        }
        shutdownTask = task
        await task.value
    }

    func cancel() { operation?.cancel() }

    func keepCurrentPlacement() {
        guard isRunning, !isBusy, !isStopping, !isShuttingDown else { return }
        previousPlacement = nil
        requiresPlacementReview = false
        message = "Current placement kept. The preceding placement was forgotten."
    }

    func perform(_ action: WindowLayoutAction) async throws {
        do {
            guard isRunning, !isStopping, !isShuttingDown else { throw WindowLayoutError.stopped }
            guard operation == nil else { throw WindowLayoutError.busy }
            guard !requiresPlacementReview else { throw WindowLayoutError.placementReview }
            let previous = previousPlacement
            let application: WorkspaceApplication?
            if action == .restore {
                guard let previous else { throw WindowLayoutError.noRestore }
                application = previous.windowID.application
            } else {
                application = targetApplication()
                guard application != nil else { throw WindowLayoutError.noTarget }
            }
            isBusy = true
            message = nil
            let task = Task { @MainActor in
                defer {
                    self.operation = nil
                    self.isBusy = false
                }
                let permit = try self.mutationAdmission.acquire(owner: .manualWindow, mode: .shared)
                defer { self.mutationAdmission.release(permit) }
                try await self.requirePermission()
                if action == .restore, let previous {
                    try await self.restore(previous)
                } else if let application {
                    try await self.arrange(action, application: application)
                }
            }
            operation = task
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if !requiresPlacementReview {
                if error is CancellationError {
                    message = previousPlacement == nil
                        ? "Window action cancelled. No observed change is available to restore."
                        : "Window action cancelled. The observed change remains available to restore."
                } else if error is MutationAdmissionError {
                    message = "Finish the active window action or end Away Mode, then try again."
                } else {
                    if let workspaceError = error as? WorkspaceError, case .permission = workspaceError {
                        permission = permission == .granted || permission == .revoked ? .revoked : .denied
                    }
                    message = error.localizedDescription
                }
            }
            throw error
        }
    }

    private func requirePermission() async throws {
        try Task.checkCancellation()
        var granted = await backend.permission(prompt: false)
        try Task.checkCancellation()
        if !granted, !prompted {
            prompted = true
            granted = await backend.permission(prompt: true)
            try Task.checkCancellation()
        }
        if granted {
            permission = .granted
        } else {
            permission = permission == .granted || permission == .revoked ? .revoked : .denied
            throw WorkspaceError.permission
        }
    }

    private func arrange(_ action: WindowLayoutAction, application: WorkspaceApplication) async throws {
        let displays = WindowLayoutGeometry.topologyIdentity(await backend.displays())
        guard let snapshot = try await backend.focusedWindow(in: application),
            snapshot.application == application
        else { throw WindowLayoutError.missingWindow }
        let frame = try supportedFrame(snapshot)
        guard let windowID = snapshot.id, windowID.application == application else {
            throw WindowLayoutError.missingWindow
        }
        guard let display = WorkspaceGeometry.display(for: frame, in: displays),
            let target = WindowLayoutGeometry.target(action, frame: frame, display: display)
        else { throw WindowLayoutError.invalidPlacement }
        guard let current = try await backend.current(windowID), current.id == windowID,
            current.application == application
        else { throw WindowLayoutError.missingWindow }
        guard try supportedFrame(current) == frame else { throw WindowLayoutError.changedWindow }
        guard WindowLayoutGeometry.topologyIdentity(await backend.displays()) == displays else {
            throw WindowLayoutError.changedDisplays
        }
        try Task.checkCancellation()
        if WorkspaceGeometry.approximatelyEqual(frame, target) {
            message = "The window is already in this placement."
            return
        }
        let observation = try await backend.move(
            windowID, to: target, expected: frame, expectedDisplays: displays)
        try record(observation, windowID: windowID, target: target, displays: displays, restoring: nil)
        message = "\(action.title) applied and verified. Restore returns to the preceding placement."
    }

    private func restore(_ previous: PreviousPlacement) async throws {
        guard let current = try await backend.current(previous.windowID), current.id == previous.windowID,
            current.application == previous.windowID.application
        else { throw WindowLayoutError.missingWindow }
        let frame = try supportedFrame(current)
        guard frame == previous.after else { throw WindowLayoutError.changedWindow }
        let displays = WindowLayoutGeometry.topologyIdentity(await backend.displays())
        guard displays == previous.displays else { throw WindowLayoutError.changedDisplays }
        guard displays.contains(where: { $0.visibleFrame.contains(previous.before) }) else {
            throw WindowLayoutError.invalidPlacement
        }
        try Task.checkCancellation()
        let observation = try await backend.move(
            previous.windowID, to: previous.before, expected: previous.after, expectedDisplays: displays)
        try record(
            observation, windowID: previous.windowID, target: previous.before,
            displays: displays, restoring: previous)
        message = "Previous placement restored and verified."
    }

    private func supportedFrame(_ snapshot: WorkspaceWindowSnapshot) throws -> CGRect {
        if let issue = snapshot.issue { throw WindowLayoutError.unsupported(issue) }
        guard let frame = snapshot.frame, WorkspaceGeometry.valid(frame) else {
            throw WindowLayoutError.unsupported(.unknownState)
        }
        return frame
    }

    private func record(
        _ observation: WorkspaceMoveObservation, windowID: WorkspaceWindowID, target: CGRect,
        displays: [WorkspaceDisplay], restoring: PreviousPlacement?
    ) throws {
        guard observation.writeAttempted else {
            throw WindowLayoutError.writeFailed(observation.failure ?? "The window action was refused before writing.")
        }
        guard let after = observation.after, WorkspaceGeometry.valid(after) else {
            previousPlacement = nil
            requiresPlacementReview = true
            message = WindowLayoutError.unverifiedWrite.localizedDescription
            throw WindowLayoutError.unverifiedWrite
        }
        let reachedTarget = WorkspaceGeometry.approximatelyEqual(after, target)
        let excludedFrame = WorkspaceGeometry.excludedByDisplayBounds(after, on: displays)
        if observation.before != after || excludedFrame {
            previousPlacement = PreviousPlacement(
                windowID: windowID, before: restoring?.before ?? observation.before, after: after, displays: displays)
        }
        if excludedFrame {
            requiresPlacementReview = true
            message = WindowLayoutError.fullHeightReadback.localizedDescription
            throw WindowLayoutError.fullHeightReadback
        }
        if restoring != nil, reachedTarget { previousPlacement = nil }
        try Task.checkCancellation()
        if let failure = observation.failure { throw WindowLayoutError.writeFailed(failure) }
        guard reachedTarget else {
            if observation.before == after {
                throw WindowLayoutError.writeFailed("The app kept the window in its current placement.")
            }
            throw WindowLayoutError.constrained
        }
    }
}
