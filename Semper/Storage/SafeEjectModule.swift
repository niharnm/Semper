import Foundation

enum SafeEjectCommand: String, Sendable, CaseIterable {
    case open = "storage.open"
    case ejectAllEligible = "storage.ejectAllEligible"

    var title: String {
        switch self {
        case .open: "Open Safe Eject"
        case .ejectAllEligible: "Review all eligible volumes"
        }
    }
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
        purpose: "Review external storage to eject and check each observed result.",
        symbol: "eject.circle", commands: SafeEjectCommand.allCases, surfaces: ["detail"], permissions: [],
        backgroundWork: "Mount, unmount, rename, sleep and wake notifications while running. No polling.",
        localDataPolicy:
            "Up to 20 recent results and one batch report in session memory. No persistent storage or diagnostics containing names or paths.",
        settingsSchemaVersion: 1
    )

    @MainActor
    static func handle(_ command: SafeEjectCommand, service: SafeEjectService, openDetail: () -> Void) throws {
        defer { openDetail() }
        switch command {
        case .open: break
        case .ejectAllEligible: _ = try service.prepareBatch().get()
        }
    }
}
