import AppKit

struct RunningAppIdentity: Equatable {
    let pid: pid_t
    let bundleID: String?
}

enum AppActivationService {
    static func preferredIdentity(
        pid: pid_t?,
        bundleID: String?,
        candidates: [RunningAppIdentity]
    ) -> RunningAppIdentity? {
        if let pid, let exactMatch = candidates.first(where: { $0.pid == pid }) {
            return exactMatch
        }
        guard let bundleID else { return nil }
        return candidates.first { $0.bundleID == bundleID }
    }

    @MainActor
    static func activate(
        pid: pid_t?,
        bundleID: String?,
        workspace: NSWorkspace = .shared
    ) -> Bool {
        let runningApplications = workspace.runningApplications
        let identities = runningApplications.map {
            RunningAppIdentity(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier)
        }

        if let identity = preferredIdentity(pid: pid, bundleID: bundleID, candidates: identities),
           let runningApplication = runningApplications.first(where: {
               $0.processIdentifier == identity.pid
           }) {
            if runningApplication.isHidden {
                runningApplication.unhide()
            }
            if runningApplication.activate(options: [.activateAllWindows]) {
                return true
            }
        }

        guard let bundleID,
              let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleID)
        else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        workspace.openApplication(at: applicationURL, configuration: configuration)
        return true
    }
}
