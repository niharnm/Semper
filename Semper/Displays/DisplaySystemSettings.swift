import AppKit
import Foundation

@MainActor
protocol DisplaySettingsURLOpening: AnyObject {
    @discardableResult
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: DisplaySettingsURLOpening {}

@MainActor
struct DisplaySystemSettingsOpener {
    static let displaysSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"
    )

    private let workspace: any DisplaySettingsURLOpening

    init(workspace: any DisplaySettingsURLOpening = NSWorkspace.shared) {
        self.workspace = workspace
    }

    @discardableResult
    func open() -> Bool {
        guard let url = Self.displaysSettingsURL else { return false }
        return workspace.open(url)
    }
}
