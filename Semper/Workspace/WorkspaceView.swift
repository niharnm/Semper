import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var service: WorkspaceService
    var workflowRequest: WorkspaceWorkflowRequest? = nil
    @State private var pendingRemoval: UUID?
    @State private var confirmReset = false
    @State private var previewedRequestID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(workflowTitle).font(.title2.weight(.semibold))
                        Text(workflowDescription)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if service.isRunning {
                        Button("Pause") { Task { await service.pause() } }
                    } else {
                        Button("Start Workspace") { Task { await service.start() } }
                    }
                }
                if !service.isRunning {
                    Text("Workspace is paused. No windows are monitored or moved.").foregroundStyle(.secondary)
                }
                if let error = service.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                if service.permission == .denied || service.permission == .revoked {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            service.permission == .revoked
                                ? "Accessibility access was revoked."
                                : "Accessibility access is needed for window actions.")
                        Button("Open Accessibility Settings") {
                            if let url = URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Text("After enabling access, invoke Capture or Preview again.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }
                if service.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Working on selected windows…")
                        Spacer()
                        Button("Cancel", action: service.cancel)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Prompt after displays change",
                        isOn: Binding(
                            get: { service.topologyPromptsEnabled },
                            set: { enabled in Task { await service.setTopologyPromptsEnabled(enabled) } }
                        )
                    )
                    .disabled(service.isUpdatingTopologyPreference)
                    Text(
                        "While Workspace is running, display changes can offer a fresh preview of the selected arrangement. Windows move only when you choose Restore."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if let notice = service.topologyNotice {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Displays changed", systemImage: "display.2").font(.headline)
                            Text(
                                "Preview \(notice.arrangementName) against the current displays before restoring any windows."
                            )
                            .font(.callout)
                            HStack {
                                Button("Preview Arrangement") {
                                    previewArrangement(noticeID: notice.id)
                                }
                                Button("Dismiss") { service.dismissTopologyNotice(notice.id) }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if workflowRequest?.workflow == .preview || workflowRequest?.workflow == .restore {
                    restoreSections
                    Divider()
                    captureSection.disabled(!service.isRunning || service.isBusy || !service.canSave)
                } else {
                    captureSection.disabled(!service.isRunning || service.isBusy || !service.canSave)
                    Divider()
                    restoreSections
                }
                HStack {
                    Button("Undo Last Restore") { Task { await service.undo() } }.disabled(!service.canUndo)
                    Text("Undo skips windows changed after the restore.").font(.caption).foregroundStyle(.secondary)
                }
                if !service.results.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Window results").font(.headline)
                        ForEach(service.results) { result in
                            HStack(alignment: .top) {
                                Image(systemName: result.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(result.succeeded ? Color.green : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.label).fontWeight(.medium)
                                    Text(result.message).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Divider()
                Text(
                    "Only standard windows exposed by their apps can be restored. Minimized windows are left unchanged. Full-screen windows require manual adjustment. Windows spanning the display height are excluded from automatic restore. A saved slot needs a new explicit window choice after Semper restarts or its original window closes. Some Spaces may not expose their windows."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Delete All Saved Workspace Data", role: .destructive) { confirmReset = true }
                    .disabled(!service.isRunning || service.isBusy)
            }
            .padding(24)
        }
        .frame(minWidth: 540, minHeight: 440)
        .onChange(of: workflowRequest, initial: true) { _, request in
            previewedRequestID = nil
            if let request { service.beginWorkflow(request) }
        }
        .onChange(of: service.selectedArrangementID) { _, _ in previewedRequestID = nil }
        .confirmationDialog(
            "Delete this saved arrangement?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Delete Arrangement", role: .destructive) {
                if let id = pendingRemoval { Task { await service.removeArrangement(id) } }
                pendingRemoval = nil
            }
        } message: {
            Text("This removes the saved layout. It does not move any windows.")
        }
        .confirmationDialog("Delete all saved workspace data?", isPresented: $confirmReset) {
            Button("Delete Workspace Data", role: .destructive) { Task { await service.resetSavedData() } }
        } message: {
            Text("Saved arrangements, live bindings, and undo records will be cleared. Windows stay where they are.")
        }
    }

    private var workflowTitle: String {
        switch workflowRequest?.workflow {
        case .capture: "Capture workspace"
        case .preview: "Preview workspace"
        case .restore: "Restore workspace"
        case nil: "Workspace Restore"
        }
    }

    private var workflowDescription: String {
        switch workflowRequest?.workflow {
        case .capture: "Choose apps and name an arrangement, then capture their current window positions."
        case .preview: "Choose a saved arrangement to preview against open windows and current displays."
        case .restore: "Choose an arrangement, create a fresh preview, then restore its resolved windows."
        case nil: "Save where chosen windows belong, then preview before moving them."
        }
    }

    @ViewBuilder
    private var restoreSections: some View {
        savedSection.disabled(!service.isRunning || service.isBusy)
        if !service.preview.isEmpty {
            previewSection.disabled(!service.isRunning || service.isBusy)
        }
    }

    private func previewArrangement(noticeID: UUID? = nil) {
        let requestID = workflowRequest?.id
        let arrangementID = service.selectedArrangementID
        Task {
            let succeeded: Bool
            if let noticeID {
                succeeded = await service.previewTopologyNotice(noticeID)
            } else {
                succeeded = await service.makePreview(requestID: requestID)
            }
            guard succeeded, workflowRequest?.id == requestID, service.selectedArrangementID == arrangementID else {
                return
            }
            previewedRequestID = requestID
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Capture an arrangement").font(.headline)
                Spacer()
                Button("Refresh Apps") { Task { await service.refreshApplications() } }
            }
            TextField("Arrangement name", text: $service.arrangementName).textFieldStyle(.roundedBorder)
            if service.applications.isEmpty { Text("No eligible apps are running.").foregroundStyle(.secondary) }
            ForEach(service.applications) { app in
                Toggle(
                    app.name,
                    isOn: Binding(
                        get: { service.selectedApplicationIDs.contains(app.id) },
                        set: { selected in
                            if selected {
                                service.selectedApplicationIDs.insert(app.id)
                            } else {
                                service.selectedApplicationIDs.remove(app.id)
                            }
                        }))
            }
            Button("Capture Selected Apps") { Task { await service.capture() } }
                .disabled(
                    service.selectedApplicationIDs.isEmpty
                        || service.arrangementName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(
                "Capturing saves only window positions and app identities. Accessibility is requested when first needed."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved arrangements").font(.headline)
            if service.arrangements.isEmpty {
                Text("Capture an arrangement to add it here.").foregroundStyle(.secondary)
            } else {
                Picker("Arrangement", selection: $service.selectedArrangementID) {
                    Text("Choose an arrangement").tag(Optional<UUID>.none)
                    ForEach(service.arrangements) { arrangement in
                        Text(arrangement.name).tag(Optional(arrangement.id))
                    }
                }
                HStack {
                    Button(workflowRequest?.workflow == .restore ? "Preview Before Restoring" : "Preview Arrangement") {
                        previewArrangement()
                    }
                    .disabled(service.selectedArrangementID == nil)
                    Spacer()
                    Button("Delete Arrangement", role: .destructive) { pendingRemoval = service.selectedArrangementID }
                        .disabled(service.selectedArrangementID == nil)
                }
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore preview").font(.headline)
            Text("Windows move in the order shown. Resolve any missing windows or displays, then apply the preview.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(service.preview.enumerated()), id: \.element.id) { index, item in
                WorkspaceSlotRow(service: service, item: item, ordinal: index + 1)
            }
            Button(
                service.preview.filter(\.canRestore).count == 1
                    ? "Restore 1 Resolved Window"
                    : "Restore \(service.preview.filter(\.canRestore).count) Resolved Windows"
            ) { Task { await service.restore() } }
            .buttonStyle(.borderedProminent)
            .disabled(
                !service.canRestore
                    || (workflowRequest?.workflow == .restore && previewedRequestID != workflowRequest?.id))
        }
    }
}

private struct WorkspaceSlotRow: View {
    @Bindable var service: WorkspaceService
    let item: WorkspacePreviewItem
    let ordinal: Int
    @State private var editedLabel = ""
    @State private var editingLabel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(ordinal). \(item.placement.label)").fontWeight(.medium)
                Spacer()
                Button("Rename") {
                    editedLabel = item.placement.label
                    editingLabel = true
                }.controlSize(.small)
            }
            if editingLabel {
                HStack {
                    TextField("Window label", text: $editedLabel)
                    Button("Save Label") {
                        Task { await service.renameSlot(item.id, label: editedLabel) }
                        editingLabel = false
                    }
                    Button("Cancel") { editingLabel = false }
                }
            }
            Picker(
                "Current window",
                selection: Binding(
                    get: { item.boundWindowID },
                    set: { id in
                        Task { await service.bind(slotID: item.id, to: id) }
                    })
            ) {
                Text("Choose a window").tag(Optional<WorkspaceWindowID>.none)
                ForEach(
                    service.candidates.compactMap { snapshot -> WorkspaceWindowChoice? in
                        guard let id = snapshot.id, snapshot.application.bundleID == item.placement.applicationBundleID
                        else { return nil }
                        return WorkspaceWindowChoice(id: id, label: snapshot.label, issue: snapshot.issue)
                    }
                ) { choice in
                    Text(choice.label + (choice.issue == nil ? "" : " (unavailable)")).tag(Optional(choice.id))
                }
            }
            Picker(
                "Destination display",
                selection: Binding(
                    get: { service.displayMappings[item.placement.displayID] ?? item.placement.displayID },
                    set: { id in
                        Task { await service.mapDisplay(item.placement.displayID, to: id) }
                    })
            ) {
                if !service.displays.contains(where: { $0.id == item.placement.displayID }) {
                    Text("\(item.placement.displayName) (missing)").tag(item.placement.displayID)
                }
                ForEach(service.displays) { display in Text(display.name).tag(display.id) }
            }
            if let reason = item.reason {
                Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let target = item.targetFrame {
                Text(
                    "Target: x \(Int(target.minX)), y \(Int(target.minY)), \(Int(target.width)) × \(Int(target.height)) points"
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WorkspaceWindowChoice: Identifiable {
    let id: WorkspaceWindowID
    let label: String
    let issue: WorkspaceWindowIssue?
}
