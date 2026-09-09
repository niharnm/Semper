import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import Semper

@Suite("Away input guard")
@MainActor
struct AwayInputGuardTests {
    private let appPID: pid_t = 41

    @Test("Full filtering blocks ordinary keyboard input addressed to Semper")
    func fullFilteringBlocksSemperKeyboardInput() {
        let event = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            targetPID: appPID
        )

        #expect(disposition(event, policy: .fullFiltering) == .block)
    }

    @Test("Full filtering blocks keyboard input addressed elsewhere")
    func fullFilteringBlocksOtherKeyboardInput() {
        let event = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            targetPID: 99
        )

        #expect(disposition(event, policy: .fullFiltering) == .block)
    }

    @Test("System authentication passes ordinary keyboard input")
    func systemAuthenticationPassesKeyboardInput() {
        let event = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            targetPID: 99
        )

        #expect(disposition(event, policy: .systemAuthentication) == .allow)
    }

    @Test("PIN entry passes every top row and keypad digit on key down and key up")
    func pinEntryPassesDigits() {
        let topRowKeyCodes = [
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
        ]
        let keypadKeyCodes = [
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
        ]
        let keyTypes: [CGEventType] = [.keyDown, .keyUp]

        for keyType in keyTypes {
            for keyCode in topRowKeyCodes {
                let event = AwayInputEvent(
                    type: keyType,
                    keyCode: CGKeyCode(keyCode),
                    targetPID: appPID
                )
                #expect(disposition(event, policy: .pinEntry) == .allow)
            }
            for keyCode in keypadKeyCodes {
                let event = AwayInputEvent(
                    type: keyType,
                    keyCode: CGKeyCode(keyCode),
                    flags: [.maskNumericPad],
                    targetPID: appPID
                )
                #expect(disposition(event, policy: .pinEntry) == .allow)
            }
        }
    }

    @Test("PIN entry passes Delete and both Return keys on key down and key up")
    func pinEntryPassesDeleteAndReturn() {
        let keyTypes: [CGEventType] = [.keyDown, .keyUp]
        for keyType in keyTypes {
            for keyCode in [kVK_Delete, kVK_Return, kVK_ANSI_KeypadEnter] {
                let event = AwayInputEvent(
                    type: keyType,
                    keyCode: CGKeyCode(keyCode),
                    targetPID: appPID
                )
                #expect(disposition(event, policy: .pinEntry) == .allow)
            }
        }
    }

    @Test("PIN entry blocks letters modified digits and wrong targets")
    func pinEntryBlocksOtherKeyboardInput() {
        let events = [
            AwayInputEvent(
                type: .keyDown,
                keyCode: CGKeyCode(kVK_ANSI_A),
                targetPID: appPID
            ),
            AwayInputEvent(
                type: .keyDown,
                keyCode: CGKeyCode(kVK_ANSI_1),
                flags: [.maskShift],
                targetPID: appPID
            ),
            AwayInputEvent(
                type: .keyDown,
                keyCode: CGKeyCode(kVK_ANSI_Keypad1),
                flags: [.maskControl, .maskNumericPad],
                targetPID: appPID
            ),
            AwayInputEvent(
                type: .keyUp,
                keyCode: CGKeyCode(kVK_ANSI_1),
                flags: [.maskSecondaryFn],
                targetPID: appPID
            ),
            AwayInputEvent(
                type: .keyDown,
                keyCode: CGKeyCode(kVK_ANSI_1),
                targetPID: 99
            ),
            AwayInputEvent(type: .flagsChanged, targetPID: appPID),
        ]
        for event in events {
            #expect(disposition(event, policy: .pinEntry) == .block)
        }
    }

    @Test("PIN entry keeps screenshot shortcuts blocked")
    func pinEntryBlocksScreenshots() {
        let event = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_4),
            flags: [.maskCommand, .maskShift, .maskControl],
            targetPID: appPID
        )

        #expect(disposition(event, policy: .pinEntry) == .block)
    }

    @Test("Screenshot shortcuts stay blocked on key down and key up under system authentication")
    func screenshotStaysBlockedDuringSystemAuthentication() {
        let shortcuts: [(Int, CGEventFlags)] = [
            (kVK_ANSI_3, [.maskCommand, .maskShift]),
            (kVK_ANSI_4, [.maskCommand, .maskShift, .maskControl]),
            (kVK_ANSI_5, [.maskCommand, .maskShift, .maskAlternate]),
            (kVK_ANSI_6, [.maskCommand, .maskShift]),
        ]
        let keyTypes: [CGEventType] = [.keyDown, .keyUp]
        for keyType in keyTypes {
            for (keyCode, flags) in shortcuts {
                let event = AwayInputEvent(
                    type: keyType,
                    keyCode: CGKeyCode(keyCode),
                    flags: flags,
                    targetPID: appPID
                )
                #expect(disposition(event, policy: .systemAuthentication) == .block)
            }
        }
    }

    @Test("Required system keyboard shortcuts pass on key down and key up")
    func requiredSystemShortcutsPass() {
        let shortcuts: [(Int, CGEventFlags)] = [
            (kVK_Escape, [.maskCommand, .maskAlternate]),
            (kVK_ANSI_Q, [.maskCommand, .maskControl]),
            (kVK_ANSI_Q, [.maskCommand, .maskShift]),
            (kVK_ANSI_Q, [.maskCommand, .maskAlternate, .maskShift]),
        ]
        let keyTypes: [CGEventType] = [.keyDown, .keyUp]

        for keyType in keyTypes {
            for (keyCode, flags) in shortcuts {
                let event = AwayInputEvent(
                    type: keyType,
                    keyCode: CGKeyCode(keyCode),
                    flags: flags,
                    targetPID: 99
                )
                #expect(disposition(event, policy: .fullFiltering) == .allow)
            }
        }
    }

    @Test("Recovery shortcut modifier near misses stay blocked")
    func recoveryShortcutNearMissesStayBlocked() {
        let nearMisses: [(Int, CGEventFlags)] = [
            (kVK_Escape, [.maskCommand]),
            (kVK_Escape, [.maskCommand, .maskAlternate, .maskShift]),
            (kVK_ANSI_Q, [.maskCommand, .maskControl, .maskAlternate]),
            (kVK_ANSI_Q, [.maskCommand, .maskControl, .maskShift]),
            (kVK_ANSI_Q, [.maskCommand, .maskAlternate]),
            (kVK_ANSI_Q, [.maskCommand, .maskControl, .maskAlternate, .maskShift]),
        ]

        for (keyCode, flags) in nearMisses {
            let event = AwayInputEvent(
                type: .keyDown,
                keyCode: CGKeyCode(keyCode),
                flags: flags,
                targetPID: 99
            )
            #expect(disposition(event, policy: .fullFiltering) == .block)
        }
    }

    @Test("Command Q requests authenticated quit once per press")
    func commandQRequestsQuitOnce() {
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )
        var callbacks: [String] = []
        guardController.onActivity = { callbacks.append("activity") }
        guardController.onAuthenticationRequested = { callbacks.append("authentication") }
        guardController.onQuitRequested = { callbacks.append("quit") }

        let keyDown = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_Q),
            flags: [.maskCommand],
            targetPID: appPID
        )
        let repeatEvent = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_Q),
            flags: [.maskCommand],
            targetPID: appPID,
            isRepeat: true
        )
        let keyUp = AwayInputEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_ANSI_Q),
            flags: [.maskCommand],
            targetPID: appPID
        )

        #expect(guardController.handle(keyDown) == .requestQuit)
        #expect(guardController.handle(repeatEvent) == .block)
        #expect(guardController.handle(keyUp) == .block)
        #expect(callbacks == ["activity", "quit", "activity", "activity"])
    }

    @Test("Full filtering blocks key-up and modifier events")
    func fullFilteringBlocksKeyboardEdges() {
        let events = [
            AwayInputEvent(
                type: .keyUp,
                keyCode: CGKeyCode(kVK_ANSI_A),
                targetPID: appPID
            ),
            AwayInputEvent(type: .flagsChanged, targetPID: appPID),
        ]

        for event in events {
            #expect(disposition(event, policy: .fullFiltering) == .block)
        }
    }

    @Test("System authentication passes key-up and modifier events")
    func systemAuthenticationPassesKeyboardEdges() {
        let events = [
            AwayInputEvent(
                type: .keyUp,
                keyCode: CGKeyCode(kVK_ANSI_A),
                targetPID: 99
            ),
            AwayInputEvent(type: .flagsChanged, targetPID: 99),
        ]

        for event in events {
            #expect(disposition(event, policy: .systemAuthentication) == .allow)
        }
    }

    @Test("Scroll tablet and media input are blocked while power passes")
    func guardedEventClassesAreClassified() {
        let blockedEvents = [
            AwayInputEvent(type: .scrollWheel),
            AwayInputEvent(type: .tabletPointer),
            AwayInputEvent(type: .tabletProximity),
            AwayInputEvent(
                type: AwayInputFilter.systemDefinedEventType,
                systemSubtype: 8,
                systemKeyType: 0
            ),
        ]
        for event in blockedEvents {
            #expect(disposition(event, policy: .fullFiltering) == .block)
        }

        let power = AwayInputEvent(
            type: AwayInputFilter.systemDefinedEventType,
            systemSubtype: Int(NSEvent.EventSubtype.powerOff.rawValue)
        )
        let shutdown = AwayInputEvent(
            type: AwayInputFilter.systemDefinedEventType,
            flags: [.maskCommand, .maskControl, .maskAlternate],
            systemSubtype: 8,
            systemKeyType: 14
        )
        #expect(disposition(power, policy: .fullFiltering) == .allow)
        #expect(disposition(shutdown, policy: .fullFiltering) == .allow)
    }

    @Test("Shutdown key near misses stay blocked")
    func shutdownKeyNearMissesStayBlocked() {
        let nearMisses = [
            AwayInputEvent(
                type: AwayInputFilter.systemDefinedEventType,
                flags: [.maskCommand, .maskControl, .maskAlternate],
                systemSubtype: 7,
                systemKeyType: 14
            ),
            AwayInputEvent(
                type: AwayInputFilter.systemDefinedEventType,
                flags: [.maskCommand, .maskControl],
                systemSubtype: 8,
                systemKeyType: 14
            ),
            AwayInputEvent(
                type: AwayInputFilter.systemDefinedEventType,
                flags: [.maskCommand, .maskControl, .maskAlternate, .maskShift],
                systemSubtype: 8,
                systemKeyType: 14
            ),
            AwayInputEvent(
                type: AwayInputFilter.systemDefinedEventType,
                flags: [.maskCommand, .maskControl, .maskAlternate],
                systemSubtype: 8,
                systemKeyType: 13
            ),
        ]

        for event in nearMisses {
            #expect(disposition(event, policy: .fullFiltering) == .block)
        }
    }

    @Test("Mouse input reaches the curtain and restores dimmed visuals")
    func mouseInputPassesAndReportsActivity() {
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )
        var activityCount = 0
        guardController.onActivity = { activityCount += 1 }

        let event = AwayInputEvent(type: .leftMouseDown, targetPID: appPID)

        #expect(guardController.handle(event) == .allow)
        #expect(activityCount == 1)
    }

    @Test("Preflight installs an allow all tap and removes it")
    func preflightUsesTemporaryTap() {
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )

        #expect(guardController.preflight())
        #expect(tap.installCount == 1)
        #expect(tap.uninstallCount == 2)
        #expect(tap.isEnabled == false)
        #expect(guardController.isActive == false)
        #expect(tap.lastInstalledHandler?(.keyDown, keyboardEvent()) == true)
    }

    @Test("Event access reflects the last active tap preflight")
    func eventAccessReflectsTapPreflight() {
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )

        #expect(guardController.hasEventAccess == false)
        #expect(guardController.preflight())
        #expect(guardController.hasEventAccess)
        #expect(tap.installCount == 1)
        #expect(tap.uninstallCount == 2)
        #expect(guardController.isActive == false)
    }

    @Test("Event access request opens the matching privacy settings")
    func eventAccessRequestUsesMatchingSettingsFallback() {
        var isGranted = false
        var accessibilityOpenCount = 0
        var inputMonitoringOpenCount = 0
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { isGranted },
            accessibilityRequester: { isGranted },
            accessibilitySettingsOpener: { accessibilityOpenCount += 1 },
            inputMonitoringSettingsOpener: { inputMonitoringOpenCount += 1 },
            applicationPID: appPID
        )

        guardController.requestEventAccess()
        #expect(accessibilityOpenCount == 1)
        #expect(inputMonitoringOpenCount == 0)

        isGranted = true
        guardController.requestEventAccess()
        #expect(accessibilityOpenCount == 1)
        #expect(inputMonitoringOpenCount == 0)

        tap.installResults = [false]
        guardController.requestEventAccess()
        #expect(inputMonitoringOpenCount == 1)
    }

    @Test("Start creates a fresh active tap after preflight")
    func startCreatesTapAfterPreflight() {
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )

        #expect(guardController.preflight())
        #expect(guardController.start())
        #expect(tap.installCount == 2)
        #expect(guardController.isFilteringOperational)
    }

    @Test("Missing accessibility permission prevents preflight and start")
    func missingAccessibilityPermissionFailsClosed() {
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { false },
            applicationPID: appPID
        )
        var failures: [AwayInputGuardFailure] = []
        guardController.onFailure = { failures.append($0) }

        #expect(guardController.preflight() == false)
        #expect(guardController.start() == false)
        #expect(tap.installCount == 0)
        #expect(failures == [.accessibilityPermissionMissing, .accessibilityPermissionMissing])
    }

    @Test("Disabled tap is enabled before a single rebuild")
    func disabledTapRebuildsOnce() {
        let tap = RecordingAwayEventTapController()
        tap.enableRequestsSucceed = false
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )

        #expect(guardController.start())
        tap.isEnabled = false
        guardController.handleTapDisabled()

        #expect(tap.enableRequests == [true])
        #expect(tap.installCount == 2)
        #expect(guardController.isFilteringOperational)
    }

    @Test("Failed rebuild reports tap failure")
    func failedRebuildReportsFailure() {
        let tap = RecordingAwayEventTapController()
        tap.enableRequestsSucceed = false
        tap.installResults = [true, false]
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )
        var failures: [AwayInputGuardFailure] = []
        guardController.onFailure = { failures.append($0) }

        #expect(guardController.start())
        tap.isEnabled = false
        guardController.handleTapDisabled()

        #expect(tap.installCount == 2)
        #expect(guardController.isActive == false)
        #expect(failures == [.tapRecoveryFailed])
    }

    @Test("A failed rebuild can recover on the next explicit attempt")
    func failedRebuildCanRecoverLater() {
        let tap = RecordingAwayEventTapController()
        tap.enableRequestsSucceed = false
        tap.installResults = [true, false, true]
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID
        )

        #expect(guardController.start())
        tap.isEnabled = false
        guardController.handleTapDisabled()
        #expect(!guardController.isActive)

        guardController.handleTapDisabled()

        #expect(guardController.isFilteringOperational)
        #expect(guardController.lastFailure == nil)
        #expect(tap.installCount == 3)
    }

    @Test("Wake and session activation rebuild an armed session tap")
    func workspaceResumeRebuildsTap() {
        let center = NotificationCenter()
        let tap = RecordingAwayEventTapController()
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID,
            workspaceNotificationCenter: center
        )
        var restorationCount = 0
        guardController.onRestored = { restorationCount += 1 }
        #expect(guardController.start(policy: .pinEntry))

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(!guardController.isFilteringOperational)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        #expect(guardController.isFilteringOperational)
        #expect(tap.installCount == 3)
        #expect(tap.enableRequests == [false, false])
        #expect(restorationCount == 2)
        #expect(guardController.policy == .pinEntry)
    }

    @Test("Failed session tap restoration reports failure and can recover later")
    func workspaceRestorationFailureCanRecover() {
        let center = NotificationCenter()
        let tap = RecordingAwayEventTapController()
        tap.installResults = [true, false, true]
        let guardController = AwayInputGuard(
            tapController: tap,
            accessibilityTrusted: { true },
            applicationPID: appPID,
            workspaceNotificationCenter: center
        )
        var failures: [AwayInputGuardFailure] = []
        var restorationCount = 0
        guardController.onFailure = { failures.append($0) }
        guardController.onRestored = { restorationCount += 1 }
        #expect(guardController.start())

        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(!guardController.isFilteringOperational)
        #expect(failures == [.tapRecoveryFailed])

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(guardController.isFilteringOperational)
        #expect(restorationCount == 1)
    }

    @Test("Exit controls can request authentication through the guard")
    func exitControlRequestsAuthentication() {
        let guardController = AwayInputGuard(
            tapController: RecordingAwayEventTapController(),
            accessibilityTrusted: { true },
            applicationPID: appPID
        )
        var callbacks: [String] = []
        guardController.onActivity = { callbacks.append("activity") }
        guardController.onAuthenticationRequested = { callbacks.append("authentication") }

        guardController.requestAuthentication()

        #expect(callbacks == ["activity", "authentication"])
    }

    @Test("Configured Away shortcut requests authentication only on an exact first key down")
    func configuredAwayShortcutRequestsAuthentication() {
        let shortcut = ShortcutCodable(
            keyCode: kVK_ANSI_L,
            modifiers: UInt(cmdKey | optionKey)
        )
        let exact = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_L),
            flags: [.maskCommand, .maskAlternate]
        )
        let repeated = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_L),
            flags: [.maskCommand, .maskAlternate],
            isRepeat: true
        )
        let keyUp = AwayInputEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_ANSI_L),
            flags: [.maskCommand, .maskAlternate]
        )
        let missingModifier = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_L),
            flags: [.maskCommand]
        )
        let extraModifier = AwayInputEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_L),
            flags: [.maskCommand, .maskAlternate, .maskShift]
        )

        #expect(disposition(exact, policy: .fullFiltering, shortcut: shortcut) == .requestAuthentication)
        #expect(disposition(repeated, policy: .fullFiltering, shortcut: shortcut) == .block)
        #expect(disposition(keyUp, policy: .fullFiltering, shortcut: shortcut) == .block)
        #expect(disposition(missingModifier, policy: .fullFiltering, shortcut: shortcut) == .block)
        #expect(disposition(extraModifier, policy: .fullFiltering, shortcut: shortcut) == .block)
        #expect(disposition(exact, policy: .pinEntry, shortcut: shortcut) == .block)
    }

    private func disposition(
        _ event: AwayInputEvent,
        policy: AwayInputPolicy,
        shortcut: ShortcutCodable? = nil
    ) -> AwayInputDisposition {
        AwayInputFilter.disposition(
            for: event,
            policy: policy,
            applicationPID: appPID,
            authenticationShortcut: shortcut
        )
    }

    private func keyboardEvent() -> CGEvent {
        CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_A),
            keyDown: true
        )!
    }
}

@MainActor
private final class RecordingAwayEventTapController: AwayEventTapControlling {
    var isEnabled = false
    var enableRequestsSucceed = true
    var installResults: [Bool] = []
    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    private(set) var enableRequests: [Bool] = []
    private(set) var lastInstalledHandler: AwayEventTapHandler?

    func install(handler: @escaping AwayEventTapHandler) -> Bool {
        installCount += 1
        lastInstalledHandler = handler
        let result = installResults.isEmpty ? true : installResults.removeFirst()
        isEnabled = result
        return result
    }

    func setEnabled(_ enabled: Bool) {
        enableRequests.append(enabled)
        if !enabled || enableRequestsSucceed {
            isEnabled = enabled
        }
    }

    func uninstall() {
        uninstallCount += 1
        isEnabled = false
    }
}
