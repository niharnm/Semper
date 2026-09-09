import KeyboardShortcuts
import SwiftUI

@MainActor
struct ScenesTab: View {
    @Bindable var sceneManager: SceneManager
    @Bindable var shortcutRegistry: SceneShortcutRegistry

    @State private var sceneName = ""
    @State private var deletionCandidate: SemperScene?
    @State private var showsKeepCurrentConfirmation = false
    @State private var replacementName: String?
    @FocusState private var nameFieldFocused: Bool

    private var trimmedSceneName: String {
        sceneName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                createSection
                savedScenesSection
                restoreSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .confirmationDialog(
            "Delete \(deletionCandidate?.name ?? "scene")?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { isPresented in
                    if !isPresented { deletionCandidate = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let scene = deletionCandidate else { return }
                deletionCandidate = nil
                sceneManager.delete(scene: scene)
            }
            Button("Cancel", role: .cancel) {
                deletionCandidate = nil
            }
        } message: {
            Text("This removes the saved scene. It does not change the current system setup.")
        }
        .confirmationDialog(
            "Keep the current setup?",
            isPresented: $showsKeepCurrentConfirmation,
            titleVisibility: .visible
        ) {
            Button("Keep Current", role: .destructive) {
                sceneManager.keepCurrentSetup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Semper will remove the saved restore point. Current settings will not change.")
        }
        .confirmationDialog(
            "Replace \(replacementName ?? "scene")?",
            isPresented: Binding(
                get: { replacementName != nil },
                set: { isPresented in
                    if !isPresented { replacementName = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                guard let name = replacementName else { return }
                replacementName = nil
                save(name: name, replacingExisting: true)
            }
            Button("Cancel", role: .cancel) {
                replacementName = nil
            }
        } message: {
            Text("This replaces the saved settings for that scene. Current settings will not change.")
        }
    }

    private var createSection: some View {
        SettingsSection("Create", subtitle: "Save the setup you are using now") {
            SettingsRow(
                "Scene Name",
                description: "Audio, display, and Awake settings are captured together"
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    TextField("Focus", text: $sceneName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .focused($nameFieldFocused)
                        .onSubmit { saveCurrent() }
                        .disabled(sceneManager.isBusy)
                        .accessibilityLabel("New scene name")

                    Button("Save Current") {
                        saveCurrent()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedSceneName.isEmpty || sceneManager.isBusy)
                }
            }

            if let message = sceneManager.statusMessage {
                SettingsRowDivider()
                SettingsRow("Status", description: message) {
                    if sceneManager.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "info.circle")
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }
            }
        }
    }

    private var savedScenesSection: some View {
        SettingsSection("Saved", subtitle: "Apply or remove a scene") {
            if sceneManager.scenes.isEmpty {
                SettingsRow(
                    "No Saved Scenes",
                    description: "Name the current setup above to create your first scene"
                ) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            } else {
                ForEach(Array(sceneManager.scenes.enumerated()), id: \.element.id) { index, scene in
                    if index > 0 {
                        SettingsRowDivider()
                    }

                    SettingsRow(
                        scene.name,
                        description: actionSummary(for: scene)
                    ) {
                        VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                            KeyboardShortcuts.Recorder(
                                for: shortcutRegistry.name(for: scene.id),
                                onChange: shortcutRegistry.recordCallback(for: scene)
                            )
                            .controlSize(.small)
                            .disabled(sceneManager.isBusy)

                            HStack(spacing: DesignTokens.Spacing.sm) {
                                Button("Apply") {
                                    sceneManager.apply(scene: scene)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(sceneManager.isBusy)

                                Button(role: .destructive) {
                                    deletionCandidate = scene
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(sceneManager.isBusy)
                                .accessibilityLabel("Delete \(scene.name)")
                            }

                            if let message = shortcutRegistry.conflicts[scene.id]
                                ?? shortcutRegistry.persistenceErrors[scene.id] {
                                Text(message)
                                    .font(DesignTokens.Typography.rowDescription)
                                    .foregroundStyle(DesignTokens.Colors.systemOrange)
                            }
                        }
                    }
                }
            }
        }
    }

    private var restoreSection: some View {
        SettingsSection("Restore", subtitle: "Return settings changed by the active scene") {
            SettingsRow(
                "Previous Setup",
                description: sceneManager.hasPendingRestore
                    ? "Only settings that still match the scene will be restored"
                    : "Apply a scene to make restore available"
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Restore") {
                        sceneManager.restore()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Keep Current") {
                        showsKeepCurrentConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .disabled(!sceneManager.hasPendingRestore || sceneManager.isBusy)
            }
        }
    }

    private func saveCurrent() {
        let name = trimmedSceneName
        guard !name.isEmpty, !sceneManager.isBusy else { return }

        if sceneManager.scenes.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            replacementName = name
            return
        }

        save(name: name, replacingExisting: false)
    }

    private func save(name: String, replacingExisting: Bool) {
        sceneManager.saveCurrent(
            named: name,
            replacingExisting: replacingExisting
        ) { succeeded in
            guard succeeded,
                  trimmedSceneName.caseInsensitiveCompare(name) == .orderedSame else {
                return
            }
            sceneName = ""
            nameFieldFocused = false
        }
    }

    private func actionSummary(for scene: SemperScene) -> String {
        let count = scene.actions.count
        return count == 1 ? "1 saved setting" : "\(count) saved settings"
    }
}
