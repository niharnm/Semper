import AppKit

@MainActor
protocol WorkspaceTopologyObserving: AnyObject {
    func start(onChange: @escaping @MainActor ([WorkspaceDisplay]) -> Void) -> [WorkspaceDisplay]
    func stop()
}

@MainActor
final class WorkspaceTopologyObserver: WorkspaceTopologyObserving {
    private var observer: (any NSObjectProtocol)?
    private var generation = UUID()

    isolated deinit { stop() }

    func start(onChange: @escaping @MainActor ([WorkspaceDisplay]) -> Void) -> [WorkspaceDisplay] {
        stop()
        let generation = generation
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.observer != nil else { return }
                onChange(AccessibilityWorkspaceBackend.displaySnapshot())
            }
        }
        return AccessibilityWorkspaceBackend.displaySnapshot()
    }

    func stop() {
        generation = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
