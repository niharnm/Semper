import SwiftUI

struct UtilityActionList: View {
    let commands: UtilityCommandCenter
    let actions: [UtilityActionDescriptor]
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
                                Text(action.title)
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
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isFavorite(action) ? Color.accentColor : Color.secondary)
                    .accessibilityLabel("\(isFavorite(action) ? "Unpin" : "Pin") \(action.title)")
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
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
            case .cancelled:
                message = "Action cancelled."
                pendingConfirmation = nil
            }
        }
    }
}
