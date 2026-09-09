import AppKit
import Observation

@Observable
@MainActor
final class WorkspaceService {
    enum PermissionState: String { case notRequested, granted, denied, revoked }
    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var permission: PermissionState = .notRequested
    private(set) var applications: [WorkspaceApplication] = []
    private(set) var displays: [WorkspaceDisplay] = []
    private(set) var arrangements: [WorkspaceArrangement] = []
    private(set) var preview: [WorkspacePreviewItem] = []
    private(set) var candidates: [WorkspaceWindowSnapshot] = []
    private(set) var results: [WorkspaceWindowResult] = []
    private(set) var errorMessage: String?
    private(set) var canSave = false
    private(set) var undoEntries: [WorkspaceUndoEntry] = []
    var selectedApplicationIDs: Set<String> = []
    var selectedArrangementID: UUID? {
        didSet {
            if oldValue != selectedArrangementID {
                preview = []
                bindings = [:]
                displayMappings = [:]
            }
        }
    }
    var arrangementName = ""
    private(set) var bindings: [UUID: WorkspaceWindowID] = [:]
    private(set) var displayMappings: [String: String] = [:]
    private var previewDisplays: [WorkspaceDisplay] = []
    private let backend: any WorkspaceWindowBackend
    private let store: WorkspaceStore
    private var operation: Task<Void, Never>?
    private var prompted = false
    private var isStopping = false

    init(backend: any WorkspaceWindowBackend, store: WorkspaceStore) {
        self.backend = backend
        self.store = store
    }

    convenience init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Semper/Workspace", directoryHint: .isDirectory)
        self.init(
            backend: AccessibilityWorkspaceBackend(),
            store: WorkspaceStore(url: directory.appending(path: "arrangements-v1.json")))
    }

    var selectedArrangement: WorkspaceArrangement? { arrangements.first { $0.id == selectedArrangementID } }
    var canRestore: Bool { preview.contains(where: \.canRestore) && isRunning && !isBusy }
    var canUndo: Bool { !undoEntries.isEmpty && isRunning && !isBusy }

    func start() async {
        guard !isRunning, !isStopping, operation == nil else { return }
        isRunning = true
        await perform {
            self.canSave = false
            let loaded = try await self.store.load()
            try Task.checkCancellation()
            self.arrangements = loaded
            self.selectedArrangementID = loaded.first?.id
            self.canSave = true
            self.applications = await self.backend.applications()
        }
    }

    func pause() async {
        if isStopping {
            await operation?.value
            return
        }
        isStopping = true
        isRunning = false
        operation?.cancel()
        await operation?.value
        operation = nil
        isBusy = false
        preview = []
        candidates = []
        isStopping = false
    }

    func shutdown() async {
        await pause()
        await backend.shutdown()
        bindings = [:]
        undoEntries = []
    }

    func cancel() { operation?.cancel() }

    func refreshApplications() async {
        await perform { self.applications = await self.backend.applications() }
    }

    func capture() async {
        await perform {
            guard self.canSave else { throw WorkspaceError.invalidStore }
            let name = self.arrangementName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                self.errorMessage = "Enter an arrangement name of up to 80 characters."
                return
            }
            guard !self.selectedApplicationIDs.isEmpty else {
                self.errorMessage = "Choose the apps to include before capturing."
                return
            }
            try await self.requirePermission()
            self.applications = await self.backend.applications()
            let chosen = self.applications.filter { self.selectedApplicationIDs.contains($0.id) }
            self.displays = await self.backend.displays()
            let windows = try await self.backend.windows(in: chosen)
            var placements: [WorkspacePlacement] = []
            var captureBindings: [UUID: WorkspaceWindowID] = [:]
            var captureResults: [WorkspaceWindowResult] = []
            for window in windows {
                guard window.issue == nil, let id = window.id, let frame = window.frame,
                    let display = WorkspaceGeometry.display(for: frame, in: self.displays)
                else {
                    captureResults.append(
                        .init(
                            label: window.label,
                            message: window.issue?.message ?? "No matching display was found.", succeeded: false))
                    continue
                }
                let slotID = UUID()
                captureBindings[slotID] = id
                placements.append(
                    .init(
                        id: slotID, applicationBundleID: window.application.bundleID,
                        applicationName: window.application.name, label: window.label,
                        displayID: display.id, displayName: display.name,
                        relativeFrame: WorkspaceGeometry.relative(frame, in: display.visibleFrame)))
                captureResults.append(.init(label: window.label, message: "Captured.", succeeded: true))
            }
            for app in chosen where !windows.contains(where: { $0.application == app }) {
                captureResults.append(
                    .init(label: app.name, message: "No standard windows were found.", succeeded: false))
            }
            self.results = captureResults
            guard !placements.isEmpty else {
                self.errorMessage =
                    "No supported windows were captured. Check the selected apps and their window states."
                return
            }
            let arrangement = WorkspaceArrangement(id: UUID(), name: name, capturedAt: Date(), windows: placements)
            let updated = self.arrangements + [arrangement]
            try Task.checkCancellation()
            try await self.store.save(updated)
            self.arrangements = updated
            self.selectedArrangementID = arrangement.id
            self.bindings = captureBindings
            self.arrangementName = ""
        }
    }

    func makePreview() async {
        await perform {
            try await self.requirePermission()
            try await self.refreshPreview()
        }
    }

    func bind(slotID: UUID, to windowID: WorkspaceWindowID?) async {
        guard isRunning, !isBusy, let slot = selectedArrangement?.windows.first(where: { $0.id == slotID }) else {
            return
        }
        if let windowID {
            guard
                candidates.contains(where: { $0.id == windowID && $0.application.bundleID == slot.applicationBundleID })
            else { return }
            bindings[slotID] = windowID
        } else {
            bindings[slotID] = nil
        }
        await makePreview()
    }

    func mapDisplay(_ originalID: String, to destinationID: String?) async {
        guard isRunning, !isBusy, destinationID == nil || displays.contains(where: { $0.id == destinationID }) else {
            return
        }
        displayMappings[originalID] = destinationID
        await makePreview()
    }

    func renameSlot(_ slotID: UUID, label: String) async {
        await perform {
            guard self.canSave,
                let index = self.arrangements.firstIndex(where: { $0.id == self.selectedArrangementID }),
                let slot = self.arrangements[index].windows.firstIndex(where: { $0.id == slotID })
            else { return }
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                self.errorMessage = "Use a window label of up to 80 characters."
                return
            }
            var updated = self.arrangements
            updated[index].windows[slot].label = name
            try await self.store.save(updated)
            self.arrangements = updated
            self.preview = []
        }
    }

    func removeArrangement(_ id: UUID) async {
        await perform {
            guard self.canSave else { throw WorkspaceError.invalidStore }
            let updated = self.arrangements.filter { $0.id != id }
            try await self.store.save(updated)
            self.arrangements = updated
            if self.selectedArrangementID == id { self.selectedArrangementID = updated.first?.id }
        }
    }

    func resetSavedData() async {
        await perform {
            try await self.store.save([])
            self.arrangements = []
            self.selectedArrangementID = nil
            self.bindings = [:]
            self.undoEntries = []
            self.preview = []
            self.canSave = true
        }
    }

    func restore() async {
        await perform {
            try await self.requirePermission()
            guard !self.preview.isEmpty else {
                self.errorMessage = "Preview an arrangement before restoring."
                return
            }
            let plan = self.preview
            var changed: [WorkspaceUndoEntry] = []
            self.results = []
            for item in plan {
                try Task.checkCancellation()
                guard item.canRestore, let id = item.boundWindowID, let target = item.targetFrame,
                    let expected = item.currentFrame
                else {
                    self.results.append(
                        .init(
                            label: item.placement.label, message: item.reason ?? "Window is unresolved.",
                            succeeded: false))
                    continue
                }
                let topology = await self.backend.displays()
                guard topology == self.previewDisplays else {
                    self.results.append(
                        .init(
                            label: item.placement.label, message: "Displays changed after preview. Preview again.",
                            succeeded: false))
                    continue
                }
                do {
                    let observation = try await self.backend.move(id, to: target, expected: expected)
                    if let after = observation.after, observation.before != after {
                        changed.append(
                            .init(id: id, label: item.placement.label, before: observation.before, after: after))
                        self.undoEntries = changed
                    }
                    let succeeded =
                        observation.failure == nil
                        && observation.after.map { WorkspaceGeometry.approximatelyEqual($0, target) } == true
                    self.results.append(
                        .init(
                            label: item.placement.label,
                            message: observation.failure
                                ?? (succeeded
                                    ? "Restored and verified."
                                    : "The app constrained the frame. The observed change can be undone."),
                            succeeded: succeeded))
                } catch is CancellationError { throw CancellationError() } catch {
                    self.results.append(
                        .init(label: item.placement.label, message: self.message(for: error), succeeded: false))
                }
            }
            self.preview = []
        }
    }

    func undo() async {
        await perform {
            try await self.requirePermission()
            let entries = self.undoEntries.reversed()
            self.results = []
            for entry in entries {
                try Task.checkCancellation()
                do {
                    guard let current = try await self.backend.current(entry.id), let frame = current.frame,
                        current.issue == nil
                    else {
                        self.results.append(
                            .init(
                                label: entry.label,
                                message: "Original window is unavailable or unsupported. Left unchanged.",
                                succeeded: false))
                        continue
                    }
                    guard frame == entry.after else {
                        self.results.append(
                            .init(
                                label: entry.label, message: "Changed since restore. Your later change was preserved.",
                                succeeded: false))
                        continue
                    }
                    let displays = await self.backend.displays()
                    guard displays.contains(where: { $0.visibleFrame.contains(entry.before) }) else {
                        self.results.append(
                            .init(
                                label: entry.label,
                                message: "The previous frame no longer fits an available display. Left unchanged.",
                                succeeded: false))
                        continue
                    }
                    let observation = try await self.backend.move(entry.id, to: entry.before, expected: entry.after)
                    let success =
                        observation.failure == nil
                        && observation.after.map { WorkspaceGeometry.approximatelyEqual($0, entry.before) } == true
                    self.results.append(
                        .init(
                            label: entry.label,
                            message: observation.failure
                                ?? (success ? "Undo verified." : "The app constrained undo. Check this window."),
                            succeeded: success))
                } catch is CancellationError { throw CancellationError() } catch {
                    self.results.append(.init(label: entry.label, message: self.message(for: error), succeeded: false))
                }
            }
            self.undoEntries = []
            self.preview = []
        }
    }

    private func refreshPreview() async throws {
        guard let arrangement = selectedArrangement else {
            preview = []
            return
        }
        let apps = await backend.applications()
        let bundleIDs = Set(arrangement.windows.map(\.applicationBundleID))
        candidates = try await backend.windows(in: apps.filter { bundleIDs.contains($0.bundleID) })
        displays = await backend.displays()
        previewDisplays = displays
        var items: [WorkspacePreviewItem] = []
        let resolvedIDs = arrangement.windows.compactMap { bindings[$0.id] }
        for placement in arrangement.windows {
            try Task.checkCancellation()
            let liveID = bindings[placement.id]
            let state: WorkspaceWindowSnapshot?
            if let liveID { state = try await backend.current(liveID) } else { state = nil }
            let displayID = displayMappings[placement.displayID] ?? placement.displayID
            let display = displays.first { $0.id == displayID }
            let reason: String?
            if let liveID, resolvedIDs.filter({ $0 == liveID }).count > 1 {
                reason = "This window is assigned to more than one slot. Choose a different window."
            } else if state == nil {
                reason = "Choose an open window for this saved slot. The original window is unavailable."
            } else if let issue = state?.issue {
                reason = issue.message
            } else if display == nil {
                reason = "The saved display is unavailable. Choose a destination display."
            } else {
                reason = nil
            }
            items.append(
                .init(
                    placement: placement, boundWindowID: state?.id, currentFrame: state?.frame,
                    targetFrame: display.map { WorkspaceGeometry.target(placement.relativeFrame, in: $0.visibleFrame) },
                    reason: reason))
        }
        preview = items
    }

    private func requirePermission() async throws {
        try Task.checkCancellation()
        let granted = await backend.permission(prompt: !prompted)
        prompted = true
        try Task.checkCancellation()
        if granted {
            permission = .granted
        } else {
            permission = permission == .granted ? .revoked : .denied
            preview = []
            throw WorkspaceError.permission
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard isRunning, operation == nil else { return }
        isBusy = true
        errorMessage = nil
        let task = Task { @MainActor in
            do { try await action() } catch is CancellationError {
                self.errorMessage = "Operation cancelled. Any observed window changes remain available to undo."
            } catch { self.errorMessage = self.message(for: error) }
        }
        operation = task
        await task.value
        operation = nil
        isBusy = false
    }

    private func message(for error: Error) -> String {
        if let error = error as? WorkspaceError { return error.localizedDescription }
        return "Workspace could not complete the operation. Saved data has been left unchanged."
    }
}
