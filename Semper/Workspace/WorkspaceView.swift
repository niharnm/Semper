import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var service: WorkspaceService
    @State private var pendingRemoval: UUID?
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Workspace Restore").font(.title2.weight(.semibold))
                        Text("Save where chosen windows belong, then preview before moving them.")
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
                captureSection.disabled(!service.isRunning || service.isBusy || !service.canSave)
                Divider()
                savedSection.disabled(!service.isRunning || service.isBusy)
                if !service.preview.isEmpty {
                    previewSection.disabled(!service.isRunning || service.isBusy)
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
                    ForEach(service.arrangements) { arrangement in
                        Text(arrangement.name).tag(Optional(arrangement.id))
                    }
                }
                HStack {
                    Button("Preview Restore") { Task { await service.makePreview() } }
                    Spacer()
                    Button("Delete Arrangement", role: .destructive) { pendingRemoval = service.selectedArrangementID }
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
            .buttonStyle(.borderedProminent).disabled(!service.canRestore)
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
