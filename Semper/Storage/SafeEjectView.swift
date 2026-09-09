import SwiftUI

struct SafeEjectView: View {
    @Bindable var service: SafeEjectService
    @State private var selection: SafeEjectVolume?
    @State private var request: SafeEjectVolume?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label("Safe Eject", systemImage: "eject.circle")
                        .font(.headline)
                    Spacer()
                    if service.state == .running {
                        Button("Refresh", systemImage: "arrow.clockwise") { service.refresh() }
                            .disabled(service.activeVolumeID != nil)
                        Button("Pause") { service.pause() }
                    } else if service.state == .paused {
                        Button("Start") { service.start() }
                    }
                }
                Text(
                    "Choose a mounted volume to eject. Semper cannot measure current file activity or predict whether macOS will allow eject."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let failure = service.inventoryFailure {
                Section { Label(failure.message, systemImage: "exclamationmark.triangle") }
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
                    Button("Clear results") { service.clearResults() }
                } header: {
                    Text("Recent results")
                } footer: {
                    Text("Names and results stay in memory for this session. No drive history is saved.")
                }
            }
        }
        .formStyle(.grouped)
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
        .task(id: request?.id) {
            guard let request else { return }
            await service.eject(request)
            self.request = nil
        }
    }
}
