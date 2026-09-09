import Foundation

nonisolated enum SceneManagerError: LocalizedError, Equatable, Sendable {
    case emptyName
    case sceneNotFound(UUID)
    case noCurrentControls
    case restoreUnavailable
    case libraryUnreadable(String)
    case duplicateName(String)
    case operationInProgress
    case mutationsBlocked
    case stopped
    case presentationReserved
    case invalidPresentationToken
    case presentationTransactionMismatch

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a scene name."
        case .sceneNotFound:
            "The selected scene no longer exists."
        case .noCurrentControls:
            "No supported controls are available to save."
        case .restoreUnavailable:
            "There is no scene state to restore."
        case .libraryUnreadable(let reason):
            "Saved scenes could not be read: \(reason)"
        case .duplicateName(let name):
            "A scene named \(name) already exists. Confirm replacement to update it."
        case .operationInProgress:
            "Another scene operation is still running."
        case .mutationsBlocked:
            "Finish the active action before changing a scene."
        case .stopped:
            "Scenes is stopped. Open the module before changing a scene."
        case .presentationReserved:
            "End Presentation before changing a scene."
        case .invalidPresentationToken:
            "This Presentation session no longer owns scene controls."
        case .presentationTransactionMismatch:
            "The restore point does not belong to this Presentation session."
        }
    }
}

@Observable
@MainActor
final class SceneManager: SceneCommandHandling {
    private(set) var scenes: [SemperScene]
    private(set) var isBusy = false
    private(set) var isSuspended = false
    private(set) var isShutDown = false
    private(set) var statusMessage: String?
    private(set) var hasPendingRestore = false
    var onScenesChanged: (() -> Void)?

    private let prepareDomains: @MainActor (Set<SceneControlDomain>) async throws -> Void
    private let captureCurrent: @MainActor () async throws -> [SceneAction]
    private let beginAudioTransaction: @MainActor () throws -> Void
    private let endAudioTransaction: @MainActor () -> Void
    private let libraryStore: any SceneLibraryStoring
    private let coordinator: SceneCoordinator
    private let mutationAdmission: MutationAdmissionGate
    private let libraryLoadFailure: String?
    @ObservationIgnored private var operationCompletion: Task<Void, Never>?
    @ObservationIgnored private var cancelOperation: (() -> Void)?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    private var presentationToken: UUID?
    private var presentationPermit: MutationAdmissionPermit?
    private var presentationTransactionID: UUID?
    private var presentationSceneID: UUID?

    private enum Access {
        case ordinary
        case presentation(UUID)
        case metadata
    }

    init(
        adapters: SceneAdapterRegistry,
        prepareDomains: @escaping @MainActor (Set<SceneControlDomain>) async throws -> Void,
        captureCurrent: @escaping @MainActor () async throws -> [SceneAction],
        beginAudioTransaction: @escaping @MainActor () throws -> Void,
        endAudioTransaction: @escaping @MainActor () -> Void,
        libraryStore: (any SceneLibraryStoring)? = nil,
        journalStore: (any SceneJournalStoring)? = nil,
        mutationAdmission: MutationAdmissionGate
    ) {
        let directory = SceneStorageLocation.defaultDirectory
        let store = libraryStore ?? FileSceneLibraryStore(directory: directory)
        var loaded: [SemperScene] = []
        var loadFailure: String?
        do {
            loaded = try store.loadScenes()
            try SceneLibraryValidation.validate(loaded)
        } catch {
            loaded = []
            loadFailure = error.localizedDescription
        }
        self.scenes = loaded
        self.libraryLoadFailure = loadFailure
        self.libraryStore = store
        self.prepareDomains = prepareDomains
        self.captureCurrent = captureCurrent
        self.beginAudioTransaction = beginAudioTransaction
        self.endAudioTransaction = endAudioTransaction
        self.mutationAdmission = mutationAdmission
        self.coordinator = SceneCoordinator(
            adapters: adapters, journalStore: journalStore ?? FileSceneJournalStore(directory: directory))
        if let loadFailure { statusMessage = SceneManagerError.libraryUnreadable(loadFailure).localizedDescription }
    }

    convenience init(
        engine: AudioEngine,
        commands: any AudioCommandDispatching,
        awake: AwakeService,
        displays: DisplayControlService,
        libraryStore: (any SceneLibraryStoring)? = nil,
        journalStore: (any SceneJournalStoring)? = nil,
        mutationAdmission: MutationAdmissionGate
    ) {
        self.init(
            adapters: SceneAdapterRegistry(
                audio: AudioSceneAdapter(engine: engine, commands: commands),
                display: DisplaySceneAdapter(displays: displays),
                power: PowerSceneAdapter(awake: awake)),
            prepareDomains: { domains in
                if domains.contains(.display) { await displays.probe() }
            },
            captureCurrent: {
                await displays.probe()
                let currentAwakeState: SceneAwakeState
                if let lease = awake.leaseState(for: .scene) {
                    currentAwakeState = lease.keepsDisplayAwake ? .displayAndSystem : .system
                } else {
                    currentAwakeState = .off
                }
                var actions = [
                    SceneAction(
                        control: .awakeMode,
                        target: .awake(currentAwakeState),
                        importance: .required
                    )
                ]

                if let deviceID = engine.deviceVolumeMonitor.defaultDeviceUID,
                    let device = engine.deviceMonitor.device(for: deviceID)
                {
                    actions.append(
                        SceneAction(
                            control: .audioOutputDevice,
                            target: .text(deviceID),
                            importance: .required
                        ))
                    if let volume = engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id) {
                        actions.append(
                            SceneAction(
                                control: .audioOutputVolume(deviceID: deviceID),
                                target: .number(Double(volume)),
                                importance: .required
                            ))
                    }
                    if engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id) != .ddc,
                        let muted = engine.deviceVolumeMonitor.muteStates[device.id]
                    {
                        actions.append(
                            SceneAction(
                                control: .audioOutputMuted(deviceID: deviceID),
                                target: .boolean(muted),
                                importance: .required
                            ))
                    }
                }

                for display in displays.displays {
                    for feature in DisplayFeature.allCases where display.sceneEligibleFeatures.contains(feature) {
                        guard let reading = display.features[feature] else { continue }
                        let control: SceneControl =
                            switch feature {
                            case .brightness: .displayBrightness(displayID: display.id.rawValue)
                            case .contrast: .displayContrast(displayID: display.id.rawValue)
                            }
                        actions.append(
                            SceneAction(
                                control: control,
                                target: .number(reading.normalized),
                                importance: .optional
                            ))
                    }
                }
                return actions
            },
            beginAudioTransaction: {
                guard commands.beginSceneTransaction() else { throw SceneApplyError.operationInProgress }
            },
            endAudioTransaction: { commands.endSceneTransaction() },
            libraryStore: libraryStore, journalStore: journalStore, mutationAdmission: mutationAdmission)
    }

    func resume() throws {
        try Task.checkCancellation()
        guard !isShutDown else { throw SceneManagerError.stopped }
        guard drainTask == nil, !isBusy else { throw SceneManagerError.operationInProgress }
        isSuspended = false
    }

    func cancelAndDrain() async {
        isSuspended = true
        if let drainTask {
            await drainTask.value
            return
        }
        cancelOperation?()
        let completion = operationCompletion
        let task = Task { if let completion { await completion.value } }
        drainTask = task
        await task.value
        drainTask = nil
    }

    func shutdown() async {
        isShutDown = true
        onScenesChanged = nil
        await cancelAndDrain()
    }

    func prepare() async {
        do {
            _ = try await runOperation(access: .metadata, recovery: true) { try await self.readPending() }
        } catch {
            if !isShutDown { statusMessage = error.localizedDescription }
        }
    }

    func pendingDomains() async throws -> Set<SceneControlDomain> {
        try await runOperation(access: .metadata, recovery: true) {
            Set(try await self.readPending()?.entries.filter { $0.phase.needsRestore }.map { $0.control.domain } ?? [])
        }
    }

    func availableScenes() -> [SceneCommandDescriptor] {
        scenes.map { SceneCommandDescriptor(id: $0.id, name: $0.name) }
    }

    func apply(scene: SemperScene) {
        launchOperation {
            guard let saved = self.scenes.first(where: { $0.id == scene.id }) else {
                throw SceneManagerError.sceneNotFound(scene.id)
            }
            _ = try await self.applyOrdinary(saved)
        }
    }

    func restore() {
        launchOperation { _ = try await self.restoreOrdinary() }
    }

    func keepCurrentSetup() {
        launchOperation {
            let permit = try self.scenePermit()
            defer { self.mutationAdmission.release(permit) }
            try Task.checkCancellation()
            try await self.coordinator.abandonPendingTransaction()
            self.hasPendingRestore = false
            self.statusMessage = "Kept the current setup and removed its restore point."
        }
    }

    func saveCurrent(named rawName: String, replacingExisting: Bool = false, completion: ((Bool) -> Void)? = nil) {
        launchOperation(completion: completion) {
            let permit = try self.scenePermit()
            defer { self.mutationAdmission.release(permit) }
            if let failure = self.libraryLoadFailure { throw SceneManagerError.libraryUnreadable(failure) }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw SceneManagerError.emptyName }
            let existing = self.scenes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if existing != nil, !replacingExisting { throw SceneManagerError.duplicateName(name) }
            let actions = try await self.captureCurrent()
            try Task.checkCancellation()
            guard !actions.isEmpty else { throw SceneManagerError.noCurrentControls }
            let scene = SemperScene(
                id: existing?.id ?? UUID(), name: name, actions: actions, shortcut: existing?.shortcut)
            try scene.validate()
            let updated = existing == nil ? self.scenes + [scene] : self.scenes.map { $0.id == scene.id ? scene : $0 }
            try self.libraryStore.saveScenes(updated)
            self.scenes = updated
            self.onScenesChanged?()
            self.statusMessage = "Saved \(scene.name)."
        }
    }

    func delete(scene: SemperScene) {
        do {
            try checkAdmission(access: .ordinary)
            let permit = try scenePermit()
            defer { mutationAdmission.release(permit) }
            if let failure = libraryLoadFailure { throw SceneManagerError.libraryUnreadable(failure) }
            let updated = scenes.filter { $0.id != scene.id }
            try libraryStore.saveScenes(updated)
            scenes = updated
            onScenesChanged?()
            statusMessage = "Deleted \(scene.name)."
        } catch { reportSceneCommandFailure(error.localizedDescription) }
    }

    func setShortcut(_ shortcut: SceneShortcut?, for sceneID: UUID) throws {
        try checkAdmission(access: .ordinary)
        let permit = try scenePermit()
        defer { mutationAdmission.release(permit) }
        if let failure = libraryLoadFailure { throw SceneManagerError.libraryUnreadable(failure) }
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagerError.sceneNotFound(sceneID)
        }
        var updated = scenes
        updated[index].shortcut = shortcut
        try libraryStore.saveScenes(updated)
        scenes = updated
        onScenesChanged?()
    }

    func applyScene(id: UUID) async throws -> SceneCommandExecution {
        try await runOperation {
            guard let scene = self.scenes.first(where: { $0.id == id }) else {
                throw SceneManagerError.sceneNotFound(id)
            }
            return try await self.applyOrdinary(scene)
        }
    }

    func restoreScene() async throws -> SceneCommandExecution {
        try await runOperation { try await self.restoreOrdinary() }
    }

    func recoverPendingScene(keepingCurrent: Bool) async throws -> SceneCommandExecution {
        try await runOperation(access: .metadata, recovery: true) {
            guard self.presentationToken == nil else { throw SceneManagerError.presentationReserved }
            if !keepingCurrent { return try await self.restoreOrdinary() }
            let permit = try self.scenePermit()
            defer { self.mutationAdmission.release(permit) }
            guard let pending = try await self.readPending() else { throw SceneManagerError.restoreUnavailable }
            try Task.checkCancellation()
            try await self.coordinator.abandonPendingTransaction(expectedTransactionID: pending.id)
            self.hasPendingRestore = false
            let message = "Kept the current setup and removed its restore point."
            self.statusMessage = message
            return SceneCommandExecution(message: message)
        }
    }

    func reservePresentation() async throws -> UUID {
        try await runOperation(access: .metadata) {
            guard self.presentationToken == nil else { throw SceneManagerError.presentationReserved }
            let permit = try self.mutationAdmission.acquire(owner: .presentation, mode: .shared)
            var reserved = false
            defer { if !reserved { self.mutationAdmission.release(permit) } }
            try await self.requireNoPending()
            try Task.checkCancellation()
            let token = UUID()
            self.presentationToken = token
            self.presentationPermit = permit
            self.presentationTransactionID = nil
            self.presentationSceneID = nil
            reserved = true
            return token
        }
    }

    func releasePresentation(_ token: UUID) async throws {
        try await runOperation(access: .presentation(token), recovery: true) {
            if let pending = try await self.readPending(), !pending.isFullySettled {
                throw SceneApplyError.transactionAlreadyActive(transactionID: pending.id)
            }
            try Task.checkCancellation()
            if let permit = self.presentationPermit { self.mutationAdmission.release(permit) }
            self.presentationPermit = nil
            self.presentationToken = nil
            self.presentationTransactionID = nil
            self.presentationSceneID = nil
        }
    }

    func previewPresentation(_ scene: SemperScene, token: UUID) async throws -> ScenePreviewReport {
        try await runOperation(access: .presentation(token)) {
            try await self.requireNoPending()
            try scene.validate()
            try await self.prepareDomains(Set(scene.actions.map { $0.control.domain }))
            try Task.checkCancellation()
            return try await self.coordinator.preview(scene)
        }
    }

    func applyPresentation(
        _ scene: SemperScene, token: UUID, expectedPreview: ScenePreviewReport? = nil
    ) async throws -> SceneApplyReport {
        try await runOperation(access: .presentation(token)) {
            let permit = try self.scenePermit()
            defer { self.mutationAdmission.release(permit) }
            try await self.requireNoPending()
            self.presentationSceneID = scene.id
            self.presentationTransactionID = nil
            do {
                let report = try await self.applyReport(scene, expectedPreview: expectedPreview)
                self.presentationTransactionID = report.transactionID
                self.presentationSceneID = nil
                return report
            } catch {
                do {
                    if try await self.ownedPresentationTransaction() == nil { self.presentationSceneID = nil }
                } catch {
                    self.hasPendingRestore = true
                }
                throw error
            }
        }
    }

    func pendingPresentationTransaction(token: UUID) async throws -> SceneTransaction? {
        try await runOperation(access: .presentation(token), recovery: true) {
            try await self.ownedPresentationTransaction()
        }
    }

    func restorePresentation(transactionID: UUID, token: UUID) async throws -> SceneRestoreReport? {
        try await runOperation(access: .presentation(token), recovery: true) {
            let permit = try self.scenePermit()
            defer { self.mutationAdmission.release(permit) }
            guard let pending = try await self.ownedPresentationTransaction(), pending.id == transactionID else {
                throw SceneManagerError.presentationTransactionMismatch
            }
            return try await self.restoreReport(pending)
        }
    }

    func keepCurrentPresentation(transactionID: UUID, token: UUID) async throws {
        try await runOperation(access: .presentation(token), recovery: true) {
            guard let pending = try await self.ownedPresentationTransaction(), pending.id == transactionID else {
                throw SceneManagerError.presentationTransactionMismatch
            }
            try Task.checkCancellation()
            try await self.coordinator.abandonPendingTransaction(expectedTransactionID: transactionID)
            self.presentationTransactionID = nil
            self.presentationSceneID = nil
            self.hasPendingRestore = false
        }
    }

    private func applyOrdinary(_ scene: SemperScene) async throws -> SceneCommandExecution {
        let permit = try scenePermit()
        defer { mutationAdmission.release(permit) }
        try await requireNoPending()
        let report = try await applyReport(scene)
        let message: String
        if report.applied.isEmpty {
            message = "\(scene.name) had no available controls to change."
        } else if report.skippedOptional.isEmpty {
            message = "Applied \(scene.name)."
        } else {
            message = "Applied \(scene.name), skipped \(report.skippedOptional.count) unavailable controls."
        }
        statusMessage = message
        return SceneCommandExecution(message: message)
    }

    private func applyReport(_ scene: SemperScene, expectedPreview: ScenePreviewReport? = nil) async throws
        -> SceneApplyReport
    {
        try scene.validate()
        let domains = Set(scene.actions.map { $0.control.domain })
        try await prepareDomains(domains)
        try Task.checkCancellation()
        let audio = domains.contains(.audio)
        if audio { try beginAudioTransaction() }
        defer { if audio { endAudioTransaction() } }
        do {
            let report = try await coordinator.apply(scene, expectedPreview: expectedPreview)
            hasPendingRestore = report.transactionID != nil
            return report
        } catch {
            await refreshPendingState()
            throw error
        }
    }

    private func restoreOrdinary() async throws -> SceneCommandExecution {
        let permit = try scenePermit()
        defer { mutationAdmission.release(permit) }
        guard let pending = try await readPending() else { throw SceneManagerError.restoreUnavailable }
        guard let report = try await restoreReport(pending) else {
            throw SceneManagerError.restoreUnavailable
        }
        let restored = report.outcomes.reduce(into: 0) { if case .restored = $1 { $0 += 1 } }
        let skipped = report.outcomes.count - restored
        let message =
            skipped == 0
            ? "Restored \(restored) controls." : "Restored \(restored) controls, left \(skipped) unchanged."
        statusMessage = message
        return SceneCommandExecution(message: message)
    }

    private func restoreReport(_ pending: SceneTransaction) async throws
        -> SceneRestoreReport?
    {
        let domains = Set(pending.entries.filter { $0.phase.needsRestore }.map { $0.control.domain })
        try await prepareDomains(domains)
        try Task.checkCancellation()
        let audio = domains.contains(.audio)
        if audio { try beginAudioTransaction() }
        defer { if audio { endAudioTransaction() } }
        do {
            let report = try await coordinator.restore(expectedTransactionID: pending.id)
            hasPendingRestore = report.map { !$0.journalCleared } ?? false
            if report?.journalCleared == true {
                presentationTransactionID = nil
                presentationSceneID = nil
            }
            return report
        } catch {
            await refreshPendingState()
            throw error
        }
    }

    private func requireNoPending() async throws {
        if let pending = try await readPending(), !pending.isFullySettled {
            throw SceneApplyError.transactionAlreadyActive(transactionID: pending.id)
        }
        try Task.checkCancellation()
    }

    private func ownedPresentationTransaction() async throws -> SceneTransaction? {
        guard let pending = try await readPending() else { return nil }
        if let owned = presentationTransactionID {
            guard pending.id == owned else { throw SceneManagerError.presentationTransactionMismatch }
        } else {
            if presentationSceneID == nil, pending.isFullySettled { return nil }
            guard presentationSceneID == pending.sceneID else {
                throw SceneManagerError.presentationTransactionMismatch
            }
            presentationTransactionID = pending.id
        }
        return pending
    }

    private func readPending() async throws -> SceneTransaction? {
        do {
            let pending = try await coordinator.pendingTransaction()
            hasPendingRestore = pending.map { !$0.isFullySettled } ?? false
            return pending
        } catch {
            hasPendingRestore = true
            throw error
        }
    }

    private func refreshPendingState() async {
        do { _ = try await readPending() } catch { statusMessage = "The scene recovery record could not be read." }
    }

    private func scenePermit() throws -> MutationAdmissionPermit {
        do { return try mutationAdmission.acquire(owner: .scene, mode: .shared) } catch {
            throw SceneManagerError.mutationsBlocked
        }
    }

    private func checkAdmission(access: Access, recovery: Bool = false) throws {
        try Task.checkCancellation()
        guard recovery || !isShutDown else { throw SceneManagerError.stopped }
        guard !isBusy, drainTask == nil else { throw SceneManagerError.operationInProgress }
        switch access {
        case .ordinary:
            guard !isSuspended else { throw SceneManagerError.stopped }
            guard presentationToken == nil else { throw SceneManagerError.presentationReserved }
        case .presentation(let token):
            guard presentationToken == token else { throw SceneManagerError.invalidPresentationToken }
        case .metadata: break
        }
    }

    private func beginOperation<Value: Sendable>(
        access: Access = .ordinary, recovery: Bool = false,
        _ operation: @escaping @MainActor () async throws -> Value
    ) throws -> Task<Value, Error> {
        try checkAdmission(access: access, recovery: recovery)
        isBusy = true
        let task = Task { @MainActor in
            defer {
                self.isBusy = false
                self.cancelOperation = nil
                self.operationCompletion = nil
            }
            try Task.checkCancellation()
            return try await operation()
        }
        cancelOperation = { task.cancel() }
        operationCompletion = Task { _ = await task.result }
        return task
    }

    private func runOperation<Value: Sendable>(
        access: Access = .ordinary, recovery: Bool = false,
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let task = try beginOperation(access: access, recovery: recovery, operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func launchOperation(
        completion: ((Bool) -> Void)? = nil, _ operation: @escaping @MainActor () async throws -> Void
    ) {
        do {
            _ = try beginOperation {
                do {
                    try await operation()
                    if !self.isShutDown { completion?(true) }
                } catch {
                    self.reportSceneCommandFailure(error.localizedDescription)
                    if !self.isShutDown { completion?(false) }
                }
            }
        } catch {
            reportSceneCommandFailure(error.localizedDescription)
            if !isShutDown { completion?(false) }
        }
    }

    func reportSceneCommandFailure(_ message: String) {
        guard !isShutDown, !isSuspended else { return }
        statusMessage = message
    }
}
