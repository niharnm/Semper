import Foundation
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
                pause: runtime.pause, remove: runtime.remove, mutationDisabledReason: runtime.mutationDisabledReason)
        case .module(let id):
            module(id).disabled(moduleInteractionDisabled(for: id))
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Search Semper actions", text: $runtime.searchText)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search Semper actions")
                if let destination = sceneRecoveryDestination {
                    Button {
                        runtime.destination = destination
                        if compact { openWindow(id: "utilities") }
                    } label: {
                        Label("Recover Previous Setup", systemImage: "arrow.uturn.backward")
                    }
                }
                if runtime.searchText.isEmpty {
                    if !runtime.registry.favoriteActions.isEmpty {
                        Text("Pinned actions").font(.headline)
                        UtilityActionList(commands: runtime.commands, actions: runtime.registry.favoriteActions)
                    }
                    ForEach(runtime.registry.addedModules) { module in
                        if compact, module.id == .shelf, shelfStopRecoveryRoute != nil {
                            ShelfStopRecoveryView(runtime: runtime)
                                .disabled(moduleInteractionDisabled(for: .shelf))
                        } else if compact, module.id == .shelf,
                            !runtime.registry.pausedModuleIDs.contains(.shelf),
                            !runtime.lifecycle.stopping.contains(.shelf), !runtime.lifecycle.isShuttingDown,
                            let shelf = runtime.shelf, shelf.isRunning
                        {
                            ShelfCompactView(service: shelf) {
                                Task {
                                    do {
                                        try await runtime.open(.shelf)
                                        runtime.message = nil
                                    } catch { runtime.message = error.localizedDescription }
                                }
                            }
                            .disabled(runtime.mutationDisabledReason != nil)
                        } else {
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
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let message = runtime.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !attentionItems.contains(where: { item in
                            item.reasons.contains { $0.caseInsensitiveCompare(message) == .orderedSame }
                        })
                    {
                        Text(message).foregroundStyle(.orange)
                    }
                    if !attentionItems.isEmpty {
                        Text("Needs attention").font(.headline)
                        ForEach(attentionItems) { item in
                            if let module = runtime.registry.descriptor(for: item.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(module.title, systemImage: "exclamationmark.triangle")
                                        .font(.subheadline.weight(.medium))
                                    ForEach(item.reasons, id: \.self) { reason in
                                        Text(reason).font(.caption)
                                    }
                                }
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                    if !runtime.commands.recentActions.isEmpty {
                        HStack {
                            Text("Recent actions").font(.headline)
                            Spacer()
                            Text("This session").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(
                            runtime.commands.recentActions.prefix(
                                compact ? 3 : UtilityCommandCenter.maximumRecentActions)
                        ) { entry in
                            if let action = runtime.registry.actionMetadata(for: entry.actionID) {
                                HStack(spacing: 10) {
                                    Label(action.title, systemImage: action.symbolName)
                                        .font(.caption)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(entry.result.displayText)
                                        Text(entry.timestamp, style: .time)
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
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

    private var attentionItems: [UtilityModuleAttention] {
        runtime.commands.attentionItems(lifecycleFailures: runtime.lifecycle.failures)
    }

    var sceneRecoveryDestination: UtilityDestination? {
        guard runtime.scenes?.hasPendingRestore == true, runtime.presentation?.reservation == nil else { return nil }
        return .module(.scenes)
    }

    var shelfStopRecoveryRoute: ShelfStopRecoveryRoute? {
        ShelfStopRecoveryRoute.current(in: runtime)
    }

    func moduleInteractionDisabled(for id: UtilityModuleID) -> Bool {
        if id == .shelf, shelfStopRecoveryRoute != nil { return false }
        return id != .away && runtime.mutationDisabledReason != nil
    }

    @ViewBuilder
    private func module(_ id: UtilityModuleID) -> some View {
        if id == .away, runtime.awayCleanupResult != nil, runtime.awayCleanupResult != .complete {
            AwayCleanupView(runtime: runtime)
        } else if id == .presentation, let controller = runtime.presentation, controller.phase == .recoveryRequired {
            PresentationView(runtime: runtime, controller: controller)
        } else if id == .scenes, let scenes = runtime.scenes, scenes.hasPendingRestore,
            runtime.presentation?.reservation == nil,
            runtime.sceneShortcuts == nil || runtime.lifecycle.isShuttingDown
        {
            SceneRecoveryView(manager: scenes)
        } else if id == .shelf, shelfStopRecoveryRoute != nil {
            ShelfStopRecoveryView(runtime: runtime)
        } else if runtime.registry.pausedModuleIDs.contains(id) {
            ContentUnavailableView {
                Label("Module paused", systemImage: "pause.circle")
            } description: {
                if case .failed(let reason) = runtime.registry.state(for: id)?.runtime {
                    Text("\(reason) Retry stopping this module in Modules.")
                } else {
                    Text("Resume this module in Modules before opening it.")
                }
            }
        } else if runtime.registry.state(for: id)?.presence != .added {
            ContentUnavailableView(
                "Module not added", systemImage: "square.grid.2x2", description: Text("Add this module in Modules."))
        } else {
            switch id {
            case .sound:
                if let sound = runtime.usableSound {
                    MenuBarPopupView(
                        audioEngine: sound.audioEngine, audioCommands: sound.audioCommands,
                        audioActivityStore: sound.audioActivityStore, callMode: sound.callMode,
                        bluetoothHDGuard: sound.bluetoothHDGuard, deviceVolumeMonitor: sound.deviceVolumeMonitor,
                        updateManager: runtime.updateManager, permission: sound.audioEngine.permission,
                        accessibility: sound.accessibility, mediaKeyStatus: sound.mediaKeyStatus,
                        popupVisibility: sound.popupVisibility, hudController: sound.hudController,
                        mediaKeyMonitor: sound.mediaKeyMonitor, experimentManager: runtime.experiments,
                        showsModuleSwitcher: false, presentation: .detailWindow)
                } else {
                    startModule(id)
                }
            case .awake:
                if let awake = runtime.awake { AwakeModuleView(awake: awake) } else { startModule(id) }
            case .away:
                if let away = runtime.usableAway {
                    AwayModuleView(coordinator: away) {
                        runtime.requestAwaySettings()
                        openSettings()
                    }
                    .disabled(runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                } else {
                    startModule(id)
                }
            case .workspace:
                if let workspace = runtime.workspace {
                    VStack(alignment: .leading, spacing: 0) {
                        if workspace.presentationReservation != nil {
                            Text(
                                "Presentation owns this workspace preview or recovery. End Presentation before changing it."
                            )
                            .foregroundStyle(.secondary).padding(24)
                        }
                        WorkspaceView(service: workspace, workflowRequest: runtime.workspaceWorkflowRequest)
                            .disabled(
                                workspace.presentationReservation != nil
                                    || runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                    }
                } else {
                    startModule(id)
                }
            case .windowLayout:
                if let service = runtime.windowLayout {
                    WindowLayoutView(service: service, commands: runtime.commands)
                        .disabled(runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                } else {
                    startModule(id)
                }
            case .shelf:
                if let shelf = runtime.shelf {
                    ShelfDetailView(service: shelf)
                        .disabled(runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                } else {
                    startModule(id)
                }
            case .storage:
                if let storage = runtime.storage {
                    SafeEjectView(service: storage)
                        .disabled(runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                } else {
                    startModule(id)
                }
            case .scenes:
                if let scenes = runtime.scenes, let shortcuts = runtime.sceneShortcuts {
                    ScenesTab(sceneManager: scenes, shortcutRegistry: shortcuts)
                        .disabled(runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                } else {
                    startModule(id)
                }
            case .displays:
                if let displays = runtime.displays {
                    #if !APP_STORE
                        ScrollView {
                            DisplaysPane(
                                displayService: displays,
                                isSceneOperationInProgress: runtime.scenes?.isBusy == true
                                    || runtime.mutationAdmission.activeExclusiveOwner != nil,
                                sceneOperationIsInProgress: {
                                    runtime.scenes?.isBusy == true
                                        || runtime.mutationAdmission.activeExclusiveOwner != nil
                                })
                        }
                        .disabled(runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                    #else
                        DisplaysPane()
                    #endif
                } else {
                    startModule(id)
                }
            case .presentation:
                if let controller = runtime.presentation {
                    PresentationView(runtime: runtime, controller: controller)
                        .disabled(runtime.lifecycle.stopping.contains(id) || runtime.lifecycle.isShuttingDown)
                } else {
                    startModule(id)
                }
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
            if case .failed(let reason) = runtime.registry.state(for: id)?.runtime {
                Text(reason).foregroundStyle(.orange)
            }
            if let message = runtime.message { Text(message).foregroundStyle(.orange) }
        }
        .padding(24)
    }
}

struct UtilitySettingsView: View {
    @Bindable var runtime: UtilityRuntime
    @State private var resetInProgress = false
    @State private var resetError: String?

    var body: some View {
        TabView(selection: $runtime.settingsTab) {
            GeneralTab(settings: runtime.settings, onResetAll: resetAllSettings)
                .disabled(resetInProgress || runtime.lifecycle.isShuttingDown || runtime.mutationDisabledReason != nil)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(UtilitySettingsTab.general)
            ModuleLibraryView(
                registry: runtime.registry, lifecycle: runtime.lifecycle,
                pause: runtime.pause, remove: runtime.remove, mutationDisabledReason: runtime.mutationDisabledReason
            )
            .tabItem { Label("Modules", systemImage: "square.grid.2x2") }
            .tag(UtilitySettingsTab.modules)
            awaySettings
                .tabItem { Label("Away", systemImage: "eye.slash.fill") }
                .tag(UtilitySettingsTab.away)
            VStack(alignment: .leading, spacing: 16) {
                Text("Search Semper actions").font(.headline)
                KeyboardShortcuts.Recorder(
                    "Keyboard shortcut", name: UtilityRuntime.searchShortcut, onChange: runtime.recordSearchShortcut)
                KeyboardShortcuts.Recorder(
                    "Prepare Workspace Restore", name: UtilityRuntime.workspaceRestoreShortcut,
                    onChange: runtime.recordWorkspaceRestoreShortcut)
                Text("Opens Workspace Restore preparation. Preview and Restore remain separate actions.")
                    .font(.caption).foregroundStyle(.secondary)
                if let conflict = runtime.workspaceShortcutConflict {
                    Text(conflict).font(.caption).foregroundStyle(.orange)
                }
                KeyboardShortcuts.Recorder(
                    "Away Mode", name: UtilityRuntime.awayShortcut, onChange: runtime.recordAwayShortcut)
                Text("Starts the countdown or requests authentication to leave Away.")
                    .font(.caption).foregroundStyle(.secondary)
                if let conflict = runtime.awayShortcutConflict {
                    Text(conflict).font(.caption).foregroundStyle(.orange)
                }
                Text("Window Layout").font(.headline)
                Text("Optional shortcuts arrange the frontmost app window. Add and resume Window Layout before using them.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ShortcutAction.windowLayoutActions, id: \.self) { action in
                    KeyboardShortcuts.Recorder(
                        action.displayName, name: action.keyboardShortcutName,
                        onChange: { runtime.recordWindowLayoutShortcut($0, action: action) })
                    if let conflict = runtime.windowLayoutShortcutConflicts[action] {
                        Text(conflict).font(.caption).foregroundStyle(.orange)
                    }
                }
                if let sound = runtime.usableSound {
                    ShortcutsTab(
                        settings: runtime.settings, accessibility: sound.accessibility,
                        mediaKeyStatus: sound.mediaKeyStatus, mediaKeyMonitor: sound.mediaKeyMonitor,
                        shortcutsRegistry: sound.shortcutsRegistry)
                } else {
                    Text("Sound shortcuts and media keys are available after Sound starts.").foregroundStyle(.secondary)
                    if case .failed(let reason) = runtime.registry.state(for: .sound)?.runtime {
                        Text(reason).foregroundStyle(.orange)
                    }
                }
            }
            .padding(24)
            .disabled(runtime.lifecycle.isShuttingDown || runtime.mutationDisabledReason != nil)
            .tabItem { Label("Shortcuts", systemImage: "command") }
            .tag(UtilitySettingsTab.shortcuts)
            if let sound = runtime.usableSound {
                AudioTab(
                    settings: runtime.settings, audioEngine: sound.audioEngine, audioCommands: sound.audioCommands,
                    callMode: sound.callMode, bluetoothHDGuard: sound.bluetoothHDGuard,
                    deviceVolumeMonitor: sound.deviceVolumeMonitor
                )
                .disabled(runtime.lifecycle.isShuttingDown || runtime.mutationDisabledReason != nil)
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
                .tag(UtilitySettingsTab.sound)
            } else if case .failed(let reason) = runtime.registry.state(for: .sound)?.runtime {
                ContentUnavailableView(
                    "Sound needs attention", systemImage: "exclamationmark.triangle",
                    description: Text(reason)
                )
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
                .tag(UtilitySettingsTab.sound)
            }
            if runtime.registry.state(for: .scenes)?.presence == .added,
                !runtime.registry.pausedModuleIDs.contains(.scenes),
                let scenes = runtime.scenes, let shortcuts = runtime.sceneShortcuts
            {
                ScenesTab(sceneManager: scenes, shortcutRegistry: shortcuts)
                    .disabled(
                        runtime.lifecycle.stopping.contains(.scenes) || runtime.lifecycle.isShuttingDown
                            || runtime.mutationDisabledReason != nil
                    )
                    .tabItem { Label("Scenes", systemImage: "square.stack.3d.up") }
                    .tag(UtilitySettingsTab.scenes)
            }
            UpdatesTab(updateManager: runtime.updateManager)
                .disabled(runtime.lifecycle.isShuttingDown || runtime.mutationDisabledReason != nil)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(UtilitySettingsTab.updates)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(UtilitySettingsTab.about)
        }
        .frame(width: 860, height: 620)
        .preferredColorScheme(runtime.settings.appSettings.appearance.swiftUIColorScheme)
        .alert(
            "Reset Could Not Finish",
            isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })
        ) {
            Button("OK") { resetError = nil }
        } message: {
            if let resetError { Text(resetError) }
        }
    }

    @ViewBuilder
    private var awaySettings: some View {
        if runtime.awayCleanupResult != nil, runtime.awayCleanupResult != .complete {
            AwayCleanupView(runtime: runtime)
        } else if let away = runtime.usableAway {
            AwayTab(coordinator: away)
                .disabled(
                    runtime.lifecycle.stopping.contains(.away) || runtime.lifecycle.isShuttingDown
                        || runtime.mutationDisabledReason != nil)
        } else {
            VStack(spacing: 14) {
                Text("Away settings").font(.title2)
                if runtime.registry.state(for: .away)?.presence != .added
                    || runtime.registry.pausedModuleIDs.contains(.away)
                {
                    Text("Add or resume Away in Modules to open its settings.").foregroundStyle(.secondary)
                    Button("Manage Modules") { runtime.settingsTab = .modules }
                } else {
                    Text("Open Away to configure its curtain and authentication.").foregroundStyle(.secondary)
                    Button("Open Away Settings") {
                        Task {
                            do { _ = try await runtime.ensureAway() } catch {
                                runtime.message = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runtime.lifecycle.isShuttingDown || runtime.mutationDisabledReason != nil)
                }
                if let message = runtime.message { Text(message).foregroundStyle(.orange) }
            }
            .padding(24)
        }
    }

    private func resetAllSettings() {
        guard !resetInProgress else { return }
        resetInProgress = true
        resetError = nil
        Task {
            if !(await runtime.resetAllSettings()) { resetError = runtime.message }
            resetInProgress = false
        }
    }
}

nonisolated enum ShelfStopRecoveryRoute: Equatable, Sendable {
    case pause, shutdown

    @MainActor
    static func current(in runtime: UtilityRuntime) -> Self? {
        guard runtime.shelf?.stopFailure != nil else { return nil }
        return runtime.lifecycle.isShuttingDown ? .shutdown : .pause
    }

    @MainActor
    static func retry(in runtime: UtilityRuntime) async throws {
        switch current(in: runtime) {
        case .pause: try await runtime.pause(.shelf)
        case .shutdown: await runtime.shutdown()
        case nil: return
        }
    }

    @MainActor
    static func acknowledgeRecoveredCopy(in runtime: UtilityRuntime, requestID: UUID) async throws {
        guard current(in: runtime) != nil,
            runtime.shelf?.acknowledgeImageCopyReceipt(requestID: requestID) == true
        else { return }
        try await retry(in: runtime)
    }

    @MainActor
    static func acknowledgeUnverifiedCopy(in runtime: UtilityRuntime, requestID: UUID) async throws {
        guard current(in: runtime) != nil, let service = runtime.shelf,
            service.imageCopy.request?.id == requestID, service.imageCopy.hasUnverifiedPublishedCopy
        else { return }
        try await service.acknowledgeUnverifiedImageCopy(requestID: requestID).get()
        guard runtime.shelf === service, service.imageCopy.request == nil else { return }
        try await retry(in: runtime)
    }
}

private struct ShelfStopRecoveryView: View {
    @Bindable var runtime: UtilityRuntime
    @State private var retrying = false

    var body: some View {
        let acknowledgementRequest =
            runtime.shelf?.imageCopy.needsReceiptAcknowledgement == true
            ? runtime.shelf?.imageCopy.request : nil
        VStack(alignment: .leading, spacing: 14) {
            Label("File Shelf cleanup needs attention", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(
                runtime.shelf?.imageCopy.message ?? runtime.shelf?.stopFailure?.localizedDescription
                    ?? "Retry cleanup to finish stopping File Shelf."
            )
            .foregroundStyle(.secondary)
            if let session = runtime.shelf?.imageCopy {
                if session.needsReceiptAcknowledgement, let receipt = session.receipt {
                    Label("Copy recovered", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text(receipt.url.path).font(.callout).textSelection(.enabled)
                } else {
                    ForEach(session.recoveryLocations, id: \.self) { location in
                        Text(location.path).font(.callout).textSelection(.enabled)
                    }
                }
            }
            Text("Shelf items are retained until cleanup finishes.").font(.callout)
            Button(acknowledgementRequest == nil ? "Retry Cleanup" : "Done") {
                guard !retrying else { return }
                retrying = true
                Task {
                    do {
                        if let acknowledgementRequest {
                            try await ShelfStopRecoveryRoute.acknowledgeRecoveredCopy(
                                in: runtime, requestID: acknowledgementRequest.id)
                        } else {
                            try await ShelfStopRecoveryRoute.retry(in: runtime)
                        }
                    } catch {
                        runtime.message = error.localizedDescription
                    }
                    retrying = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying || runtime.shelf?.isStopping == true || runtime.lifecycle.stopping.contains(.shelf))
            if let session = runtime.shelf?.imageCopy, session.hasUnverifiedPublishedCopy,
                let request = session.request
            {
                ShelfUnverifiedCopyExplanation()
                Button("Finish Without Verification") {
                    guard !retrying else { return }
                    retrying = true
                    Task {
                        do {
                            try await ShelfStopRecoveryRoute.acknowledgeUnverifiedCopy(
                                in: runtime, requestID: request.id)
                        } catch {
                            runtime.message = error.localizedDescription
                        }
                        retrying = false
                    }
                }
                .buttonStyle(.borderless)
                .disabled(
                    retrying || session.isWorking || runtime.shelf?.isStopping == true
                        || runtime.lifecycle.stopping.contains(.shelf))
            }
            if retrying { ProgressView().controlSize(.small) }
        }
        .padding(24)
    }
}

private struct AwayCleanupView: View {
    @Bindable var runtime: UtilityRuntime
    @State private var retrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Away cleanup needs attention", systemImage: "exclamationmark.triangle")
                .font(.title2)
            Text(runtime.lifecycle.failures[.away] ?? "Retry to finish releasing Away resources.")
                .foregroundStyle(.secondary)
            Button("Retry Cleanup") {
                retrying = true
                Task {
                    _ = await runtime.retryAwayCleanup()
                    retrying = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying)
            if retrying { ProgressView().controlSize(.small) }
        }
        .padding(24)
    }
}
