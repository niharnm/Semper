import AppKit

@MainActor
final class WindowLayoutTargetTracker {
    private var observer: (any NSObjectProtocol)?
    private(set) var lastApplication: WorkspaceApplication?
    private var generation = UUID()

    isolated deinit { stop() }

    func start() {
        guard observer == nil else { return }
        capture(NSWorkspace.shared.frontmostApplication)
        let generation = generation
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.observer != nil else { return }
                self.capture(application)
            }
        }
    }

    func targetApplication() -> WorkspaceApplication? {
        guard observer != nil else { return nil }
        capture(NSWorkspace.shared.frontmostApplication)
        return lastApplication
    }

    func stop() {
        generation = UUID()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        lastApplication = nil
    }

    private func capture(_ app: NSRunningApplication?) {
        guard let app else {
            recordActivation(nil, isSemper: false)
            return
        }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || (Bundle.main.bundleIdentifier.map { app.bundleIdentifier == $0 } ?? false)
        {
            recordActivation(nil, isSemper: true)
            return
        }
        guard app.activationPolicy == .regular, !app.isTerminated, let bundleID = app.bundleIdentifier,
            let launchDate = app.launchDate
        else {
            recordActivation(nil, isSemper: false)
            return
        }
        recordActivation(WorkspaceApplication(
            pid: app.processIdentifier, bundleID: bundleID,
            name: app.localizedName ?? bundleID, launchDate: launchDate), isSemper: false)
    }

    func recordActivation(_ application: WorkspaceApplication?, isSemper: Bool) {
        if !isSemper { lastApplication = application }
    }
}
