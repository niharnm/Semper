import Foundation

enum AudioProcessingFailure: String, Equatable, Sendable {
    case aggregateCleanup
    case resourceCleanup
    case settingsPersistence
}

enum AudioProcessingState: Equatable, Sendable {
    case active
    case bypassing
    case bypassed
    case waitingForPermission
    case resuming
    case failed(AudioProcessingFailure)

    var accessibilityValue: String {
        switch self {
        case .active: "Active"
        case .bypassing: "Bypassing"
        case .bypassed: "Bypassed"
        case .waitingForPermission: "Permission required"
        case .resuming: "Resuming"
        case .failed: "Resume failed"
        }
    }
}

struct OrphanedTapCleanupResult: Equatable, Sendable {
    var scannedAggregateCount = 0
    var matchedCount = 0
    var destroyedCount = 0
    var failedCount = 0

    static let empty = OrphanedTapCleanupResult()
}

struct AudioRecoveryDiagnostics: Equatable, Sendable {
    private(set) var bypassAttempts = 0
    private(set) var resumeAttempts = 0
    private(set) var lastCleanup = OrphanedTapCleanupResult.empty
    private(set) var lastResourceCleanup = TapResourceCleanupResult.empty
    private(set) var lastFailure: AudioProcessingFailure?

    init(startupCleanup: OrphanedTapCleanupResult = .empty) {
        lastCleanup = startupCleanup
        lastFailure = startupCleanup.failedCount == 0 ? nil : .aggregateCleanup
    }

    mutating func recordBypass(
        cleanup: OrphanedTapCleanupResult,
        resources: TapResourceCleanupResult
    ) {
        bypassAttempts += 1
        lastCleanup = cleanup
        lastResourceCleanup = resources
        lastFailure = Self.failure(cleanup: cleanup, resources: resources)
    }

    mutating func recordResume(
        cleanup: OrphanedTapCleanupResult,
        resources: TapResourceCleanupResult = .empty
    ) {
        resumeAttempts += 1
        lastCleanup = cleanup
        lastResourceCleanup = resources
        lastFailure = Self.failure(cleanup: cleanup, resources: resources)
    }

    mutating func recordFailure(_ failure: AudioProcessingFailure) {
        lastFailure = failure
    }

    func report(
        state: AudioProcessingState,
        permission: AudioCapturePermissionStatus,
        activeTapCount: Int
    ) -> String {
        let permissionValue: String
        switch permission {
        case .unknown: permissionValue = "unknown"
        case .authorized: permissionValue = "authorized"
        case .denied: permissionValue = "denied"
        }

        return [
            "Semper audio recovery report",
            "Processing state: \(state.accessibilityValue)",
            "Permission: \(permissionValue)",
            "Active tap count: \(activeTapCount)",
            "Bypass attempts: \(bypassAttempts)",
            "Resume attempts: \(resumeAttempts)",
            "Aggregates scanned: \(lastCleanup.scannedAggregateCount)",
            "Semper aggregates found: \(lastCleanup.matchedCount)",
            "Aggregates destroyed: \(lastCleanup.destroyedCount)",
            "Aggregate cleanup failures: \(lastCleanup.failedCount)",
            "Audio stop failures: \(lastResourceCleanup.stopFailureCount)",
            "IO proc cleanup failures: \(lastResourceCleanup.ioProcFailureCount)",
            "Tap aggregate cleanup failures: \(lastResourceCleanup.aggregateFailureCount)",
            "Process tap cleanup failures: \(lastResourceCleanup.processTapFailureCount)",
            "Failure code: \(lastFailure?.rawValue ?? "none")"
        ].joined(separator: "\n")
    }

    private static func failure(
        cleanup: OrphanedTapCleanupResult,
        resources: TapResourceCleanupResult
    ) -> AudioProcessingFailure? {
        if resources.failureCount > 0 { return .resourceCleanup }
        if cleanup.failedCount > 0 { return .aggregateCleanup }
        return nil
    }
}
