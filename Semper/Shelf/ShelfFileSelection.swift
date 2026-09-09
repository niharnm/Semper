import AppKit

@MainActor
protocol ShelfFileChoosing: AnyObject {
    func chooseFiles() async -> [URL]?
    func cancel()
}

@MainActor
final class NativeShelfFileChooser: ShelfFileChoosing {
    private var panel: NSOpenPanel?

    func chooseFiles() async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Add to Shelf"
        panel.message = "Choose files or folders. Original items stay in place."
        self.panel = panel
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                Task { @MainActor in
                    self.panel = nil
                    continuation.resume(returning: response == .OK ? panel.urls : nil)
                }
            }
        }
    }

    func cancel() {
        panel?.cancel(nil)
    }
}
