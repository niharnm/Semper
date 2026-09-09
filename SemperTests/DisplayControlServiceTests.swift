#if !APP_STORE

import Foundation
import Synchronization
import Testing
@testable import Semper

private actor DisplayOperationTestSignal {
    private var isSignalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func send() {
        guard !isSignalled else { return }
        isSignalled = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private actor DisplayOperationTestGate {
    private let entered = DisplayOperationTestSignal()
    private let beforeContinuationRegistration: (@Sendable () async -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    init(beforeContinuationRegistration: (@Sendable () async -> Void)? = nil) {
        self.beforeContinuationRegistration = beforeContinuationRegistration
    }

    func wait() async {
        guard !isOpen else { return }
        await entered.send()
        if let beforeContinuationRegistration {
            await beforeContinuationRegistration()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        await entered.wait()
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private nonisolated final class DisplayThreadSignal: @unchecked Sendable {
    private struct State {
        var isSignalled = false
        var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }

    private let state = Mutex(State())

    func send() {
        let continuations = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            guard !state.isSignalled else { return [] }
            state.isSignalled = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume(returning: true) }
    }

    func wait() async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isSignalled else { return true }
                state.continuations[id] = continuation
                return false
            }
            if shouldResume {
                continuation.resume(returning: true)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishWait(id, result: false)
            }
        }
    }

    private func finishWait(_ id: UUID, result: Bool) {
        let continuation = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
        continuation?.resume(returning: result)
    }
}

private nonisolated final class DisplayRefreshOverlapTransport: @unchecked Sendable {
    private struct State {
        var readCount = 0
        var brightness: UInt16 = 40
    }

    let refreshReadStarted = DisplayThreadSignal()
    let setReadStarted = DisplayThreadSignal()
    private let allowRefreshRead = DispatchSemaphore(value: 0)
    private let allowSetRead = DispatchSemaphore(value: 0)
    private let state = Mutex(State())
    private let service = DDCService(service: kCFBooleanTrue)

    func discover() -> [DDCExternalDisplayRecord] {
        [DDCExternalDisplayRecord(
            registryID: DDCDisplayCandidate.ID(rawValue: 901),
            name: "Test Display",
            edid: DDCDisplayEDID(vendorID: 101, productID: 202, serialNumber: 303),
            service: service
        )]
    }

    func read(
        _ service: DDCService,
        feature: DisplayFeature
    ) throws -> (current: UInt16, maximum: UInt16) {
        let snapshot = state.withLock { state -> (readCount: Int, brightness: UInt16) in
            state.readCount += 1
            return (state.readCount, state.brightness)
        }
        if snapshot.readCount == 3 {
            refreshReadStarted.send()
            allowRefreshRead.wait()
        } else if snapshot.readCount == 5 {
            setReadStarted.send()
            allowSetRead.wait()
        }
        switch feature {
        case .brightness:
            return (snapshot.brightness, 100)
        case .contrast:
            return (20, 100)
        }
    }

    func write(_ service: DDCService, feature: DisplayFeature, value: UInt16) throws {
        guard feature == .brightness else { return }
        state.withLock { $0.brightness = value }
    }

    func releaseRefreshRead() {
        allowRefreshRead.signal()
    }

    func releaseSetRead() {
        allowSetRead.signal()
    }
}

@Suite("Display controls")
struct DisplayControlServiceTests {
    private enum TestError: Error {
        case failed
    }

    @Test("Overlapping display probes share one operation")
    func overlappingProbesShareWork() async throws {
        let callCount = Mutex(0)
        let probe = DisplayProbeSingleFlight<Int> {
            callCount.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            return 42
        }

        async let first = probe.value()
        async let second = probe.value()
        let values = try await (first, second)

        #expect(values.0 == 42)
        #expect(values.1 == 42)
        #expect(callCount.withLock { $0 } == 1)
    }

    @Test("Completed probe flights are cleared before later callers arrive")
    func completedProbeFlightsAreCleared() async throws {
        let callCount = Mutex(0)
        let probe = DisplayProbeSingleFlight<Int> {
            callCount.withLock { count in
                count += 1
                return count
            }
        }

        let first = try await probe.flight()
        #expect(await first.value() == 1)

        let second = try await probe.flight()

        #expect(second.id == first.id + 1)
        #expect(await second.value() == 2)
        #expect(callCount.withLock { $0 } == 2)
    }

    @Test("Cancellation before probe flight creation starts no operation")
    func cancellationBeforeProbeFlightStartsNoOperation() async throws {
        let operationCalls = Mutex(0)
        let gate = DisplayOperationTestGate()
        let probe = DisplayProbeSingleFlight<Int> {
            operationCalls.withLock { $0 += 1 }
            return 42
        }
        var caller: Task<Int, Error>?

        await withCheckedContinuation { callerStarted in
            caller = Task {
                callerStarted.resume()
                await gate.wait()
                return try await probe.value()
            }
        }

        let callerTask = try #require(caller)
        callerTask.cancel()
        await gate.open()

        do {
            _ = try await callerTask.value
            Issue.record("Cancelled probe created a flight")
        } catch is CancellationError {
        } catch {
            Issue.record("Cancelled probe returned \(error)")
        }
        #expect(operationCalls.withLock { $0 } == 0)
    }

    @Test("Opening an operation gate during registration does not lose the wakeup")
    func openingGateDuringRegistrationDoesNotLoseWakeup() async {
        let windowEntered = DisplayThreadSignal()
        let releaseWindow = DisplayThreadSignal()
        let waiterFinished = DisplayThreadSignal()
        let gate = DisplayOperationTestGate(beforeContinuationRegistration: {
            windowEntered.send()
            _ = await releaseWindow.wait()
        })
        let waiter = Task {
            await gate.wait()
            waiterFinished.send()
        }

        let entered = await windowEntered.wait()
        if entered {
            await gate.open()
        }
        releaseWindow.send()
        let finished = await waiterFinished.wait()

        releaseWindow.send()
        await gate.open()
        waiter.cancel()
        _ = await waiter.result

        #expect(entered)
        #expect(finished)
    }

    @Test("Newer probe publication rejects a delayed older flight")
    func newerProbePublicationRejectsDelayedOlderFlight() {
        let identity = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let endpoint = DisplayEndpointIdentity(
            displayIdentity: identity,
            registryID: DDCDisplayCandidate.ID(rawValue: 10)
        )
        let firstToken = DisplayConnectionToken(
            endpoint: endpoint,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let secondToken = DisplayConnectionToken(
            endpoint: endpoint,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        var state = DisplayProbePublicationState<DisplayConnectionToken>()
        state.requested(1)
        state.requested(2)

        let acceptedSecond = state.publish(secondToken, from: 2, isCancelled: false)
        let acceptedFirst = state.publish(firstToken, from: 1, isCancelled: false)
        #expect(acceptedSecond)
        #expect(!acceptedFirst)
        #expect(state.value == secondToken)
        #expect(state.latestAcceptedFlightID == 2)
        #expect(DisplayEndpointResolver.acceptsResult(
            captured: secondToken,
            current: state.value
        ))
    }

    @Test("Cancelled probe waiter cannot publish")
    func cancelledProbeWaiterCannotPublish() {
        var state = DisplayProbePublicationState<String>()
        state.requested(1)

        let accepted = state.publish("cancelled", from: 1, isCancelled: true)
        #expect(!accepted)
        #expect(state.value == nil)
        #expect(state.latestAcceptedFlightID == 0)
    }

    @Test("Concurrent drains wait for full operation cleanup")
    @MainActor
    func concurrentDrainsWaitForFullOperationCleanup() async throws {
        let registry = DisplayOperationRegistry()
        let admission = MutationAdmissionGate()
        let cleanupGate = DisplayOperationTestGate()
        let drainStarted = DisplayOperationTestSignal()
        let drainCompletions = Mutex(0)
        let publicationCalls = Mutex(0)

        let operation = Task {
            try await registry.run {
                let permit = try admission.acquire(owner: .manual, mode: .shared)
                defer { admission.release(permit) }
                await cleanupGate.wait()
                if !Task.isCancelled {
                    publicationCalls.withLock { $0 += 1 }
                }
            }
        }

        await cleanupGate.waitUntilEntered()

        let firstDrain = Task {
            await registry.cancelAndDrain {
                await drainStarted.send()
            }
            drainCompletions.withLock { $0 += 1 }
        }
        let secondDrain = Task {
            await registry.cancelAndDrain()
            drainCompletions.withLock { $0 += 1 }
        }

        await drainStarted.wait()
        try #require(registry.isDraining)
        #expect(drainCompletions.withLock { $0 } == 0)
        #expect(admission.activeSharedPermitCount == 1)
        #expect(publicationCalls.withLock { $0 } == 0)

        await cleanupGate.open()
        await firstDrain.value
        await secondDrain.value
        _ = try? await operation.value

        #expect(drainCompletions.withLock { $0 } == 2)
        #expect(admission.activeSharedPermitCount == 0)
        #expect(publicationCalls.withLock { $0 } == 0)
        #expect(!registry.isDraining)
    }

    @Test("Display service lifecycle is explicit and resumable")
    @MainActor
    func displayServiceLifecycleIsExplicitAndResumable() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DisplayLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DDCController(settingsManager: SettingsManager(directory: directory))
        let service = DisplayControlService(
            ddcController: controller,
            mutationAdmission: MutationAdmissionGate()
        )

        #expect(!service.isRunning)
        service.start()
        #expect(service.isRunning)
        await service.stopAndDrain()
        #expect(!service.isRunning)
        service.resume()
        #expect(service.isRunning)
        await service.stopAndDrain()
    }

    @Test("Away exclusive admission blocks manual display writes")
    @MainActor
    func awayExclusiveAdmissionBlocksManualDisplayWrites() throws {
        let admission = MutationAdmissionGate()
        let awayPermit = try admission.acquire(owner: .awayMode, mode: .exclusive)
        defer { admission.release(awayPermit) }

        do {
            _ = try admission.acquire(owner: .manual, mode: .shared)
            Issue.record("Manual display admission succeeded during Away exclusivity")
        } catch let error as MutationAdmissionError {
            #expect(error == .exclusivePermitActive(owner: .awayMode))
        } catch {
            Issue.record("Manual display admission returned \(error)")
        }
    }

    @Test("Stable identity requires nonzero EDID components")
    func stableIdentityValidation() {
        #expect(DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3) != nil)
        #expect(DisplayIdentity(vendorID: 0, productID: 2, serialNumber: 3) == nil)
        #expect(DisplayIdentity(vendorID: 1, productID: 0, serialNumber: 3) == nil)
        #expect(DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 0) == nil)
    }

    @Test("Missing and duplicate EDID identities are not stable")
    func duplicateIdentityValidation() {
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let unique = DisplayIdentityResolver.unique([first, first, second, nil])

        #expect(unique == [second])
    }

    @Test("Scene identifiers round trip the stable EDID identity")
    func sceneIdentifierRoundTrip() {
        let identity = DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)!

        #expect(identity.rawValue == "101:202:303")
        #expect(DisplayIdentity(rawValue: identity.rawValue) == identity)
        #expect(DisplayIdentity(rawValue: "101:202") == nil)
        #expect(DisplayIdentity(rawValue: "0:202:303") == nil)
    }

    @Test("Readings require a reported range and current value within it")
    func readingValidation() {
        #expect(DisplayFeatureReading(current: 0, maximum: 0) == nil)
        #expect(DisplayFeatureReading(current: 101, maximum: 100) == nil)
        #expect(DisplayFeatureReading(current: 25, maximum: 100)?.normalized == 0.25)
    }

    @Test("Normalized values map through the display reported maximum")
    func normalizedMapping() {
        #expect(DisplayFeatureIO.rawValue(normalized: 0.5, maximum: 254) == 127)
        #expect(DisplayFeatureIO.rawValue(normalized: -1, maximum: 80) == nil)
        #expect(DisplayFeatureIO.rawValue(normalized: 2, maximum: 80) == nil)
        #expect(DisplayFeatureIO.rawValue(normalized: .nan, maximum: 80) == nil)
    }

    @Test("Non-finite targets are rejected without a hardware write")
    func invalidTargetIsRejected() throws {
        var writeCount = 0
        let result = try DisplayFeatureIO.set(
            normalized: .infinity,
            maximum: 100,
            write: { _ in writeCount += 1 },
            read: { (0, 100) }
        )

        #expect(result == .invalidTarget)
        #expect(writeCount == 0)
    }

    @Test("Out of range targets are rejected without a hardware write")
    func outOfRangeTargetIsRejected() throws {
        var writeCount = 0
        let result = try DisplayFeatureIO.set(
            normalized: -0.01,
            maximum: 100,
            write: { _ in writeCount += 1 },
            read: { (0, 100) }
        )

        #expect(result == .invalidTarget)
        #expect(writeCount == 0)
    }

    @Test("Feature discovery reads the current value")
    func probeReadsCurrentValue() {
        let result = DisplayFeatureIO.probe(read: { (35, 70) })

        #expect(result == DisplayFeatureReading(current: 35, maximum: 70))
    }

    @Test("Feature discovery leaves a physical change made after its read untouched")
    func probeDoesNotOverwritePhysicalChange() {
        var liveValue: UInt16 = 40
        let result = DisplayFeatureIO.probe {
            let reportedValue = liveValue
            liveValue = 65
            return (reportedValue, 80)
        }

        #expect(result == DisplayFeatureReading(current: 40, maximum: 80))
        #expect(liveValue == 65)
    }

    @Test("Brightness failure does not hide valid contrast support")
    func featuresAreProbedIndependently() {
        let result = DisplayFeatureIO.probeAll(
            read: { feature in
                switch feature {
                case .brightness:
                    throw TestError.failed
                case .contrast:
                    return (25, 50)
                }
            }
        )

        #expect(result.readings[.brightness] == nil)
        #expect(result.readings[.contrast] == DisplayFeatureReading(current: 25, maximum: 50))
        #expect(result.sceneEligibleFeatures == [.contrast])
    }

    @Test("Set succeeds only after an exact matching readback")
    func setRequiresMatchingReadback() throws {
        var value: UInt16 = 0
        let result = try DisplayFeatureIO.set(
            normalized: 0.25,
            maximum: 80,
            write: { value = $0 },
            read: { (value, 80) }
        )

        #expect(result == .applied(DisplayFeatureReading(current: 20, maximum: 80)!))
    }

    @Test("Set reports a valid mismatched readback as failure")
    func setRejectsMismatchedReadback() throws {
        let result = try DisplayFeatureIO.set(
            normalized: 0.5,
            maximum: 100,
            write: { _ in },
            read: { (49, 100) }
        )

        #expect(result == .failed(
            expected: 50,
            readback: DisplayFeatureReading(current: 49, maximum: 100)
        ))
    }

    @Test("A failed display write restores the confirmed slider value")
    func failedWriteRestoresSliderValue() {
        let result = DisplayWriteResult.failed(
            expected: 80,
            readback: DisplayFeatureReading(current: 40, maximum: 100)
        )

        let value = DisplayFeatureIO.resolvedSliderValue(
            requested: 0.8,
            result: result,
            confirmed: 0.4
        )

        #expect(value == 0.4)
    }

    @Test("Set rejects a readback from a changed reported range")
    func setRejectsChangedRange() throws {
        let result = try DisplayFeatureIO.set(
            normalized: 0.5,
            maximum: 100,
            write: { _ in },
            read: { (50, 80) }
        )

        #expect(result == .failed(
            expected: 50,
            readback: DisplayFeatureReading(current: 50, maximum: 80)
        ))
    }

    @Test("Changed live range is rejected before hardware write")
    func changedLiveRangePreventsWrite() throws {
        var writeCount = 0
        let result = try DisplayFeatureIO.set(
            normalized: 0.5,
            maximum: 100,
            write: { _ in writeCount += 1 },
            read: { (40, 80) }
        )

        #expect(result == .failed(
            expected: 50,
            readback: DisplayFeatureReading(current: 40, maximum: 80)
        ))
        #expect(writeCount == 0)
    }

    @Test("Stale display endpoint is rejected before hardware write")
    func staleEndpointPreventsWrite() throws {
        var validationCount = 0
        var writeCount = 0
        let result = try DisplayFeatureIO.set(
            normalized: 0.5,
            maximum: 100,
            isEndpointCurrent: {
                validationCount += 1
                return false
            },
            write: { _ in writeCount += 1 },
            read: { (50, 100) }
        )

        #expect(result == .unavailable)
        #expect(validationCount == 1)
        #expect(writeCount == 0)
    }

    @Test("Cancellation at the display mutation claim prevents hardware write")
    func cancellationAtDisplayMutationClaimPreventsWrite() {
        var claimCount = 0
        var writeCount = 0

        do {
            _ = try DisplayFeatureIO.set(
                normalized: 0.5,
                maximum: 100,
                claimMutation: {
                    claimCount += 1
                    throw CancellationError()
                },
                write: { _ in writeCount += 1 },
                read: { (25, 100) }
            )
            Issue.record("Cancelled display mutation returned success")
        } catch is CancellationError {
        } catch {
            Issue.record("Cancelled display mutation returned \(error)")
        }

        #expect(claimCount == 1)
        #expect(writeCount == 0)
    }

    @Test("A claimed display mutation reports its one completed write")
    func claimedDisplayMutationReportsCompletedWrite() throws {
        var value: UInt16 = 25
        var claimCount = 0
        var writeCount = 0
        let result = try DisplayFeatureIO.set(
            normalized: 0.5,
            maximum: 100,
            claimMutation: { claimCount += 1 },
            write: {
                writeCount += 1
                value = $0
            },
            read: { (value, 100) }
        )

        #expect(result == .applied(DisplayFeatureReading(current: 50, maximum: 100)!))
        #expect(claimCount == 1)
        #expect(writeCount == 1)
    }

    @Test("Endpoint validation distinguishes same EDID reconnects")
    func endpointValidationRejectsReconnect() {
        let identity = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let original = DisplayEndpointIdentity(
            displayIdentity: identity,
            registryID: DDCDisplayCandidate.ID(rawValue: 10)
        )
        let matching = DisplayEndpointCandidate(
            displayIdentity: identity,
            registryID: DDCDisplayCandidate.ID(rawValue: 10)
        )
        let reconnected = DisplayEndpointCandidate(
            displayIdentity: identity,
            registryID: DDCDisplayCandidate.ID(rawValue: 11)
        )
        let unaddressable = DisplayEndpointCandidate(
            displayIdentity: identity,
            registryID: nil
        )

        #expect(DisplayEndpointResolver.isCurrent(original, among: [matching]))
        #expect(!DisplayEndpointResolver.isCurrent(original, among: [reconnected]))
        #expect(!DisplayEndpointResolver.isCurrent(original, among: [matching, matching]))
        #expect(!DisplayEndpointResolver.isCurrent(original, among: [matching, unaddressable]))
    }

    @Test("Endpoint generations reject results after reconnect")
    func endpointGenerationRejectsOldResult() {
        let identity = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let endpoint = DisplayEndpointIdentity(
            displayIdentity: identity,
            registryID: DDCDisplayCandidate.ID(rawValue: 10)
        )
        let first = DisplayConnectionToken(
            endpoint: endpoint,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let reconnected = DisplayConnectionToken(
            endpoint: endpoint,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        #expect(DisplayEndpointResolver.acceptsResult(captured: first, current: first))
        #expect(!DisplayEndpointResolver.acceptsResult(captured: first, current: reconnected))
        #expect(!DisplayEndpointResolver.acceptsResult(captured: first, current: nil))
    }

    @Test("Refresh preserves a confirmed write to the same display connection")
    @MainActor
    func refreshOverlappingConfirmedWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-DisplayRefreshTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DisplayRefreshOverlapTransport()
        let controller = DDCController(
            settingsManager: SettingsManager(directory: directory),
            ddcQueue: DispatchQueue(label: "com.semper.tests.display-refresh")
        )
        let service = DisplayControlService(
            ddcController: controller,
            mutationAdmission: MutationAdmissionGate(),
            discover: transport.discover,
            read: transport.read,
            write: transport.write
        )
        let identity = DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)!
        defer {
            transport.releaseRefreshRead()
            transport.releaseSetRead()
        }
        service.start()
        await service.probe()
        #expect(service.displays.first?.features[.brightness]?.current == 40)

        let refresh = Task { @MainActor in
            await service.probe()
        }
        try #require(await transport.refreshReadStarted.wait())
        let setInvoked = DisplayThreadSignal()
        let write = Task { @MainActor in
            setInvoked.send()
            return try await service.set(0.75, feature: .brightness, for: identity)
        }
        try #require(await setInvoked.wait())
        transport.releaseRefreshRead()
        try #require(await transport.setReadStarted.wait())
        await refresh.value
        transport.releaseSetRead()

        let result = try await write.value
        #expect(result == .applied(DisplayFeatureReading(current: 75, maximum: 100)!))
        #expect(service.displays.first?.features[.brightness]?.current == 75)
        await service.stopAndDrain()
    }

    @Test("Brightness and contrast use their standard VCP codes")
    func featureCodes() {
        #expect(DisplayFeature.brightness.rawValue == 0x10)
        #expect(DisplayFeature.contrast.rawValue == 0x12)
    }
}

#endif
