import Foundation
import Testing
@testable import Semper

@Suite("Audio automation state")
@MainActor
struct AudioAutomationStateTests {
    @Test("Mode overlays use the lowest owner gain and reveal the remaining owner")
    func overlayOwnership() {
        let store = AudioModeOverlayStore()
        let call = AudioAutomationOwner(rawValue: "call")
        let ping = AudioAutomationOwner(rawValue: "ping")
        var changed: [Set<String>] = []
        store.onChange = { changed.append($0) }

        #expect(store.setGain(0.25, for: "music", owner: call))
        #expect(store.setGain(0, for: "music", owner: ping))
        #expect(store.effectiveGain(for: "music") == 0)

        store.removeAll(for: ping)
        #expect(store.effectiveGain(for: "music") == 0.25)
        #expect(changed == [["music"], ["music"], ["music"]])
    }

    @Test("Invalid overlay gain is rejected")
    func invalidOverlay() {
        let store = AudioModeOverlayStore()
        let owner = AudioAutomationOwner(rawValue: "test")
        #expect(!store.setGain(-0.1, for: "music", owner: owner))
        #expect(!store.setGain(.nan, for: "music", owner: owner))
        #expect(store.effectiveGain(for: "music") == 1)
    }

    @Test("Replacing owner gains updates added and removed apps together")
    func replaceOwnerGains() {
        let store = AudioModeOverlayStore()
        let owner = AudioAutomationOwner(rawValue: "call")
        var changed: [Set<String>] = []
        store.onChange = { changed.append($0) }

        #expect(store.replaceGains(["music": 0.25, "video": 0.25], for: owner))
        #expect(store.replaceGains(["video": 0.25, "game": 0.25], for: owner))

        #expect(store.effectiveGain(for: "music") == 1)
        #expect(store.effectiveGain(for: "video") == 0.25)
        #expect(store.effectiveGain(for: "game") == 0.25)
        #expect(changed == [["music", "video"], ["music", "video", "game"]])
    }

    @Test("Replacing gains rejects the full invalid update")
    func invalidReplacement() {
        let store = AudioModeOverlayStore()
        let owner = AudioAutomationOwner(rawValue: "call")
        #expect(store.replaceGains(["music": 0.25], for: owner))
        #expect(!store.replaceGains(["music": 0.5, "video": 1.1], for: owner))
        #expect(store.effectiveGain(for: "music") == 0.25)
        #expect(store.effectiveGain(for: "video") == 1)
    }

    @Test("Repeated writes by one owner preserve the first original value")
    func recoveryPreservesOriginal() {
        let journal = AudioAutomationRecoveryJournal()
        let owner = AudioAutomationOwner(rawValue: "call")
        let key = AudioControlKey.appVolume(.persisted("music"))
        let first = journal.begin(owner: owner, key: key, original: .scalar(1))
        #expect(journal.confirm(first, applied: .scalar(0.5)))
        let second = journal.begin(owner: owner, key: key, original: .scalar(0.5))
        #expect(journal.confirm(second, applied: .scalar(0.25)))
        var current = AudioControlValue.scalar(0.25)

        let report = journal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )

        #expect(report.restored == [key])
        #expect(current == .scalar(1))
    }

    @Test("Recovery skips a value changed outside its claim")
    func recoverySkipsExternalChange() {
        let journal = AudioAutomationRecoveryJournal()
        let owner = AudioAutomationOwner(rawValue: "call")
        let key = AudioControlKey.appMute(.persisted("music"))
        let token = journal.begin(owner: owner, key: key, original: .flag(false))
        #expect(journal.confirm(token, applied: .flag(true)))

        let report = journal.restore(
            owner: owner,
            read: { _ in .flag(false) },
            write: { _, _ in true }
        )

        #expect(report.skipped == [key])
        #expect(report.restored.isEmpty)
    }

    @Test("Recovery accepts a quantized scalar readback")
    func recoveryAcceptsQuantizedScalar() {
        let journal = AudioAutomationRecoveryJournal()
        let owner = AudioAutomationOwner(rawValue: "safe-cap")
        let key = AudioControlKey.outputVolume("speaker")
        let token = journal.begin(owner: owner, key: key, original: .scalar(0.8))
        #expect(journal.confirm(token, applied: .scalar(0.4)))
        var current = AudioControlValue.scalar(0.405)

        let report = journal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )

        #expect(report.restored == [key])
        #expect(current == .scalar(0.8))
    }

    @Test("Rejected replacement restores the prior recovery claim")
    func rejectedReplacementPreservesClaim() {
        let journal = AudioAutomationRecoveryJournal()
        let owner = AudioAutomationOwner(rawValue: "call")
        let key = AudioControlKey.appVolume(.persisted("music"))
        let first = journal.begin(owner: owner, key: key, original: .scalar(1))
        #expect(journal.confirm(first, applied: .scalar(0.5)))

        let rejected = journal.begin(owner: owner, key: key, original: .scalar(0.5))
        journal.cancel(rejected)
        var current = AudioControlValue.scalar(0.5)
        let report = journal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )

        #expect(report.restored == [key])
        #expect(current == .scalar(1))
    }

    @Test("Failed recovery remains available for retry")
    func failedRecoveryCanRetry() {
        let journal = AudioAutomationRecoveryJournal()
        let owner = AudioAutomationOwner(rawValue: "call")
        let key = AudioControlKey.appVolume(.persisted("music"))
        let token = journal.begin(owner: owner, key: key, original: .scalar(1))
        #expect(journal.confirm(token, applied: .scalar(0.25)))
        var current = AudioControlValue.scalar(0.25)

        let failed = journal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, _ in false }
        )
        #expect(failed.failed == [key])

        let retried = journal.restore(
            owner: owner,
            read: { _ in current },
            write: { _, value in current = value; return true }
        )
        #expect(retried.restored == [key])
        #expect(current == .scalar(1))
    }

    @Test("Input policy follows explicit, guard, call, lock precedence")
    func inputPolicyPrecedence() {
        var coordinator = InputPolicyCoordinator()
        coordinator.setRequest(deviceUID: "lock", owner: .inputLock)
        coordinator.setRequest(deviceUID: "call", owner: .callMode)
        coordinator.setRequest(deviceUID: "guard", owner: .bluetoothGuard)
        coordinator.setRequest(deviceUID: "user", owner: .explicitUser)
        let available: Set<String> = ["lock", "call", "guard", "user"]

        #expect(coordinator.resolve(availableUIDs: available, currentUID: nil)
            == InputPolicyResolution(deviceUID: "user", owner: .explicitUser))
        coordinator.removeRequest(owner: .explicitUser)
        #expect(coordinator.resolve(availableUIDs: available, currentUID: nil)
            == InputPolicyResolution(deviceUID: "guard", owner: .bluetoothGuard))
        coordinator.removeRequest(owner: .bluetoothGuard)
        #expect(coordinator.resolve(availableUIDs: available, currentUID: nil)
            == InputPolicyResolution(deviceUID: "call", owner: .callMode))
    }

    @Test("Unavailable input request falls through and valid current input is retained")
    func unavailableInputFallback() {
        var coordinator = InputPolicyCoordinator()
        coordinator.setRequest(deviceUID: "missing", owner: .explicitUser)
        coordinator.setRequest(deviceUID: "lock", owner: .inputLock)
        #expect(coordinator.resolve(availableUIDs: ["lock"], currentUID: nil)
            == InputPolicyResolution(deviceUID: "lock", owner: .inputLock))

        coordinator.removeRequest(owner: .inputLock)
        #expect(coordinator.resolve(availableUIDs: ["current"], currentUID: "current")
            == InputPolicyResolution(deviceUID: "current", owner: nil))
    }

    @Test("Activity history is bounded and visible activity can be dismissed")
    func activityStore() {
        let store = AudioActivityStore(historyLimit: 2)
        store.record(
            presentation: AudioActivityPresentation(message: "One"),
            source: .system,
            reason: .deviceFallback
        )
        store.record(
            presentation: AudioActivityPresentation(message: "Two"),
            source: .automation,
            reason: .callMode
        )
        store.record(
            presentation: AudioActivityPresentation(message: "Three"),
            source: .automation,
            reason: .bluetoothGuard
        )

        #expect(store.history.map(\.presentation.message) == ["Two", "Three"])
        #expect(store.visibleActivity?.presentation.message == "Three")
        store.dismiss()
        #expect(store.visibleActivity == nil)
    }

    @Test("Clearing an activity action updates history and prevents execution")
    func clearActivityAction() {
        let store = AudioActivityStore()
        var executions = 0
        let id = store.record(
            presentation: AudioActivityPresentation(
                message: "Changed",
                actionTitle: "Undo"
            ),
            source: .popup,
            reason: .directUser,
            action: { executions += 1 }
        )

        store.clearAction(for: id)
        store.performVisibleAction()

        #expect(executions == 0)
        #expect(store.visibleActivity?.presentation.actionTitle == nil)
        #expect(store.history.last?.presentation.actionTitle == nil)
    }
}
