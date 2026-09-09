import KeyboardShortcuts
import SwiftUI

struct UtilityShellView: View {
    @Bindable var runtime: UtilityRuntime
    var compact = false
    var connectsShellActions = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if compact {
                home.padding(14)
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 180)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: compact ? 400 : nil)
        .frame(minWidth: compact ? nil : 820, minHeight: compact ? nil : 580)
        .preferredColorScheme(runtime.settings.appSettings.appearance.swiftUIColorScheme)
        .onAppear {
            guard connectsShellActions else { return }
            runtime.onOpenDetail = { openWindow(id: "utilities") }
            runtime.startShellShortcuts()
            if !compact, runtime.destination == .home { searchFocused = true }
        }
        .onChange(of: runtime.searchFocusRequest) { _, _ in
            if !compact { searchFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Semper").font(.headline)
            Spacer()
            Button {
                runtime.requestSearchFocus()
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Search Semper actions")
            .accessibilityLabel("Search Semper actions")
            if compact {
                Button {
                    openWindow(id: "utilities")
                } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open Semper window").accessibilityLabel("Open Semper window")
                Button {
                    runtime.destination = .modules
                    openWindow(id: "utilities")
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .help("Manage modules").accessibilityLabel("Manage modules")
            }
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings").accessibilityLabel("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Semper").accessibilityLabel("Quit Semper")
        }
        .buttonStyle(.plain)
        .padding(14)
    }

    private var sidebar: some View {
        List(selection: $runtime.destination) {
            Label("Home", systemImage: "house").tag(UtilityDestination.home)
            Section("Added modules") {
                ForEach(runtime.registry.addedModules) { module in
                    Label(module.title, systemImage: module.symbolName).tag(UtilityDestination.module(module.id))
                }
            }
            Label("Modules", systemImage: "square.grid.2x2").tag(UtilityDestination.modules)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch runtime.destination {
        case .home: home.padding(24)
        case .modules:
            ModuleLibraryView(
                registry: runtime.registry, lifecycle: runtime.lifecycle,
                pause: runtime.pause, remove: runtime.remove)
        case .module(let id):
            module(id)
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Search Semper actions", text: $runtime.searchText)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search Semper actions")
                if runtime.searchText.isEmpty {
                    if !runtime.registry.favoriteActions.isEmpty {
                        Text("Pinned actions").font(.headline)
                        UtilityActionList(commands: runtime.commands, actions: runtime.registry.favoriteActions)
                    }
                    ForEach(runtime.registry.addedModules) { module in
                        Button {
                            runtime.destination = .module(module.id)
                            if compact { openWindow(id: "utilities") }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: module.symbolName).frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(module.title).font(.headline)
                                    Text(runtime.summary(for: module.id)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let message = runtime.message { Text(message).foregroundStyle(.orange) }
                    ForEach(runtime.lifecycle.failures.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
                        id in
                        Text(runtime.lifecycle.failures[id] ?? "").foregroundStyle(.orange)
                    }
                    Text("Actions").font(.headline)
                }
                let matches = runtime.commands.registry.search(runtime.searchText)
                if matches.isEmpty {
                    Text("No matching actions. Add a module to make its actions available.").foregroundStyle(.secondary)
                } else {
                    UtilityActionList(commands: runtime.commands, actions: matches)
                }
            }
        }
        .frame(maxHeight: compact ? 560 : nil)
    }

    @ViewBuilder
    private func module(_ id: UtilityModuleID) -> some View {
        if runtime.registry.pausedModuleIDs.contains(id) {
            ContentUnavailableView(
                "Module paused", systemImage: "pause.circle",
                description: Text("Resume this module in Modules before opening it."))
        } else if runtime.registry.state(for: id)?.presence != .added {
            ContentUnavailableView(
                "Module not added", systemImage: "square.grid.2x2", description: Text("Add this module in Modules."))
        } else {
            switch id {
            case .sound:
                if let sound = runtime.sound {
                    MenuBarPopupView(
                        audioEngine: sound.audioEngine, audioCommands: sound.audioCommands,
                        audioActivityStore: sound.audioActivityStore, callMode: sound.callMode,
                        bluetoothHDGuard: sound.bluetoothHDGuard, deviceVolumeMonitor: sound.deviceVolumeMonitor,
                        updateManager: runtime.updateManager, permission: sound.audioEngine.permission,
                        accessibility: sound.accessibility, mediaKeyStatus: sound.mediaKeyStatus,
                        popupVisibility: sound.popupVisibility, hudController: sound.hudController,
                        mediaKeyMonitor: sound.mediaKeyMonitor, experimentManager: runtime.experiments,
                        showsModuleSwitcher: false)
                } else {
                    startModule(id)
                }
            case .awake:
                if let awake = runtime.awake { AwakeModuleView(awake: awake) } else { startModule(id) }
            default:
                startModule(id)
            }
        }
    }

    private func startModule(_ id: UtilityModuleID) -> some View {
        VStack(spacing: 14) {
            Text(runtime.registry.descriptor(for: id)?.title ?? id.rawValue).font(.title2)
            Text(runtime.summary(for: id)).foregroundStyle(.secondary)
            Button("Open \(runtime.registry.descriptor(for: id)?.title ?? id.rawValue)") {
                Task {
                    do {
                        try await runtime.open(id)
                        runtime.message = nil
                    } catch { runtime.message = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent)
            if let message = runtime.message { Text(message).foregroundStyle(.orange) }
        }
        .padding(24)
    }
}

struct UtilitySettingsView: View {
    @Bindable var runtime: UtilityRuntime

    var body: some View {
        TabView {
            GeneralTab(settings: runtime.settings, onResetAll: runtime.resetSoundSettings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModuleLibraryView(
                registry: runtime.registry, lifecycle: runtime.lifecycle,
                pause: runtime.pause, remove: runtime.remove
            )
            .tabItem { Label("Modules", systemImage: "square.grid.2x2") }
            VStack(alignment: .leading, spacing: 16) {
                Text("Search Semper actions").font(.headline)
                KeyboardShortcuts.Recorder("Keyboard shortcut", name: UtilityRuntime.searchShortcut)
                Text("Sound shortcuts and media keys are available after Sound starts.").foregroundStyle(.secondary)
                if let sound = runtime.sound {
                    ShortcutsTab(
                        settings: runtime.settings, accessibility: sound.accessibility,
                        mediaKeyStatus: sound.mediaKeyStatus, mediaKeyMonitor: sound.mediaKeyMonitor,
                        shortcutsRegistry: sound.shortcutsRegistry)
                }
            }.padding(24).tabItem { Label("Shortcuts", systemImage: "command") }
            if let sound = runtime.sound {
                AudioTab(
                    settings: runtime.settings, audioEngine: sound.audioEngine, audioCommands: sound.audioCommands,
                    callMode: sound.callMode, bluetoothHDGuard: sound.bluetoothHDGuard,
                    deviceVolumeMonitor: sound.deviceVolumeMonitor
                )
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
            }
            UpdatesTab(updateManager: runtime.updateManager).tabItem {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 860, height: 620)
        .preferredColorScheme(runtime.settings.appSettings.appearance.swiftUIColorScheme)
    }
}
