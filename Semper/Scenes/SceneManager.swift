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
            "End Away Mode before changing a scene."
        }
    }
}

@Observable
@MainActor
final class SceneManager: SceneCommandHandling {
    private(set) var scenes: [SemperScene]
    private(set) var isBusy = false
    private(set) var statusMessage: String?
    private(set) var hasPendingRestore = false
    var onScenesChanged: (() -> Void)?

    private let engine: AudioEngine
    private let commands: any AudioCommandDispatching
    private let awake: AwakeService
    private let displays: DisplayControlService
    private let libraryStore: any SceneLibraryStoring
    private let coordinator: SceneCoordinator
    private let mutationAdmission: MutationAdmissionGate
    private var preparationTask: Task<Void, Never>?
    private let libraryLoadFailure: String?

    init(
        engine: AudioEngine,
        commands: any AudioCommandDispatching,
        awake: AwakeService,
        displays: DisplayControlService,
        libraryStore: (any SceneLibraryStoring)? = nil,
        journalStore: (any SceneJournalStoring)? = nil,
        mutationAdmission: MutationAdmissionGate
    ) {
        let directory = SceneStorageLocation.defaultDirectory
        let resolvedLibraryStore = libraryStore ?? FileSceneLibraryStore(directory: directory)
        var loadedScenes: [SemperScene] = []
        var libraryLoadFailure: String?
        do {
            loadedScenes = try resolvedLibraryStore.loadScenes()
            try SceneLibraryValidation.validate(loadedScenes)
            libraryLoadFailure = nil
        } catch {
            loadedScenes = []
            libraryLoadFailure = error.localizedDescription
        }
        self.engine = engine
        self.commands = commands
        self.awake = awake
        self.displays = displays
        self.libraryStore = resolvedLibraryStore
        self.mutationAdmission = mutationAdmission
        self.scenes = loadedScenes
        self.libraryLoadFailure = libraryLoadFailure
        self.coordinator = SceneCoordinator(
            adapters: SceneAdapterRegistry(
                audio: AudioSceneAdapter(engine: engine, commands: commands),
                display: DisplaySceneAdapter(displays: displays),
                power: PowerSceneAdapter(awake: awake)
            ),
            journalStore: journalStore ?? FileSceneJournalStore(directory: directory)
        )
        if let libraryLoadFailure {
            self.statusMessage = "Saved scenes could not be read: \(libraryLoadFailure)"
        }

    }

    func prepare() async {
        if let preparationTask {
            await preparationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshPendingState()
        }
        preparationTask = task
        await task.value
    }

    func apply(scene: SemperScene) {
        guard !isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await applyScene(id: scene.id)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func restore() {
        guard !isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await restoreScene()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func keepCurrentSetup() {
        guard !isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self, !isBusy else { return }
            guard let permit = acquireSceneMutationPermit() else { return }
            defer { mutationAdmission.release(permit) }
            isBusy = true
            defer { isBusy = false }

            do {
                try await coordinator.abandonPendingTransaction()
                hasPendingRestore = false
                statusMessage = "Kept the current setup and removed its restore point."
            } catch {
                await refreshPendingState()
                statusMessage = "The restore point could not be removed: \(error.localizedDescription)"
            }
        }
    }

    func saveCurrent(
        named rawName: String,
        replacingExisting: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isBusy = false }

            let previousScenes = scenes
            do {
                if let libraryLoadFailure {
                    throw SceneManagerError.libraryUnreadable(libraryLoadFailure)
                }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw SceneManagerError.emptyName }
                let existing = scenes.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                })
                if existing != nil, !replacingExisting {
                    throw SceneManagerError.duplicateName(name)
                }
                await displays.probe()
                let actions = currentActions()
                guard !actions.isEmpty else { throw SceneManagerError.noCurrentControls }

                let scene: SemperScene
                if let existing {
                    let currentShortcut = scenes.first(where: { $0.id == existing.id })?.shortcut
                    scene = SemperScene(
                        id: existing.id,
                        name: name,
                        actions: actions,
                        shortcut: currentShortcut
                    )
                    scenes = scenes.map { $0.id == existing.id ? scene : $0 }
                } else {
                    scene = SemperScene(name: name, actions: actions)
                    scenes.append(scene)
                }
                try scene.validate()
                try persistScenes()
                onScenesChanged?()
                statusMessage = "Saved \(scene.name)."
                completion?(true)
            } catch {
                scenes = previousScenes
                statusMessage = error.localizedDescription
                completion?(false)
            }
        }
    }

    func delete(scene: SemperScene) {
        guard !isBusy else { return }
        if let libraryLoadFailure {
            statusMessage = SceneManagerError.libraryUnreadable(libraryLoadFailure).localizedDescription
            return
        }
        let previous = scenes
        scenes.removeAll { $0.id == scene.id }
        do {
            try persistScenes()
            onScenesChanged?()
            statusMessage = "Deleted \(scene.name)."
        } catch {
            scenes = previous
            statusMessage = error.localizedDescription
        }
    }

    func availableScenes() -> [SceneCommandDescriptor] {
        scenes.map { SceneCommandDescriptor(id: $0.id, name: $0.name) }
    }

    func setShortcut(_ shortcut: SceneShortcut?, for sceneID: UUID) throws {
        guard !isBusy else { throw SceneManagerError.operationInProgress }
        if let libraryLoadFailure {
            throw SceneManagerError.libraryUnreadable(libraryLoadFailure)
        }
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else {
            throw SceneManagerError.sceneNotFound(sceneID)
        }
        let previous = scenes[index].shortcut
        scenes[index].shortcut = shortcut
        do {
            try persistScenes()
            onScenesChanged?()
        } catch {
            scenes[index].shortcut = previous
            throw error
        }
    }

    func applyScene(id: UUID) async throws -> SceneCommandExecution {
        guard !isBusy else { throw SceneApplyError.operationInProgress }
        guard let scene = scenes.first(where: { $0.id == id }) else {
            throw SceneManagerError.sceneNotFound(id)
        }
        guard let permit = acquireSceneMutationPermit() else {
            throw SceneManagerError.mutationsBlocked
        }
        defer { mutationAdmission.release(permit) }

        isBusy = true
        defer { isBusy = false }
        await prepare()
        if scene.actions.contains(where: { $0.control.domain == .display }) {
            await displays.probe()
        }

        do {
            if let pending = try await coordinator.pendingTransaction(),
               !pending.isFullySettled {
                throw SceneApplyError.transactionAlreadyActive(transactionID: pending.id)
            }
            guard commands.beginSceneTransaction() else {
                throw SceneApplyError.operationInProgress
            }
            defer { commands.endSceneTransaction() }
            let report = try await coordinator.apply(scene)
            hasPendingRestore = report.transactionID != nil

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
        } catch {
            await refreshPendingState()
            throw error
        }
    }

    func restoreScene() async throws -> SceneCommandExecution {
        guard !isBusy else { throw SceneRestoreError.operationInProgress }
        guard let permit = acquireSceneMutationPermit() else {
            throw SceneManagerError.mutationsBlocked
        }
        defer { mutationAdmission.release(permit) }
        isBusy = true
        defer { isBusy = false }
        await prepare()
        await displays.probe()

        do {
            guard commands.beginSceneTransaction() else {
                throw SceneRestoreError.operationInProgress
            }
            defer { commands.endSceneTransaction() }
            guard let report = try await coordinator.restore() else {
                hasPendingRestore = false
                throw SceneManagerError.restoreUnavailable
            }
            hasPendingRestore = !report.journalCleared
            let restoredCount = report.outcomes.reduce(into: 0) { count, outcome in
                if case .restored = outcome { count += 1 }
            }
            let skippedCount = report.outcomes.count - restoredCount
            let message = skippedCount == 0
                ? "Restored \(restoredCount) controls."
                : "Restored \(restoredCount) controls, left \(skippedCount) unchanged."
            statusMessage = message
            return SceneCommandExecution(message: message)
        } catch {
            await refreshPendingState()
            throw error
        }
    }

    private func currentActions() -> [SceneAction] {
        var actions = [
            SceneAction(
                control: .awakeMode,
                target: .awake(currentAwakeState),
                importance: .required
            )
        ]

        if let deviceID = engine.deviceVolumeMonitor.defaultDeviceUID,
           let device = engine.deviceMonitor.device(for: deviceID) {
            actions.append(SceneAction(
                control: .audioOutputDevice,
                target: .text(deviceID),
                importance: .required
            ))
            if let volume = engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id) {
                actions.append(SceneAction(
                    control: .audioOutputVolume(deviceID: deviceID),
                    target: .number(Double(volume)),
                    importance: .required
                ))
            }
            if engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id) != .ddc,
               let muted = engine.deviceVolumeMonitor.muteStates[device.id] {
                actions.append(SceneAction(
                    control: .audioOutputMuted(deviceID: deviceID),
                    target: .boolean(muted),
                    importance: .required
                ))
            }
        }

        for display in displays.displays {
            for feature in DisplayFeature.allCases where display.sceneEligibleFeatures.contains(feature) {
                guard let reading = display.features[feature] else { continue }
                let control: SceneControl = switch feature {
                case .brightness: .displayBrightness(displayID: display.id.rawValue)
                case .contrast: .displayContrast(displayID: display.id.rawValue)
                }
                actions.append(SceneAction(
                    control: control,
                    target: .number(reading.normalized),
                    importance: .optional
                ))
            }
        }
        return actions
    }

    private var currentAwakeState: SceneAwakeState {
        guard let lease = awake.leaseState(for: .scene) else { return .off }
        return lease.keepsDisplayAwake ? .displayAndSystem : .system
    }

    private func persistScenes() throws {
        try libraryStore.saveScenes(scenes)
    }

    func reportSceneCommandFailure(_ message: String) {
        statusMessage = message
    }

    private func acquireSceneMutationPermit() -> MutationAdmissionPermit? {
        do {
            return try mutationAdmission.acquire(owner: .scene, mode: .shared)
        } catch {
            statusMessage = SceneManagerError.mutationsBlocked.localizedDescription
            return nil
        }
    }

    private func refreshPendingState() async {
        do {
            hasPendingRestore = try await coordinator.pendingTransaction().map {
                !$0.isFullySettled
            } ?? false
        } catch {
            hasPendingRestore = true
            statusMessage = "The scene recovery record could not be read."
        }
    }
}
