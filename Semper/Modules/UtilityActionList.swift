import SwiftUI

struct UtilityActionList: View {
    let commands: UtilityCommandCenter
    let actions: [UtilityActionDescriptor]
    var showsModuleName = false
    var selectedActionID: UtilityActionID?
    var activationRequest = 0
    @State private var pendingConfirmation: UtilityActionDescriptor?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actions) { action in
                HStack(spacing: 10) {
                    Button {
                        execute(action)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: action.symbolName).frame(width: 20).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(action.title).font(.callout.weight(.medium))
                                if showsModuleName, let module = commands.registry.descriptor(for: action.module) {
                                    Text(module.title).font(.caption).foregroundStyle(.secondary)
                                }
                                if let reason = commands.disabledReason(for: action.id) {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if commands.running.contains(action.id) { ProgressView().controlSize(.small) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                    .accessibilityValue(commands.disabledReason(for: action.id) ?? "")
                    .disabled(commands.disabledReason(for: action.id) != nil)
                    Button {
                        do {
                            try commands.registry.setFavorite(!isFavorite(action), for: action.id)
                            message = nil
                        } catch ModuleRegistryError.favoriteLimitReached {
                            message = "You can pin up to four actions. Unpin one first."
                        } catch {
                            message = error.localizedDescription
                        }
                    } label: {
                        Image(systemName: isFavorite(action) ? "star.fill" : "star")
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isFavorite(action) ? Color.accentColor : Color.secondary)
                    .accessibilityLabel("\(isFavorite(action) ? "Unpin" : "Pin") \(action.title)")
                    .help("\(isFavorite(action) ? "Unpin" : "Pin") \(action.title)")
                }
                .padding(10)
                .background(
                    selectedActionID == action.id
                        ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    if selectedActionID == action.id {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1)
                    }
                }
                .id(action.id)
                .accessibilityAddTraits(selectedActionID == action.id ? .isSelected : [])
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .onChange(of: activationRequest) { _, _ in
            guard pendingConfirmation == nil,
                let action = actions.first(where: { $0.id == selectedActionID })
            else { return }
            execute(action)
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "Confirm action",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ), titleVisibility: .visible
        ) {
            if let action = pendingConfirmation {
                Button(action.title, role: .destructive) { execute(action, confirmed: true) }
                Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            }
        } message: {
            Text(pendingConfirmation?.confirmationMessage ?? "")
        }
    }

    private func isFavorite(_ action: UtilityActionDescriptor) -> Bool {
        commands.registry.favoriteIDs.contains(action.id)
    }

    private func execute(_ action: UtilityActionDescriptor, confirmed: Bool = false) {
        Task {
            let result = await commands.execute(action.id, confirmed: confirmed)
            switch result {
            case .confirmationRequired: pendingConfirmation = action
            case .failed(let reason), .unavailable(let reason): message = reason
            case .completed:
                message = nil
                pendingConfirmation = nil
            case .accepted:
                message = "Action accepted."
                pendingConfirmation = nil
            case .cancelled:
                message = "Action cancelled."
                pendingConfirmation = nil
            }
        }
    }
}

enum UtilityActionSelection {
    static func reconciled(_ selection: UtilityActionID?, among ids: [UtilityActionID]) -> UtilityActionID? {
        if let selection, ids.contains(selection) { return selection }
        return ids.first
    }

    static func moved(from selection: UtilityActionID?, by direction: Int, among ids: [UtilityActionID])
        -> UtilityActionID?
    {
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            return direction < 0 ? ids.last : ids.first
        }
        return ids[min(max(index + direction, 0), ids.count - 1)]
    }
}
