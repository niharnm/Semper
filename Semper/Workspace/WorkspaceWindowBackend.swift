import AppKit
import ApplicationServices

protocol WorkspaceWindowBackend: Sendable {
    func permission(prompt: Bool) async -> Bool
    func applications() async -> [WorkspaceApplication]
    func displays() async -> [WorkspaceDisplay]
    func windows(in applications: [WorkspaceApplication]) async throws -> [WorkspaceWindowSnapshot]
    func current(_ id: WorkspaceWindowID) async throws -> WorkspaceWindowSnapshot?
    // After the first write attempt, return observed state even on cancellation or failure.
    func move(_ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect) async throws -> WorkspaceMoveObservation
    func shutdown() async
}

actor AccessibilityWorkspaceBackend: WindowLayoutWindowBackend {
    private var handles = WorkspaceWindowHandleStore<AXUIElement>()
    private let messageTimeout: Float = 0.15
    private var currentDisplays: [WorkspaceDisplay] = []

    func permission(prompt: Bool) -> Bool {
        if prompt { return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        return AXIsProcessTrusted()
    }

    func applications() async -> [WorkspaceApplication] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular,
                    app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                    let bundleID = app.bundleIdentifier, let date = app.launchDate
                else { return nil }
                return WorkspaceApplication(
                    pid: app.processIdentifier, bundleID: bundleID,
                    name: app.localizedName ?? bundleID, launchDate: date)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func displays() async -> [WorkspaceDisplay] {
        let result = await Self.displaySnapshot()
        currentDisplays = result
        return result
    }

    @MainActor
    static func displaySnapshot() -> [WorkspaceDisplay] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            else { return nil }
            let identity = CFUUIDCreateString(nil, uuid) as String
            return WorkspaceDisplay(
                id: identity, name: screen.localizedName,
                visibleFrame: Self.accessibilityFrame(screen.visibleFrame, primaryHeight: primaryHeight),
                fullScreenFrame: Self.accessibilityFrame(
                    CGRect(
                        x: screen.frame.minX + screen.safeAreaInsets.left,
                        y: screen.frame.minY + screen.safeAreaInsets.bottom,
                        width: screen.frame.width - screen.safeAreaInsets.left - screen.safeAreaInsets.right,
                        height: screen.frame.height - screen.safeAreaInsets.top - screen.safeAreaInsets.bottom),
                    primaryHeight: primaryHeight))
        }
    }

    nonisolated static func accessibilityFrame(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    func windows(in applications: [WorkspaceApplication]) async throws -> [WorkspaceWindowSnapshot] {
        guard AXIsProcessTrusted() else { throw WorkspaceError.permission }
        _ = await displays()
        await pruneTerminatedProcesses()
        var snapshots: [WorkspaceWindowSnapshot] = []
        for application in applications.prefix(30) {
            try Task.checkCancellation()
            guard await isSameProcess(application) else { continue }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            let element = AXUIElementCreateApplication(application.pid)
            AXUIElementSetMessagingTimeout(element, messageTimeout)
            do {
                var value: CFArray?
                let error = AXUIElementCopyAttributeValues(element, kAXWindowsAttribute as CFString, 0, 200, &value)
                guard error == .success, let elements = value as? [AXUIElement] else {
                    snapshots.append(
                        .init(
                            id: nil, application: application, ordinal: 1, frame: nil,
                            issue: error == .cannotComplete ? .timedOut : .unavailable))
                    continue
                }
                handles.retainWorkspaceWindows(in: application, elements: elements, equal: CFEqual)
                for (index, window) in elements.enumerated() {
                    try Task.checkCancellation()
                    if ContinuousClock.now >= deadline {
                        snapshots.append(
                            .init(id: nil, application: application, ordinal: index + 1, frame: nil, issue: .timedOut))
                        break
                    }
                    AXUIElementSetMessagingTimeout(window, messageTimeout)
                    guard
                        let id = handles.retain(
                            element: window, application: application, ordinal: index + 1,
                            policy: .workspaceRestore, equal: CFEqual)
                    else {
                        snapshots.append(
                            .init(
                                id: nil, application: application, ordinal: index + 1, frame: nil, issue: .unavailable))
                        continue
                    }
                    snapshots.append(try snapshot(id, deadline: deadline))
                    if snapshots.count >= 200 { return snapshots }
                }
            } catch is CancellationError { throw CancellationError() } catch {
                snapshots.append(
                    .init(id: nil, application: application, ordinal: snapshots.count + 1, frame: nil, issue: .timedOut)
                )
            }
        }
        return snapshots
    }

    func focusedWindow(in application: WorkspaceApplication) async throws -> WorkspaceWindowSnapshot? {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw WorkspaceError.permission }
        _ = await displays()
        await pruneTerminatedProcesses()
        guard await isSameProcess(application) else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let element = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
        guard result != .noValue else { return nil }
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .init(
                id: nil, application: application, ordinal: 1, frame: nil,
                issue: result == .cannotComplete ? .timedOut : .unavailable)
        }
        let window = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == application.pid else {
            return .init(id: nil, application: application, ordinal: 1, frame: nil, issue: .ambiguousIdentity)
        }
        AXUIElementSetMessagingTimeout(window, messageTimeout)
        for _ in 0..<min(4, handles.windowLayoutCount) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            guard let candidate = handles.nextWindowLayoutProbeCandidates(limit: 1).first else { break }
            var role: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(candidate.element, kAXRoleAttribute as CFString, &role)
            handles.recordProbe(result, for: candidate.id)
        }
        guard
            let id = handles.retain(
                element: window, application: application, ordinal: 1, policy: .windowLayout, equal: CFEqual)
        else {
            return .init(id: nil, application: application, ordinal: 1, frame: nil, issue: .unavailable)
        }
        let state = try snapshot(id, deadline: deadline)
        let sameProcess = await Self.processMatches(application)
        guard sameProcess == true else {
            if sameProcess == false { handles.removeProcesses([application]) }
            return nil
        }
        try Task.checkCancellation()
        return state
    }

    func current(_ id: WorkspaceWindowID) async throws -> WorkspaceWindowSnapshot? {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw WorkspaceError.permission }
        guard handles[id] != nil else { return nil }
        let sameProcess = await Self.processMatches(id.application)
        guard sameProcess == true else {
            if sameProcess == false { handles.removeProcesses([id.application]) }
            return nil
        }
        _ = await displays()
        let state = try snapshot(id, deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        return state.issue == .unavailable ? nil : state
    }

    func move(_ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect) async throws -> WorkspaceMoveObservation {
        try await moveWindow(id, to: frame, expected: expected, expectedDisplays: nil)
    }

    func move(
        _ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect, expectedDisplays: [WorkspaceDisplay]
    ) async throws -> WorkspaceMoveObservation {
        try await moveWindow(id, to: frame, expected: expected, expectedDisplays: expectedDisplays)
    }

    private func moveWindow(
        _ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect, expectedDisplays: [WorkspaceDisplay]?
    ) async throws -> WorkspaceMoveObservation {
        guard WorkspaceGeometry.valid(frame), let state = try await current(id), let before = state.frame,
            let handle = handles[id]
        else { throw WorkspaceError.missing }
        if let expectedDisplays,
            WindowLayoutGeometry.topologyIdentity(currentDisplays) != WindowLayoutGeometry.topologyIdentity(expectedDisplays)
        {
            return .init(
                before: before, after: before,
                failure: "The displays changed before the window layout was applied. Check the window and try again.",
                writeAttempted: false)
        }
        guard state.issue == nil else {
            return .init(before: before, after: before, failure: state.issue?.message, writeAttempted: false)
        }
        guard before == expected else {
            return .init(
                before: before, after: before,
                failure: handle.policy == .windowLayout
                    ? "The window changed before the layout was applied. Try again."
                    : "The window changed after preview. Preview again before restoring.",
                writeAttempted: false)
        }
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return .init(
                before: before, after: before, failure: "The requested frame is invalid.", writeAttempted: false)
        }
        var failure: String?
        var writeAttempted = false
        // A second size write lets the destination display apply its own size constraints.
        for (attribute, value) in [
            (kAXSizeAttribute, sizeValue), (kAXPositionAttribute, positionValue), (kAXSizeAttribute, sizeValue),
        ] {
            guard !Task.isCancelled else {
                failure = handle.policy == .windowLayout
                    ? "Window change cancelled after the last observed change."
                    : "Restore cancelled after the last observed change."
                break
            }
            guard AXIsProcessTrusted() else {
                failure = WorkspaceError.permission.localizedDescription
                break
            }
            writeAttempted = true
            let result = AXUIElementSetAttributeValue(handle.element, attribute as CFString, value)
            if result != .success {
                failure =
                    result == .cannotComplete
                    ? "The app did not respond to the window change." : "The app rejected a window change."
                break
            }
        }
        let after = readFrame(handle.element)
        if after == nil && failure == nil { failure = "The app did not return the resulting window frame." }
        return WorkspaceMoveObservation(before: before, after: after, failure: failure, writeAttempted: writeAttempted)
    }

    func shutdown() {
        handles.removeAll()
        currentDisplays = []
    }

    private func isSameProcess(_ application: WorkspaceApplication) async -> Bool {
        await Self.processMatches(application) == true
    }

    private func pruneTerminatedProcesses() async {
        let known = Set(handles.entries.values.map(\.application))
        let stale = await MainActor.run { known.filter { Self.processMatches($0) == false } }
        handles.removeProcesses(Array(stale))
    }

    @MainActor
    private static func processMatches(_ application: WorkspaceApplication) -> Bool? {
        guard let app = NSRunningApplication(processIdentifier: application.pid) else { return false }
        guard !app.isTerminated else { return false }
        guard let bundleID = app.bundleIdentifier, let launchDate = app.launchDate else { return nil }
        return bundleID == application.bundleID && launchDate == application.launchDate
    }

    private func snapshot(_ id: WorkspaceWindowID, deadline: ContinuousClock.Instant) throws -> WorkspaceWindowSnapshot
    {
        guard let handle = handles[id] else { throw WorkspaceError.missing }
        func value(_ name: String) throws -> CFTypeRef? {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw WorkspaceWindowReadError.timeout }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(handle.element, name as CFString, &value)
            if result == .invalidUIElement {
                handles.recordProbe(result, for: id)
                throw WorkspaceError.missing
            }
            if result == .cannotComplete && handle.policy == .windowLayout { throw WorkspaceWindowReadError.timeout }
            return result == .success ? value : nil
        }
        do {
            let role = try value(kAXSubroleAttribute) as? String
            let minimized = try value(kAXMinimizedAttribute) as? Bool
            let frame = readFrame(handle.element)
            var movable = DarwinBoolean(false)
            var resizable = DarwinBoolean(false)
            let moveResult = AXUIElementIsAttributeSettable(handle.element, kAXPositionAttribute as CFString, &movable)
            let sizeResult = AXUIElementIsAttributeSettable(handle.element, kAXSizeAttribute as CFString, &resizable)
            let issue: WorkspaceWindowIssue?
            switch handle.policy {
            case .workspaceRestore:
                issue = WorkspaceWindowRules.issue(
                    standard: role.map { $0 == kAXStandardWindowSubrole }, minimized: minimized, frame: frame,
                    displays: currentDisplays,
                    movable: moveResult == .success ? movable.boolValue : nil,
                    resizable: sizeResult == .success ? resizable.boolValue : nil)
            case .windowLayout:
                issue = WindowLayoutWindowRules.issue(
                    standard: role.map { $0 == kAXStandardWindowSubrole }, minimized: minimized, frame: frame,
                    displays: currentDisplays,
                    movable: moveResult == .success ? movable.boolValue : nil,
                    resizable: sizeResult == .success ? resizable.boolValue : nil)
            }
            return .init(id: id, application: handle.application, ordinal: handle.ordinal, frame: frame, issue: issue)
        } catch is CancellationError { throw CancellationError() } catch {
            return .init(
                id: id, application: handle.application, ordinal: handle.ordinal, frame: nil,
                issue: error is WorkspaceWindowReadError ? .timedOut : .unavailable)
        }
    }

    private func readFrame(_ element: AXUIElement) -> CGRect? {
        var originValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &originValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let originValue, let sizeValue, CFGetTypeID(originValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(originValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        let frame = CGRect(origin: origin, size: size)
        return WorkspaceGeometry.valid(frame) ? frame : nil
    }
}

private enum WorkspaceWindowReadError: Error { case timeout }
