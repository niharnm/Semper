import Foundation

enum AwakeMode: String, Codable, CaseIterable, Sendable {
    case system
    case displayAndSystem

    var activityOptions: ProcessInfo.ActivityOptions {
        switch self {
        case .system:
            return [.idleSystemSleepDisabled]
        case .displayAndSystem:
            return [.idleDisplaySleepDisabled, .idleSystemSleepDisabled]
        }
    }

    var activityReason: String {
        switch self {
        case .system:
            return "Semper is preventing system sleep."
        case .displayAndSystem:
            return "Semper is preventing display and system sleep."
        }
    }
}

enum AwakeApplyResult: Equatable, Sendable {
    case applied
    case unchanged
    case failed
}

@MainActor
protocol AwakeActivityProviding: AnyObject {
    func beginActivity(
        options: ProcessInfo.ActivityOptions,
        reason: String
    ) -> NSObjectProtocol?

    func endActivity(_ activity: NSObjectProtocol)
}

@MainActor
final class ProcessInfoAwakeActivityProvider: AwakeActivityProviding {
    private let processInfo: ProcessInfo

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    func beginActivity(
        options: ProcessInfo.ActivityOptions,
        reason: String
    ) -> NSObjectProtocol? {
        processInfo.beginActivity(options: options, reason: reason)
    }

    func endActivity(_ activity: NSObjectProtocol) {
        processInfo.endActivity(activity)
    }
}

@Observable
@MainActor
final class AwakeController {
    private(set) var activeMode: AwakeMode?

    var isActive: Bool {
        activeMode != nil
    }

    private let activityProvider: AwakeActivityProviding
    private var activity: NSObjectProtocol?

    init(activityProvider: AwakeActivityProviding = ProcessInfoAwakeActivityProvider()) {
        self.activityProvider = activityProvider
    }

    @discardableResult
    func apply(_ mode: AwakeMode) -> AwakeApplyResult {
        guard activeMode != mode else {
            return .unchanged
        }

        guard let replacement = activityProvider.beginActivity(
            options: mode.activityOptions,
            reason: mode.activityReason
        ) else {
            return .failed
        }

        let previous = activity
        activity = replacement
        activeMode = mode

        if let previous {
            activityProvider.endActivity(previous)
        }

        return .applied
    }

    func stop() {
        guard let ownedActivity = activity else {
            activeMode = nil
            return
        }

        activity = nil
        activeMode = nil
        activityProvider.endActivity(ownedActivity)
    }
}
