import SwiftUI

struct PresentationView: View {
    @Bindable var runtime: UtilityRuntime
    @Bindable var controller: PresentationController
    @State private var duration = PresentationDuration.oneHour
    @State private var keepDisplayAwake = true
    @State private var useDisplays = false
    @State private var brightness: [String: Double] = [:]
    @State private var useWorkspace = false
    @State private var selectedWindows: Set<UUID> = []
    @State private var useSound = false
    @State private var outputUID = ""
    @State private var outputVolume = 0.5
    @State private var setMute = false
    @State private var muted = false
    @State private var confirmation = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Presentation").font(.title2.weight(.semibold))
                Text("Review selected settings, present for a fixed duration, then restore your previous setup.")
                    .foregroundStyle(.secondary)
                if let message = errorMessage ?? controller.message {
                    Text(message).foregroundStyle(controller.phase == .recoveryRequired ? .orange : .secondary)
                        .textSelection(.enabled)
                }
                if controller.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finishing the current operation…")
                        if controller.canCancelOperation {
                            Button("Cancel Presentation") { run { try await controller.stop() } }
                                .keyboardShortcut(.cancelAction)
                                .help("Cancel preparation or startup and restore any applied changes.")
                        }
                    }
                }
                if controller.reservation == nil {
                    if runtime.scenes?.hasPendingRestore == true {
                        Button("Recover Previous Setup") { runtime.destination = .module(.scenes) }
                    }
                    configuration
                } else {
                    reviewedSession
                }
                if let receipt = controller.workspaceReceipt { workspaceResults(receipt) }
                if let report = controller.restoreReport {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Setting recovery").font(.headline)
                        ForEach(Array(report.outcomes.enumerated()), id: \.offset) { _, outcome in
                            Text(PresentationLabels.restore(outcome, names: controller.draft?.controlNames ?? [:]))
                                .font(.callout)
                        }
                    }
                }
                Text(
                    "Presentation keeps your Mac awake temporarily. Display and Sound recovery can continue after relaunch. Window recovery is available only in this running session, so finish it before quitting. Later manual changes stay in place."
                ).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .confirmationDialog("Keep the current Presentation setup?", isPresented: $confirmation) {
            Button("Keep Current Setup", role: .destructive) {
                run { try await controller.keepCurrent() }
            }
        } message: {
            Text("This accepts the current display, Sound, and window positions and removes this session's recovery ownership. Presentation's Awake request will end. This cannot restore unverified window changes later.")
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Duration", selection: $duration) {
                ForEach(PresentationDuration.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 320)
            Toggle("Keep the display awake too", isOn: $keepDisplayAwake)
            Text("The Mac stays awake for the selected duration. Other Awake requests keep their own settings.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Set display brightness", isOn: $useDisplays)
            if useDisplays { displaySelection }
            Divider()
            Toggle("Restore selected workspace windows", isOn: $useWorkspace)
            if useWorkspace { workspaceSelection }
            Divider()
            Toggle("Set Sound output", isOn: $useSound)
            if useSound { soundSelection }
            Divider()
            Button("Preview Presentation") { prepare() }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy || !selectionReady)
            if !selectionReady {
                Text("Select at least one target for each enabled option and load its module before previewing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(controller.isBusy)
    }

    @ViewBuilder
    private var displaySelection: some View {
        if let displays = runtime.displays {
            if displays.displays.isEmpty {
                Text("No displays with readable controls are available. Probe Displays to check connected hardware.")
                    .foregroundStyle(.secondary)
            }
            ForEach(displays.displays) { display in
                let key = display.id.rawValue
                Toggle(display.name, isOn: Binding(
                    get: { brightness[key] != nil },
                    set: { selected in brightness[key] = selected ? display.features[.brightness]?.normalized : nil }
                )).disabled(!display.sceneEligibleFeatures.contains(.brightness))
                if brightness[key] != nil {
                    HStack {
                        Slider(value: Binding(get: { brightness[key] ?? 0.5 }, set: { brightness[key] = $0 }), in: 0...1)
                            .accessibilityLabel("\(display.name) brightness")
                        Text("\(Int((brightness[key] ?? 0) * 100))%").monospacedDigit().frame(width: 44)
                    }
                } else if !display.sceneEligibleFeatures.contains(.brightness) {
                    Text("Brightness must support confirmed reads and writes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Button("Load Display Controls") { run { try await runtime.start(.displays) } }
        moduleRequirement(.displays)
    }

    @ViewBuilder
    private var workspaceSelection: some View {
        if let workspace = runtime.workspace, workspace.isRunning {
            if workspace.arrangements.isEmpty {
                Text("Save an arrangement in Workspace Restore first.").foregroundStyle(.secondary)
            } else {
                Picker("Arrangement", selection: Binding(
                    get: { workspace.selectedArrangementID },
                    set: { workspace.selectedArrangementID = $0; selectedWindows = [] }
                )) {
                    Text("Choose an arrangement").tag(Optional<UUID>.none)
                    ForEach(workspace.arrangements) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Preview Windows") {
                    run {
                        selectedWindows = []
                        await workspace.makePreview()
                        if let error = workspace.errorMessage { throw PresentationError.recoveryRequired(error) }
                    }
                }
                ForEach(workspace.preview) { item in
                    Toggle(item.placement.label, isOn: Binding(
                        get: { selectedWindows.contains(item.id) },
                        set: { selected in
                            if selected { selectedWindows.insert(item.id) } else { selectedWindows.remove(item.id) }
                        }
                    )).disabled(!item.canRestore)
                    if let reason = item.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if let before = item.currentFrame, let after = item.targetFrame, item.canRestore {
                        Text("\(PresentationLabels.frame(before)) to \(PresentationLabels.frame(after))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Choose Windows and Displays in Workspace Restore") { run { try await runtime.open(.workspace) } }
        } else {
            Button("Load Workspace Restore") { run { try await runtime.start(.workspace) } }
        }
        moduleRequirement(.workspace)
    }

    @ViewBuilder
    private var soundSelection: some View {
        if let sound = runtime.usableSound {
            Picker("Output", selection: $outputUID) {
                Text("Choose an output").tag("")
                ForEach(sound.audioEngine.deviceMonitor.outputDevices) { Text($0.name).tag($0.uid) }
            }
            HStack {
                Text("Volume")
                Slider(value: $outputVolume, in: 0...1).accessibilityLabel("Presentation output volume")
                Text("\(Int(outputVolume * 100))%").monospacedDigit().frame(width: 44)
            }
            Toggle("Set output mute", isOn: $setMute)
            if setMute { Toggle("Muted", isOn: $muted) }
        } else {
            Button("Load Sound Controls") {
                run {
                    try await runtime.start(.sound)
                    outputUID = runtime.usableSound?.deviceVolumeMonitor.defaultDeviceUID ?? ""
                }
            }
        }
        moduleRequirement(.sound)
    }

    private var reviewedSession: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let draft = controller.draft {
                Text(controller.phase == .active ? "Active session" : controller.phase == .recoveryRequired
                    ? "Session needs recovery" : "Reviewed settings").font(.headline)
                Text("Requested duration: \(draft.duration.title)\(draft.keepsDisplayAwake ? ", including display wake" : "").")
            }
            if let deadline = controller.deadline, controller.phase == .active || controller.phase == .starting {
                Text("Ends at \(deadline.formatted(date: .omitted, time: .shortened))").font(.headline)
            }
            if let preview = controller.scenePreview {
                ForEach(Array(preview.entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PresentationLabels.control(entry.control, names: controller.draft?.controlNames ?? [:]))
                        Text("\(valueTitle(entry.snapshotValue)) to \(valueTitle(entry.targetValue))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(preview.requiredFailures.enumerated()), id: \.offset) { _, failure in
                    Text("\(PresentationLabels.control(failure.control, names: controller.draft?.controlNames ?? [:])): \(PresentationLabels.reason(failure.reason))")
                        .foregroundStyle(.orange)
                }
            }
            if let plan = controller.draft?.workspacePlan {
                Text("Selected windows").font(.headline)
                ForEach(plan.steps) { item in
                    Text(item.placement.label)
                    if let before = item.currentFrame, let after = item.targetFrame {
                        Text("\(PresentationLabels.frame(before)) to \(PresentationLabels.frame(after))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if controller.phase == .preview {
                    Button("Start Presentation") { run { try await controller.start() } }
                        .buttonStyle(.borderedProminent).disabled(!controller.canStart)
                    Button("Edit Selection") { run { try await controller.stop() } }
                } else {
                    Button(controller.phase == .recoveryRequired ? "Retry Cleanup" : "End and Restore") {
                        run { try await controller.stop() }
                    }
                    Button("Keep Current Setup…") { confirmation = true }
                }
            }.disabled(controller.isBusy)
        }
    }

    private func moduleRequirement(_ id: UtilityModuleID) -> some View {
        Group {
            if runtime.registry.state(for: id)?.presence != .added {
                Text("Add \(runtime.registry.descriptor(for: id)?.title ?? id.rawValue) in Modules first.")
            } else if runtime.registry.pausedModuleIDs.contains(id) {
                Text("Resume \(runtime.registry.descriptor(for: id)?.title ?? id.rawValue) in Modules first.")
            }
        }.font(.caption).foregroundStyle(.orange)
    }

    private var selectionReady: Bool {
        (!useDisplays || !brightness.isEmpty)
            && (!useWorkspace || !selectedWindows.isEmpty)
            && (!useSound || (!outputUID.isEmpty && runtime.usableSound != nil))
    }

    private func prepare() {
        run {
            var actions: [SceneAction] = []
            if useDisplays {
                actions += brightness.sorted { $0.key < $1.key }.map {
                    SceneAction(control: .displayBrightness(displayID: $0.key), target: .number($0.value), importance: .required)
                }
            }
            if useSound {
                actions += [
                    SceneAction(control: .audioOutputDevice, target: .text(outputUID), importance: .required),
                    SceneAction(control: .audioOutputVolume(deviceID: outputUID), target: .number(outputVolume), importance: .required)
                ]
                if setMute {
                    actions.append(SceneAction(control: .audioOutputMuted(deviceID: outputUID), target: .boolean(muted), importance: .required))
                }
            }
            let workspace = useWorkspace ? runtime.workspace : nil
            if useWorkspace, workspace == nil { throw PresentationError.invalidSelection }
            let plan = try workspace?.makeRestorePlan(selectedSlotIDs: selectedWindows)
            let scene = actions.isEmpty ? nil : SemperScene(name: "Presentation", actions: actions)
            var controlNames: [SceneControl: String] = [:]
            for display in runtime.displays?.displays ?? [] {
                controlNames[.displayBrightness(displayID: display.id.rawValue)] = "\(display.name) brightness"
                controlNames[.displayContrast(displayID: display.id.rawValue)] = "\(display.name) contrast"
            }
            var deviceNames: [String: String] = [:]
            for device in runtime.usableSound?.audioEngine.deviceMonitor.outputDevices ?? [] {
                deviceNames[device.uid] = device.name
                controlNames[.audioOutputVolume(deviceID: device.uid)] = "\(device.name) volume"
                controlNames[.audioOutputMuted(deviceID: device.uid)] = "\(device.name) mute"
            }
            try await controller.prepare(
                PresentationDraft(duration: duration, keepsDisplayAwake: keepDisplayAwake, scene: scene, workspacePlan: plan,
                    controlNames: controlNames, deviceNames: deviceNames),
                workspace: workspace)
        }
    }

    private func valueTitle(_ value: SceneValue) -> String {
        if case .text(let uid) = value, let name = controller.draft?.deviceNames[uid] { return name }
        return PresentationLabels.value(value)
    }

    private func workspaceResults(_ receipt: WorkspaceOperationReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window results").font(.headline)
            ForEach(Array(receipt.steps.enumerated()), id: \.offset) { _, step in
                Text("\(step.step.placement.label): \(PresentationLabels.workspace(step))").font(.callout)
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { errorMessage = nil; try await action() }
            catch is CancellationError { errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

enum PresentationLabels {
    static func control(_ control: SceneControl, names: [SceneControl: String] = [:]) -> String {
        if let name = names[control] { return name }
        return switch control {
        case .awakeMode: "Awake"
        case .audioOutputDevice: "Sound output"
        case .audioOutputVolume: "Output volume"
        case .audioOutputMuted: "Output mute"
        case .displayBrightness(let id): "Display \(id) brightness"
        case .displayContrast(let id): "Display \(id) contrast"
        }
    }

    static func value(_ value: SceneValue) -> String {
        switch value {
        case .number(let number): "\(Int((number * 100).rounded()))%"
        case .boolean(let enabled): enabled ? "On" : "Off"
        case .text(let text): text
        case .awake(let state): state.rawValue
        }
    }

    static func reason(_ reason: SceneSkipReason) -> String {
        switch reason {
        case .capability(let capability): "Control is \(capability.rawValue)."
        case .targetUnavailable(let reason), .readFailed(let reason), .writeFailed(let reason): reason
        }
    }

    static func frame(_ frame: CGRect) -> String {
        "\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.width)) × \(Int(frame.height))"
    }

    static func restore(_ outcome: SceneRestoreOutcome, names: [SceneControl: String] = [:]) -> String {
        switch outcome {
        case .restored(let setting): "\(control(setting, names: names)): restored."
        case .skippedDrift(let setting, _): "\(control(setting, names: names)): later manual change preserved."
        case .skippedUnavailable(let setting): "\(control(setting, names: names)): unavailable, left unchanged."
        case .untouched(let setting): "\(control(setting, names: names)): no write was made."
        case .alreadySettled(let setting): "\(control(setting, names: names)): recovery already settled."
        case .failed(let setting, let reason): "\(control(setting, names: names)): \(reason)"
        }
    }

    static func workspace(_ step: WorkspaceStepReceipt) -> String {
        switch step.recovery {
        case .pending: return "Change recorded; restore still available."
        case .manualRecoveryRequired: return "Write could not be verified. Manual recovery required."
        case .manualChangePreserved: return "Later manual change preserved."
        case .none:
            switch step.outcome {
            case .restored, .alreadyRestored: return "Restored and verified."
            case .applied, .unchanged: return "Target verified."
            case .constrained: return "The app constrained the requested frame."
            case .cancelled, .notAttempted: return "No completed write."
            case .skipped(let issue), .failed(let issue): return workspaceIssue(issue)
            }
        }
    }

    private static func workspaceIssue(_ issue: WorkspaceOperationIssue) -> String {
        switch issue {
        case .stopped: "Workspace is stopped."
        case .busy: "Another Workspace operation owns this window."
        case .mutationsBlocked: "End Away before moving windows."
        case .invalidPlan: "The preview or recovery receipt is no longer valid."
        case .permission: "Accessibility access is unavailable."
        case .unresolved: "Choose a supported window in Workspace Restore."
        case .missingWindow: "The original window is unavailable."
        case .changedFrame: "The window changed after preview."
        case .changedDisplays: "The original display setup changed."
        case .unsupported(let issue): issue.message
        case .writeFailed: "The window move failed."
        case .unverifiedReadback: "The window move could not be verified."
        case .manualRecoveryRequired: "Manual window recovery is required."
        case .manualChangePreserved: "Later manual change preserved."
        }
    }
}
