import SwiftUI

struct ModuleLibraryView: View {
    let registry: ModuleRegistry
    let lifecycle: UtilityLifecycle
    let pause: (UtilityModuleID) async throws -> Void
    let remove: (UtilityModuleID) async throws -> Void
    var mutationDisabledReason: String?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Modules").font(.title2.bold())
                    Text(
                        "Add the controls you use. Adding a module starts no background work and requests no permission. Removing a module keeps its saved data."
                    )
                    .foregroundStyle(.secondary)
                }
                if let mutationDisabledReason {
                    Text(mutationDisabledReason).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(registry.modules) { module in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: module.symbolName).font(.title3).frame(width: 28)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(module.title).font(.headline)
                                    Text(module.summary).foregroundStyle(.secondary)
                                    Text(statusText(for: module.id))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                controls(for: module.id)
                                    .controlSize(.small)
                            }
                            if let reason = attentionReason(for: module.id) {
                                Text(reason).font(.callout).foregroundStyle(.orange)
                            }
                            DisclosureGroup("Permissions, activity and data") {
                                moduleDetails(for: module)
                                    .padding(.top, 10)
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 14)
                        if module.id != registry.modules.last?.id { Divider() }
                    }
                }
                if let message { Text(message).foregroundStyle(.orange).accessibilityAddTraits(.updatesFrequently) }
            }
            .padding(24)
        }
    }

    private func moduleDetails(for module: UtilityModuleDescriptor) -> some View {
        let details = module.disclosure
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions").fontWeight(.medium)
                if let permissionReasons = details.permissionReasons {
                    if permissionReasons.isEmpty {
                        Text("No additional macOS permission is required.").foregroundStyle(.secondary)
                    } else {
                        ForEach(permissionReasons, id: \.name) { permission in
                            Text("\(permission.name): \(permission.reason)").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Access is checked before an action needs it. Adding this module requests no permission.")
                        .foregroundStyle(.secondary)
                }
                if let state = registry.state(for: module.id) {
                    LabeledContent("Access status", value: state.permission.displayText)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Background activity").fontWeight(.medium)
                Text(details.idleBackgroundPolicy).foregroundStyle(.secondary)
                if let runningPolicy = details.runningBackgroundPolicy {
                    Text(runningPolicy).foregroundStyle(.secondary)
                }
                if let state = registry.state(for: module.id) {
                    LabeledContent(
                        "Current state",
                        value: lifecycle.stopping.contains(module.id) ? "Stopping" : state.runtime.displayText
                    )
                    .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Local data").fontWeight(.medium)
                Text(details.localDataPolicy).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Requirements").fontWeight(.medium)
                Text(details.minimumOS).foregroundStyle(.secondary)
                ForEach(details.hardwareRequirements, id: \.self) { requirement in
                    Text(requirement).foregroundStyle(.secondary)
                }
                if !details.requiredModules.isEmpty {
                    Text("Add these modules before use: \(moduleNames(details.requiredModules)).")
                        .foregroundStyle(.secondary)
                }
                if !details.selectedModules.isEmpty {
                    Text("Needed only for selected actions or targets: \(moduleNames(details.selectedModules)).")
                        .foregroundStyle(.secondary)
                }
                ForEach(details.conflicts, id: \.self) { conflict in
                    Text(conflict).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Included resources").fontWeight(.medium)
                Text("Module code is included with Semper. Removing it does not change the app's installed size.")
                    .foregroundStyle(.secondary)
                switch details.resources {
                case .builtIn:
                    Text("No additional download is needed.").foregroundStyle(.secondary)
                case .optionalDownloads(let description, let sizeBytes):
                    Text(description).foregroundStyle(.secondary)
                    if let sizeBytes {
                        Text(
                            "Download size: \(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Download size varies by catalog and selected resource.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func moduleNames(_ ids: [UtilityModuleID]) -> String {
        ids.map { registry.descriptor(for: $0)?.title ?? $0.rawValue }.joined(separator: ", ")
    }

    private func statusText(for id: UtilityModuleID) -> String {
        guard let state = registry.state(for: id) else { return "Unavailable" }
        if lifecycle.stopping.contains(id) { return "Stopping" }
        switch state.presence {
        case .available: return "Not added"
        case .unsupported: return "Unavailable"
        case .added:
            switch state.runtime {
            case .failed: return registry.pausedModuleIDs.contains(id) ? "Cleanup needed" : "Failed"
            case .limited: return "Needs attention"
            default: return state.runtime.displayText
            }
        }
    }

    private func attentionReason(for id: UtilityModuleID) -> String? {
        switch registry.state(for: id)?.runtime {
        case .failed(let reason), .limited(let reason): reason
        default: nil
        }
    }

    @ViewBuilder
    private func controls(for id: UtilityModuleID) -> some View {
        if let state = registry.state(for: id) {
            switch state.presence {
            case .unsupported(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .available:
                Button("Add") { change { try registry.add(id) } }
                    .disabled(mutationDisabledReason != nil || lifecycle.isShuttingDown)
                    .accessibilityLabel("Add \(registry.descriptor(for: id)?.title ?? id.rawValue)")
                    .fixedSize(horizontal: true, vertical: false)
            case .added:
                HStack {
                    if lifecycle.stopping.contains(id) {
                        ProgressView().controlSize(.small).accessibilityLabel("Stopping module")
                    } else if case .failed = state.runtime, registry.pausedModuleIDs.contains(id) {
                        Button("Retry stop") { Task { await changeAsync { try await pause(id) } } }
                    } else if registry.pausedModuleIDs.contains(id) {
                        Button("Resume") { change { try registry.resume(id) } }
                    } else {
                        Button("Pause") { Task { await changeAsync { try await pause(id) } } }
                    }
                    Button("Remove") { Task { await changeAsync { try await remove(id) } } }
                }
                .disabled(mutationDisabledReason != nil || lifecycle.stopping.contains(id) || lifecycle.isShuttingDown)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func changeAsync(_ action: () async throws -> Void) async {
        do {
            try await action()
            message = nil
        } catch { message = error.localizedDescription }
    }
}

extension ModuleRuntimeState {
    var displayText: String {
        switch self {
        case .stopped: "Stopped"
        case .preparing: "Preparing"
        case .ready: "Ready"
        case .active: "Active"
        case .paused: "Paused"
        case .limited(let reason): "Limited: \(reason)"
        case .failed(let reason): "Failed: \(reason)"
        case .removing: "Removing"
        }
    }
}

extension ModulePermissionState {
    var displayText: String {
        switch self {
        case .unknown: "Checked when needed"
        case .notRequired: "Not required"
        case .notDetermined: "Not requested"
        case .granted: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .revoked: "Revoked"
        }
    }
}
