import Foundation

enum SafeEjectCommand: String, Sendable, CaseIterable {
    case open = "storage.open"
}

struct SafeEjectModuleDescriptor: Sendable {
    let id: String
    let name: String
    let purpose: String
    let symbol: String
    let commands: [SafeEjectCommand]
    let surfaces: [String]
    let permissions: [String]
    let backgroundWork: String
    let localDataPolicy: String
    let settingsSchemaVersion: Int
}

enum SafeEjectModule {
    static let descriptor = SafeEjectModuleDescriptor(
        id: "storage", name: "Safe Eject",
        purpose: "Eject selected external storage and check the observed result.",
        symbol: "eject.circle", commands: [.open], surfaces: ["detail"], permissions: [],
        backgroundWork: "Mount, unmount, rename, sleep and wake notifications while running. No polling.",
        localDataPolicy:
            "Up to 20 results in session memory. No persistent storage or diagnostics containing names or paths.",
        settingsSchemaVersion: 1
    )

    @MainActor
    static func handle(_ command: SafeEjectCommand, openDetail: () -> Void) {
        switch command {
        case .open: openDetail()
        }
    }
}
