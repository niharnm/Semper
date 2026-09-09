import AppKit
import Foundation
import KeyboardShortcuts
import Observation

enum UtilityDestination: Hashable {
    case home, modules
    case module(UtilityModuleID)
}

@Observable
@MainActor
final class UtilityRuntime {
    let settings: SettingsManager
    let registry: ModuleRegistry
    let lifecycle: UtilityLifecycle
    let commands: UtilityCommandCenter
    let updateManager: UpdateManager
    let experiments: ExperimentManager
    let mutationAdmission: MutationAdmissionGate
    private(set) var sound: SoundRuntime?
    private(set) var awake: AwakeService?
    private(set) var workspace: WorkspaceService?
    private(set) var shelf: ShelfService?
    private(set) var storage: SafeEjectService?
    private(set) var scenes: SceneManager?
    private(set) var displays: DisplayControlService?
    private(set) var sceneShortcuts: SceneShortcutRegistry?
    private(set) var presentation: PresentationController?
    var destination: UtilityDestination = .home
    var searchText = ""
    private(set) var searchFocusRequest = UUID()
    var onOpenDetail: (() -> Void)?
    var message: String?
    @ObservationIgnored private let soundFactory:
        @MainActor (SettingsManager, AudioEngine.SharedDDCController?) throws -> SoundRuntime
    @ObservationIgnored private let awakeFactory: @MainActor () throws -> AwakeService
    @ObservationIgnored private let workspaceFactory: @MainActor () throws -> WorkspaceService
    @ObservationIgnored private let shelfFactory: @MainActor () throws -> ShelfService
    @ObservationIgnored private let storageFactory: @MainActor () throws -> SafeEjectService
    @ObservationIgnored private let sceneLibraryStore: (any SceneLibraryStoring)?
    @ObservationIgnored private let sceneJournalStore: (any SceneJournalStoring)?
    @ObservationIgnored private var audioSceneAdapter: AudioSceneAdapter?
    @ObservationIgnored private var displaySceneAdapter: DisplaySceneAdapter?
    @ObservationIgnored private var powerSceneAdapter: PowerSceneAdapter?
    @ObservationIgnored private var sceneAudioCommands: (any AudioCommandDispatching)?
    @ObservationIgnored private var presentationWakeObserver: NSObjectProtocol?
    @ObservationIgnored private lazy var statusObserver = ModuleStatusObserver(registry: registry) {
        [weak self] _, error in
        self?.message = error.localizedDescription
    }
    @ObservationIgnored private var shutdownRequested = false
    @ObservationIgnored private var stoppingModules: Set<UtilityModuleID> = []
    @ObservationIgnored private var shortcutsStarted = false
    @ObservationIgnored private let shellIcon: MenuBarIconCoordinator
    #if !APP_STORE
        private let ddc: DDCController
        @ObservationIgnored private var ddcUsers: Set<UtilityModuleID> = []
    #endif

    static let searchShortcut = KeyboardShortcuts.Name(
        "search-semper-actions", default: .init(.k, modifiers: [.command, .option]))

    var usableSound: SoundRuntime? {
        guard let sound, !sound.isShutDown,
            !lifecycle.isShuttingDown, !lifecycle.stopping.contains(.sound),
            registry.state(for: .sound)?.presence == .added,
            !registry.pausedModuleIDs.contains(.sound)
        else { return nil }
        switch registry.state(for: .sound)?.runtime {
        case .ready, .active, .limited: return sound
        default: return nil
        }
    }

    var mutationDisabledReason: String? {
        mutationAdmission.activeExclusiveOwner == nil ? nil : "End Away before changing other utilities."
    }

    func installIntentActivation() {
        guard !shutdownRequested else { return }
        SemperAppIntentRuntime.installActivation(owner: self) { [weak self] in
            guard let self else { throw AppShortcutExecutionError.unavailable }
            try await self.start(.sound)
            guard self.usableSound != nil else { throw AppShortcutExecutionError.unavailable }
        }
        SemperSceneAppIntentRuntime.installActivation(owner: self) { [weak self] in
            guard let self else { throw SceneCommandRuntimeError.unavailable }
            try await self.start(.scenes)
        }
    }

    init(
        settings: SettingsManager = SettingsManager(managesLaunchAtLogin: true),
        defaults: UserDefaults = .standard,
        updateManager: UpdateManager? = nil,
        soundFactory: @escaping @MainActor (SettingsManager, AudioEngine.SharedDDCController?) throws -> SoundRuntime =
            {
                SoundRuntime(settings: $0, sharedDDCController: $1)
            },
        awakeFactory: (@MainActor () throws -> AwakeService)? = nil,
        workspaceFactory: @escaping @MainActor () throws -> WorkspaceService = { WorkspaceService() },
        shelfFactory: @escaping @MainActor () throws -> ShelfService = { ShelfService() },
        storageFactory: @escaping @MainActor () throws -> SafeEjectService = { SafeEjectService() },
        sceneLibraryStore: (any SceneLibraryStoring)? = nil,
        sceneJournalStore: (any SceneJournalStoring)? = nil
    ) throws {
        self.settings = settings
        self.soundFactory = soundFactory
        self.workspaceFactory = workspaceFactory
        self.shelfFactory = shelfFactory
        self.storageFactory = storageFactory
        self.sceneLibraryStore = sceneLibraryStore
        self.sceneJournalStore = sceneJournalStore
        let admission = MutationAdmissionGate()
        mutationAdmission = admission
        self.awakeFactory = awakeFactory ?? {
            AwakeService(
                backend: IOPMPowerAssertionBackend(),
                manualMutationAllowed: { admission.activeExclusiveOwner == nil })
        }
        registry = try ModuleRegistry(defaults: defaults, modules: UtilityModuleDescriptor.integratedCatalog)
        let lifecycle = UtilityLifecycle(registry: registry)
        self.lifecycle = lifecycle
        commands = UtilityCommandCenter(registry: registry, moduleAdmissionReason: { module in
            if lifecycle.isShuttingDown { return "Semper is shutting down. Finish any pending recovery before quitting." }
            return module == .away || admission.activeExclusiveOwner == nil
                ? nil : "End Away before changing other utilities."
        })
        self.updateManager = updateManager ?? UpdateManager(bundle: .main, userDefaults: defaults)
        experiments = ExperimentManager(defaults: defaults)
        shellIcon = MenuBarIconCoordinator(settings: settings)
        #if !APP_STORE
            ddc = DDCController(settingsManager: settings)
        #endif
        try installServices()
        try installActions()
        registry.finishActionRegistration()
    }

    func startShellShortcuts() {
        guard !shutdownRequested, !shortcutsStarted else { return }
        shortcutsStarted = true
        if sound == nil { shellIcon.start() }
        KeyboardShortcuts.onKeyDown(for: Self.searchShortcut) { [weak self] in
            guard let self else { return }
            self.requestSearchFocus()
            self.onOpenDetail?()
        }
    }

    func requestSearchFocus() {
        destination = .home
        searchFocusRequest = UUID()
    }

    func resetSoundSettings() {
        guard mutationDisabledReason == nil else {
            message = mutationDisabledReason
            return
        }
        if let sound {
            sound.callMode.shutdown()
            sound.bluetoothHDGuard.shutdown()
            sound.audioEngine.handleSettingsReset()
            sound.deviceVolumeMonitor.setSystemFollowDefault()
        } else {
            settings.resetAllSettings()
        }
    }

    func start(_ module: UtilityModuleID) async throws {
        guard !shutdownRequested else { throw UtilityLifecycleError.shuttingDown }
        guard !stoppingModules.contains(module) else { throw ModuleRegistryError.transitionInProgress(module) }
        let permit = try acquireUtilityPermit(module)
        defer { if let permit { mutationAdmission.release(permit) } }
        try await lifecycle.start(module)
        try Task.checkCancellation()
        guard !shutdownRequested, !stoppingModules.contains(module) else { throw CancellationError() }
        observeStatus(for: module)
    }

    func ensureAwakeService() throws -> AwakeService {
        guard !shutdownRequested, !lifecycle.isShuttingDown else { throw UtilityLifecycleError.shuttingDown }
        if let awake { return awake }
        let service = try awakeFactory()
        awake = service
        return service
    }

    func ensureSceneManager() async throws -> SceneManager {
        guard !shutdownRequested, !lifecycle.isShuttingDown else { throw UtilityLifecycleError.shuttingDown }
        if let scenes { return scenes }
        let adapters = SceneAdapterRegistry(
            audio: LazySceneAdapter(domain: .audio) { [weak self] in
                guard let self, self.isModuleUsable(.sound, allowsRecovery: true) else { return nil }
                return self.audioSceneAdapter
            },
            display: LazySceneAdapter(domain: .display) { [weak self] in
                guard let self, self.isModuleUsable(.displays, allowsRecovery: true) else { return nil }
                return self.displaySceneAdapter
            },
            power: LazySceneAdapter(domain: .power) { [weak self] in
                guard let self, self.isModuleUsable(.awake, allowsRecovery: true) else { return nil }
                return self.powerSceneAdapter
            })
        let manager = SceneManager(
            adapters: adapters,
            prepareDomains: { [weak self] domains in
                guard let self else { throw CancellationError() }
                try await self.prepareSceneDomains(domains)
            },
            captureCurrent: { [weak self] in
                guard let self else { throw CancellationError() }
                return self.currentSceneActions()
            },
            beginAudioTransaction: { [weak self] in
                guard let self, self.isModuleUsable(.sound, allowsRecovery: true),
                    let sound = self.sound, !sound.isShutDown
                else { throw SceneCommandRuntimeError.unavailable }
                guard sound.audioCommands.beginSceneTransaction() else { throw SceneManagerError.operationInProgress }
                self.sceneAudioCommands = sound.audioCommands
            },
            endAudioTransaction: { [weak self] in
                self?.sceneAudioCommands?.endSceneTransaction()
                self?.sceneAudioCommands = nil
            },
            libraryStore: sceneLibraryStore, journalStore: sceneJournalStore, mutationAdmission: mutationAdmission)
        scenes = manager
        await manager.prepare()
        return manager
    }

    func open(_ module: UtilityModuleID) async throws {
        try await start(module)
        destination = .module(module)
        onOpenDetail?()
    }

    func shutdown() async {
        shutdownRequested = true
        statusObserver.stopAll()
        SemperAppIntentRuntime.uninstallActivation(owner: self)
        SemperSceneAppIntentRuntime.uninstallActivation(owner: self)
        if let scenes { SemperSceneAppIntentRuntime.uninstall(scenes) }
        sound?.stopUserEntryPoints()
        shellIcon.stop()
        if shortcutsStarted {
            KeyboardShortcuts.removeHandler(for: Self.searchShortcut)
            shortcutsStarted = false
        }
        let sceneShortcuts = self.sceneShortcuts
        self.sceneShortcuts = nil
        await sceneShortcuts?.shutdown()
        for module in registry.modules { await commands.cancelAndDrain(module: module.id) }
        await scenes?.cancelAndDrain()
        await lifecycle.shutdown()
        #if !APP_STORE
            if ddcUsers.isEmpty { await ddc.stopAndDrain() }
        #endif
        settings.flushSync()
    }

    func pause(_ module: UtilityModuleID) async throws {
        guard !shutdownRequested else { throw UtilityLifecycleError.shuttingDown }
        let permit = try acquireUtilityPermit(module)
        defer { if let permit { mutationAdmission.release(permit) } }
        try requirePresentationDependencyCanStop(module)
        try await requireSceneDependencyCanStop(module)
        guard stoppingModules.insert(module).inserted else {
            throw ModuleRegistryError.transitionInProgress(module)
        }
        statusObserver.stopObserving(module: module)
        defer {
            stoppingModules.remove(module)
            observeStatus(for: module)
        }
        await commands.cancelAndDrain(module: module)
        try await lifecycle.pause(module)
    }

    func remove(_ module: UtilityModuleID) async throws {
        guard !shutdownRequested else { throw UtilityLifecycleError.shuttingDown }
        let permit = try acquireUtilityPermit(module)
        defer { if let permit { mutationAdmission.release(permit) } }
        try requirePresentationDependencyCanStop(module)
        try await requireSceneDependencyCanStop(module)
        if module == .scenes { try await requireSceneRemovalCanFinish() }
        guard stoppingModules.insert(module).inserted else {
            throw ModuleRegistryError.transitionInProgress(module)
        }
        statusObserver.stopObserving(module: module)
        defer {
            stoppingModules.remove(module)
            observeStatus(for: module)
        }
        await commands.cancelAndDrain(module: module)
        try await lifecycle.remove(module)
        if destination == .module(module) { destination = .home }
    }

    func summary(for module: UtilityModuleID) -> String {
        switch module {
        case .sound:
            guard let sound else { return "Open Sound to start audio controls." }
            return "\(sound.audioEngine.apps.count) apps available"
        case .awake:
            guard let session = awake?.session else {
                if let awake, awake.effectiveLeaseCount > 0 { return "Awake for another utility" }
                return "No active Awake session"
            }
            if let end = session.endsAt { return "Awake until \(end.formatted(date: .omitted, time: .shortened))" }
            return "Awake until turned off"
        case .workspace:
            guard let workspace else { return "Open Workspace Restore to view saved arrangements." }
            let count = workspace.arrangements.count
            return "\(count) \(count == 1 ? "arrangement" : "arrangements"), "
                + (workspace.canUndo ? "undo available" : "no restore to undo")
        case .shelf:
            guard let shelf else { return "Open File Shelf to collect items." }
            return "\(shelf.items.count) \(shelf.items.count == 1 ? "item" : "items") on the shelf"
        case .storage:
            guard let storage else { return "Open Safe Eject to view external volumes." }
            let issues =
                storage.receipts.filter { !$0.outcome.isVerified }.count
                + (storage.inventoryFailure == nil ? 0 : 1)
            return "\(storage.volumes.count) \(storage.volumes.count == 1 ? "volume" : "volumes"), "
                + "\(issues) \(issues == 1 ? "issue" : "issues")"
        case .scenes:
            guard let scenes else { return "Open Scenes to view saved setups." }
            let count = scenes.scenes.count
            return "\(count) saved \(count == 1 ? "scene" : "scenes")"
                + (scenes.hasPendingRestore ? ", previous setup available" : "")
        case .displays:
            guard let displays else { return "Open Displays to check supported controls." }
            let count = displays.displays.count
            return "\(count) supported \(count == 1 ? "display" : "displays")"
        case .presentation:
            guard let presentation else { return "Open Presentation to prepare a timed session." }
            switch presentation.phase {
            case .idle: return "No active Presentation session"
            case .preparing: return "Preparing a preview"
            case .preview: return "Preview ready for review"
            case .starting: return "Starting Presentation"
            case .active:
                if let deadline = presentation.deadline {
                    return "Active until \(deadline.formatted(date: .omitted, time: .shortened))"
                }
                return "Presentation active"
            case .restoring: return "Restoring the previous setup"
            case .recoveryRequired: return "Recovery needs attention"
            }
        default:
            return registry.state(for: module)?.runtime.displayText ?? "Stopped"
        }
    }

    private func installServices() throws {
        try lifecycle.register(
            .sound,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    self.shellIcon.stop()
                    #if !APP_STORE
                        if self.ddcUsers.isEmpty { self.ddc.start() }
                        self.ddcUsers.insert(.sound)
                        self.sound = try self.soundFactory(self.settings, self.ddc)
                    #else
                        self.sound = try self.soundFactory(self.settings, nil)
                    #endif
                    if let sound = self.sound {
                        try sound.audioEngine.installMutationAdmission(self.mutationAdmission)
                        try sound.deviceVolumeMonitor.installMutationAdmission(self.mutationAdmission)
                        try sound.audioCommands.installMutationAdmission(self.mutationAdmission)
                        self.audioSceneAdapter = AudioSceneAdapter(
                            engine: sound.audioEngine, commands: sound.audioCommands)
                        sound.shortcutsRegistry.onShortcutsChanged = { [weak self] in self?.sceneShortcuts?.sync() }
                    }
                },
                stop: { [weak self] _ in
                    guard let self else { return }
                    try self.requirePresentationDependencyCanStop(.sound)
                    try await self.requireSceneDependencyCanStop(.sound)
                    let sound = self.sound
                    try await sound?.shutdownAndDrain()
                    #if !APP_STORE
                        if self.ddcUsers.isSubset(of: [.sound]) {
                            await self.ddc.stopAndDrain()
                        } else {
                            try await self.ddc.performSerialized { () }
                        }
                        self.ddcUsers.remove(.sound)
                    #endif
                    sound?.audioCommands.finishShutdownAfterBackendDrain()
                    self.sound = nil
                    self.audioSceneAdapter = nil
                    if self.shortcutsStarted, !self.lifecycle.isShuttingDown { self.shellIcon.start() }
                }))
        try lifecycle.register(
            .awake,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    _ = try self.ensureAwakeService()
                },
                stop: { [weak self] reason in
                    guard let self, let awake = self.awake else { return }
                    try self.requirePresentationDependencyCanStop(.awake)
                    try await self.requireSceneDependencyCanStop(.awake)
                    if awake.hasPendingAssertionCleanup, !awake.retryPendingAssertionCleanup() {
                        throw UtilityLifecycleError.unavailable(
                            "A power assertion could not be released. Retry stopping Awake.")
                    }
                    if reason == .termination {
                        awake.shutdown()
                    } else {
                        awake.stop()
                        if awake.effectiveLeaseCount == 0, !awake.hasPendingAssertionCleanup { awake.shutdown() }
                    }
                    if awake.failure == .couldNotRelease {
                        throw UtilityLifecycleError.unavailable(
                            "A power assertion could not be released. Retry stopping Awake.")
                    }
                    if reason == .termination || awake.effectiveLeaseCount == 0 {
                        self.awake = nil
                        self.powerSceneAdapter = nil
                    }
                }))
        try lifecycle.register(
            .workspace,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    if self.workspace == nil { self.workspace = try self.workspaceFactory() }
                    try self.workspace?.installMutationAdmission(self.mutationAdmission)
                    await self.workspace?.start()
                },
                stop: { [weak self] reason in
                    guard let self, let workspace = self.workspace else { return }
                    try self.requirePresentationDependencyCanStop(.workspace)
                    guard workspace.presentationReservation == nil else {
                        throw UtilityCleanupDeferral(
                            reason: "Workspace Restore is retained for Presentation recovery.", retaining: [.workspace])
                    }
                    if reason == .pause {
                        await workspace.pause()
                    } else {
                        await workspace.shutdown()
                        self.workspace = nil
                    }
                }))
        try lifecycle.register(
            .shelf,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    if self.shelf == nil { self.shelf = try self.shelfFactory() }
                    self.shelf?.start()
                },
                stop: { [weak self] reason in
                    guard let self, let shelf = self.shelf else { return }
                    if reason == .pause {
                        await shelf.pause()
                    } else {
                        await shelf.shutdown()
                        self.shelf = nil
                    }
                }))
        try lifecycle.register(
            .storage,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    if self.storage == nil { self.storage = try self.storageFactory() }
                    try self.storage?.installMutationAdmission(self.mutationAdmission)
                    self.storage?.start()
                    guard self.storage?.state == .running else {
                        throw UtilityLifecycleError.unavailable(
                            self.storage?.inventoryFailure?.message ?? SafeEjectFailure.unavailable.message)
                    }
                },
                stop: { [weak self] reason in
                    guard let self, let storage = self.storage else { return }
                    if reason == .pause { storage.pause() } else { storage.shutdown() }
                    if case .failure(let failure) = await storage.waitForCleanup() {
                        throw UtilityCleanupDeferral(reason: failure.message, retaining: [.storage])
                    }
                    if reason != .pause { self.storage = nil }
                }))
        try lifecycle.register(
            .scenes,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    let manager = try await self.ensureSceneManager()
                    try manager.resume()
                    let shortcuts = SceneShortcutRegistry(settings: self.settings, sceneManager: manager)
                    self.sceneShortcuts = shortcuts
                    manager.onScenesChanged = { [weak self] in self?.sceneShortcuts?.sync() }
                    shortcuts.start()
                    SemperSceneAppIntentRuntime.install(manager)
                },
                stop: { [weak self] reason in
                    guard let self, let scenes = self.scenes else { return }
                    try self.requirePresentationDependencyCanStop(.scenes)
                    SemperSceneAppIntentRuntime.uninstall(scenes)
                    await self.sceneShortcuts?.shutdown()
                    self.sceneShortcuts = nil
                    await scenes.cancelAndDrain()
                    if reason != .pause {
                        let dependencies = try await self.sceneRecoveryModules()
                        guard dependencies.isEmpty, !scenes.hasPendingRestore else {
                            throw UtilityCleanupDeferral(
                                reason: "Restore the pending scene or keep the current setup before removing Scenes.",
                                retaining: dependencies.union([.scenes]))
                        }
                        await scenes.shutdown()
                        self.scenes = nil
                    }
                }))
        try lifecycle.register(
            .presentation,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireModuleAdmission(.awake)
                    if self.presentation == nil {
                        self.presentation = PresentationController(dependencies: self.presentationDependencies())
                    }
                    if self.presentationWakeObserver == nil {
                        self.presentationWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                        ) { [weak self] _ in
                            MainActor.assumeIsolated {
                                guard let self, let presentation = self.presentation else { return }
                                Task { @MainActor in
                                    do { try await presentation.checkExpiry() }
                                    catch { self.message = error.localizedDescription }
                                }
                            }
                        }
                    }
                },
                stop: { [weak self] reason in
                    guard let self, let presentation = self.presentation else { return }
                    do {
                        if reason == .pause { try await presentation.stop() } else { try await presentation.shutdown() }
                    } catch {
                        throw UtilityCleanupDeferral(
                            reason: error.localizedDescription, retaining: presentation.retainedModules)
                    }
                    if let observer = self.presentationWakeObserver {
                        NSWorkspace.shared.notificationCenter.removeObserver(observer)
                        self.presentationWakeObserver = nil
                    }
                    if reason != .pause { self.presentation = nil }
                }))
    }

    private func installActions() throws {
        var actions: [UtilityActionHandler] = []
        for module in registry.modules
        where [.sound, .awake, .workspace, .scenes, .displays, .presentation].contains(module.id) {
            actions.append(
                UtilityActionHandler(
                    descriptor: .init(
                        id: .init(rawValue: "\(module.id.rawValue).open"), module: module.id,
                        title: "Open \(module.title)", keywords: [module.title], symbolName: module.symbolName),
                    disabledReason: { nil },
                    perform: { [weak self] in try await self?.open(module.id) }
                ))
        }
        actions.append(
            UtilityActionHandler(
                descriptor: .init(
                    id: .init(rawValue: "awake.start"), module: .awake, title: "Stay awake for 30 minutes",
                    keywords: ["timer", "sleep"], symbolName: "sun.max"),
                disabledReason: { nil },
                perform: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.start(.awake)
                    self.awake?.start(.thirtyMinutes)
                    guard self.awake?.isActive == true else {
                        throw UtilityLifecycleError.unavailable(
                            "Awake could not start. Open Awake to inspect the failure.")
                    }
                }
            ))
        actions.append(
            UtilityActionHandler(
                descriptor: .init(
                    id: .init(rawValue: "awake.stop"), module: .awake, title: "Stop Awake",
                    keywords: ["sleep", "timer"], symbolName: "stop.circle"),
                disabledReason: { [weak self] in
                    self?.awake?.isActive == true ? nil : "No manual Awake session is active."
                },
                perform: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.start(.awake)
                    self.awake?.stop()
                    if self.awake?.failure == .couldNotRelease {
                        throw UtilityLifecycleError.unavailable("A power assertion could not be released.")
                    }
                }
            ))
        for command in WorkspaceCommand.allCases {
            actions.append(
                UtilityActionHandler(
                    descriptor: .init(
                        id: .init(rawValue: command.rawValue), module: .workspace, title: command.title,
                        keywords: ["workspace", "windows", "arrangement"], symbolName: WorkspaceModuleMetadata.symbol),
                    disabledReason: { [weak self] in
                        guard command == .undo else { return nil }
                        guard let workspace = self?.workspace, !workspace.undoEntries.isEmpty else {
                            return "No workspace restore is available to undo."
                        }
                        return workspace.isBusy ? "Workspace Restore is busy." : nil
                    },
                    perform: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.start(.workspace)
                        guard let workspace = self.workspace else { throw CancellationError() }
                        switch await workspace.handle(command) {
                        case .openWorkspace:
                            self.destination = .module(.workspace)
                            self.onOpenDetail?()
                        case .completed:
                            if let reason = workspace.errorMessage {
                                throw UtilityLifecycleError.unavailable(reason)
                            }
                            self.message = workspace.results.map(\.message).joined(separator: "\n")
                        }
                    }))
        }
        let shelfMetadata = ShelfModuleRegistration()
        for command in [ShelfCommand.open, .clear] {
            actions.append(
                UtilityActionHandler(
                    descriptor: .init(
                        id: .init(rawValue: command.rawValue), module: .shelf,
                        title: command == .open ? "Open \(shelfMetadata.title)" : "Clear File Shelf",
                        keywords: ["shelf", "files", "items"], symbolName: shelfMetadata.symbol,
                        confirmationMessage: command == .clear
                            ? "Remove all shelf-held items? Source files remain untouched." : nil),
                    disabledReason: { [weak self] in
                        guard command == .clear else { return nil }
                        return self?.shelf?.isClearing == true ? "File Shelf is being cleared." : nil
                    },
                    perform: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.start(.shelf)
                        guard let shelf = self.shelf else { throw CancellationError() }
                        await ShelfCommandHandler(
                            service: shelf,
                            openDetail: {
                                self.destination = .module(.shelf)
                                self.onOpenDetail?()
                            }
                        ).execute(command)
                    }))
        }
        for command in SafeEjectModule.descriptor.commands {
            actions.append(
                UtilityActionHandler(
                    descriptor: .init(
                        id: .init(rawValue: command.rawValue), module: .storage,
                        title: command.title, keywords: ["eject", "storage", "volumes"],
                        symbolName: SafeEjectModule.descriptor.symbol),
                    disabledReason: { nil },
                    perform: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.start(.storage)
                        guard let storage = self.storage else { throw CancellationError() }
                        try SafeEjectModule.handle(command, service: storage) {
                            self.destination = .module(.storage)
                            self.onOpenDetail?()
                        }
                    }))
        }
        actions.append(
            UtilityActionHandler(
                descriptor: .init(
                    id: .init(rawValue: "scenes.restore"), module: .scenes, title: "Restore previous setup",
                    keywords: ["scene", "restore", "undo"], symbolName: "arrow.uturn.backward"),
                disabledReason: { [weak self] in
                    guard let scenes = self?.scenes, scenes.hasPendingRestore else {
                        return "No scene setup is available to restore."
                    }
                    return scenes.isBusy ? "Another scene operation is still running." : nil
                },
                perform: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.start(.scenes)
                    guard let scenes = self.scenes else { throw SceneCommandRuntimeError.unavailable }
                    self.message = try await scenes.restoreScene().message
                }))
        actions.append(
            UtilityActionHandler(
                descriptor: .init(
                    id: .init(rawValue: "presentation.prepare"), module: .presentation, title: "Prepare Presentation",
                    keywords: ["presentation", "preview", "meeting"], symbolName: "play.rectangle"),
                disabledReason: { nil },
                perform: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.open(.presentation)
                }))
        actions.append(
            UtilityActionHandler(
                descriptor: .init(
                    id: .init(rawValue: "presentation.stop"), module: .presentation, title: "End Presentation",
                    keywords: ["presentation", "restore", "stop"], symbolName: "stop.circle"),
                disabledReason: { [weak self] in
                    self?.presentation?.reservation == nil ? "No Presentation session is active." : nil
                },
                perform: { [weak self] in
                    guard let self, let presentation = self.presentation else { throw PresentationError.busy }
                    try await presentation.stop()
                    self.message = presentation.message
                }))
        try commands.register(actions)
    }

    private func presentationDependencies() -> PresentationDependencies {
        PresentationDependencies(
            reserve: { [weak self] in
                guard let self else { throw CancellationError() }
                try self.requireModuleAdmission(.awake)
                let manager = try await self.ensureSceneManager()
                return try await manager.reservePresentation()
            },
            release: { [weak self] token in
                guard let manager = self?.scenes else { throw SceneCommandRuntimeError.unavailable }
                try await manager.releasePresentation(token)
            },
            preview: { [weak self] scene, token in
                guard let manager = self?.scenes else { throw SceneCommandRuntimeError.unavailable }
                return try await manager.previewPresentation(scene, token: token)
            },
            apply: { [weak self] scene, token, preview in
                guard let manager = self?.scenes else { throw SceneCommandRuntimeError.unavailable }
                return try await manager.applyPresentation(scene, token: token, expectedPreview: preview)
            },
            pending: { [weak self] token in
                guard let manager = self?.scenes else { throw SceneCommandRuntimeError.unavailable }
                return try await manager.pendingPresentationTransaction(token: token)
            },
            restore: { [weak self] transaction, token in
                guard let manager = self?.scenes else { throw SceneCommandRuntimeError.unavailable }
                return try await manager.restorePresentation(transactionID: transaction, token: token)
            },
            keepCurrent: { [weak self] transaction, token in
                guard let manager = self?.scenes else { throw SceneCommandRuntimeError.unavailable }
                try await manager.keepCurrentPresentation(transactionID: transaction, token: token)
            },
            acquireAwake: { [weak self] deadline, keepsDisplayAwake in
                guard let self else { throw CancellationError() }
                try self.requireModuleAdmission(.awake)
                return try self.ensureAwakeService().acquireLease(
                    owner: .presentation, keepsDisplayAwake: keepsDisplayAwake, deadline: deadline)
            },
            releaseAwake: { [weak self] token in
                guard let awake = self?.awake else { return false }
                if awake.leaseState(for: .presentation) == nil {
                    return awake.retryReleaseLease(token)
                }
                return awake.releaseLease(token)
            },
            pendingAwakeCleanup: { [weak self] in
                self?.awake?.hasPendingLeaseCleanup(owner: .presentation) ?? false
            },
            retryAwakeCleanup: { [weak self] in
                self?.awake?.retryPendingLeaseCleanup(owner: .presentation) ?? true
            })
    }

    private func acquireUtilityPermit(_ module: UtilityModuleID) throws -> MutationAdmissionPermit? {
        if module == .away { return nil }
        do { return try mutationAdmission.acquire(owner: .manual, mode: .shared) }
        catch { throw UtilityLifecycleError.unavailable("End Away before changing other utilities.") }
    }

    private func requireModuleAdmission(_ module: UtilityModuleID) throws {
        guard !shutdownRequested, !lifecycle.isShuttingDown else { throw UtilityLifecycleError.shuttingDown }
        guard !stoppingModules.contains(module), !lifecycle.stopping.contains(module) else {
            throw ModuleRegistryError.transitionInProgress(module)
        }
        guard registry.state(for: module)?.presence == .added else { throw ModuleRegistryError.moduleNotAdded(module) }
        guard !registry.pausedModuleIDs.contains(module) else { throw ModuleRegistryError.modulePaused(module) }
    }

    private func isModuleUsable(_ module: UtilityModuleID, allowsRecovery: Bool = false) -> Bool {
        guard allowsRecovery || (!shutdownRequested && !lifecycle.isShuttingDown), !stoppingModules.contains(module),
            !lifecycle.stopping.contains(module), registry.state(for: module)?.presence == .added,
            !registry.pausedModuleIDs.contains(module)
        else { return false }
        switch registry.state(for: module)?.runtime {
        case .ready, .active, .limited: return true
        default: return false
        }
    }

    private func prepareSceneDomains(_ domains: Set<SceneControlDomain>) async throws {
        for domain in [SceneControlDomain.audio, .display, .power] where domains.contains(domain) {
            let module: UtilityModuleID =
                switch domain {
                case .audio: .sound
                case .display: .displays
                case .power: .awake
                }
            guard registry.state(for: module)?.presence == .added, !registry.pausedModuleIDs.contains(module) else {
                continue
            }
            if !isModuleUsable(module, allowsRecovery: true) { try await start(module) }
            if domain == .power, powerSceneAdapter == nil, let awake {
                powerSceneAdapter = PowerSceneAdapter(awake: awake)
            }
        }
    }

    private func currentSceneActions() -> [SceneAction] {
        var actions: [SceneAction] = []
        if isModuleUsable(.awake), let awake {
            let lease = awake.leaseState(for: .scene)
            let state: SceneAwakeState = lease.map { $0.keepsDisplayAwake ? .displayAndSystem : .system } ?? .off
            actions.append(.init(control: .awakeMode, target: .awake(state), importance: .required))
        }
        if let sound = usableSound {
            let engine = sound.audioEngine
            if let deviceID = engine.deviceVolumeMonitor.defaultDeviceUID,
                let device = engine.deviceMonitor.device(for: deviceID)
            {
                actions.append(.init(control: .audioOutputDevice, target: .text(deviceID), importance: .required))
                if let volume = engine.deviceVolumeMonitor.confirmedOutputVolume(for: device.id) {
                    actions.append(
                        .init(
                            control: .audioOutputVolume(deviceID: deviceID), target: .number(Double(volume)),
                            importance: .required))
                }
                if engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id) != .ddc,
                    let muted = engine.deviceVolumeMonitor.muteStates[device.id]
                {
                    actions.append(
                        .init(
                            control: .audioOutputMuted(deviceID: deviceID), target: .boolean(muted),
                            importance: .required))
                }
            }
        }
        if isModuleUsable(.displays), let displays {
            for display in displays.displays {
                for feature in DisplayFeature.allCases where display.sceneEligibleFeatures.contains(feature) {
                    guard let reading = display.features[feature] else { continue }
                    let control: SceneControl =
                        switch feature {
                        case .brightness: .displayBrightness(displayID: display.id.rawValue)
                        case .contrast: .displayContrast(displayID: display.id.rawValue)
                        }
                    actions.append(.init(control: control, target: .number(reading.normalized), importance: .optional))
                }
            }
        }
        return actions
    }

    private func sceneRecoveryModules() async throws -> Set<UtilityModuleID> {
        guard let scenes else { return [] }
        do {
            return Set(
                try await scenes.pendingDomains().map { domain in
                    switch domain {
                    case .audio: UtilityModuleID.sound
                    case .display: UtilityModuleID.displays
                    case .power: UtilityModuleID.awake
                    }
                })
        } catch {
            throw UtilityCleanupDeferral(
                reason:
                    "The scene recovery record could not be read. Keep its services available until recovery is checked.",
                retaining: [.scenes, .sound, .displays, .awake])
        }
    }

    private func requireSceneDependencyCanStop(_ module: UtilityModuleID) async throws {
        guard [.sound, .displays, .awake].contains(module), let scenes else { return }
        guard !scenes.isBusy else {
            throw UtilityCleanupDeferral(
                reason: "Wait for the current scene operation before stopping this module.", retaining: [module])
        }
        guard !(try await sceneRecoveryModules()).contains(module) else {
            throw UtilityCleanupDeferral(
                reason: "Restore the pending scene or keep the current setup before stopping this module.",
                retaining: [module])
        }
    }

    private func requireSceneRemovalCanFinish() async throws {
        guard let scenes else { return }
        let dependencies = try await sceneRecoveryModules()
        guard !scenes.isBusy, !scenes.hasPendingRestore, dependencies.isEmpty else {
            throw UtilityCleanupDeferral(
                reason: "Restore the pending scene or keep the current setup before removing Scenes.",
                retaining: dependencies.union([.scenes]))
        }
    }

    private func requirePresentationDependencyCanStop(_ module: UtilityModuleID) throws {
        guard module != .presentation, let presentation, presentation.retainedModules.contains(module) else { return }
        throw UtilityCleanupDeferral(
            reason: "End Presentation and finish its recovery before stopping this module.",
            retaining: presentation.retainedModules)
    }

    private func observeStatus(for module: UtilityModuleID) {
        guard !shutdownRequested, !lifecycle.isShuttingDown, !stoppingModules.contains(module),
            !lifecycle.stopping.contains(module), registry.state(for: module)?.presence == .added,
            !registry.pausedModuleIDs.contains(module)
        else { return }
        switch registry.state(for: module)?.runtime {
        case .ready, .active, .limited: break
        default: return
        }
        switch module {
        case .sound:
            guard let sound else { return }
            var wasGranted =
                registry.state(for: .sound)?.permission == .granted
                || registry.state(for: .sound)?.permission == .revoked
            statusObserver.observe(module: module) {
                let permission: ModulePermissionState
                switch sound.audioEngine.permission.status {
                case .authorized:
                    wasGranted = true
                    permission = .granted
                case .unknown: permission = .notDetermined
                case .denied: permission = wasGranted ? .revoked : .denied
                }
                let runtime: ModuleRuntimeState
                if permission != .granted {
                    runtime = .limited(reason: "Allow Screen & System Audio Recording to control individual apps.")
                } else {
                    runtime = sound.audioEngine.activeProcessingTapCount > 0 ? .active : .ready
                }
                return .init(runtime: runtime, permission: permission)
            }
        case .awake:
            guard let awake else { return }
            statusObserver.observe(module: module) {
                let runtime: ModuleRuntimeState
                switch awake.failure {
                case .couldNotStart: runtime = .limited(reason: "Awake could not start a power assertion.")
                case .couldNotRelease: runtime = .limited(reason: "A power assertion could not be released.")
                case nil: runtime = awake.hasEffectiveAwakeRequest ? .active : .ready
                }
                return .init(runtime: runtime, permission: .notRequired)
            }
        case .workspace:
            guard let workspace else { return }
            statusObserver.observe(module: module) {
                let permission: ModulePermissionState
                switch workspace.permission {
                case .notRequested: permission = .notDetermined
                case .granted: permission = .granted
                case .denied: permission = .denied
                case .revoked: permission = .revoked
                }
                let runtime: ModuleRuntimeState
                if let reason = workspace.errorMessage {
                    runtime = .limited(reason: reason)
                } else if permission == .denied || permission == .revoked {
                    runtime = .limited(reason: WorkspaceError.permission.localizedDescription)
                } else if !workspace.isRunning {
                    runtime = .limited(reason: "Workspace Restore is stopped.")
                } else {
                    runtime = workspace.isBusy ? .active : .ready
                }
                return .init(runtime: runtime, permission: permission)
            }
        case .shelf:
            guard let shelf else { return }
            statusObserver.observe(module: module) {
                let runtime: ModuleRuntimeState
                if let reason = shelf.message {
                    runtime = .limited(reason: reason)
                } else if shelf.storeNeedsReset {
                    runtime = .limited(reason: ShelfFailure.invalidStore.localizedDescription)
                } else if !shelf.isRunning {
                    runtime = .limited(reason: "File Shelf is stopped.")
                } else {
                    let busy =
                        shelf.isClearing || shelf.importCount > 0
                        || shelf.checksums.values.contains(.calculating)
                    runtime = busy ? .active : .ready
                }
                return .init(runtime: runtime, permission: .notRequired)
            }
        case .storage:
            guard let storage else { return }
            statusObserver.observe(module: module) {
                let runtime: ModuleRuntimeState
                if let failure = storage.inventoryFailure {
                    runtime = .limited(reason: failure.message)
                } else {
                    switch storage.state {
                    case .running: runtime = storage.activeVolumeID == nil ? .ready : .active
                    case .sleeping: runtime = .limited(reason: SafeEjectFailure.sleeping.message)
                    case .paused, .shutDown: runtime = .limited(reason: SafeEjectFailure.paused.message)
                    }
                }
                return .init(runtime: runtime, permission: .notRequired)
            }
        case .scenes:
            guard let scenes else { return }
            statusObserver.observe(module: module) {
                let runtime: ModuleRuntimeState =
                    scenes.isBusy
                    ? .active
                    : scenes.hasPendingRestore ? .limited(reason: "A previous setup is available to restore.") : .ready
                return .init(runtime: runtime, permission: .notRequired)
            }
        case .presentation:
            guard let presentation else { return }
            statusObserver.observe(module: module) {
                let runtime: ModuleRuntimeState
                switch presentation.phase {
                case .idle, .preview: runtime = .ready
                case .preparing, .starting, .active, .restoring: runtime = .active
                case .recoveryRequired:
                    runtime = .limited(reason: presentation.message ?? "Presentation recovery needs attention.")
                }
                return .init(runtime: runtime, permission: .notRequired)
            }
        default: break
        }
    }
}
