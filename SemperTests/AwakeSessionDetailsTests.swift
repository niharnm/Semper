import AppKit
import Foundation
import IOKit.pwr_mgt
import SwiftUI
import Testing
@testable import Semper

@Suite("Awake session presentation")
struct AwakeSessionPresentationTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Countdown handles hour and minute boundaries with spoken units")
    func countdownBoundaries() {
        let session = AwakeSession(
            duration: .twoHours, keepsDisplayAwake: false,
            startedAt: start, endsAt: start.addingTimeInterval(7_200), reason: "Render export"
        )
        let hour = AwakeSessionPresentation(session: session, now: start.addingTimeInterval(3_600))
        #expect(hour.remainingText == "1:00:00 remaining")
        #expect(hour.remainingAccessibilityText == "1 hour remaining")
        #expect(hour.reason == "Render export")

        let minute = AwakeSessionPresentation(session: session, now: start.addingTimeInterval(7_139))
        #expect(minute.remainingText == "1:01 remaining")
        #expect(minute.remainingAccessibilityText == "1 minute, 1 second remaining")

        let seconds = AwakeSessionPresentation(session: session, now: start.addingTimeInterval(7_198.8))
        #expect(seconds.remainingText == "0:02 remaining")
        #expect(seconds.remainingAccessibilityText == "2 seconds remaining")
    }

    @Test("Elapsed deadlines never show a negative countdown or an active time limit")
    func elapsedCountdown() {
        let session = AwakeSession(
            duration: .thirtyMinutes, keepsDisplayAwake: false,
            startedAt: start, endsAt: start.addingTimeInterval(1_800)
        )
        let deadline = AwakeSessionPresentation(session: session, now: start.addingTimeInterval(1_800))
        let later = AwakeSessionPresentation(session: session, now: start.addingTimeInterval(9_000))
        #expect(deadline.remainingText == "Time elapsed")
        #expect(later == deadline)
        #expect(later.remainingAccessibilityText == "The session time has elapsed.")
    }

    @Test("Indefinite sessions explain condition stops and use the default reason")
    func indefiniteCountdown() {
        let session = AwakeSession(
            duration: .untilTurnedOff, keepsDisplayAwake: true,
            startedAt: start, endsAt: nil, reason: ""
        )
        let presentation = AwakeSessionPresentation(session: session, now: start.addingTimeInterval(999_999))
        #expect(presentation.reason == "Manual Awake session")
        #expect(presentation.remainingText == "No time limit")
        #expect(presentation.remainingAccessibilityText.contains("stop condition"))
    }

    @Test("Battery copy distinguishes missing observation, unknown state, desktop, AC and battery")
    func batteryStates() {
        #expect(AwakeSessionPresentation.batteryStatus(nil) == "Battery state is checked when the session starts.")
        let unknown = AwakeSessionPresentation.batteryStatus(.init(selectedApplicationRunning: nil, battery: .unknown))
        #expect(unknown == "Battery state unknown. Awake needs a reading to use the cutoff.")
        let desktop = AwakeSessionPresentation.batteryStatus(.init(selectedApplicationRunning: nil, battery: .noBattery))
        #expect(desktop == "No battery detected; cutoff does not apply.")
        let external = AwakeSessionPresentation.batteryStatus(.init(selectedApplicationRunning: nil, battery: .externalPower(percentage: 20)))
        #expect(external == "Plugged in, battery 20%. Cutoff is ignored.")
        let externalUnknown = AwakeSessionPresentation.batteryStatus(.init(selectedApplicationRunning: nil, battery: .externalPower(percentage: nil)))
        #expect(externalUnknown == "Plugged in. Battery percentage unknown; cutoff is ignored.")
        let battery = AwakeSessionPresentation.batteryStatus(.init(selectedApplicationRunning: nil, battery: .battery(percentage: 19)))
        #expect(battery == "On battery, 19%.")
    }

    @Test("Stop messages name the actual condition without claiming that other requests ended")
    func stopReasons() {
        #expect(AwakeSessionPresentation.endReasonText(.selectedApplicationExited("Keynote")) == "Keynote is no longer running. Manual session ended.")
        #expect(AwakeSessionPresentation.endReasonText(.batteryThresholdReached(20)) == "Battery is at or below 20%. Manual session ended.")
        #expect(AwakeSessionPresentation.endReasonText(.expired) == "The timed Awake session ended.")
        #expect(AwakeSessionPresentation.endReasonText(.batteryStateUnavailable).contains("needs a reading"))
        #expect(AwakeSessionPresentation.endReasonText(.conditionMonitoringUnavailable).contains("could not watch"))
    }

    @Test("Other Awake owners are listed in a stable order and omitted when absent")
    func ownerSummary() {
        #expect(AwakeSessionPresentation.leaseOwners([:], manualSessionActive: false) == nil)
        let states: [AwakeLeaseOwner: AwakeLeaseState] = [
            .presentation: .init(owner: .presentation, keepsDisplayAwake: true, deadline: start),
            .awayMode: .init(owner: .awayMode, keepsDisplayAwake: false),
            .scene: .init(owner: .scene, keepsDisplayAwake: false)
        ]
        #expect(AwakeSessionPresentation.leaseOwners(states, manualSessionActive: false) == "Kept awake by Away, Scenes, Presentation.")
        #expect(AwakeSessionPresentation.leaseOwners(states, manualSessionActive: true) == "Also kept awake by Away, Scenes, Presentation.")
    }
}

@MainActor
private final class AwakeViewFixtureBackend: PowerAssertionCreating {
    var failsCreation = false
    var failsRelease = false
    private var nextID: PowerAssertionID = 1

    func createAssertion(
        kind: PowerAssertionKind, reason: String, timeout: TimeInterval?
    ) throws(PowerAssertionError) -> PowerAssertionID {
        if failsCreation { throw .creationFailed(kIOReturnError) }
        defer { nextID += 1 }
        return nextID
    }

    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        if failsRelease { throw .releaseFailed(kIOReturnError) }
    }
}

@MainActor
private final class AwakeViewFixtureMonitor: AwakeConditionMonitoring {
    var state = AwakeConditionSnapshot(selectedApplicationRunning: true, battery: .battery(percentage: 71))

    func availableApplications() -> [AwakeApplication] { [] }
    func snapshot(for conditions: AwakeStopConditions) -> AwakeConditionSnapshot { state }
    func start(
        conditions: AwakeStopConditions,
        onChange: @escaping @MainActor @Sendable (AwakeConditionSnapshot) -> Void
    ) throws(AwakeConditionMonitorError) {
        onChange(state)
    }
    func stop() {}
}

@MainActor
private final class AwakeViewFixtureScheduler: AwakeExpiryScheduling {
    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {}
    func cancelScheduledExpiry() {}
}

@MainActor
@Suite("Awake native view fixtures")
struct AwakeSessionDetailsTests {
    enum Fixture: String, CaseIterable, Sendable {
        case inactive, bounded, indefinite, longApplication, batteryUnknown, startFailure, releaseFailure, otherOwners, admissionDenied
    }

    @Test("Awake controls render within compact and regular popup widths", arguments: Fixture.allCases, [260.0, 360.0])
    func rendersFixture(fixture: Fixture, width: Double) throws {
        let backend = AwakeViewFixtureBackend()
        let monitor = AwakeViewFixtureMonitor()
        let now = Date()
        let service = AwakeService(
            backend: backend,
            scheduler: AwakeViewFixtureScheduler(),
            now: { now },
            workspaceNotificationCenter: NotificationCenter(),
            conditionMonitor: monitor,
            manualMutationAllowed: { fixture != .admissionDenied }
        )
        defer {
            backend.failsRelease = false
            service.shutdown()
        }
        switch fixture {
        case .inactive:
            break
        case .bounded:
            service.setSessionReason("Design review")
            service.start(.twoHours)
        case .indefinite:
            service.start(.untilTurnedOff)
        case .longApplication:
            let application = AwakeApplication(
                id: .init(processIdentifier: 42_424, launchDate: now),
                name: "A very long application name with multiple words and a second running instance"
            )
            service.setConditions(.init(application: application, batteryThreshold: .twenty))
            service.setSessionReason("Keep the quarterly design review available while the presentation application remains open")
            service.start(.oneHour)
        case .batteryUnknown:
            monitor.state = .init(selectedApplicationRunning: nil, battery: .unknown)
            service.setConditions(.init(batteryThreshold: .twenty))
            service.start(.oneHour)
        case .startFailure:
            backend.failsCreation = true
            service.start(.oneHour)
        case .releaseFailure:
            service.start(.oneHour)
            backend.failsRelease = true
            service.stop()
        case .otherOwners:
            _ = try service.acquireLease(owner: .awayMode, keepsDisplayAwake: false)
            _ = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
            _ = try service.acquireLease(owner: .presentation, keepsDisplayAwake: true, deadline: now.addingTimeInterval(3_600))
        case .admissionDenied:
            service.start(.oneHour)
        }

        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: AwakeModuleView(awake: service)
                .frame(width: width)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.setFrameSize(hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        #expect(hostingView.window == nil)
        #expect(abs(hostingView.bounds.width - CGFloat(width)) < 0.5)
        #expect(abs(bitmap.size.width - CGFloat(width)) < 0.5)
        #expect(bitmap.size.height > 200)
        #expect(bitmap.size.height < 620, "Awake controls exceed the compact popup height budget")
        #expect(bitmap.pixelsWide == Int(width) || bitmap.pixelsWide == Int(width) * 2)
        let backingScale = bitmap.pixelsWide / Int(width)
        #expect(bitmap.pixelsHigh == Int((hostingView.bounds.height * CGFloat(backingScale)).rounded(.up)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(png, named: "awake-native-\(fixture.rawValue)-\(Int(width)).png")
    }
}
