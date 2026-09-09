import Foundation

enum WorkspaceCommand: String, CaseIterable, Sendable {
    case capture = "workspace.capture"
    case preview = "workspace.preview"
    case restore = "workspace.restore"
    case undo = "workspace.undo"

    var title: String {
        switch self {
        case .capture: "Capture workspace"
        case .preview: "Preview workspace"
        case .restore: "Restore workspace"
        case .undo: "Undo last workspace restore"
        }
    }
}

enum WorkspaceCommandEffect: Sendable { case openWorkspace, completed }

enum WorkspaceModuleMetadata {
    static let id = "workspace"
    static let name = "Workspace Restore"
    static let purpose = "Return selected app windows to a saved arrangement."
    static let symbol = "macwindow.on.rectangle"
    static let settingsSchemaVersion = 1
    static let minimumOS = "macOS 15.4"
    static let actions = WorkspaceCommand.allCases
    static let surfaces = ["detail"]
    static let permissionReason =
        "Accessibility is used only after an invoked window action to read, move, and resize chosen windows."
    static let backgroundWork =
        "No monitoring or automatic rearrangement. Window operations run only when invoked. Pausing cancels and drains current work."
    static let localDataPolicy =
        "Named arrangements and display-relative slots are saved locally until deleted. No window titles are collected. Live window bindings and undo records last for the current session."
    static let dependencies: [String] = []
    static let conflicts: [String] = []
}

extension WorkspaceService {
    func handle(_ command: WorkspaceCommand) async -> WorkspaceCommandEffect {
        switch command {
        case .capture, .preview, .restore: return .openWorkspace
        case .undo:
            guard canUndo else { return .openWorkspace }
            await undo()
            return .completed
        }
    }
}
