import SwiftUI

struct ShelfImageCleanupView: View {
    let service: ShelfService
    private var session: ShelfImageCopySession { service.imageCopy }

    var body: some View {
        if session.needsCleanup {
            HStack(alignment: .top) {
                Label("An image operation needs recovery.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Retry Cleanup") {
                    guard session.needsCleanup, let requestID = session.request?.id else { return }
                    Task { await service.cancelImageCopy(requestID: requestID) }
                }
                .disabled(session.isWorking)
            }.font(.callout)
        }
    }
}

struct ShelfImageCopyView: View {
    let service: ShelfService
    private var session: ShelfImageCopySession { service.imageCopy }
    let request: ShelfImageCopyRequest
    @State private var size: ShelfImageCopySize = .pixels1024

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize a Copy").font(.title2.weight(.semibold))
            Text(request.name).font(.headline).lineLimit(2).textSelection(.enabled)
            if let receipt = session.receipt {
                Label("Copy saved", systemImage: "checkmark.circle").foregroundStyle(.green)
                Text("\(receipt.dimensions.width) × \(receipt.dimensions.height) pixels")
                Text(receipt.url.path).font(.callout).textSelection(.enabled)
                Text("The original is unchanged.").foregroundStyle(.secondary)
            } else if let plan = session.plan {
                Text("Original: \(plan.dimensions.width) × \(plan.dimensions.height) pixels")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Longest edge", selection: $size) {
                    ForEach(ShelfImageCopySize.allCases) { option in
                        let output = plan.outputDimensions(for: option)
                        Text("Up to \(option.rawValue) pixels: \(output.width) × \(output.height)")
                            .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(session.isWorking || session.needsCleanup)
                Text(
                    "Smaller images keep their dimensions. The copy keeps its format, orientation, color profile, and PNG transparency."
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(
                    "Camera, location, and other descriptive metadata are removed. JPEG copies are re-encoded with some quality loss."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            if session.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(session.plan == nil ? "Reading image…" : "Saving copy…")
                }.font(.callout)
            }
            if !session.recoveryLocations.isEmpty {
                Text("Locations to check").font(.caption).foregroundStyle(.secondary)
                ForEach(session.recoveryLocations, id: \.self) { url in
                    Text(url.path).font(.caption).textSelection(.enabled)
                }
            }
            if let message = session.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(session.needsCleanup ? "Retry Cleanup" : session.receipt == nil ? "Cancel" : "Done") {
                    Task { await service.cancelImageCopy(requestID: request.id) }
                }
                .keyboardShortcut(session.needsCleanup ? nil : .cancelAction)
                if session.plan != nil && session.receipt == nil {
                    Button("Save Copy…") {
                        if session.request?.id == request.id { session.save(size: size) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isWorking || session.needsCleanup)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(session.isWorking)
    }
}
