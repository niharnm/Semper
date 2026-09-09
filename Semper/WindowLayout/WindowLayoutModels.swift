import CoreGraphics
import Foundation

enum WindowLayoutAction: String, CaseIterable, Identifiable, Sendable {
    case leftHalf = "window-layout.left-half"
    case rightHalf = "window-layout.right-half"
    case maximize = "window-layout.maximize"
    case center = "window-layout.center"
    case restore = "window-layout.restore"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore Previous Placement"
        }
    }

    var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .center: "rectangle.center.inset.filled"
        case .restore: "arrow.uturn.backward"
        }
    }
}

protocol WindowLayoutWindowBackend: WorkspaceWindowBackend {
    func focusedWindow(in application: WorkspaceApplication) async throws -> WorkspaceWindowSnapshot?
    func move(
        _ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect, expectedDisplays: [WorkspaceDisplay]
    ) async throws -> WorkspaceMoveObservation
}

enum WindowLayoutGeometry {
    static func topologyIdentity(_ displays: [WorkspaceDisplay]) -> [WorkspaceDisplay] {
        displays.map {
            WorkspaceDisplay(id: $0.id, name: "", visibleFrame: $0.visibleFrame, fullScreenFrame: $0.fullScreenFrame)
        }.sorted { $0.id < $1.id }
    }

    static func target(_ action: WindowLayoutAction, frame: CGRect, display: WorkspaceDisplay) -> CGRect? {
        let bounds = display.visibleFrame
        guard WorkspaceGeometry.valid(frame), WorkspaceGeometry.valid(bounds),
            let fullBounds = display.fullScreenFrame, WorkspaceGeometry.valid(fullBounds), fullBounds.contains(bounds)
        else { return nil }
        let target: CGRect
        switch action {
        case .leftHalf:
            target = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .rightHalf:
            target = CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .maximize:
            target = bounds
        case .center:
            guard frame.width <= bounds.width, frame.height <= bounds.height else { return nil }
            target = CGRect(
                x: bounds.minX + (bounds.width - frame.width) / 2,
                y: bounds.minY + (bounds.height - frame.height) / 2,
                width: frame.width, height: frame.height)
        case .restore:
            return nil
        }
        return WorkspaceGeometry.valid(target) && bounds.contains(target)
            && !WorkspaceGeometry.excludedByDisplayBounds(target, on: [display]) ? target : nil
    }
}

enum WindowLayoutWindowRules {
    static func issue(
        standard: Bool?, minimized: Bool?, frame: CGRect?, displays: [WorkspaceDisplay],
        movable: Bool?, resizable: Bool?
    ) -> WorkspaceWindowIssue? {
        if let issue = WorkspaceWindowRules.issue(
            standard: standard, minimized: minimized, frame: frame, displays: displays,
            movable: movable, resizable: resizable)
        {
            return issue
        }
        guard displays.allSatisfy({ display in
            guard let fullBounds = display.fullScreenFrame else { return false }
            return WorkspaceGeometry.valid(fullBounds) && fullBounds.contains(display.visibleFrame)
        }) else { return .unknownState }
        return nil
    }
}
