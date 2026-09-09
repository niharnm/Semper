import SwiftUI

struct SafeEjectView: View {
    @Bindable var service: SafeEjectService
    @State private var selection: SafeEjectVolume?
    @State private var request: SafeEjectVolume?
    @State private var cleanupRequest: UUID?
    @State private var batchRequest: UUID?
    @State private var batchFailure: SafeEjectFailure?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label("Safe Eject", systemImage: "eject.circle")
                        .font(.headline)
                    Spacer()
                    if service.state == .running {
                        Button("Refresh", systemImage: "arrow.clockwise") { service.refresh() }
                            .disabled(service.isEjecting)
                        Button("Pause") {
                            service.pause()
                            cleanupRequest = UUID()
                        }
                        .disabled(cleanupRequest != nil)
                    } else if service.state == .paused {
                        Button("Start") { service.start() }
                            .disabled(service.isEjecting || service.cleanupFailure != nil || cleanupRequest != nil)
                    }
                }
                Text(
                    "Choose a mounted volume to eject. Semper cannot measure current file activity or predict whether macOS will allow eject."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let failure = service.cleanupFailure {
                Section {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                    Button("Retry Cleanup") { cleanupRequest = UUID() }
                        .disabled(cleanupRequest != nil)
                }
            }
            if cleanupRequest != nil {
                Section { ProgressView("Finishing storage checks") }
            }

            if let failure = service.inventoryFailure, failure != .cleanupPending {
                Section { Label(failure.message, systemImage: "exclamationmark.triangle") }
            }
            if let batchFailure {
                Section { Label(batchFailure.message, systemImage: "exclamationmark.triangle") }
            }

            if let progress = service.batchProgress {
                Section("Ejecting reviewed volumes") {
                    ProgressView(value: Double(progress.completedCount), total: Double(progress.total))
                        .accessibilityLabel("Batch eject progress")
                        .accessibilityValue("\(progress.completedCount) of \(progress.total) results checked")
                    Text("\(progress.completedCount) of \(progress.total) results checked")
                    if let volume = progress.currentVolume { Text(volume.name).font(.headline) }
                    Button(progress.isCancelling ? "Cancelling remaining requests" : "Cancel Remaining") {
                        service.cancelBatch()
                    }
                    .disabled(progress.isCancelling)
                    Text("A request already sent to macOS may still finish. Cancellation cannot undo it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Mounted external volumes") {
                if service.state == .paused || service.state == .shutDown {
                    Text("Safe Eject is paused. It is not watching mounted volumes.")
                        .foregroundStyle(.secondary)
                } else if service.state == .sleeping {
                    Text("Waiting for this Mac to wake.")
                        .foregroundStyle(.secondary)
                } else if service.volumes.isEmpty && service.inventoryFailure == nil {
                    ContentUnavailableView(
                        "No external volumes", systemImage: "externaldrive",
                        description: Text("Mounted removable or external storage will appear here."))
                }
                ForEach(service.volumes) { volume in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(volume.name, systemImage: "externaldrive")
                                .lineLimit(2)
                            Spacer()
                            if service.activeVolumeID == volume.id {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel("Checking eject for \(volume.name)")
                            } else {
                                Button("Eject", systemImage: "eject") { selection = volume }
                                    .disabled(service.refusal(for: volume) != nil)
                                    .accessibilityLabel("Eject \(volume.name)")
                            }
                        }
                        if let failure = service.refusal(for: volume), failure != .operationInProgress {
                            Text(failure.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if service.state == .running && !service.volumes.isEmpty {
                    Button("Review All Eligible Volumes…") {
                        switch service.prepareBatch() {
                        case .success: batchFailure = nil
                        case .failure(let failure): batchFailure = failure
                        }
                    }
                    .disabled(service.isEjecting || service.cleanupFailure != nil || cleanupRequest != nil)
                }
            }

            if let result = service.lastBatchResult {
                Section("Last batch") {
                    Text(
                        "\(result.ejectedCount) ejected, \(result.failedCount) incomplete, \(result.notAttemptedCount) not attempted"
                    )
                    DisclosureGroup("Per-volume results") {
                        ForEach(result.items, id: \.volume.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(
                                    item.volume.name,
                                    systemImage: item.outcome.isEjected ? "checkmark.circle" : "exclamationmark.circle"
                                ).font(.headline)
                                Text(item.outcome.message).font(.callout)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    if !result.excluded.isEmpty {
                        Text("\(result.excluded.count) excluded during review.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !service.receipts.isEmpty {
                Section {
                    ForEach(service.receipts) { receipt in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                receipt.volumeName,
                                systemImage: receipt.outcome.isVerified
                                    ? "checkmark.circle" : "exclamationmark.circle"
                            )
                            .font(.headline)
                            Text(receipt.outcome.message).font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Recent results")
                }
            }
            if !service.receipts.isEmpty || service.lastBatchResult != nil {
                Section {
                    Button("Clear All Results") { service.clearResults() }
                } footer: {
                    Text("Names and results stay in memory for this session. No drive history is saved.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(
            item: Binding(
                get: { service.pendingBatchConfirmation },
                set: { if $0 == nil { service.discardBatchConfirmation() } }
            )
        ) { confirmation in
            SafeEjectBatchReview(
                confirmation: confirmation,
                confirm: { batchRequest = confirmation.id },
                cancel: { service.discardBatchConfirmation() })
        }
        .confirmationDialog(
            "Eject selected volume?",
            isPresented: Binding(
                get: { selection != nil },
                set: { if !$0 { selection = nil } }
            ), titleVisibility: .visible, presenting: selection
        ) { volume in
            Button("Eject \(volume.name)") { request = volume }
            Button("Cancel", role: .cancel) { selection = nil }
        } message: { volume in
            Text(
                "Unmount \(volume.name), then ask macOS to eject its device. This request will stop if another volume on that device is mounted."
            )
        }
        .task(id: cleanupRequest) {
            guard let cleanupRequest else { return }
            await service.waitForCleanup()
            if self.cleanupRequest == cleanupRequest { self.cleanupRequest = nil }
        }
        .task(id: request?.id) {
            guard let request else { return }
            await service.eject(request)
            self.request = nil
        }
        .task(id: batchRequest) {
            guard let batchRequest else { return }
            switch await service.ejectBatch(confirmationID: batchRequest) {
            case .success: batchFailure = nil
            case .failure(let failure): batchFailure = failure
            }
            if self.batchRequest == batchRequest { self.batchRequest = nil }
        }
    }
}

private struct SafeEjectBatchReview: View {
    let confirmation: SafeEjectBatchConfirmation
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review volumes to eject").font(.title2.weight(.semibold))
            Text("Only the volumes listed here will be requested. Each is checked again before its request.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Included (\(confirmation.eligible.count))").font(.headline)
                    if confirmation.eligible.isEmpty {
                        Text("No volumes are currently eligible.").foregroundStyle(.secondary)
                    }
                    ForEach(confirmation.eligible) { volume in
                        Label(volume.name, systemImage: "externaldrive")
                    }
                    if !confirmation.excluded.isEmpty {
                        Divider()
                        Text("Excluded (\(confirmation.excluded.count))").font(.headline)
                        ForEach(confirmation.excluded, id: \.volume.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.volume.name).fontWeight(.medium)
                                Text(item.reason.message).font(.callout).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            Text(
                "Semper cannot measure current file activity. macOS may refuse a request, and some volumes may remain mounted."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(
                    confirmation.eligible.count == 1
                        ? "Eject 1 Volume" : "Eject \(confirmation.eligible.count) Volumes",
                    action: confirm
                )
                .buttonStyle(.borderedProminent)
                .disabled(confirmation.eligible.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
