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
    private(set) var sound: SoundRuntime?
    private(set) var awake: AwakeService?
    private(set) var workspace: WorkspaceService?
    private(set) var shelf: ShelfService?
    private(set) var storage: SafeEjectService?
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

    func installIntentActivation() {
        SemperAppIntentRuntime.installActivation(owner: self) { [weak self] in
            guard let self else { throw AppShortcutExecutionError.unavailable }
            try await self.start(.sound)
            guard self.usableSound != nil else { throw AppShortcutExecutionError.unavailable }
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
        awakeFactory: @escaping @MainActor () throws -> AwakeService = {
            AwakeService(backend: IOPMPowerAssertionBackend())
        },
        workspaceFactory: @escaping @MainActor () throws -> WorkspaceService = { WorkspaceService() },
        shelfFactory: @escaping @MainActor () throws -> ShelfService = { ShelfService() },
        storageFactory: @escaping @MainActor () throws -> SafeEjectService = { SafeEjectService() }
    ) throws {
        self.settings = settings
        self.soundFactory = soundFactory
        self.awakeFactory = awakeFactory
        self.workspaceFactory = workspaceFactory
        self.shelfFactory = shelfFactory
        self.storageFactory = storageFactory
        registry = try ModuleRegistry(defaults: defaults, modules: UtilityModuleDescriptor.integratedCatalog)
        lifecycle = UtilityLifecycle(registry: registry)
        commands = UtilityCommandCenter(registry: registry)
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
        guard !shortcutsStarted else { return }
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

    func open(_ module: UtilityModuleID) async throws {
        try await start(module)
        destination = .module(module)
        onOpenDetail?()
    }

    func shutdown() async {
        shutdownRequested = true
        statusObserver.stopAll()
        SemperAppIntentRuntime.uninstallActivation(owner: self)
        shellIcon.stop()
        if shortcutsStarted {
            KeyboardShortcuts.removeHandler(for: Self.searchShortcut)
            shortcutsStarted = false
        }
        for module in registry.modules { await commands.cancelAndDrain(module: module.id) }
        await lifecycle.shutdown()
        #if !APP_STORE
            await ddc.stopAndDrain()
        #endif
        settings.flushSync()
    }

    func pause(_ module: UtilityModuleID) async throws {
        guard !shutdownRequested else { throw UtilityLifecycleError.shuttingDown }
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
                        self.ddc.start()
                        self.sound = try self.soundFactory(self.settings, self.ddc)
                    #else
                        self.sound = try self.soundFactory(self.settings, nil)
                    #endif
                },
                stop: { [weak self] _ in
                    guard let self else { return }
                    try await self.sound?.shutdownAndDrain()
                    self.sound = nil
                    #if !APP_STORE
                        await self.ddc.stopAndDrain()
                    #endif
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
                    if reason == .termination {
                        awake.shutdown()
                    } else {
                        awake.stop()
                        if awake.effectiveLeaseCount == 0 { awake.shutdown() }
                    }
                    if awake.failure == .couldNotRelease {
                        throw UtilityLifecycleError.unavailable(
                            "A power assertion could not be released. Retry stopping Awake.")
                    }
                    if reason == .termination || awake.effectiveLeaseCount == 0 { self.awake = nil }
                }))
        try lifecycle.register(
            .workspace,
            binding: UtilityServiceBinding(
                start: { [weak self] in
                    guard let self else { throw CancellationError() }
                    if self.workspace == nil { self.workspace = try self.workspaceFactory() }
                    await self.workspace?.start()
                },
                stop: { [weak self] reason in
                    guard let self, let workspace = self.workspace else { return }
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
                    self.storage?.start()
                    guard self.storage?.state == .running else {
                        throw UtilityLifecycleError.unavailable(
                            self.storage?.inventoryFailure?.message ?? SafeEjectFailure.unavailable.message)
                    }
                },
                stop: { [weak self] reason in
                    guard let self, let storage = self.storage else { return }
                    if reason == .pause { storage.pause() } else { storage.shutdown() }
                    await storage.waitForCleanup()
                    if reason != .pause { self.storage = nil }
                }))
    }

    private func installActions() throws {
        var actions: [UtilityActionHandler] = []
        for module in registry.modules where [.sound, .awake, .workspace].contains(module.id) {
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
        try commands.register(actions)
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
        default: break
        }
    }
}
