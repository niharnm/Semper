import Foundation
import Testing

@testable import Semper

@MainActor
private final class DisplaySettingsWorkspaceSpy: DisplaySettingsURLOpening {
    var result = true
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return result
    }
}

@Suite("Display System Settings")
@MainActor
struct DisplaySystemSettingsTests {
    @Test("Opener uses the Displays settings destination exactly once")
    func opensDisplaysSettings() throws {
        let workspace = DisplaySettingsWorkspaceSpy()
        let opener = DisplaySystemSettingsOpener(workspace: workspace)

        #expect(opener.open())
        #expect(workspace.openedURLs.count == 1)
        #expect(
            workspace.openedURLs.first?.absoluteString
                == "x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }

    @Test("Workspace rejection is returned to the caller")
    func reportsWorkspaceRejection() {
        let workspace = DisplaySettingsWorkspaceSpy()
        workspace.result = false

        #expect(!DisplaySystemSettingsOpener(workspace: workspace).open())
        #expect(workspace.openedURLs.count == 1)
    }
}
