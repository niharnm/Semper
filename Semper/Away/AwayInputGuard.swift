import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin

nonisolated enum AwayInputPolicy: Equatable, Sendable {
    case fullFiltering
    case pinEntry
    case systemAuthentication
}

nonisolated enum AwayInputDisposition: Equatable, Sendable {
    case allow
    case block
    case requestAuthentication
    case requestQuit
}

nonisolated enum AwayInputGuardFailure: Error, Equatable, Sendable {
    case accessibilityPermissionMissing
    case tapCreationFailed
    case tapRecoveryFailed
}

nonisolated struct AwayInputEvent: Equatable, Sendable {
    let type: CGEventType
    let keyCode: CGKeyCode?
    let flags: CGEventFlags
    let targetPID: pid_t?
    let isRepeat: Bool
    let systemSubtype: Int?
    let systemKeyType: Int?

    init(
        type: CGEventType,
        keyCode: CGKeyCode? = nil,
        flags: CGEventFlags = [],
        targetPID: pid_t? = nil,
        isRepeat: Bool = false,
        systemSubtype: Int? = nil,
        systemKeyType: Int? = nil
    ) {
        self.type = type
        self.keyCode = keyCode
        self.flags = flags
        self.targetPID = targetPID
        self.isRepeat = isRepeat
        self.systemSubtype = systemSubtype
        self.systemKeyType = systemKeyType
    }

    init(type: CGEventType, event: CGEvent) {
        self.type = type
        flags = event.flags
        if type == .keyDown || type == .keyUp {
            keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        } else {
            keyCode = nil
            isRepeat = false
        }

        let rawPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        targetPID = rawPID > 0 ? pid_t(truncatingIfNeeded: rawPID) : nil

        if type.rawValue == AwayInputFilter.systemDefinedEventType.rawValue,
           let nsEvent = NSEvent(cgEvent: event) {
            systemSubtype = Int(nsEvent.subtype.rawValue)
            systemKeyType = (nsEvent.data1 >> 16) & 0xFFFF
        } else {
            systemSubtype = nil
            systemKeyType = nil
        }
    }
}

nonisolated enum AwayInputFilter {
    static let systemDefinedEventType = CGEventType(rawValue: 14)!

    private static let modifierMask: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl,
    ]
    private static let shortcutModifierMask = modifierMask.union(.maskSecondaryFn)
    private static let functionCarbonMask: UInt = 1 << 17
    private static let command: CGEventFlags = [.maskCommand]
    private static let commandShift: CGEventFlags = [.maskCommand, .maskShift]
    private static let commandOptionShift: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskShift,
    ]
    private static let commandOption: CGEventFlags = [.maskCommand, .maskAlternate]
    private static let commandControl: CGEventFlags = [.maskCommand, .maskControl]
    private static let commandControlOption: CGEventFlags = [
        .maskCommand,
        .maskControl,
        .maskAlternate,
    ]

    static func disposition(
        for event: AwayInputEvent,
        policy: AwayInputPolicy,
        applicationPID: pid_t,
        authenticationShortcut: ShortcutCodable? = nil
    ) -> AwayInputDisposition {
        if event.type.rawValue == systemDefinedEventType.rawValue {
            return systemEventDisposition(event)
        }

        switch event.type {
        case .keyDown, .keyUp:
            if isScreenshotShortcut(event) {
                return .block
            }
            if isAllowedSystemShortcut(event) {
                return .allow
            }
            if isCommandQ(event) {
                return event.type == .keyDown && !event.isRepeat
                    ? .requestQuit
                    : .block
            }
            if policy == .fullFiltering,
               isAuthenticationShortcut(event, shortcut: authenticationShortcut) {
                return .requestAuthentication
            }
            if policy == .pinEntry {
                return pinEntryDisposition(event, applicationPID: applicationPID)
            }
            return keyboardDisposition(
                policy: policy
            )
        case .flagsChanged:
            if policy == .pinEntry {
                return .block
            }
            return keyboardDisposition(
                policy: policy
            )
        case .scrollWheel, .tabletPointer, .tabletProximity:
            return .block
        default:
            return .allow
        }
    }

    private static func keyboardDisposition(
        policy: AwayInputPolicy
    ) -> AwayInputDisposition {
        switch policy {
        case .fullFiltering:
            return .block
        case .pinEntry:
            return .block
        case .systemAuthentication:
            return .allow
        }
    }

    private static func pinEntryDisposition(
        _ event: AwayInputEvent,
        applicationPID: pid_t
    ) -> AwayInputDisposition {
        guard event.targetPID == applicationPID,
              event.flags.intersection([
                  .maskCommand,
                  .maskShift,
                  .maskAlternate,
                  .maskControl,
                  .maskSecondaryFn,
              ]).isEmpty,
              let keyCode = event.keyCode,
              pinEntryKeyCodes.contains(Int(keyCode)) else {
            return .block
        }
        return .allow
    }

    private static func systemEventDisposition(_ event: AwayInputEvent) -> AwayInputDisposition {
        if event.systemSubtype == Int(NSEvent.EventSubtype.powerOff.rawValue) {
            return .allow
        }
        let modifiers = event.flags.intersection(modifierMask)
        if event.systemSubtype == 8,
           modifiers == commandControlOption,
           event.systemKeyType == 14 {
            return .allow
        }
        return .block
    }

    private static func isScreenshotShortcut(_ event: AwayInputEvent) -> Bool {
        guard event.flags.intersection(modifierMask).isSuperset(of: commandShift),
              let keyCode = event.keyCode else {
            return false
        }
        return [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
            .contains(Int(keyCode))
    }

    private static func isAllowedSystemShortcut(_ event: AwayInputEvent) -> Bool {
        let modifiers = event.flags.intersection(modifierMask)
        switch Int(event.keyCode ?? 0) {
        case kVK_Escape:
            return modifiers == commandOption
        case kVK_ANSI_Q:
            return modifiers == commandControl
                || modifiers == commandShift
                || modifiers == commandOptionShift
        default:
            return false
        }
    }

    private static func isCommandQ(_ event: AwayInputEvent) -> Bool {
        event.keyCode == CGKeyCode(kVK_ANSI_Q)
            && event.flags.intersection(modifierMask) == command
    }

    private static func isAuthenticationShortcut(
        _ event: AwayInputEvent,
        shortcut: ShortcutCodable?
    ) -> Bool {
        guard event.type == .keyDown,
              !event.isRepeat,
              let shortcut,
              event.keyCode == CGKeyCode(shortcut.keyCode) else {
            return false
        }

        var expected: CGEventFlags = []
        if shortcut.modifiers & UInt(cmdKey) != 0 {
            expected.insert(.maskCommand)
        }
        if shortcut.modifiers & UInt(shiftKey) != 0 {
            expected.insert(.maskShift)
        }
        if shortcut.modifiers & UInt(optionKey) != 0 {
            expected.insert(.maskAlternate)
        }
        if shortcut.modifiers & UInt(controlKey) != 0 {
            expected.insert(.maskControl)
        }
        if shortcut.modifiers & functionCarbonMask != 0 {
            expected.insert(.maskSecondaryFn)
        }
        return event.flags.intersection(shortcutModifierMask) == expected
    }

    private static let pinEntryKeyCodes: Set<Int> = [
        kVK_ANSI_0,
        kVK_ANSI_1,
        kVK_ANSI_2,
        kVK_ANSI_3,
        kVK_ANSI_4,
        kVK_ANSI_5,
        kVK_ANSI_6,
        kVK_ANSI_7,
        kVK_ANSI_8,
        kVK_ANSI_9,
        kVK_ANSI_Keypad0,
        kVK_ANSI_Keypad1,
        kVK_ANSI_Keypad2,
        kVK_ANSI_Keypad3,
        kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6,
        kVK_ANSI_Keypad7,
        kVK_ANSI_Keypad8,
        kVK_ANSI_Keypad9,
        kVK_Delete,
        kVK_Return,
        kVK_ANSI_KeypadEnter,
    ]
}

typealias AwayEventTapHandler = @MainActor (CGEventType, CGEvent) -> Bool

@MainActor
protocol AwayEventTapControlling: AnyObject {
    var isEnabled: Bool { get }

    @discardableResult
    func install(handler: @escaping AwayEventTapHandler) -> Bool
    func setEnabled(_ enabled: Bool)
    func uninstall()
}

@MainActor
final class CoreGraphicsAwayEventTap: AwayEventTapControlling {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: AwayEventTapHandler?

    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    func install(handler: @escaping AwayEventTapHandler) -> Bool {
        uninstall()
        self.handler = handler

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: awayInputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            return false
        }

        let newSource = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        tap = newTap
        source = newSource
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    func setEnabled(_ enabled: Bool) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        handler = nil
    }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
        handler?(type, event) ?? true
    }

    isolated deinit {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        CGEventType.keyDown,
        .keyUp,
        .flagsChanged,
        .scrollWheel,
        .tabletPointer,
        .tabletProximity,
        systemDefinedEventType,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << type.rawValue)
    }

    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
}

@MainActor
final class AwayInputGuard {
    private let tapController: any AwayEventTapControlling
    private let accessibilityTrusted: () -> Bool
    private let accessibilityRequester: () -> Bool
    private let accessibilitySettingsOpener: () -> Void
    private let inputMonitoringSettingsOpener: () -> Void
    private let applicationPID: pid_t
    private let workspaceNotificationCenter: NotificationCenter

    private(set) var isActive = false
    private(set) var policy: AwayInputPolicy = .fullFiltering
    private(set) var lastFailure: AwayInputGuardFailure?
    private var didPassPreflight = false
    private var shouldMaintainTap = false
    private var isSuspended = false
    private var authenticationShortcut: ShortcutCodable?
    private var workspaceObservers: [NSObjectProtocol] = []

    var onActivity: (() -> Void)?
    var onAuthenticationRequested: (() -> Void)?
    var onQuitRequested: (() -> Void)?
    var onFailure: ((AwayInputGuardFailure) -> Void)?
    var onRestored: (() -> Void)?

    var isFilteringOperational: Bool {
        isActive && tapController.isEnabled
    }

    var hasEventAccess: Bool {
        isActive
            ? isFilteringOperational
            : accessibilityTrusted() && didPassPreflight
    }

    init(
        tapController: any AwayEventTapControlling = CoreGraphicsAwayEventTap(),
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        accessibilityRequester: @escaping () -> Bool = {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        accessibilitySettingsOpener: @escaping () -> Void = {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else {
                return
            }
            NSWorkspace.shared.open(url)
        },
        inputMonitoringSettingsOpener: @escaping () -> Void = {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            ) else {
                return
            }
            NSWorkspace.shared.open(url)
        },
        applicationPID: pid_t = getpid(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.tapController = tapController
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityRequester = accessibilityRequester
        self.accessibilitySettingsOpener = accessibilitySettingsOpener
        self.inputMonitoringSettingsOpener = inputMonitoringSettingsOpener
        self.applicationPID = applicationPID
        self.workspaceNotificationCenter = workspaceNotificationCenter
        subscribeToWorkspaceLifecycle()
    }

    isolated deinit {
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
    }

    func requestEventAccess() {
        guard accessibilityTrusted() else {
            if !accessibilityRequester() {
                accessibilitySettingsOpener()
            }
            return
        }
        if !preflight() {
            inputMonitoringSettingsOpener()
        }
    }

    @discardableResult
    func preflight() -> Bool {
        guard !isActive else { return false }
        guard accessibilityTrusted() else {
            didPassPreflight = false
            report(.accessibilityPermissionMissing)
            return false
        }

        tapController.uninstall()
        let installed = tapController.install { _, _ in true }
        let verified = installed && tapController.isEnabled
        tapController.uninstall()
        if verified {
            lastFailure = nil
            didPassPreflight = true
        } else {
            didPassPreflight = false
            report(.tapCreationFailed)
        }
        return verified
    }

    @discardableResult
    func start(policy: AwayInputPolicy = .fullFiltering) -> Bool {
        guard !isActive else {
            setPolicy(policy)
            return isFilteringOperational
        }
        guard accessibilityTrusted() else {
            didPassPreflight = false
            report(.accessibilityPermissionMissing)
            return false
        }

        self.policy = policy
        tapController.uninstall()
        guard installActiveTap() else {
            tapController.uninstall()
            didPassPreflight = false
            report(.tapCreationFailed)
            return false
        }

        isActive = true
        shouldMaintainTap = true
        isSuspended = false
        didPassPreflight = true
        lastFailure = nil
        return true
    }

    func setPolicy(_ policy: AwayInputPolicy) {
        self.policy = policy
    }

    func setAuthenticationShortcut(_ shortcut: ShortcutCodable?) {
        authenticationShortcut = shortcut
    }

    func stop() {
        tapController.uninstall()
        isActive = false
        shouldMaintainTap = false
        isSuspended = false
        lastFailure = nil
        policy = .fullFiltering
    }

    func requestAuthentication() {
        onActivity?()
        onAuthenticationRequested?()
    }

    func handleTapDisabled() {
        guard !isSuspended else { return }
        guard isActive else {
            guard shouldMaintainTap else { return }
            guard accessibilityTrusted() else {
                didPassPreflight = false
                report(.accessibilityPermissionMissing)
                return
            }
            tapController.uninstall()
            guard installActiveTap() else {
                tapController.uninstall()
                didPassPreflight = false
                report(.tapRecoveryFailed)
                return
            }
            isActive = true
            didPassPreflight = true
            lastFailure = nil
            onRestored?()
            return
        }
        tapController.setEnabled(true)
        guard !tapController.isEnabled else { return }

        tapController.uninstall()
        guard installActiveTap() else {
            tapController.uninstall()
            isActive = false
            didPassPreflight = false
            report(.tapRecoveryFailed)
            return
        }
        lastFailure = nil
        onRestored?()
    }

    @discardableResult
    func handle(_ event: AwayInputEvent) -> AwayInputDisposition {
        let disposition = AwayInputFilter.disposition(
            for: event,
            policy: policy,
            applicationPID: applicationPID,
            authenticationShortcut: authenticationShortcut
        )
        onActivity?()
        if disposition == .requestAuthentication {
            onAuthenticationRequested?()
        } else if disposition == .requestQuit {
            onQuitRequested?()
        }
        return disposition
    }

    private func installActiveTap() -> Bool {
        let installed = tapController.install { [weak self] type, event in
            guard let self else { return true }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                self.handleTapDisabled()
                return false
            }
            return self.handle(AwayInputEvent(type: type, event: event)) == .allow
        }
        return installed && tapController.isEnabled
    }

    private func subscribeToWorkspaceLifecycle() {
        observeWorkspace(NSWorkspace.willSleepNotification) { [weak self] in
            self?.suspendForWorkspaceTransition()
        }
        observeWorkspace(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.suspendForWorkspaceTransition()
        }
        observeWorkspace(NSWorkspace.didWakeNotification) { [weak self] in
            self?.restoreAfterWorkspaceTransition()
        }
        observeWorkspace(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.restoreAfterWorkspaceTransition()
        }
    }

    private func observeWorkspace(
        _ name: Notification.Name,
        handler: @escaping @MainActor () -> Void
    ) {
        let observer = workspaceNotificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        workspaceObservers.append(observer)
    }

    private func suspendForWorkspaceTransition() {
        guard shouldMaintainTap else { return }
        isSuspended = true
        tapController.setEnabled(false)
    }

    private func restoreAfterWorkspaceTransition() {
        guard shouldMaintainTap else { return }
        isSuspended = false
        guard accessibilityTrusted() else {
            tapController.uninstall()
            isActive = false
            didPassPreflight = false
            report(.accessibilityPermissionMissing)
            return
        }

        tapController.uninstall()
        guard installActiveTap() else {
            tapController.uninstall()
            isActive = false
            didPassPreflight = false
            report(.tapRecoveryFailed)
            return
        }
        isActive = true
        didPassPreflight = true
        lastFailure = nil
        onRestored?()
    }

    private func report(_ failure: AwayInputGuardFailure) {
        lastFailure = failure
        onFailure?(failure)
    }
}

private let awayInputTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<CoreGraphicsAwayEventTap>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    struct EventBox: @unchecked Sendable {
        let event: CGEvent
    }
    let box = EventBox(event: event)
    let shouldPass = MainActor.assumeIsolated {
        controller.process(type: type, event: box.event)
    }
    return shouldPass ? Unmanaged.passUnretained(event) : nil
}
