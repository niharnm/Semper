// SemperTests/SceneTestSupport.swift
import Foundation
import Synchronization
import Testing
@testable import Semper

nonisolated struct SceneMockError: Error, Equatable {
    let message: String
}

nonisolated struct SceneWriteRecord: Equatable, Sendable {
    let control: SceneControl
    let value: SceneValue
}

actor SceneOperationSuspension {
    private var isSuspended = false
    private var releaseRequested = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func suspend() async {
        if releaseRequested {
            releaseRequested = false
            return
        }

        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
            isSuspended = true
            let continuations = arrivalContinuations.values
            arrivalContinuations.removeAll()
            for continuation in continuations {
                continuation.resume(returning: true)
            }
        }
        isSuspended = false
    }

    func waitUntilSuspended() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isSuspended else { return true }
        let id = UUID()
        let arrived = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                arrivalContinuations[id] = continuation
            }
        } onCancel: {
            Task { await self.finishArrivalWait(id, result: false) }
        }
        return arrived && !Task.isCancelled
    }

    private func finishArrivalWait(_ id: UUID, result: Bool) {
        arrivalContinuations.removeValue(forKey: id)?.resume(returning: result)
    }

    func resume() {
        guard let suspensionContinuation else {
            releaseRequested = true
            return
        }
        self.suspensionContinuation = nil
        suspensionContinuation.resume()
    }
}

/// In-memory adapter standing in for all three domains. Records every write
/// attempt (including failed ones) in one global log so tests can assert
/// exact apply, rollback, and restore ordering across controls.
nonisolated final class SceneControlAdapterMock: SceneControlAdapting {
    private struct State {
        var capabilities: [SceneControl: SceneControlCapability] = [:]
        var values: [SceneControl: SceneValue] = [:]
        var failingReadControls: Set<SceneControl> = []
        var failingWriteControls: Set<SceneControl> = []
        var failingWriteValues: [SceneControl: SceneValue] = [:]
        var unavailableTargets: [SceneControl: String] = [:]
        var prerequisites: [SceneControl: [SceneControlPrerequisite]] = [:]
        var mutationsAfterWrite: [SceneControl: SceneWriteRecord] = [:]
        var readsToFailAfterWrite: [SceneControl: SceneControl] = [:]
        var stuckControls: Set<SceneControl> = []
        var readSuspensions: [SceneControl: SceneOperationSuspension] = [:]
        var writeSuspensions: [SceneControl: [SceneValue: SceneOperationSuspension]] = [:]
        var cancellationAwareReads = false
        var cancellationAwareWrites = false
        var writeLog: [SceneWriteRecord] = []
    }

    private let state = Mutex(State())

    func seed(_ control: SceneControl, capability: SceneControlCapability = .readWrite, value: SceneValue) {
        state.withLock {
            $0.capabilities[control] = capability
            $0.values[control] = value
        }
    }

    func setCapability(_ capability: SceneControlCapability, for control: SceneControl) {
        state.withLock { $0.capabilities[control] = capability }
    }

    /// Simulates external change (user drift) without logging a write.
    func setCurrentValue(_ value: SceneValue, for control: SceneControl) {
        state.withLock { $0.values[control] = value }
    }

    func currentValue(for control: SceneControl) -> SceneValue? {
        state.withLock { $0.values[control] }
    }

    func failReads(for control: SceneControl) {
        state.withLock { _ = $0.failingReadControls.insert(control) }
    }

    func rejectTarget(for control: SceneControl, reason: String) {
        state.withLock { $0.unavailableTargets[control] = reason }
    }

    func require(_ prerequisite: SceneControl, beforeWriting trigger: SceneControl) {
        state.withLock {
            $0.prerequisites[trigger, default: []].append(
                SceneControlPrerequisite(control: prerequisite)
            )
        }
    }

    func mutate(
        _ control: SceneControl,
        to value: SceneValue,
        afterWriting trigger: SceneControl
    ) {
        state.withLock {
            $0.mutationsAfterWrite[trigger] = SceneWriteRecord(
                control: control,
                value: value
            )
        }
    }

    func failReadsAfterWrite(
        for control: SceneControl,
        afterWriting trigger: SceneControl
    ) {
        state.withLock {
            $0.readsToFailAfterWrite[trigger] = control
        }
    }

    /// Fails writes to `control`; when `value` is given, only writes of that
    /// exact value fail, so targeted apply or rollback steps can be broken.
    func failWrites(for control: SceneControl, matching value: SceneValue? = nil) {
        state.withLock {
            if let value {
                $0.failingWriteValues[control] = value
            } else {
                _ = $0.failingWriteControls.insert(control)
            }
        }
    }

    func clearWriteFailures(for control: SceneControl) {
        state.withLock {
            $0.failingWriteControls.remove(control)
            $0.failingWriteValues[control] = nil
        }
    }

    /// Writes succeed but the stored value never changes, so readback
    /// verification fails.
    func stick(_ control: SceneControl) {
        state.withLock { _ = $0.stuckControls.insert(control) }
    }

    func makeReadsCancellationAware() {
        state.withLock { $0.cancellationAwareReads = true }
    }

    func makeWritesCancellationAware() {
        state.withLock { $0.cancellationAwareWrites = true }
    }

    func suspendNextRead(for control: SceneControl) -> SceneOperationSuspension {
        let suspension = SceneOperationSuspension()
        state.withLock { $0.readSuspensions[control] = suspension }
        return suspension
    }

    func suspendNextWrite(
        for control: SceneControl,
        matching value: SceneValue
    ) -> SceneOperationSuspension {
        let suspension = SceneOperationSuspension()
        state.withLock { $0.writeSuspensions[control, default: [:]][value] = suspension }
        return suspension
    }

    var writeLog: [SceneWriteRecord] {
        state.withLock { $0.writeLog }
    }

    // MARK: SceneControlAdapting

    func capability(for control: SceneControl) async -> SceneControlCapability {
        state.withLock { $0.capabilities[control] ?? .unsupported }
    }

    func preflightTarget(_ value: SceneValue, for control: SceneControl) async -> SceneTargetPreflight {
        state.withLock {
            $0.unavailableTargets[control].map(SceneTargetPreflight.unavailable) ?? .ready
        }
    }

    func prerequisites(
        of value: SceneValue,
        for control: SceneControl
    ) async -> [SceneControlPrerequisite] {
        state.withLock { $0.prerequisites[control] ?? [] }
    }

    func readValue(for control: SceneControl) async throws -> SceneValue {
        let suspension = state.withLock { $0.readSuspensions.removeValue(forKey: control) }
        if let suspension {
            await suspension.suspend()
        }
        if state.withLock({ $0.cancellationAwareReads }) {
            try Task.checkCancellation()
        }
        return try state.withLock {
            if $0.failingReadControls.contains(control) {
                throw SceneMockError(message: "read failed for \(control)")
            }
            guard let value = $0.values[control] else {
                throw SceneMockError(message: "no value seeded for \(control)")
            }
            return value
        }
    }

    func writeValue(_ value: SceneValue, for control: SceneControl) async throws {
        let suspension = state.withLock { state -> SceneOperationSuspension? in
            let suspension = state.writeSuspensions[control]?[value]
            state.writeSuspensions[control]?[value] = nil
            if state.writeSuspensions[control]?.isEmpty == true {
                state.writeSuspensions[control] = nil
            }
            return suspension
        }
        if let suspension {
            await suspension.suspend()
        }
        if state.withLock({ $0.cancellationAwareWrites }) {
            try Task.checkCancellation()
        }
        try state.withLock {
            $0.writeLog.append(SceneWriteRecord(control: control, value: value))
            if $0.failingWriteControls.contains(control) {
                throw SceneMockError(message: "write failed for \(control)")
            }
            if let failing = $0.failingWriteValues[control], failing == value {
                throw SceneMockError(message: "write failed for \(control)")
            }
            if !$0.stuckControls.contains(control) {
                $0.values[control] = value
            }
            if let mutation = $0.mutationsAfterWrite.removeValue(forKey: control) {
                $0.values[mutation.control] = mutation.value
            }
            if let failedRead = $0.readsToFailAfterWrite.removeValue(forKey: control) {
                _ = $0.failingReadControls.insert(failedRead)
            }
        }
    }
}

nonisolated enum SceneTestSupport {
    /// One mock serves audio, display, and power so ordering assertions can
    /// span domains through a single write log.
    static func registry(_ mock: SceneControlAdapterMock) -> SceneAdapterRegistry {
        SceneAdapterRegistry(audio: mock, display: mock, power: mock)
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperSceneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whole-second date so ISO 8601 journal encoding round-trips exactly.
    static let fixedDate = Date(timeIntervalSince1970: 1_757_000_000)
}

extension SceneOperationSuspension {
    fileprivate var pendingArrivalWaiterCount: Int { arrivalContinuations.count }

    fileprivate func suspendCancelling(_ waiter: Task<Bool, Never>) async {
        waiter.cancel()
        await suspend()
    }
}

@Suite("Scene operation suspension", .timeLimit(.minutes(1)))
@MainActor
struct SceneOperationSuspensionTests {
    @Test("Cancellation before arrival-wait entry does not register a continuation")
    func cancelledBeforeEntry() async {
        let suspension = SceneOperationSuspension()
        let waiter = Task { await suspension.waitUntilSuspended() }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(await suspension.pendingArrivalWaiterCount == 0)
    }

    @Test("Cancelling one registered waiter preserves another waiter's arrival")
    func cancellationDuringWaitPreservesOtherWaiter() async {
        let suspension = SceneOperationSuspension()
        let cancelledWaiter = Task { await suspension.waitUntilSuspended() }
        let remainingWaiter = Task { await suspension.waitUntilSuspended() }
        while await suspension.pendingArrivalWaiterCount < 2 && !Task.isCancelled {
            await Task.yield()
        }
        #expect(await suspension.pendingArrivalWaiterCount == 2)
        cancelledWaiter.cancel()
        #expect(await cancelledWaiter.value == false)
        #expect(await suspension.pendingArrivalWaiterCount == 1)
        let operation = Task { await suspension.suspend() }
        let arrived = await withTaskCancellationHandler {
            await remainingWaiter.value
        } onCancel: {
            remainingWaiter.cancel()
            Task { await suspension.resume() }
        }
        #expect(arrived)
        await suspension.resume()
        await operation.value
        #expect(await suspension.pendingArrivalWaiterCount == 0)
    }

    @Test("Cancellation wins when arrival precedes the queued cancellation callback")
    func cancellationRacingArrival() async {
        let suspension = SceneOperationSuspension()
        let waiter = Task { await suspension.waitUntilSuspended() }
        while await suspension.pendingArrivalWaiterCount == 0 && !Task.isCancelled {
            await Task.yield()
        }
        let operation = Task { await suspension.suspendCancelling(waiter) }
        #expect(await waiter.value == false)
        await suspension.resume()
        await operation.value
        #expect(await suspension.pendingArrivalWaiterCount == 0)
    }

    @Test("Arrival remains observable until the held operation is resumed")
    func arrivalBeforeWaitIsObserved() async {
        let suspension = SceneOperationSuspension()
        let operation = Task { await suspension.suspend() }
        #expect(await suspension.waitUntilSuspended())
        #expect(await suspension.waitUntilSuspended())
        await suspension.resume()
        await operation.value
        #expect(await suspension.pendingArrivalWaiterCount == 0)
    }

    @Test("Cleanup before operation entry releases its later suspension")
    func resumeBeforeSuspend() async {
        let suspension = SceneOperationSuspension()
        await suspension.resume()
        await withTaskCancellationHandler {
            await suspension.suspend()
        } onCancel: {
            Task { await suspension.resume() }
        }
        #expect(await suspension.pendingArrivalWaiterCount == 0)
    }
}
