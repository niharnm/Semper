import CoreGraphics
import Foundation

struct WorkspaceApplication: Identifiable, Hashable, Sendable {
    var id: String { "\(pid):\(launchDate.timeIntervalSince1970)" }
    let pid: Int32
    let bundleID: String
    let name: String
    let launchDate: Date
}

struct WorkspaceWindowID: Hashable, Sendable {
    let application: WorkspaceApplication
    let token: UUID
}

struct WorkspaceDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let visibleFrame: CGRect
    let fullScreenFrame: CGRect?

    init(id: String, name: String, visibleFrame: CGRect, fullScreenFrame: CGRect? = nil) {
        self.id = id
        self.name = name
        self.visibleFrame = visibleFrame
        self.fullScreenFrame = fullScreenFrame
    }
}

enum WorkspaceWindowIssue: String, Codable, Sendable {
    case unsupported, minimized, manualAdjustmentRequired, unknownState, ambiguousIdentity, unavailable, timedOut

    var message: String {
        switch self {
        case .unsupported: "This window does not support moving and resizing."
        case .minimized: "Minimized. Unminimize this window before restoring."
        case .manualAdjustmentRequired:
            "This window spans the display height and cannot be restored automatically. Manual adjustment may be required."
        case .unknownState: "The app did not provide a verifiable window state."
        case .ambiguousIdentity: "This window could not be identified without ambiguity."
        case .unavailable: "This window is no longer available."
        case .timedOut: "The app did not respond within the time limit."
        }
    }
}

struct WorkspaceWindowSnapshot: Sendable {
    let id: WorkspaceWindowID?
    let application: WorkspaceApplication
    let ordinal: Int
    let frame: CGRect?
    let issue: WorkspaceWindowIssue?
    var label: String { "\(application.name), window \(ordinal)" }
}

struct WorkspacePlacement: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let applicationBundleID: String
    let applicationName: String
    var label: String
    let displayID: String
    let displayName: String
    let relativeFrame: CGRect
}

struct WorkspaceArrangement: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let capturedAt: Date
    var windows: [WorkspacePlacement]
}

struct WorkspacePreviewItem: Identifiable, Sendable {
    var id: UUID { placement.id }
    let placement: WorkspacePlacement
    let boundWindowID: WorkspaceWindowID?
    let currentFrame: CGRect?
    let targetFrame: CGRect?
    let reason: String?
    var canRestore: Bool { targetFrame != nil && reason == nil }
}

struct WorkspaceWindowResult: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let message: String
    let succeeded: Bool
}

struct WorkspaceMoveObservation: Sendable {
    let before: CGRect
    let after: CGRect?
    let failure: String?
    let writeAttempted: Bool
}

struct WorkspaceUndoEntry: Sendable {
    let id: WorkspaceWindowID
    let label: String
    let before: CGRect
    let after: CGRect
}

enum WorkspaceGeometry {
    static func excludedByDisplayBounds(_ frame: CGRect, on displays: [WorkspaceDisplay]) -> Bool {
        displays.contains { display in
            guard let bounds = display.fullScreenFrame, frame.intersects(bounds) else { return false }
            return frame.minY <= bounds.minY + 1 && frame.maxY >= bounds.maxY - 1
        }
    }

    static func valid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && frame.width < 100_000 && frame.height < 100_000
    }

    static func approximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) <= 1 && abs(left.minY - right.minY) <= 1
            && abs(left.width - right.width) <= 1 && abs(left.height - right.height) <= 1
    }

    static func relative(_ frame: CGRect, in display: CGRect) -> CGRect {
        CGRect(
            x: (frame.minX - display.minX) / display.width,
            y: (frame.minY - display.minY) / display.height,
            width: frame.width / display.width, height: frame.height / display.height)
    }

    static func target(_ relative: CGRect, in display: CGRect) -> CGRect {
        let width = min(relative.width * display.width, display.width)
        let height = min(relative.height * display.height, display.height)
        return CGRect(
            x: max(display.minX, min(display.maxX - width, display.minX + relative.minX * display.width)),
            y: max(display.minY, min(display.maxY - height, display.minY + relative.minY * display.height)),
            width: width, height: height
        ).integral
    }

    static func display(for frame: CGRect, in displays: [WorkspaceDisplay]) -> WorkspaceDisplay? {
        displays.max { left, right in
            let a = frame.intersection(left.visibleFrame)
            let b = frame.intersection(right.visibleFrame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }.flatMap { frame.intersects($0.visibleFrame) ? $0 : nil }
    }
}

enum WorkspaceError: LocalizedError {
    case permission, missing, invalidStore, storeTooLarge, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .permission: "Accessibility access is unavailable. Review Semper in System Settings, then try again."
        case .missing: "The original window is no longer available. Capture the arrangement again."
        case .invalidStore: "Saved workspace data is invalid. Existing data has been left unchanged."
        case .storeTooLarge: "The workspace store exceeds its size limit."
        case .unsupportedVersion: "This workspace store was created by an unsupported version."
        }
    }
}

enum WorkspaceWindowRules {
    static func issue(
        standard: Bool?, minimized: Bool?, frame: CGRect?, displays: [WorkspaceDisplay],
        movable: Bool?, resizable: Bool?
    ) -> WorkspaceWindowIssue? {
        guard let standard else { return .unknownState }
        guard standard else { return .unsupported }
        if minimized == true { return .minimized }
        if let frame, WorkspaceGeometry.excludedByDisplayBounds(frame, on: displays) {
            return .manualAdjustmentRequired
        }
        guard minimized != nil, frame != nil, !displays.isEmpty, let movable, let resizable else {
            return .unknownState
        }
        return movable && resizable ? nil : .unsupported
    }
}
