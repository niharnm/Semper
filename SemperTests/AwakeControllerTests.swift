import Foundation
import Testing
@testable import Semper

@MainActor
private final class AwakeActivityProviderSpy: AwakeActivityProviding {
    enum Event: Equatable {
        case begin(ProcessInfo.ActivityOptions, String)
        case end(ObjectIdentifier)
    }

    private(set) var events: [Event] = []
    private(set) var createdActivityIdentifiers: [ObjectIdentifier] = []
    var failNextBegin = false

    func beginActivity(
        options: ProcessInfo.ActivityOptions,
        reason: String
    ) -> NSObjectProtocol? {
        events.append(.begin(options, reason))

        if failNextBegin {
            failNextBegin = false
            return nil
        }

        let token = NSObject()
        createdActivityIdentifiers.append(ObjectIdentifier(token))
        return token
    }

    func endActivity(_ activity: NSObjectProtocol) {
        events.append(.end(ObjectIdentifier(activity)))
    }
}

@Suite("Awake controller")
@MainActor
struct AwakeControllerTests {
    @Test("System mode prevents only idle system sleep")
    func systemModeOptions() {
        let provider = AwakeActivityProviderSpy()
        let controller = AwakeController(activityProvider: provider)

        #expect(controller.apply(.system) == .applied)
        #expect(controller.activeMode == .system)
        #expect(controller.isActive)
        #expect(provider.events == [
            .begin(
                [.idleSystemSleepDisabled],
                "Semper is preventing system sleep."
            ),
        ])
    }

    @Test("Display mode prevents idle display and system sleep")
    func displayAndSystemModeOptions() {
        let provider = AwakeActivityProviderSpy()
        let controller = AwakeController(activityProvider: provider)

        #expect(controller.apply(.displayAndSystem) == .applied)
        #expect(provider.events == [
            .begin(
                [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                "Semper is preventing display and system sleep."
            ),
        ])
    }

    @Test("Reapplying the active mode is unchanged")
    func reapplyingModeIsUnchanged() {
        let provider = AwakeActivityProviderSpy()
        let controller = AwakeController(activityProvider: provider)

        #expect(controller.apply(.system) == .applied)
        #expect(controller.apply(.system) == .unchanged)
        #expect(provider.events.count == 1)
    }

    @Test("Mode replacement starts before the previous activity ends")
    func replacementOrdering() {
        let provider = AwakeActivityProviderSpy()
        let controller = AwakeController(activityProvider: provider)

        #expect(controller.apply(.system) == .applied)
        #expect(controller.apply(.displayAndSystem) == .applied)
        #expect(controller.activeMode == .displayAndSystem)
        let originalActivityIdentifier = provider.createdActivityIdentifiers[0]
        #expect(provider.events == [
            .begin(
                [.idleSystemSleepDisabled],
                "Semper is preventing system sleep."
            ),
            .begin(
                [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                "Semper is preventing display and system sleep."
            ),
            .end(originalActivityIdentifier),
        ])
    }

    @Test("Failed replacement retains the prior mode and token")
    func failedReplacementRetainsPriorActivity() {
        let provider = AwakeActivityProviderSpy()
        let controller = AwakeController(activityProvider: provider)

        #expect(controller.apply(.system) == .applied)
        provider.failNextBegin = true

        #expect(controller.apply(.displayAndSystem) == .failed)
        #expect(controller.activeMode == .system)
        #expect(controller.isActive)
        let priorActivityIdentifier = provider.createdActivityIdentifiers[0]
        #expect(provider.events == [
            .begin(
                [.idleSystemSleepDisabled],
                "Semper is preventing system sleep."
            ),
            .begin(
                [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                "Semper is preventing display and system sleep."
            ),
        ])

        controller.stop()
        #expect(provider.events.last == .end(priorActivityIdentifier))
    }

    @Test("Initial failure leaves the controller inactive")
    func failedInitialApply() {
        let provider = AwakeActivityProviderSpy()
        provider.failNextBegin = true
        let controller = AwakeController(activityProvider: provider)

        #expect(controller.apply(.system) == .failed)
        #expect(controller.activeMode == nil)
        #expect(!controller.isActive)
    }

    @Test("Stop ends the owned token exactly once")
    func stopIsIdempotent() {
        let provider = AwakeActivityProviderSpy()
        let controller = AwakeController(activityProvider: provider)

        #expect(controller.apply(.system) == .applied)
        controller.stop()
        controller.stop()

        #expect(controller.activeMode == nil)
        #expect(!controller.isActive)
        let ownedActivityIdentifier = provider.createdActivityIdentifiers[0]
        #expect(provider.events == [
            .begin(
                [.idleSystemSleepDisabled],
                "Semper is preventing system sleep."
            ),
            .end(ownedActivityIdentifier),
        ])
    }
}
