import SwiftUI

struct WindowLayoutView: View {
    @Bindable var service: WindowLayoutService
    let commands: UtilityCommandCenter
    @State private var confirmKeepCurrent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Window Layout").font(.title2.weight(.semibold))
                Text("Arrange the frontmost app window. When Semper is in front, actions use the last app active while this module was running.")
                    .foregroundStyle(.secondary)
                if let message = service.message {
                    Text(message).textSelection(.enabled)
                        .foregroundStyle(service.requiresPlacementReview ? .orange : .secondary)
                }
                if service.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the window…")
                        Button("Cancel", action: service.cancel).keyboardShortcut(.cancelAction)
                    }
                }
                if service.requiresPlacementReview {
                    Text("Check the affected window before continuing. Its last result is outside automatic restore support or could not be verified.")
                        .font(.callout)
                    Button("Keep Current Placement…") { confirmKeepCurrent = true }
                        .disabled(service.isBusy || !service.isRunning)
                }
                HStack(alignment: .top, spacing: 16) {
                    placementGroup("Halves", actions: WindowLayoutAction.halves)
                    placementGroup("Quarters", actions: WindowLayoutAction.quarters)
                }
                actionList(remainingActions)
                Text(
                    "Halves, quarters and Maximize use the display area available around the Dock and menu bar. Center keeps the current size. Restore returns the last changed window to its immediately preceding placement and skips later manual changes."
                )
                    .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Full-height windows and targets are conservatively refused. This can limit Left Half, Right Half and Maximize when the menu bar and Dock auto-hide, while Top Half, Bottom Half and the quarters use half the usable height. Minimized, unsupported, and unreadable windows also stay unchanged. You can assign optional shortcuts in Settings."
                )
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pausing retains the previous placement. Removing Window Layout or quitting clears that session history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .confirmationDialog("Keep this window placement?", isPresented: $confirmKeepCurrent) {
            Button("Keep Current Placement", role: .destructive) { service.keepCurrentPlacement() }
        } message: {
            Text("This discards the preceding placement record. Arrange the window manually if needed before continuing.")
        }
    }

    private var remainingActions: [WindowLayoutAction] {
        WindowLayoutAction.allCases.filter {
            !WindowLayoutAction.halves.contains($0) && !WindowLayoutAction.quarters.contains($0)
        }
    }

    private func placementGroup(_ title: String, actions: [WindowLayoutAction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            actionList(actions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionList(_ actions: [WindowLayoutAction]) -> some View {
        UtilityActionList(
            commands: commands,
            actions: actions.compactMap { commands.registry.action(for: .init(rawValue: $0.rawValue)) })
    }
}
