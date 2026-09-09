import Foundation
import Testing
@testable import Semper

@Suite("Scene coordinator")
struct SceneCoordinatorTests {
    @Test("Required preflight failure aborts with zero writes")
    func requiredPreflightFailureDoesNotMutate() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        let missing = SceneControl.displayBrightness(displayID: "missing")
        let scene = SemperScene(name: "Cannot apply", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: missing, target: .number(0.8), importance: .required),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected required preflight to fail")
        } catch let error as SceneApplyError {
            #expect(error == .requiredPreflightFailed(failures: [
                ScenePreflightFailure(control: missing, reason: .capability(.unsupported)),
            ]))
        }

        #expect(fixture.mock.writeLog.isEmpty)
        #expect(try fixture.journal.load() == nil)
    }

    @Test("Required target failure aborts with zero writes")
    func requiredTargetFailureDoesNotMutate() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.rejectTarget(
            for: .audioOutputDevice,
            reason: "Audio output output.usb is disconnected."
        )
        let scene = SemperScene(name: "Disconnected", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected target preflight to fail")
        } catch let error as SceneApplyError {
            #expect(error == .requiredPreflightFailed(failures: [
                ScenePreflightFailure(
                    control: .audioOutputDevice,
                    reason: .targetUnavailable("Audio output output.usb is disconnected.")
                ),
            ]))
        }

        #expect(fixture.mock.writeLog.isEmpty)
        #expect(try fixture.journal.load() == nil)
    }

    @Test("Unsupported optional actions are skipped without blocking supported actions")
    func optionalUnsupportedActionIsSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(volume, value: .number(0.25))
        let missing = SceneControl.displayContrast(displayID: "missing")
        let scene = SemperScene(name: "Partial", actions: [
            SceneAction(control: missing, target: .number(0.6), importance: .optional),
            SceneAction(control: volume, target: .number(0.75), importance: .required),
        ])

        let report = try await fixture.coordinator.apply(scene)

        #expect(report.transactionID != nil)
        #expect(report.applied.map(\.control) == [volume])
        #expect(report.skippedOptional == [
            SceneSkippedAction(control: missing, reason: .capability(.unsupported)),
        ])
        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: volume, value: .number(0.75)),
        ])
    }

    @Test("Actions apply in deterministic cross-domain order")
    func deterministicApplyOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let actions: [SceneAction] = [
            SceneAction(control: .displayContrast(displayID: "display-b"), target: .number(0.8), importance: .required),
            SceneAction(control: .audioOutputMuted(deviceID: "output.usb"), target: .boolean(true), importance: .required),
            SceneAction(control: .displayBrightness(displayID: "display-b"), target: .number(0.7), importance: .required),
            SceneAction(control: .audioOutputVolume(deviceID: "output.usb"), target: .number(0.6), importance: .required),
            SceneAction(control: .displayContrast(displayID: "display-a"), target: .number(0.5), importance: .required),
            SceneAction(control: .awakeMode, target: .awake(.displayAndSystem), importance: .required),
            SceneAction(control: .displayBrightness(displayID: "display-a"), target: .number(0.4), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
        ]
        Self.seedSnapshots(for: actions, in: fixture.mock)
        let expectedControls: [SceneControl] = [
            .awakeMode,
            .audioOutputVolume(deviceID: "output.usb"),
            .audioOutputMuted(deviceID: "output.usb"),
            .audioOutputDevice,
            .displayBrightness(displayID: "display-a"),
            .displayBrightness(displayID: "display-b"),
            .displayContrast(displayID: "display-a"),
            .displayContrast(displayID: "display-b"),
        ]

        let report = try await fixture.coordinator.apply(SemperScene(name: "Ordered", actions: actions))

        #expect(fixture.mock.writeLog.map(\.control) == expectedControls)
        #expect(report.applied.map(\.control) == expectedControls)
        #expect(try fixture.journal.load()?.entries.map(\.control) == expectedControls)
    }

    @Test(
        "Output restore failure defers dependent writes and restores independent state",
        arguments: [SceneActionImportance.required, .optional]
    )
    func outputRestoreFailureIsBarrier(outputImportance: SceneActionImportance) async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        let mute = SceneControl.audioOutputMuted(deviceID: "output.usb")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.seed(mute, value: .boolean(false))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        let scene = SemperScene(name: "Restore barrier", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: volume, target: .number(0.8), importance: .required),
            SceneAction(control: mute, target: .boolean(true), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: outputImportance),
        ])
        _ = try await fixture.coordinator.apply(scene)
        fixture.mock.failWrites(
            for: .audioOutputDevice,
            matching: .text("output.internal")
        )

        do {
            _ = try await fixture.coordinator.restore()
            Issue.record("Expected output restore to remain incomplete")
        } catch let error as SceneRestoreError {
            guard case .incomplete(let report) = error else {
                Issue.record("Unexpected restore error: \(error)")
                return
            }
            #expect(report.outcomes.count == 4)
            guard let outcome = report.outcomes.first,
                  case .failed(.audioOutputDevice, let reason) = outcome else {
                Issue.record("Expected the output route failure to defer dependent restoration")
                return
            }
            #expect(reason.contains("write failed"))
            #expect(report.outcomes.dropFirst() == [
                .failed(mute, reason: "Output route must be restored first."),
                .failed(volume, reason: "Output route must be restored first."),
                .restored(.awakeMode),
            ])
            #expect(!report.journalCleared)
        }

        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: volume, value: .number(0.8)),
            SceneWriteRecord(control: mute, value: .boolean(true)),
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.usb")),
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.internal")),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        let pending = try #require(try fixture.journal.load())
        #expect(pending.entries.map(\.phase).map(\.rawValue) == [
            SceneEntryPhase.restored.rawValue,
            SceneEntryPhase.applied.rawValue,
            SceneEntryPhase.applied.rawValue,
            SceneEntryPhase.applied.rawValue,
        ])
        #expect(fixture.mock.currentValue(for: volume) == .number(0.8))
        #expect(fixture.mock.currentValue(for: mute) == .boolean(true))
        #expect(fixture.mock.currentValue(for: .audioOutputDevice) == .text("output.usb"))
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.off))
    }

    @Test(
        "A settled or pending route is rechecked before dependent recovery",
        arguments: [SceneEntryPhase.pending, .restored]
    )
    func priorOutputPhaseIsRechecked(phase: SceneEntryPhase) async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(volume, value: .number(0.8))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.usb"))
        try fixture.journal.save(SceneTransaction(
            sceneID: UUID(),
            sceneName: "Interrupted route recovery",
            startedAt: SceneTestSupport.fixedDate,
            entries: [
                SceneTransactionEntry(
                    control: volume,
                    importance: .required,
                    snapshotValue: .number(0.2),
                    targetValue: .number(0.8),
                    appliedValue: .number(0.8),
                    phase: .applied
                ),
                SceneTransactionEntry(
                    control: .audioOutputDevice,
                    importance: .required,
                    snapshotValue: .text("output.internal"),
                    targetValue: .text("output.usb"),
                    appliedValue: phase == .restored ? .text("output.usb") : nil,
                    phase: phase
                ),
            ]
        ))

        do {
            _ = try await fixture.coordinator.restore()
            Issue.record("Expected the active scene route to block recovery")
        } catch let error as SceneRestoreError {
            guard case .incomplete(let report) = error else {
                Issue.record("Unexpected restore error: \(error)")
                return
            }
            #expect(report.outcomes.count == 2)
            guard let outcome = report.outcomes.first,
                  case .failed(.audioOutputDevice, _) = outcome else {
                Issue.record("Expected an output route barrier")
                return
            }
            #expect(report.outcomes.last == .failed(
                volume,
                reason: "Output route must be restored first."
            ))
        }

        #expect(fixture.mock.writeLog.isEmpty)
        #expect(fixture.mock.currentValue(for: volume) == .number(0.8))
        #expect(try fixture.journal.load() != nil)
    }

    @Test("An unreadable settled route blocks dependent recovery")
    func unreadableSettledOutputIsBarrier() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(volume, value: .number(0.8))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.failReads(for: .audioOutputDevice)
        try fixture.journal.save(SceneTransaction(
            sceneID: UUID(),
            sceneName: "Unreadable route recovery",
            startedAt: SceneTestSupport.fixedDate,
            entries: [
                SceneTransactionEntry(
                    control: volume,
                    importance: .required,
                    snapshotValue: .number(0.2),
                    targetValue: .number(0.8),
                    appliedValue: .number(0.8),
                    phase: .applied
                ),
                SceneTransactionEntry(
                    control: .audioOutputDevice,
                    importance: .required,
                    snapshotValue: .text("output.internal"),
                    targetValue: .text("output.usb"),
                    appliedValue: .text("output.usb"),
                    phase: .restored
                ),
            ]
        ))

        do {
            _ = try await fixture.coordinator.restore()
            Issue.record("Expected the unreadable route to block recovery")
        } catch let error as SceneRestoreError {
            guard case .incomplete(let report) = error else {
                Issue.record("Unexpected restore error: \(error)")
                return
            }
            #expect(report.outcomes.count == 2)
            guard let outcome = report.outcomes.first,
                  case .failed(.audioOutputDevice, _) = outcome else {
                Issue.record("Expected an output route read failure")
                return
            }
            #expect(report.outcomes.last == .failed(
                volume,
                reason: "Output route must be restored first."
            ))
        }

        #expect(fixture.mock.writeLog.isEmpty)
        #expect(fixture.mock.currentValue(for: volume) == .number(0.8))
        #expect(try fixture.journal.load() != nil)
    }

    @Test("Failed apply unwind defers dependent audio and restores Awake")
    func failedApplyOutputRestoreFailureIsBarrier() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        let mute = SceneControl.audioOutputMuted(deviceID: "output.usb")
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.seed(mute, value: .boolean(false))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.seed(display, value: .number(0.4))
        fixture.mock.failWrites(
            for: .audioOutputDevice,
            matching: .text("output.internal")
        )
        fixture.mock.failWrites(for: display, matching: .number(0.9))
        let scene = SemperScene(name: "Apply barrier", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: volume, target: .number(0.8), importance: .required),
            SceneAction(control: mute, target: .boolean(true), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
            SceneAction(control: display, target: .number(0.9), importance: .required),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected display apply to fail")
        } catch let error as SceneApplyError {
            guard case .actionFailed(let control, _, let cleanup) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(control == display)
            #expect(cleanup == .rollbackIncomplete(controls: [
                .audioOutputDevice,
                mute,
                volume,
            ]))
        }

        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: volume, value: .number(0.8)),
            SceneWriteRecord(control: mute, value: .boolean(true)),
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.usb")),
            SceneWriteRecord(control: display, value: .number(0.9)),
            SceneWriteRecord(control: display, value: .number(0.4)),
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.internal")),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        let pending = try #require(try fixture.journal.load())
        #expect(pending.entries.map(\.phase).map(\.rawValue) == [
            SceneEntryPhase.rolledBack.rawValue,
            SceneEntryPhase.applied.rawValue,
            SceneEntryPhase.applied.rawValue,
            SceneEntryPhase.applied.rawValue,
            SceneEntryPhase.rolledBack.rawValue,
        ])
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.off))
        #expect(fixture.mock.currentValue(for: volume) == .number(0.8))
        #expect(fixture.mock.currentValue(for: mute) == .boolean(true))
        #expect(fixture.mock.currentValue(for: .audioOutputDevice) == .text("output.usb"))
    }

    @Test("Output already at its snapshot does not block failed apply unwind")
    func outputAlreadyAtSnapshotDoesNotBlockUnwind() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        let mute = SceneControl.audioOutputMuted(deviceID: "output.usb")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.seed(mute, value: .boolean(false))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.mutate(
            .audioOutputDevice,
            to: .text("output.internal"),
            afterWriting: .audioOutputDevice
        )
        fixture.mock.failWrites(
            for: .audioOutputDevice,
            matching: .text("output.internal")
        )
        let scene = SemperScene(name: "Already restored route", actions: [
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: volume, target: .number(0.8), importance: .required),
            SceneAction(control: mute, target: .boolean(true), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected output readback to fail")
        } catch let error as SceneApplyError {
            guard case .actionFailed(let control, _, let cleanup) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(control == .audioOutputDevice)
            #expect(cleanup == .rolledBack)
        }

        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: volume, value: .number(0.8)),
            SceneWriteRecord(control: mute, value: .boolean(true)),
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.usb")),
            SceneWriteRecord(control: mute, value: .boolean(false)),
            SceneWriteRecord(control: volume, value: .number(0.2)),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        #expect(try fixture.journal.load() == nil)
    }

    @Test("Optional output prewrite drift blocks dependent unwind")
    func optionalOutputPrewriteDriftIsBarrier() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        let mute = SceneControl.audioOutputMuted(deviceID: "output.usb")
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.seed(mute, value: .boolean(false))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.seed(display, value: .number(0.4))
        fixture.mock.mutate(
            .audioOutputDevice,
            to: .text("output.usb"),
            afterWriting: mute
        )
        fixture.mock.failWrites(for: display, matching: .number(0.9))
        let scene = SemperScene(name: "Optional output drift", actions: [
            SceneAction(control: volume, target: .number(0.8), importance: .required),
            SceneAction(control: mute, target: .boolean(true), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .optional),
            SceneAction(control: display, target: .number(0.9), importance: .required),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected display apply to fail")
        } catch let error as SceneApplyError {
            guard case .actionFailed(let control, _, let cleanup) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(control == display)
            #expect(cleanup == .rollbackIncomplete(controls: [
                .audioOutputDevice,
                mute,
                volume,
            ]))
        }

        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: volume, value: .number(0.8)),
            SceneWriteRecord(control: mute, value: .boolean(true)),
            SceneWriteRecord(control: display, value: .number(0.9)),
            SceneWriteRecord(control: display, value: .number(0.4)),
        ])
        #expect(fixture.mock.currentValue(for: volume) == .number(0.8))
        #expect(fixture.mock.currentValue(for: mute) == .boolean(true))
        #expect(fixture.mock.currentValue(for: .audioOutputDevice) == .text("output.usb"))
        #expect(try fixture.journal.load() != nil)
    }

    @Test("A write failure rolls back in reverse order")
    func writeFailureRollsBackInReverse() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.failWrites(for: volume, matching: .number(0.8))
        let scene = SemperScene(name: "Write failure", actions: [
            SceneAction(control: volume, target: .number(0.8), importance: .required),
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected scene write to fail")
        } catch let error as SceneApplyError {
            guard case .actionFailed(let control, _, let cleanup) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(control == volume)
            #expect(cleanup == .rolledBack)
        }

        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: volume, value: .number(0.8)),
            SceneWriteRecord(control: volume, value: .number(0.2)),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.off))
        #expect(fixture.mock.currentValue(for: .audioOutputDevice) == .text("output.internal"))
        #expect(fixture.mock.currentValue(for: volume) == .number(0.2))
        #expect(try fixture.journal.load() == nil)
    }

    @Test("A readback mismatch rolls back the failed write and prior writes in reverse order")
    func readbackFailureRollsBackInReverse() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.stick(volume)
        let scene = SemperScene(name: "Readback failure", actions: [
            SceneAction(control: volume, target: .number(0.8), importance: .required),
            SceneAction(control: .awakeMode, target: .awake(.system), importance: .required),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected scene readback to fail")
        } catch let error as SceneApplyError {
            guard case .actionFailed(let control, let reason, let cleanup) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(control == volume)
            #expect(reason.contains("did not match target"))
            #expect(cleanup == .rolledBack)
        }

        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: volume, value: .number(0.8)),
            SceneWriteRecord(control: volume, value: .number(0.2)),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        #expect(try fixture.journal.load() == nil)
    }

    @Test("An optional write failure rolls back that control and continues")
    func optionalWriteFailureContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(display, value: .number(0.4))
        fixture.mock.failWrites(for: display, matching: .number(0.9))
        let scene = SemperScene(name: "Optional", actions: [
            SceneAction(
                control: .awakeMode,
                target: .awake(.system),
                importance: .required
            ),
            SceneAction(
                control: display,
                target: .number(0.9),
                importance: .optional
            ),
        ])

        let report = try await fixture.coordinator.apply(scene)

        #expect(report.applied.map(\.control) == [.awakeMode])
        #expect(report.skippedOptional.count == 1)
        #expect(report.skippedOptional.first?.control == display)
        guard case .writeFailed(let reason) = report.skippedOptional.first?.reason else {
            Issue.record("Expected optional write failure")
            return
        }
        #expect(reason.contains("write failed"))
        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: display, value: .number(0.9)),
            SceneWriteRecord(control: display, value: .number(0.4)),
        ])
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.system))
        #expect(fixture.mock.currentValue(for: display) == .number(0.4))
    }

    @Test("An optional control changed after preflight is skipped")
    func optionalChangedSnapshotContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(display, value: .number(0.4))
        fixture.mock.mutate(
            display,
            to: .number(0.5),
            afterWriting: .awakeMode
        )
        let scene = SemperScene(name: "Optional drift", actions: [
            SceneAction(
                control: .awakeMode,
                target: .awake(.system),
                importance: .required
            ),
            SceneAction(
                control: display,
                target: .number(0.9),
                importance: .optional
            ),
        ])

        let report = try await fixture.coordinator.apply(scene)

        #expect(report.applied.map(\.control) == [.awakeMode])
        #expect(report.skippedOptional.count == 1)
        #expect(report.skippedOptional.first?.control == display)
        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
        ])
        #expect(fixture.mock.currentValue(for: display) == .number(0.5))
    }

    @Test("An optional control disconnected after preflight is skipped")
    func optionalDisconnectContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(display, value: .number(0.4))
        fixture.mock.failReadsAfterWrite(
            for: display,
            afterWriting: .awakeMode
        )
        let scene = SemperScene(name: "Optional disconnect", actions: [
            SceneAction(
                control: .awakeMode,
                target: .awake(.system),
                importance: .required
            ),
            SceneAction(
                control: display,
                target: .number(0.9),
                importance: .optional
            ),
        ])

        let report = try await fixture.coordinator.apply(scene)

        #expect(report.applied.map(\.control) == [.awakeMode])
        #expect(report.skippedOptional.count == 1)
        #expect(report.skippedOptional.first?.control == display)
        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
        ])
    }

    @Test("A value changed after preflight aborts before its write")
    func changedSnapshotAbortsBeforeWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.mutate(
            volume,
            to: .number(0.3),
            afterWriting: .awakeMode
        )
        let scene = SemperScene(name: "Race", actions: [
            SceneAction(
                control: .awakeMode,
                target: .awake(.system),
                importance: .required
            ),
            SceneAction(
                control: volume,
                target: .number(0.8),
                importance: .required
            ),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected changed snapshot to abort apply")
        } catch let error as SceneApplyError {
            guard case .actionFailed(let control, let reason, let cleanup) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(control == volume)
            #expect(reason.contains("changed after preflight"))
            #expect(cleanup == .rolledBack)
        }

        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        #expect(fixture.mock.currentValue(for: volume) == .number(0.3))
        #expect(try fixture.journal.load() == nil)
    }

    @Test("Restore runs in reverse order and leaves drifted controls alone")
    func driftAwareReverseRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        let actions: [SceneAction] = [
            SceneAction(control: .displayBrightness(displayID: "display-a"), target: .number(0.9), importance: .required),
            SceneAction(control: volume, target: .number(0.8), importance: .required),
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
            SceneAction(control: .awakeMode, target: .awake(.displayAndSystem), importance: .required),
        ]
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.seed(.displayBrightness(displayID: "display-a"), value: .number(0.4))
        _ = try await fixture.coordinator.apply(SemperScene(name: "Restore", actions: actions))
        fixture.mock.setCurrentValue(.text("output.hdmi"), for: .audioOutputDevice)

        let report = try #require(try await fixture.coordinator.restore())

        #expect(report.outcomes == [
            .restored(.displayBrightness(displayID: "display-a")),
            .skippedDrift(.audioOutputDevice, currentValue: .text("output.hdmi")),
            .restored(volume),
            .restored(.awakeMode),
        ])
        #expect(report.journalCleared)
        #expect(Array(fixture.mock.writeLog.suffix(3)) == [
            SceneWriteRecord(control: .displayBrightness(displayID: "display-a"), value: .number(0.4)),
            SceneWriteRecord(control: volume, value: .number(0.2)),
            SceneWriteRecord(control: .awakeMode, value: .awake(.off)),
        ])
        #expect(fixture.mock.currentValue(for: .audioOutputDevice) == .text("output.hdmi"))
        #expect(try fixture.journal.load() == nil)
    }

    @Test("Journal recovery resolves pending and in-flight entries")
    func journalRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let display = SceneControl.displayBrightness(displayID: "display-a")
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        fixture.mock.seed(.audioOutputDevice, value: .text("output.usb"))
        fixture.mock.seed(volume, value: .number(0.2))
        fixture.mock.seed(display, value: .number(0.89))
        let transaction = SceneTransaction(
            id: UUID(uuidString: "0ED27CB1-9E6B-4E77-A2E3-EBD58BDDC05F")!,
            sceneID: UUID(uuidString: "72FB9C62-2912-46D5-83C6-87D6B2258534")!,
            sceneName: "Interrupted",
            startedAt: SceneTestSupport.fixedDate,
            entries: [
                SceneTransactionEntry(
                    control: .awakeMode,
                    importance: .required,
                    snapshotValue: .awake(.off),
                    targetValue: .awake(.system),
                    phase: .pending
                ),
                SceneTransactionEntry(
                    control: volume,
                    importance: .required,
                    snapshotValue: .number(0.2),
                    targetValue: .number(0.8),
                    phase: .inFlight
                ),
                SceneTransactionEntry(
                    control: .audioOutputDevice,
                    importance: .required,
                    snapshotValue: .text("output.internal"),
                    targetValue: .text("output.usb"),
                    phase: .inFlight
                ),
                SceneTransactionEntry(
                    control: display,
                    importance: .required,
                    snapshotValue: .number(0.4),
                    targetValue: .number(0.9),
                    appliedValue: .number(0.89),
                    phase: .applied
                ),
            ]
        )
        try fixture.journal.save(transaction)

        let report = try #require(try await fixture.coordinator.restore())

        #expect(report.outcomes == [
            .restored(display),
            .restored(.audioOutputDevice),
            .restored(volume),
            .untouched(.awakeMode),
        ])
        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: display, value: .number(0.4)),
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.internal")),
        ])
        #expect(report.journalCleared)
        #expect(try fixture.journal.load() == nil)
    }

    @Test("An in-flight quantized write restores within readback tolerance")
    func quantizedInFlightWriteRestores() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(volume, value: .number(0.895))
        try fixture.journal.save(SceneTransaction(
            sceneID: UUID(),
            sceneName: "Interrupted",
            startedAt: SceneTestSupport.fixedDate,
            entries: [
                SceneTransactionEntry(
                    control: volume,
                    importance: .required,
                    snapshotValue: .number(0.2),
                    targetValue: .number(0.9),
                    phase: .inFlight
                ),
            ]
        ))

        let report = try #require(try await fixture.coordinator.restore())

        #expect(report.outcomes == [.restored(volume)])
        #expect(fixture.mock.currentValue(for: volume) == .number(0.2))
        #expect(report.journalCleared)
    }

    @Test("A required control prerequisite fails before any write when missing")
    func missingRequiredPrerequisiteDoesNotMutate() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.require(volume, beforeWriting: .audioOutputDevice)
        let scene = SemperScene(name: "Route only", actions: [
            SceneAction(
                control: .audioOutputDevice,
                target: .text("output.usb"),
                importance: .required
            ),
        ])

        do {
            _ = try await fixture.coordinator.apply(scene)
            Issue.record("Expected prerequisite preflight to fail")
        } catch let error as SceneApplyError {
            guard case .requiredPreflightFailed(let failures) = error else {
                Issue.record("Unexpected scene apply error: \(error)")
                return
            }
            #expect(failures.count == 1)
            #expect(failures.first?.control == .audioOutputDevice)
        }
        #expect(fixture.mock.writeLog.isEmpty)
        #expect(try fixture.journal.load() == nil)
    }

    @Test("A prepared output volume restores after switching away")
    func prerequisiteVolumeUsesSafeRestoreOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(.audioOutputDevice, value: .text("output.internal"))
        fixture.mock.seed(volume, value: .number(0.8))
        fixture.mock.require(volume, beforeWriting: .audioOutputDevice)
        let scene = SemperScene(name: "Prepared route", actions: [
            SceneAction(control: .audioOutputDevice, target: .text("output.usb"), importance: .required),
            SceneAction(control: volume, target: .number(0.4), importance: .optional),
        ])

        _ = try await fixture.coordinator.apply(scene)
        let transaction = try #require(try fixture.journal.load())
        #expect(transaction.entries.map(\.control) == [volume, .audioOutputDevice])
        #expect(transaction.entries.first?.importance == .required)
        #expect(fixture.mock.writeLog == [
            SceneWriteRecord(control: volume, value: .number(0.4)),
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.usb")),
        ])

        let report = try #require(try await fixture.coordinator.restore())

        #expect(report.outcomes == [
            .restored(.audioOutputDevice),
            .restored(volume),
        ])
        #expect(Array(fixture.mock.writeLog.suffix(2)) == [
            SceneWriteRecord(control: .audioOutputDevice, value: .text("output.internal")),
            SceneWriteRecord(control: volume, value: .number(0.8)),
        ])
    }

    @Test("A one percent adjustment is preserved during restore")
    func onePercentAdjustmentIsDrift() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(volume, value: .number(0.2))
        let scene = SemperScene(name: "Volume", actions: [
            SceneAction(
                control: volume,
                target: .number(0.8),
                importance: .required
            ),
        ])
        _ = try await fixture.coordinator.apply(scene)
        fixture.mock.setCurrentValue(.number(0.79), for: volume)

        let report = try #require(try await fixture.coordinator.restore())

        #expect(report.outcomes == [
            .skippedDrift(volume, currentValue: .number(0.79)),
        ])
        #expect(fixture.mock.currentValue(for: volume) == .number(0.79))
        #expect(report.journalCleared)
    }

    @Test("A required unavailable control remains pending until reconnect")
    func requiredUnavailableControlCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let volume = SceneControl.audioOutputVolume(deviceID: "output.usb")
        fixture.mock.seed(volume, value: .number(0.2))
        let scene = SemperScene(name: "Reconnect", actions: [
            SceneAction(
                control: volume,
                target: .number(0.8),
                importance: .required
            ),
        ])
        _ = try await fixture.coordinator.apply(scene)
        fixture.mock.setCapability(.unsupported, for: volume)

        do {
            _ = try await fixture.coordinator.restore()
            Issue.record("Expected unavailable required restore to remain pending")
        } catch let error as SceneRestoreError {
            guard case .incomplete(let report) = error else {
                Issue.record("Unexpected restore error: \(error)")
                return
            }
            #expect(report.outcomes == [
                .failed(volume, reason: "Required control is unavailable."),
            ])
            #expect(!report.journalCleared)
        }
        #expect(try fixture.journal.load() != nil)

        fixture.mock.setCapability(.readWrite, for: volume)
        let report = try #require(try await fixture.coordinator.restore())

        #expect(report.outcomes == [.restored(volume)])
        #expect(fixture.mock.currentValue(for: volume) == .number(0.2))
        #expect(report.journalCleared)
        #expect(try fixture.journal.load() == nil)
    }

    @Test("An applied optional display remains pending until reconnect")
    func optionalDisplayUnavailableDuringRestoreCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let display = SceneControl.displayBrightness(displayID: "display-a")
        fixture.mock.seed(display, value: .number(0.4))
        let scene = SemperScene(name: "Display reconnect", actions: [
            SceneAction(
                control: display,
                target: .number(0.9),
                importance: .optional
            ),
        ])
        _ = try await fixture.coordinator.apply(scene)
        fixture.mock.setCapability(.unsupported, for: display)

        do {
            _ = try await fixture.coordinator.restore()
            Issue.record("Expected unavailable optional display restore to remain pending")
        } catch let error as SceneRestoreError {
            guard case .incomplete(let report) = error else {
                Issue.record("Unexpected restore error: \(error)")
                return
            }
            #expect(report.outcomes == [
                .failed(display, reason: "Optional control is unavailable."),
            ])
            #expect(!report.journalCleared)
        }
        let pending = try #require(try fixture.journal.load())
        let entry = try #require(pending.entries.first)
        #expect(entry.snapshotValue == .number(0.4))
        #expect(entry.phase == .applied)

        fixture.mock.setCapability(.readWrite, for: display)
        let report = try #require(try await fixture.coordinator.restore())

        #expect(report.outcomes == [.restored(display)])
        #expect(fixture.mock.currentValue(for: display) == .number(0.4))
        #expect(report.journalCleared)
        #expect(try fixture.journal.load() == nil)
    }

    @Test("A pending transaction can be abandoned explicitly")
    func abandonPendingTransaction() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        let transaction = SceneTransaction(
            sceneID: UUID(),
            sceneName: "Keep current",
            startedAt: SceneTestSupport.fixedDate,
            entries: [
                SceneTransactionEntry(
                    control: .awakeMode,
                    importance: .required,
                    snapshotValue: .awake(.off),
                    targetValue: .awake(.system),
                    appliedValue: .awake(.system),
                    phase: .applied
                ),
            ]
        )
        try fixture.journal.save(transaction)

        try await fixture.coordinator.abandonPendingTransaction()

        #expect(try fixture.journal.load() == nil)
        #expect(fixture.mock.writeLog.isEmpty)
    }

    @Test("Awake state restores after the applying process exits")
    func awakeRestoreAcrossProcessExit() async throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = SceneControlAdapterMock()
        let journal = FileSceneJournalStore(directory: directory)
        let firstSession = UUID()
        let secondSession = UUID()
        mock.seed(.awakeMode, value: .awake(.system))
        let firstCoordinator = SceneCoordinator(
            adapters: SceneTestSupport.registry(mock),
            journalStore: journal,
            now: { SceneTestSupport.fixedDate },
            sessionID: firstSession
        )
        let scene = SemperScene(name: "Awake", actions: [
            SceneAction(
                control: .awakeMode,
                target: .awake(.displayAndSystem),
                importance: .required
            ),
        ])
        _ = try await firstCoordinator.apply(scene)

        mock.setCurrentValue(.awake(.off), for: .awakeMode)
        let relaunchedCoordinator = SceneCoordinator(
            adapters: SceneTestSupport.registry(mock),
            journalStore: journal,
            now: { SceneTestSupport.fixedDate },
            sessionID: secondSession
        )
        let report = try #require(try await relaunchedCoordinator.restore())

        #expect(report.outcomes == [.restored(.awakeMode)])
        #expect(mock.currentValue(for: .awakeMode) == .awake(.system))
        #expect(mock.writeLog == [
            SceneWriteRecord(
                control: .awakeMode,
                value: .awake(.displayAndSystem)
            ),
            SceneWriteRecord(control: .awakeMode, value: .awake(.system)),
        ])
        #expect(report.journalCleared)
    }

    @Test("A user turning Awake off is preserved after relaunch")
    func awakeUserOverrideAcrossRelaunch() async throws {
        let directory = try SceneTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = SceneControlAdapterMock()
        let journal = FileSceneJournalStore(directory: directory)
        let awakeControl = SceneControl.awakeMode
        let displayControl = SceneControl.displayBrightness(displayID: "1:2:3")
        mock.seed(awakeControl, value: .awake(.system))
        mock.seed(displayControl, value: .number(0.2))
        let firstCoordinator = SceneCoordinator(
            adapters: SceneTestSupport.registry(mock),
            journalStore: journal,
            now: { SceneTestSupport.fixedDate },
            sessionID: UUID()
        )
        let scene = SemperScene(name: "Awake", actions: [
            SceneAction(
                control: awakeControl,
                target: .awake(.displayAndSystem),
                importance: .required
            ),
            SceneAction(
                control: displayControl,
                target: .number(0.8),
                importance: .required
            ),
        ])
        _ = try await firstCoordinator.apply(scene)

        let reservation = try #require(
            try await firstCoordinator.beginUserOverride(for: awakeControl)
        )
        mock.setCurrentValue(.awake(.off), for: awakeControl)
        #expect(try await firstCoordinator.commitUserOverride(reservation))

        let relaunchedCoordinator = SceneCoordinator(
            adapters: SceneTestSupport.registry(mock),
            journalStore: journal,
            now: { SceneTestSupport.fixedDate },
            sessionID: UUID()
        )
        let report = try #require(try await relaunchedCoordinator.restore())

        #expect(report.outcomes == [
            .restored(displayControl),
            .alreadySettled(awakeControl),
        ])
        #expect(mock.currentValue(for: awakeControl) == .awake(.off))
        #expect(mock.currentValue(for: displayControl) == .number(0.2))
        #expect(report.journalCleared)
    }

    @Test("A failed user Awake replacement keeps its restore record")
    func failedAwakeUserOverrideKeepsRestoreRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryDirectory() }
        fixture.mock.seed(.awakeMode, value: .awake(.off))
        let scene = SemperScene(name: "Awake", actions: [
            SceneAction(
                control: .awakeMode,
                target: .awake(.system),
                importance: .required
            ),
        ])
        _ = try await fixture.coordinator.apply(scene)

        let reservation = try #require(
            try await fixture.coordinator.beginUserOverride(for: .awakeMode)
        )
        #expect(try await fixture.coordinator.cancelUserOverride(reservation))

        let pending = try #require(try await fixture.coordinator.pendingTransaction())
        #expect(pending.entries.first?.phase == .applied)
        let report = try #require(try await fixture.coordinator.restore())
        #expect(report.outcomes == [.restored(.awakeMode)])
        #expect(fixture.mock.currentValue(for: .awakeMode) == .awake(.off))
    }

    private static func seedSnapshots(for actions: [SceneAction], in mock: SceneControlAdapterMock) {
        for action in actions {
            let value: SceneValue
            switch action.control.valueKind {
            case .number:
                value = .number(0.1)
            case .boolean:
                value = .boolean(false)
            case .text:
                value = .text("output.internal")
            case .awake:
                value = .awake(.off)
            }
            mock.seed(action.control, value: value)
        }
    }

    private final class Fixture {
        let directory: URL
        let mock: SceneControlAdapterMock
        let journal: FileSceneJournalStore
        let coordinator: SceneCoordinator

        init() throws {
            directory = try SceneTestSupport.makeTemporaryDirectory()
            mock = SceneControlAdapterMock()
            journal = FileSceneJournalStore(directory: directory)
            coordinator = SceneCoordinator(
                adapters: SceneTestSupport.registry(mock),
                journalStore: journal,
                now: { SceneTestSupport.fixedDate }
            )
        }

        func removeTemporaryDirectory() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
