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
    var destination: UtilityDestination = .home
    var searchText = ""
    private(set) var searchFocusRequest = UUID()
    var onOpenDetail: (() -> Void)?
    var message: String?
    @ObservationIgnored private let soundFactory:
        @MainActor (SettingsManager, AudioEngine.SharedDDCController?) throws -> SoundRuntime
    @ObservationIgnored private var shortcutsStarted = false
    @ObservationIgnored private let shellIcon: MenuBarIconCoordinator
    #if !APP_STORE
        private let ddc: DDCController
    #endif

    static let searchShortcut = KeyboardShortcuts.Name(
        "search-semper-actions", default: .init(.k, modifiers: [.command, .option]))

    init(
        settings: SettingsManager = SettingsManager(managesLaunchAtLogin: true),
        defaults: UserDefaults = .standard,
        updateManager: UpdateManager? = nil,
        soundFactory: @escaping @MainActor (SettingsManager, AudioEngine.SharedDDCController?) throws -> SoundRuntime =
            {
                SoundRuntime(settings: $0, sharedDDCController: $1)
            }
    ) throws {
        self.settings = settings
        self.soundFactory = soundFactory
        registry = try ModuleRegistry(defaults: defaults)
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

    func open(_ module: UtilityModuleID) async throws {
        try await lifecycle.start(module)
        destination = .module(module)
        onOpenDetail?()
    }

    func shutdown() async {
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
        await commands.cancelAndDrain(module: module)
        try await lifecycle.pause(module)
    }

    func remove(_ module: UtilityModuleID) async throws {
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
            guard let session = awake?.session else { return "No active Awake session" }
            if let end = session.endsAt { return "Awake until \(end.formatted(date: .omitted, time: .shortened))" }
            return "Awake until turned off"
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
                    self.awake = AwakeService(backend: IOPMPowerAssertionBackend())
                    try self.registry.setPermission(.notRequired, for: .awake)
                },
                stop: { [weak self] _ in
                    guard let self else { return }
                    self.awake?.shutdown()
                    if self.awake?.failure == .couldNotRelease {
                        throw UtilityLifecycleError.unavailable(
                            "A power assertion could not be released. Retry stopping Awake.")
                    }
                    self.awake = nil
                }))
    }

    private func installActions() throws {
        var actions: [UtilityActionHandler] = []
        for module in registry.modules where [.sound, .awake].contains(module.id) {
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
                    try await self.lifecycle.start(.awake)
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
                    self?.awake?.stop()
                    if self?.awake?.failure == .couldNotRelease {
                        throw UtilityLifecycleError.unavailable("A power assertion could not be released.")
                    }
                }
            ))
        try commands.register(actions)
    }
}
