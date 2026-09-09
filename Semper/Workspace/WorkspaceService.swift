import AppKit
import CoreGraphics
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
    private(set) var topologyPromptsEnabled = false
    private(set) var isUpdatingTopologyPreference = false
    private(set) var undoEntries: [WorkspaceUndoEntry] = []
    var selectedApplicationIDs: Set<String> = []
    private var arrangementSelection: UUID?
    var selectedArrangementID: UUID? {
        get { arrangementSelection }
        set {
            guard presentationReservation == nil else { return }
            if arrangementSelection != newValue {
                arrangementSelection = newValue
                pendingTopologyNotice = nil
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
    private let topologyObserver: any WorkspaceTopologyObserving
    private var pendingTopologyNotice: WorkspaceTopologyNotice?
    private var topologyBaseline: [WorkspaceDisplay]?
    private var topologyObservationGeneration = UUID()
    private var isObservingTopology = false
    private var topologyPreferenceTask: Task<Void, Never>?
    private var isResettingSavedData = false
    private var operation: Task<Void, Never>?
    private var prompted = false
    private var isStopping = false
    private var isShuttingDown = false
    private var pauseTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var managedOperationID: UUID?
    private var receiptOwnerID = UUID()
    private var planGenerationID = UUID()
    private var previewSourceArrangementID: UUID?
    private(set) var presentationReservation: UUID?
    private var reservedPlanID: UUID?
    private var reservedReceiptID: UUID?
    private var reservedRecoveryPending = false
    private var mutationAdmission: MutationAdmissionGate?

    init(
        backend: any WorkspaceWindowBackend, store: WorkspaceStore,
        mutationAdmission: MutationAdmissionGate? = nil,
        topologyObserver: (any WorkspaceTopologyObserving)? = nil
    ) {
        self.backend = backend
        self.store = store
        self.topologyObserver = topologyObserver ?? WorkspaceTopologyObserver()
        self.mutationAdmission = mutationAdmission
    }

    isolated deinit { topologyObserver.stop() }

    convenience init(mutationAdmission: MutationAdmissionGate? = nil) {
        let directory = URL.applicationSupportDirectory.appending(path: "Semper/Workspace", directoryHint: .isDirectory)
        self.init(
            backend: AccessibilityWorkspaceBackend(),
            store: WorkspaceStore(url: directory.appending(path: "arrangements-v1.json")),
            mutationAdmission: mutationAdmission)
    }

    var selectedArrangement: WorkspaceArrangement? { arrangements.first { $0.id == selectedArrangementID } }
    var canRestore: Bool { preview.contains(where: \.canRestore) && isRunning && !isBusy }
    var canUndo: Bool { !undoEntries.isEmpty && isRunning && !isBusy }

    var topologyNotice: WorkspaceTopologyNotice? {
        guard isRunning, topologyPromptsEnabled, !isBusy, !isStopping, !isShuttingDown,
            presentationReservation == nil, mutationAdmission?.activeSharedPermitCount ?? 0 == 0,
            mutationAdmission?.activeExclusiveOwner == nil,
            let notice = pendingTopologyNotice, notice.arrangementID == selectedArrangement?.id
        else { return nil }
        return notice
    }

    func setTopologyPromptsEnabled(_ enabled: Bool) async {
        guard !isUpdatingTopologyPreference, !isResettingSavedData, !isStopping, !isShuttingDown else { return }
        isUpdatingTopologyPreference = true
        if !enabled {
            topologyPromptsEnabled = false
            stopTopologyObservation()
        }
        let task = Task { @MainActor in
            defer {
                self.isUpdatingTopologyPreference = false
                self.topologyPreferenceTask = nil
            }
            do {
                try await self.store.saveTopologyPromptsEnabled(enabled)
                self.topologyPromptsEnabled = enabled
                self.startTopologyObservationIfNeeded()
            } catch {
                let reason = self.message(for: error)
                self.errorMessage =
                    enabled
                    ? reason
                    : "Prompts are off for this active session. The saved setting could not be changed; "
                        + "starting Workspace again may enable prompts. " + reason
            }
        }
        topologyPreferenceTask = task
        await task.value
    }

    func dismissTopologyNotice(_ id: UUID) {
        if pendingTopologyNotice?.id == id { pendingTopologyNotice = nil }
    }

    func previewTopologyNotice(_ id: UUID) async {
        guard let notice = topologyNotice, notice.id == id else { return }
        await makePreview()
        if pendingTopologyNotice?.id == id, previewSourceArrangementID == notice.arrangementID, !preview.isEmpty {
            pendingTopologyNotice = nil
        }
    }

    private func startTopologyObservationIfNeeded() {
        guard isRunning, topologyPromptsEnabled, !isStopping, !isShuttingDown, !isResettingSavedData,
            !isObservingTopology
        else { return }
        let generation = UUID()
        topologyObservationGeneration = generation
        isObservingTopology = true
        let baseline = topologyObserver.start { [weak self] displays in
            guard let self, self.topologyObservationGeneration == generation, self.isObservingTopology,
                self.isRunning, self.topologyPromptsEnabled
            else { return }
            let snapshot = self.topologyIdentity(displays)
            guard snapshot != self.topologyBaseline else { return }
            self.topologyBaseline = snapshot
            guard let arrangement = self.selectedArrangement else {
                self.pendingTopologyNotice = nil
                return
            }
            self.pendingTopologyNotice = WorkspaceTopologyNotice(
                id: UUID(), arrangementID: arrangement.id, arrangementName: arrangement.name)
        }
        topologyBaseline = topologyIdentity(baseline)
    }

    private func stopTopologyObservation() {
        topologyObservationGeneration = UUID()
        if isObservingTopology { topologyObserver.stop() }
        isObservingTopology = false
        topologyBaseline = nil
        pendingTopologyNotice = nil
    }

    private func topologyIdentity(_ displays: [WorkspaceDisplay]) -> [WorkspaceDisplay] {
        displays.map {
            WorkspaceDisplay(id: $0.id, name: "", visibleFrame: $0.visibleFrame, fullScreenFrame: $0.fullScreenFrame)
        }.sorted { $0.id < $1.id }
    }

    func installMutationAdmission(_ gate: MutationAdmissionGate) throws {
        guard !isRunning, operation == nil, presentationReservation == nil,
            mutationAdmission == nil || mutationAdmission === gate
        else { throw WorkspacePlanError.busy }
        mutationAdmission = gate
    }

    func start() async {
        guard !isRunning, !isStopping, !isShuttingDown, operation == nil else { return }
        guard !isUpdatingTopologyPreference else { return }
        isRunning = true
        isUpdatingTopologyPreference = true
        await perform {
            defer { self.isUpdatingTopologyPreference = false }
            self.topologyPromptsEnabled = false
            do { self.topologyPromptsEnabled = try await self.store.loadTopologyPromptsEnabled() } catch {
                self.errorMessage = self.message(for: error)
            }
            try Task.checkCancellation()
            self.canSave = false
            let loaded = try await self.store.load()
            try Task.checkCancellation()
            self.arrangements = loaded
            self.selectedArrangementID = loaded.first?.id
            self.canSave = true
            self.applications = await self.backend.applications()
            try Task.checkCancellation()
            self.startTopologyObservationIfNeeded()
        }
    }

    func pause() async {
        guard presentationReservation == nil else {
            errorMessage = "End Presentation and finish its recovery before pausing Workspace."
            return
        }
        if let pauseTask {
            await pauseTask.value
            return
        }
        isStopping = true
        stopTopologyObservation()
        planGenerationID = UUID()
        isRunning = false
        let pending = operation
        let preference = topologyPreferenceTask
        pending?.cancel()
        let task = Task { @MainActor in
            await pending?.value
            await preference?.value
            self.operation = nil
            self.managedOperationID = nil
            self.isBusy = false
            self.preview = []
            self.candidates = []
            self.pauseTask = nil
            self.isStopping = false
        }
        pauseTask = task
        await task.value
    }

    func shutdown() async {
        guard presentationReservation == nil else {
            errorMessage =
                "Presentation still owns this Workspace session. Finish its recovery before removing Workspace."
            return
        }
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        stopTopologyObservation()
        let task = Task { @MainActor in
            await self.pause()
            await self.backend.shutdown()
            self.bindings = [:]
            self.undoEntries = []
            self.receiptOwnerID = UUID()
            self.shutdownTask = nil
            self.isShuttingDown = false
        }
        shutdownTask = task
        await task.value
    }

    func cancel() {
        guard presentationReservation == nil else { return }
        operation?.cancel()
    }

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
            self.preview = []
            self.previewSourceArrangementID = nil
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
        guard !isUpdatingTopologyPreference, !isResettingSavedData else {
            errorMessage = "Wait for the display prompt preference or saved-data reset to finish, then try again."
            return
        }
        isResettingSavedData = true
        defer { isResettingSavedData = false }
        await perform {
            self.topologyPromptsEnabled = false
            self.stopTopologyObservation()
            try await self.store.resetTopologyPreference()
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
        await perform(mutatesWindows: true) {
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
        await perform(mutatesWindows: true) {
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
        guard selectedArrangementID == arrangement.id else { throw WorkspacePlanError.previewRequired }
        preview = items
        previewSourceArrangementID = arrangement.id
    }

    func makeRestorePlan(selectedSlotIDs: Set<UUID>) throws -> WorkspaceRestorePlan {
        guard isRunning, !isStopping, !isShuttingDown else { throw WorkspacePlanError.stopped }
        guard operation == nil else { throw WorkspacePlanError.busy }
        guard !selectedSlotIDs.isEmpty else { throw WorkspacePlanError.emptySelection }
        guard let arrangement = selectedArrangement, previewSourceArrangementID == arrangement.id,
            !preview.isEmpty, Set(preview.map(\.id)) == Set(arrangement.windows.map(\.id))
        else { throw WorkspacePlanError.previewRequired }
        guard selectedSlotIDs.isSubset(of: Set(preview.map(\.id))) else {
            throw WorkspacePlanError.unknownSelection
        }
        return WorkspaceRestorePlan(
            id: UUID(), arrangementID: arrangement.id, selectedSlotIDs: selectedSlotIDs,
            displays: previewDisplays, steps: preview.filter { selectedSlotIDs.contains($0.id) },
            ownerID: receiptOwnerID, generationID: planGenerationID)
    }

    func reserveForPresentation(_ plan: WorkspaceRestorePlan, token: UUID) throws {
        guard isRunning, !isStopping, !isShuttingDown else { throw WorkspacePlanError.stopped }
        guard operation == nil, presentationReservation == nil else { throw WorkspacePlanError.busy }
        guard plan.ownerID == receiptOwnerID, plan.generationID == planGenerationID,
            plan.arrangementID == previewSourceArrangementID,
            !plan.selectedSlotIDs.isEmpty, plan.steps.allSatisfy(\.canRestore)
        else { throw WorkspacePlanError.previewRequired }
        presentationReservation = token
        reservedPlanID = plan.id
        reservedReceiptID = nil
        reservedRecoveryPending = false
    }

    func releasePresentationReservation(_ token: UUID, keepingCurrent: Bool = false) throws {
        guard presentationReservation == token, !reservedRecoveryPending || keepingCurrent, operation == nil else {
            throw WorkspacePlanError.busy
        }
        presentationReservation = nil
        reservedPlanID = nil
        reservedReceiptID = nil
        reservedRecoveryPending = false
    }

    func apply(_ plan: WorkspaceRestorePlan, ownerToken: UUID? = nil) async -> WorkspaceOperationReceipt {
        let initial = plan.steps.map {
            WorkspaceStepReceipt(step: $0, outcome: .notAttempted, observation: nil, recovery: .none)
        }
        if ownerToken != nil, presentationReservation == ownerToken, reservedReceiptID != nil {
            return receipt(planID: plan.id, reversing: nil, steps: initial, issue: .busy)
        }
        guard plan.ownerID == receiptOwnerID, plan.generationID == planGenerationID,
            !plan.selectedSlotIDs.isEmpty, plan.steps.count <= 200,
            Set(plan.steps.map(\.id)) == plan.selectedSlotIDs, plan.steps.count == plan.selectedSlotIDs.count
        else {
            return receipt(planID: plan.id, reversing: nil, steps: initial, issue: .invalidPlan)
        }
        let result = await performReceipt(planID: plan.id, reversing: nil, initial: initial, ownerToken: ownerToken) {
            var entries: [WorkspaceStepReceipt] = []
            for item in plan.steps {
                if Task.isCancelled {
                    entries.append(.init(step: item, outcome: .notAttempted, observation: nil, recovery: .none))
                    continue
                }
                guard item.canRestore, let windowID = item.boundWindowID, let target = item.targetFrame,
                    let expected = item.currentFrame, WorkspaceGeometry.valid(target), WorkspaceGeometry.valid(expected)
                else {
                    entries.append(.init(step: item, outcome: .skipped(.unresolved), observation: nil, recovery: .none))
                    continue
                }
                do {
                    try await self.requirePermission()
                    guard await self.backend.displays() == plan.displays else {
                        entries.append(
                            .init(step: item, outcome: .skipped(.changedDisplays), observation: nil, recovery: .none))
                        continue
                    }
                    guard let current = try await self.backend.current(windowID), current.id == windowID,
                        let frame = current.frame
                    else {
                        entries.append(
                            .init(step: item, outcome: .skipped(.missingWindow), observation: nil, recovery: .none))
                        continue
                    }
                    if let issue = current.issue {
                        entries.append(
                            .init(step: item, outcome: .skipped(.unsupported(issue)), observation: nil, recovery: .none)
                        )
                        continue
                    }
                    guard frame == expected else {
                        entries.append(
                            .init(step: item, outcome: .skipped(.changedFrame), observation: nil, recovery: .none))
                        continue
                    }
                    try Task.checkCancellation()
                    let observation = try await self.backend.move(windowID, to: target, expected: expected)
                    entries.append(
                        self.appliedStep(
                            item, windowID: windowID, target: target, displays: plan.displays, observation: observation)
                    )
                } catch is CancellationError {
                    entries.append(.init(step: item, outcome: .cancelled, observation: nil, recovery: .none))
                } catch {
                    entries.append(
                        .init(
                            step: item, outcome: .failed(self.operationIssue(error)), observation: nil, recovery: .none)
                    )
                }
            }
            return self.receipt(planID: plan.id, reversing: nil, steps: entries, cancelled: Task.isCancelled)
        }
        if ownerToken != nil, presentationReservation == ownerToken, reservedPlanID == result.planID {
            reservedRecoveryPending = result.needsRecovery
            reservedReceiptID = result.operationID
        }
        return result
    }

    func reverse(_ original: WorkspaceOperationReceipt, ownerToken: UUID? = nil) async -> WorkspaceOperationReceipt {
        let ordered = original.reversesOperationID == nil ? Array(original.steps.reversed()) : original.steps
        let initial = ordered.map {
            WorkspaceStepReceipt(step: $0.step, outcome: .notAttempted, observation: nil, recovery: $0.recovery)
        }
        if ownerToken != nil, presentationReservation == ownerToken, reservedReceiptID != original.operationID {
            return receipt(
                planID: original.planID, reversing: original.operationID, steps: initial, issue: .invalidPlan)
        }
        guard original.ownerID == receiptOwnerID, initial.count <= 200,
            Set(initial.map(\.slotID)).count == initial.count
        else {
            return receipt(
                planID: original.planID, reversing: original.operationID, steps: initial, issue: .invalidPlan,
                ownerID: original.ownerID)
        }
        let result = await performReceipt(
            planID: original.planID, reversing: original.operationID, initial: initial, ownerToken: ownerToken
        ) {
            var entries: [WorkspaceStepReceipt] = []
            for entry in initial {
                if Task.isCancelled {
                    entries.append(entry)
                    continue
                }
                switch entry.recovery {
                case .none:
                    entries.append(.init(step: entry.step, outcome: .unchanged, observation: nil, recovery: .none))
                case .manualRecoveryRequired:
                    entries.append(
                        .init(
                            step: entry.step, outcome: .skipped(.manualRecoveryRequired), observation: nil,
                            recovery: .manualRecoveryRequired))
                case .manualChangePreserved:
                    entries.append(
                        .init(
                            step: entry.step, outcome: .skipped(.manualChangePreserved), observation: nil,
                            recovery: .manualChangePreserved))
                case .pending(let change):
                    entries.append(await self.reverseStep(entry, change: change))
                }
            }
            return self.receipt(
                planID: original.planID, reversing: original.operationID, steps: entries, cancelled: Task.isCancelled)
        }
        if ownerToken != nil, presentationReservation == ownerToken, reservedPlanID == result.planID {
            reservedRecoveryPending = result.needsRecovery
            reservedReceiptID = result.operationID
        }
        return result
    }

    private func reverseStep(_ entry: WorkspaceStepReceipt, change: WorkspaceRecoveryChange) async
        -> WorkspaceStepReceipt
    {
        func result(_ outcome: WorkspaceStepOutcome, recovery: WorkspaceRecoveryState? = nil) -> WorkspaceStepReceipt {
            .init(step: entry.step, outcome: outcome, observation: nil, recovery: recovery ?? entry.recovery)
        }
        guard entry.step.boundWindowID == change.windowID,
            WorkspaceGeometry.valid(change.before), WorkspaceGeometry.valid(change.after)
        else { return result(.failed(.invalidPlan)) }
        do {
            try await requirePermission()
            guard let current = try await backend.current(change.windowID), current.id == change.windowID,
                let frame = current.frame
            else { return result(.skipped(.missingWindow)) }
            guard frame == change.before || frame == change.after else {
                return result(.skipped(.manualChangePreserved), recovery: .manualChangePreserved)
            }
            if let issue = current.issue { return result(.skipped(.unsupported(issue))) }
            let displays = await backend.displays()
            guard displays.contains(change.display), change.display.visibleFrame.contains(change.before) else {
                return result(.skipped(.changedDisplays))
            }
            if frame == change.before { return result(.alreadyRestored, recovery: WorkspaceRecoveryState.none) }
            try Task.checkCancellation()
            let observation = try await backend.move(change.windowID, to: change.before, expected: change.after)
            let recovery: WorkspaceRecoveryState
            if !observation.writeAttempted {
                let changed = observation.before != change.after || observation.after.map { $0 != change.after } == true
                recovery = changed ? .manualChangePreserved : entry.recovery
            } else if let after = observation.after {
                recovery =
                    after == change.before
                    ? .none
                    : .pending(
                        .init(windowID: change.windowID, display: change.display, before: change.before, after: after))
            } else {
                recovery = .manualRecoveryRequired
            }
            let outcome: WorkspaceStepOutcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if recovery == .manualChangePreserved {
                outcome = .skipped(.manualChangePreserved)
            } else if observation.after == nil && observation.writeAttempted {
                outcome = .failed(.unverifiedReadback)
            } else if observation.failure != nil {
                outcome = .failed(.writeFailed)
            } else {
                outcome = recovery == .none ? .restored : .constrained
            }
            return .init(step: entry.step, outcome: outcome, observation: observation, recovery: recovery)
        } catch is CancellationError {
            return result(.cancelled)
        } catch {
            return result(.failed(operationIssue(error)))
        }
    }

    private func appliedStep(
        _ item: WorkspacePreviewItem, windowID: WorkspaceWindowID, target: CGRect, displays: [WorkspaceDisplay],
        observation: WorkspaceMoveObservation
    ) -> WorkspaceStepReceipt {
        let recovery: WorkspaceRecoveryState
        if let after = observation.after, observation.writeAttempted, observation.before != after {
            if let display = WorkspaceGeometry.display(for: observation.before, in: displays),
                display.visibleFrame.contains(observation.before)
            {
                recovery = .pending(
                    .init(windowID: windowID, display: display, before: observation.before, after: after))
            } else {
                recovery = .manualRecoveryRequired
            }
        } else if observation.writeAttempted && observation.after == nil {
            recovery = .manualRecoveryRequired
        } else {
            recovery = .none
        }
        let outcome: WorkspaceStepOutcome
        if Task.isCancelled {
            outcome = .cancelled
        } else if observation.after == nil && observation.writeAttempted {
            outcome = .failed(.unverifiedReadback)
        } else if observation.failure != nil {
            outcome = .failed(.writeFailed)
        } else if let after = observation.after, WorkspaceGeometry.approximatelyEqual(after, target) {
            outcome = observation.before == after ? .unchanged : .applied
        } else {
            outcome = .constrained
        }
        return .init(step: item, outcome: outcome, observation: observation, recovery: recovery)
    }

    private func receipt(
        planID: UUID, reversing: UUID?, steps: [WorkspaceStepReceipt], issue: WorkspaceOperationIssue? = nil,
        cancelled: Bool = false, ownerID: UUID? = nil
    ) -> WorkspaceOperationReceipt {
        let outcome: WorkspaceOperationOutcome
        if cancelled {
            outcome = .cancelled
        } else if issue != nil {
            outcome = .failed
        } else if steps.allSatisfy({ $0.outcome.succeeded }) {
            outcome = .completed
        } else if steps.contains(where: { $0.outcome.succeeded || $0.observation?.writeAttempted == true }) {
            outcome = .partial
        } else {
            outcome = .failed
        }
        return .init(
            operationID: UUID(), planID: planID, reversesOperationID: reversing, outcome: outcome,
            issue: issue, steps: steps, ownerID: ownerID ?? receiptOwnerID)
    }

    private func operationIssue(_ error: Error) -> WorkspaceOperationIssue {
        if let error = error as? WorkspaceError {
            switch error {
            case .permission: return .permission
            case .missing: return .missingWindow
            default: return .writeFailed
            }
        }
        return .writeFailed
    }

    private func performReceipt(
        planID: UUID, reversing: UUID?, initial: [WorkspaceStepReceipt],
        ownerToken: UUID? = nil,
        action: @escaping @MainActor () async -> WorkspaceOperationReceipt
    ) async -> WorkspaceOperationReceipt {
        guard presentationReservation == ownerToken,
            ownerToken == nil || reservedPlanID == planID
        else { return receipt(planID: planID, reversing: reversing, steps: initial, issue: .busy) }
        let permit: MutationAdmissionPermit?
        do { permit = try mutationAdmission?.acquire(owner: .manual, mode: .shared) } catch {
            return receipt(planID: planID, reversing: reversing, steps: initial, issue: .mutationsBlocked)
        }
        defer { if let permit { mutationAdmission?.release(permit) } }
        if Task.isCancelled { return receipt(planID: planID, reversing: reversing, steps: initial, cancelled: true) }
        guard isRunning, !isStopping, !isShuttingDown else {
            return receipt(planID: planID, reversing: reversing, steps: initial, issue: .stopped)
        }
        guard operation == nil else {
            return receipt(planID: planID, reversing: reversing, steps: initial, issue: .busy)
        }
        let operationID = UUID()
        isBusy = true
        managedOperationID = operationID
        let task = Task { @MainActor in await action() }
        let drain = Task {
            await withTaskCancellationHandler {
                _ = await task.value
            } onCancel: {
                task.cancel()
            }
        }
        operation = drain
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await drain.value
        if managedOperationID == operationID {
            operation = nil
            managedOperationID = nil
            isBusy = false
        }
        return value
    }

    private func requirePermission() async throws {
        try Task.checkCancellation()
        let granted = await backend.permission(prompt: !prompted)
        prompted = true
        try Task.checkCancellation()
        if granted {
            permission = .granted
        } else {
            permission = permission == .granted || permission == .revoked ? .revoked : .denied
            preview = []
            throw WorkspaceError.permission
        }
    }

    private func perform(
        mutatesWindows: Bool = false, _ action: @escaping @MainActor () async throws -> Void
    ) async {
        guard presentationReservation == nil else {
            errorMessage = "End Presentation and finish its recovery before changing Workspace."
            return
        }
        let permit: MutationAdmissionPermit?
        do { permit = mutatesWindows ? try mutationAdmission?.acquire(owner: .manual, mode: .shared) : nil } catch {
            errorMessage = "End Away Mode before moving windows."
            return
        }
        defer { if let permit { mutationAdmission?.release(permit) } }
        guard isRunning, !isShuttingDown, operation == nil else { return }
        let operationID = UUID()
        managedOperationID = operationID
        isBusy = true
        errorMessage = nil
        let task = Task { @MainActor in
            do { try await action() } catch is CancellationError {
                self.errorMessage = "Operation cancelled. Any observed window changes remain available to undo."
            } catch { self.errorMessage = self.message(for: error) }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if managedOperationID == operationID {
            operation = nil
            managedOperationID = nil
            isBusy = false
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? WorkspaceError { return error.localizedDescription }
        return "Workspace could not complete the operation. Saved data has been left unchanged."
    }
}
