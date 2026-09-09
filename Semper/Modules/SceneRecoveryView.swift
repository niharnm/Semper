import SwiftUI

struct SceneRecoveryView: View {
    @Bindable var manager: SceneManager
    @State private var confirmKeep = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover the previous setup").font(.title2.weight(.semibold))
            Text("A scene recovery record remains. Restore its settings where available, or explicitly keep the current setup.")
                .foregroundStyle(.secondary)
            if let message = message ?? manager.statusMessage { Text(message).textSelection(.enabled) }
            HStack {
                Button("Restore Previous Setup") { recover(keepingCurrent: false) }
                Button("Keep Current Setup…") { confirmKeep = true }
            }.disabled(manager.isBusy || !manager.hasPendingRestore)
            if manager.isBusy { ProgressView().controlSize(.small) }
            Text("Restore preserves later manual changes. Missing controls stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(24)
        .confirmationDialog("Keep the current setup?", isPresented: $confirmKeep) {
            Button("Keep Current Setup", role: .destructive) { recover(keepingCurrent: true) }
        } message: {
            Text("This removes the pending scene recovery record. Its earlier settings will no longer be available to restore.")
        }
    }

    private func recover(keepingCurrent: Bool) {
        Task { @MainActor in
            do { message = try await manager.recoverPendingScene(keepingCurrent: keepingCurrent).message }
            catch { message = error.localizedDescription }
        }
    }
}
