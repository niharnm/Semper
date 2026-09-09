import Foundation

nonisolated struct ShelfModuleRegistration: Sendable {
    let id = "shelf"
    let title = "File Shelf"
    let purpose = "Hold temporary files, links, images, and text between apps."
    let symbol = "tray"
    let actionIDs = ["shelf.open", "shelf.clear"]
    let surfaces = ["compact", "detail"]
    let permissions = ["Access only to files the user drops or selects"]
    let backgroundWork = "One expiry task while enabled; file reads only for requested imports and checksums."
    let localData = "Session only by default; optional local version 1 store with explicit opt-in."
    let dependencies: [String] = []
    let conflicts: [String] = []
    let settingsSchemaVersion = 1
}

nonisolated enum ShelfCommand: String, Sendable {
    case open = "shelf.open"
    case clear = "shelf.clear"
}

@MainActor
struct ShelfCommandHandler {
    let service: ShelfService
    let openDetail: () -> Void
    func execute(_ command: ShelfCommand) async {
        switch command {
        case .open: openDetail()
        case .clear: await service.clear()
        }
    }
}
