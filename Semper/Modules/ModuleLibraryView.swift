import SwiftUI

enum ModuleLibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case added = "Added"
    case available = "Available"

    var id: String { rawValue }

    @MainActor
    func modules(in registry: ModuleRegistry, matching query: String = "") -> [UtilityModuleDescriptor] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return registry.modules.filter { module in
            let presence = registry.state(for: module.id)?.presence
            let included =
                switch self {
                case .all: true
                case .added: presence == .added
                case .available: presence == .available
                }
            let searchableText = "\(module.title) \(module.summary)"
            return included && terms.allSatisfy { searchableText.localizedStandardContains(String($0)) }
        }
    }
}

struct ModuleLibraryView: View {
    let registry: ModuleRegistry
    let lifecycle: UtilityLifecycle
    let pause: (UtilityModuleID) async throws -> Void
    let remove: (UtilityModuleID) async throws -> Void
    var mutationDisabledReason: String?
    var open: ((UtilityModuleID) -> Void)? = nil
    @State private var message: String?
    @State private var searchText = ""
    @State private var filter = ModuleLibraryFilter.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Modules").font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose the controls you use on your Mac.").foregroundStyle(.secondary)
                }
                if let mutationDisabledReason {
                    Label(mutationDisabledReason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search modules", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .accessibilityLabel("Search modules")
                        .onExitCommand { searchText = "" }
                    Picker("Show modules", selection: $filter) {
                        ForEach(ModuleLibraryFilter.allCases) { option in
                            Text("\(option.rawValue) (\(option.modules(in: registry).count))").tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Show modules")
                    Text(
                        "Adding a module starts no background work and requests no permission. Removing it keeps its saved data."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                let modules = filter.modules(in: registry, matching: searchText)
                if modules.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(modules) { module in
                            moduleCard(module)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (filter == .added ? "No modules added" : "No modules available")
                    : "No matching modules",
                systemImage: "square.grid.2x2"
            )
        } description: {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Try a tool name or what it does, such as audio, windows, or files.")
            } else if filter == .added {
                Text("Browse the library and add the tools you want to use.")
            } else if filter == .available {
                Text("There are no more modules to add on this Mac. Choose All to view the library.")
            } else {
                Text("Modules supported on this Mac will appear here.")
            }
        } actions: {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Clear Search") { searchText = "" }
            }
            if filter != .all {
                Button("Show All Modules") { filter = .all }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func moduleCard(_ module: UtilityModuleDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: module.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.title).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(statusText(for: module.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(module.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = attentionReason(for: module.id) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if registry.state(for: module.id)?.presence == .added, let open {
                    Button("Open") { open(module.id) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Open \(module.title)")
                        .disabled(lifecycle.isShuttingDown)
                }
                Spacer(minLength: 0)
                controls(for: module.id)
            }
            .controlSize(.small)
            Divider()
            DisclosureGroup("Permissions, activity and data") {
                moduleDetails(for: module)
                    .font(.callout)
                    .padding(.top, 10)
            }
            .font(.caption)
            .accessibilityLabel("Permissions, activity and data for \(module.title)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
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
                            .accessibilityLabel("Retry stopping \(registry.descriptor(for: id)?.title ?? id.rawValue)")
                    } else if registry.pausedModuleIDs.contains(id) {
                        Button("Resume") { change { try registry.resume(id) } }
                            .accessibilityLabel("Resume \(registry.descriptor(for: id)?.title ?? id.rawValue)")
                    } else {
                        Button("Pause") { Task { await changeAsync { try await pause(id) } } }
                            .accessibilityLabel("Pause \(registry.descriptor(for: id)?.title ?? id.rawValue)")
                    }
                    Button("Remove") { Task { await changeAsync { try await remove(id) } } }
                        .accessibilityLabel("Remove \(registry.descriptor(for: id)?.title ?? id.rawValue)")
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
