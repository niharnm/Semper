#if !APP_STORE

import CoreFoundation
import Foundation
import Synchronization
import Testing
@testable import Semper

private nonisolated final class DisplayInventoryThreadSignal: @unchecked Sendable {
    private struct State {
        var isSignalled = false
        var continuations: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func send() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.isSignalled else { return [] }
            state.isSignalled = true
            let continuations = state.continuations
            state.continuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                guard !state.isSignalled else { return true }
                state.continuations.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

@Suite("Display inventory and direct controls")
struct DisplayInventoryControlTests {
    private enum TestError: Error {
        case failed
    }

    @Test("Backends expose exact user-facing labels")
    func backendLabels() {
        #expect(DisplayControlBackend.ddcCI.label == "DDC/CI")
        #expect(DisplayControlBackend.macOSSettings.label == "macOS Settings")
    }

    @Test("System display matching requires one exact EDID match")
    func systemDisplayMatching() {
        let identity = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let other = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let match = DisplaySystemDisplayCandidate(displayID: 90, identity: identity)

        #expect(DisplaySystemDisplayResolver.resolve(identity, among: [match]) == .matched(90))
        #expect(DisplaySystemDisplayResolver.resolve(
            identity,
            among: [DisplaySystemDisplayCandidate(displayID: 91, identity: other)]
        ) == .unavailable(.systemDisplayNotFound))
        #expect(DisplaySystemDisplayResolver.resolve(identity, among: [match, match])
            == .unavailable(.ambiguousSystemDisplayMatch))
    }

    @Test("Endpoint matching rejects a registry endpoint reused by another display")
    func reusedRegistryEndpointIsRejected() {
        let identity = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let other = DisplayIdentity(vendorID: 4, productID: 5, serialNumber: 6)!
        let registryID = DDCDisplayCandidate.ID(rawValue: 10)
        let expected = DisplayEndpointIdentity(displayIdentity: identity, registryID: registryID)

        #expect(!DisplayEndpointResolver.isCurrent(expected, among: [
            DisplayEndpointCandidate(displayIdentity: identity, registryID: registryID),
            DisplayEndpointCandidate(displayIdentity: other, registryID: registryID),
        ]))
    }

    @Test("Volume encodings map only their adjustable ranges")
    func volumeEncodingRanges() {
        #expect(DisplayVolumeIO.rawValue(
            normalized: 0.5,
            maximum: 100,
            encoding: .continuous
        ) == 50)
        #expect(DisplayVolumeIO.rawValue(
            normalized: 0,
            maximum: 254,
            encoding: .continuousSubrange
        ) == 1)
        #expect(DisplayVolumeIO.rawValue(
            normalized: 1,
            maximum: 255,
            encoding: .continuousSubrange
        ) == 254)
        #expect(DisplayVolumeReading(current: 0, maximum: 255, encoding: .continuousSubrange)?.normalized == nil)
        #expect(DisplayVolumeReading(current: 255, maximum: 255, encoding: .continuousSubrange)?.normalized == nil)
        #expect(DisplayVolumeReading(current: 128, maximum: 255, encoding: .continuousSubrange)?.normalized
            == Double(127) / Double(253))
    }

    @Test("Input values must be advertised and the current value must match")
    func inputReadingValidation() {
        #expect(DisplayInputReading(current: 0x11, advertisedValues: [0x0F, 0x11])?.current == 0x11)
        #expect(DisplayInputReading(current: 0x12, advertisedValues: [0x0F, 0x11]) == nil)
        #expect(DisplayInputReading(current: 0x11, advertisedValues: [0x11, 0x11]) == nil)
    }

    @Test("Direct input applies one write and requires one matching readback")
    func inputWriteIsSingleAttempt() throws {
        var current: UInt16 = 0x11
        var reads = 0
        var writes = 0
        let result = try DisplayInputIO.set(
            value: 0x0F,
            advertisedValues: [0x0F, 0x11],
            writeOnce: { value in
                writes += 1
                current = UInt16(value)
            },
            read: {
                reads += 1
                return (current, 0x11)
            }
        )

        #expect(result == .applied(DisplayInputReading(
            current: 0x0F,
            advertisedValues: [0x0F, 0x11]
        )!))
        #expect(writes == 1)
        #expect(reads == 2)
    }

    @Test("An uncertain input switch is not retried or restored")
    func uncertainInputWriteIsNotRepeated() throws {
        var reads = 0
        var writes = 0
        let result = try DisplayInputIO.set(
            value: 0x0F,
            advertisedValues: [0x0F, 0x11],
            writeOnce: { _ in writes += 1 },
            read: {
                reads += 1
                return (0x11, 0x11)
            }
        )

        #expect(result == .unconfirmed(
            expected: 0x0F,
            readback: DisplayInputReading(current: 0x11, advertisedValues: [0x0F, 0x11])
        ))
        #expect(writes == 1)
        #expect(reads == 2)
    }

    @Test("Input write errors stay unconfirmed after one attempt")
    func inputWriteErrorIsNotRepeated() throws {
        var writes = 0
        let result = try DisplayInputIO.set(
            value: 0x0F,
            advertisedValues: [0x0F, 0x11],
            writeOnce: { _ in
                writes += 1
                throw TestError.failed
            },
            read: { (0x11, 0x11) }
        )

        #expect(result == .unconfirmed(expected: 0x0F, readback: nil))
        #expect(writes == 1)
    }

    @Test("Invalid input is rejected before reads or writes")
    func invalidInputDoesNoIO() throws {
        var reads = 0
        var writes = 0
        let result = try DisplayInputIO.set(
            value: 0x12,
            advertisedValues: [0x0F, 0x11],
            writeOnce: { _ in writes += 1 },
            read: {
                reads += 1
                return (0x11, 0x11)
            }
        )

        #expect(result == .invalidTarget)
        #expect(reads == 0)
        #expect(writes == 0)
    }

    @Test("Groups preserve first member order and remove duplicates")
    func groupMembership() {
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let group = DisplayControlGroup(name: "Desk", members: [first, second, first])

        #expect(group.members == [first, second])
    }

    @Test("Endpoint replacement preserves native results without stale publication")
    func endpointReplacementPreservesNativeResults() {
        let identity = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let endpoint = DisplayEndpointIdentity(
            displayIdentity: identity,
            registryID: DDCDisplayCandidate.ID(rawValue: 10)
        )
        let captured = DisplayConnectionToken(
            endpoint: endpoint,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let replacement = DisplayConnectionToken(
            endpoint: endpoint,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let featureResult = DisplayWriteResult.applied(
            DisplayFeatureReading(current: 50, maximum: 100)!
        )
        let volumeResult = DisplayVolumeWriteResult.applied(
            DisplayVolumeReading(current: 50, maximum: 100, encoding: .continuous)!
        )
        let inputResult = DisplayInputWriteResult.unconfirmed(
            expected: 0x0F,
            readback: DisplayInputReading(current: 0x11, advertisedValues: [0x0F, 0x11])
        )

        let feature = DisplayResultPublicationPolicy.evaluate(
            featureResult,
            captured: captured,
            current: replacement
        )
        let volume = DisplayResultPublicationPolicy.evaluate(
            volumeResult,
            captured: captured,
            current: replacement
        )
        let input = DisplayResultPublicationPolicy.evaluate(
            inputResult,
            captured: captured,
            current: replacement
        )

        #expect(feature.result == featureResult)
        #expect(volume.result == volumeResult)
        #expect(input.result == inputResult)
        #expect(!feature.shouldPublish)
        #expect(!volume.shouldPublish)
        #expect(!input.shouldPublish)
    }

    @Test("Group cancellation at a held second member preserves every target outcome")
    @MainActor
    func groupCancellationPreservesOutcomes() async {
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let third = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 5)!
        let members = [first, second, third]
        let attempts = Mutex<[DisplayIdentity]>([])
        let secondStarted = DisplayInventoryThreadSignal()
        let releaseSecond = DisplayInventoryThreadSignal()
        let task = Task { @MainActor in
            await DisplayGroupOperationRunner.run(members: members) { identity in
                attempts.withLock { $0.append(identity) }
                if identity == second {
                    secondStarted.send()
                    await releaseSecond.wait()
                    try Task.checkCancellation()
                }
                return .feature(.applied(
                    DisplayFeatureReading(current: 50, maximum: 100)!
                ))
            }
        }

        await secondStarted.wait()
        task.cancel()
        releaseSecond.send()
        let cancelled = await task.value

        #expect(attempts.withLock { $0 } == [first, second])
        #expect(cancelled.map(\.identity) == members)
        #expect(cancelled[0].result == .feature(.applied(
            DisplayFeatureReading(current: 50, maximum: 100)!
        )))
        #expect(cancelled[1].result == .cancelled)
        #expect(cancelled[2].result == .notAttempted)

        let failed = await DisplayGroupOperationRunner.run(members: members) { identity in
            if identity == second { throw TestError.failed }
            return .feature(.applied(DisplayFeatureReading(current: 50, maximum: 100)!))
        }
        #expect(failed.map(\.result) == [
            .feature(.applied(DisplayFeatureReading(current: 50, maximum: 100)!)),
            .failed,
            .notAttempted,
        ])
    }

    @Test("Probe keeps unsupported monitors with explicit reasons")
    @MainActor
    func unsupportedInventoryIsRetained() async {
        let directory = temporaryDirectory("unsupported-inventory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ddcController = DDCController(settingsManager: SettingsManager(directory: directory))
        let readCalls = Mutex(0)
        let service = DDCService(service: kCFBooleanTrue)
        let duplicate = DDCDisplayEDID(vendorID: 1, productID: 2, serialNumber: 3)
        let noEndpoint = DDCDisplayEDID(vendorID: 4, productID: 5, serialNumber: 6)
        let duplicateEndpointOne = DDCDisplayEDID(vendorID: 7, productID: 8, serialNumber: 9)
        let duplicateEndpointTwo = DDCDisplayEDID(vendorID: 10, productID: 11, serialNumber: 12)
        let records = [
            DDCExternalDisplayRecord(
                registryID: DDCDisplayCandidate.ID(rawValue: 10),
                name: "Missing identity",
                edid: nil,
                service: service
            ),
            DDCExternalDisplayRecord(
                registryID: DDCDisplayCandidate.ID(rawValue: 11),
                name: "Duplicate one",
                edid: duplicate,
                service: service
            ),
            DDCExternalDisplayRecord(
                registryID: DDCDisplayCandidate.ID(rawValue: 12),
                name: "Duplicate two",
                edid: duplicate,
                service: service
            ),
            DDCExternalDisplayRecord(
                registryID: nil,
                name: "Missing endpoint",
                edid: noEndpoint,
                service: service
            ),
            DDCExternalDisplayRecord(
                registryID: DDCDisplayCandidate.ID(rawValue: 13),
                name: "Duplicate endpoint one",
                edid: duplicateEndpointOne,
                service: service
            ),
            DDCExternalDisplayRecord(
                registryID: DDCDisplayCandidate.ID(rawValue: 13),
                name: "Duplicate endpoint two",
                edid: duplicateEndpointTwo,
                service: service
            ),
        ]
        let displayService = DisplayControlService(
            ddcController: ddcController,
            mutationAdmission: MutationAdmissionGate(),
            discover: { records },
            read: { _, _ in
                readCalls.withLock { $0 += 1 }
                return (50, 100)
            },
            readCapabilities: { _ in
                readCalls.withLock { $0 += 1 }
                return Self.capabilities
            },
            readVCP: { _, _ in
                readCalls.withLock { $0 += 1 }
                return (50, 100)
            },
            discoverSystemDisplays: { [] }
        )

        displayService.start()
        await displayService.probe()

        #expect(displayService.inventory.count == 6)
        #expect(displayService.displays.count == 3)
        #expect(readCalls.withLock { $0 } == 0)
        #expect(displayService.inventory.first(where: { $0.name == "Missing identity" })?
            .controls.brightness == .unavailable(.missingStableIdentity))
        #expect(displayService.inventory.first(where: { $0.name == "Duplicate one" })?
            .controls.input == .unavailable(.duplicateStableIdentity))
        #expect(displayService.inventory.first(where: { $0.name == "Missing endpoint" })?
            .controls.volume == .unavailable(.missingRegistryEndpoint))
        #expect(displayService.inventory.first(where: { $0.name == "Duplicate endpoint one" })?
            .controls.input == .unavailable(.duplicateRegistryEndpoint))
        let noEndpointIdentity = DisplayIdentity(edid: noEndpoint)!
        let duplicateEndpointIdentity = DisplayIdentity(edid: duplicateEndpointOne)!
        #expect(await displayService.read(.brightness, for: noEndpointIdentity) == nil)
        #expect(await displayService.read(.contrast, for: duplicateEndpointIdentity) == nil)
        #expect(await displayService.readVolume(for: noEndpointIdentity)
            == .unavailable(.missingRegistryEndpoint))
        #expect(await displayService.readInput(for: duplicateEndpointIdentity)
            == .unavailable(.duplicateRegistryEndpoint))
        #expect(readCalls.withLock { $0 } == 0)
        await displayService.stopAndDrain()
    }

    @Test("Probe verifies all four controls and the system display mapping")
    @MainActor
    func supportedInventoryIsVerified() async {
        let directory = temporaryDirectory("supported-inventory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)!
        let record = record(identity: identity, registryID: 901, name: "Desk Display")
        let displayService = DisplayControlService(
            ddcController: DDCController(settingsManager: SettingsManager(directory: directory)),
            mutationAdmission: MutationAdmissionGate(),
            discover: { [record] },
            read: { _, feature in
                feature == .brightness ? (40, 100) : (30, 60)
            },
            readCapabilities: { request in
                if request.isCancelled() { throw CancellationError() }
                return Self.capabilities
            },
            readVCP: { _, code in
                code == 0x62 ? (50, 100) : (0x11, 0x11)
            },
            discoverSystemDisplays: {
                [DisplaySystemDisplayCandidate(displayID: 77, identity: identity)]
            }
        )

        displayService.start()
        await displayService.probe()

        let item = displayService.inventory.first
        #expect(item?.backendLabel == "DDC/CI")
        #expect(item?.systemDisplay == .matched(77))
        #expect(item?.controls.brightness.value?.current == 40)
        #expect(item?.controls.contrast.value?.maximum == 60)
        #expect(item?.controls.volume.value?.current == 50)
        #expect(item?.controls.input.value?.current == 0x11)
        #expect(displayService.systemDisplayID(for: identity) == 77)
        await displayService.stopAndDrain()
    }

    @Test("Failed feature reads remove stale controls and preserve write verification state")
    @MainActor
    func failedFeatureReadsRemoveStaleState() async throws {
        let directory = temporaryDirectory("feature-failure-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)!
        let record = record(identity: identity, registryID: 901, name: "Desk Display")
        let brightness = Mutex<UInt16>(40)
        let failFirstWriteReadback = Mutex(true)
        let failNextBrightnessRead = Mutex(false)
        let displayService = DisplayControlService(
            ddcController: DDCController(settingsManager: SettingsManager(directory: directory)),
            mutationAdmission: MutationAdmissionGate(),
            discover: { [record] },
            read: { _, feature in
                if feature == .brightness {
                    let shouldFail = failNextBrightnessRead.withLock { value in
                        defer { value = false }
                        return value
                    }
                    if shouldFail { throw TestError.failed }
                    return (brightness.withLock { $0 }, 100)
                }
                return (50, 100)
            },
            write: { _, feature, value in
                guard feature == .brightness else { return }
                let failReadback = failFirstWriteReadback.withLock { value in
                    defer { value = false }
                    return value
                }
                if failReadback {
                    failNextBrightnessRead.withLock { $0 = true }
                } else {
                    brightness.withLock { $0 = value }
                }
            },
            readCapabilities: { _ in "(mccs_ver(2.2)vcp(10 12))" },
            readVCP: { _, _ in throw TestError.failed },
            discoverSystemDisplays: { [] }
        )

        displayService.start()
        await displayService.probe()
        let failed = try await displayService.set(0.5, feature: .brightness, for: identity)

        #expect(failed == .failed(expected: 50, readback: nil))
        #expect(displayService.displays.first?.features[.brightness] == nil)
        #expect(displayService.inventory.first?.controls.brightness
            == .unavailable(.liveReadFailed(.brightness)))
        #expect(displayService.inventory.first?.unverifiedWrites == [.brightness])

        await displayService.probe()
        #expect(displayService.displays.first?.features[.brightness]?.current == 40)
        #expect(displayService.inventory.first?.unverifiedWrites == [.brightness])

        let applied = try await displayService.set(0.6, feature: .brightness, for: identity)
        #expect(applied == .applied(DisplayFeatureReading(current: 60, maximum: 100)!))
        #expect(displayService.inventory.first?.unverifiedWrites.isEmpty == true)

        failNextBrightnessRead.withLock { $0 = true }
        #expect(await displayService.read(.brightness, for: identity) == nil)
        #expect(displayService.displays.first?.features[.brightness] == nil)
        #expect(displayService.inventory.first?.controls.brightness
            == .unavailable(.liveReadFailed(.brightness)))
        await displayService.stopAndDrain()
    }

    @Test("Volume writes require matching readback and clear only after confirmation")
    @MainActor
    func volumeWriteVerificationState() async throws {
        let directory = temporaryDirectory("volume-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)!
        let record = record(identity: identity, registryID: 901, name: "Desk Display")
        let volume = Mutex<UInt16>(20)
        let applyWrites = Mutex(false)
        let writes = Mutex(0)
        let displayService = DisplayControlService(
            ddcController: DDCController(settingsManager: SettingsManager(directory: directory)),
            mutationAdmission: MutationAdmissionGate(),
            discover: { [record] },
            read: { _, _ in (50, 100) },
            readCapabilities: { _ in Self.capabilities },
            readVCP: { _, code in
                code == 0x62 ? (volume.withLock { $0 }, 100) : (0x11, 0x11)
            },
            writeVCP: { _, code, value in
                guard code == 0x62 else { return }
                writes.withLock { $0 += 1 }
                if applyWrites.withLock({ $0 }) {
                    volume.withLock { $0 = value }
                }
            },
            discoverSystemDisplays: { [] }
        )

        displayService.start()
        await displayService.probe()
        let failed = try await displayService.setVolume(0.75, for: identity)

        #expect(failed == .failed(
            expected: 75,
            readback: DisplayVolumeReading(
                current: 20,
                maximum: 100,
                encoding: .continuousSubrange
            )
        ))
        #expect(displayService.inventory.first?.unverifiedWrites == [.volume])
        _ = await displayService.readVolume(for: identity)
        #expect(displayService.inventory.first?.unverifiedWrites == [.volume])

        applyWrites.withLock { $0 = true }
        let applied = try await displayService.setVolume(0.5, for: identity)
        #expect(applied == .applied(
            DisplayVolumeReading(current: 51, maximum: 100, encoding: .continuousSubrange)!
        ))
        #expect(writes.withLock { $0 } == 2)
        #expect(displayService.inventory.first?.unverifiedWrites.isEmpty == true)
        await displayService.stopAndDrain()
    }

    @Test("Service input switching records and clears an unverified write")
    @MainActor
    func serviceInputWriteVerificationState() async throws {
        let directory = temporaryDirectory("input-switch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)!
        let record = record(identity: identity, registryID: 901, name: "Desk Display")
        let currentInput = Mutex<UInt16>(0x11)
        let shouldApplyWrite = Mutex(false)
        let writeCount = Mutex(0)
        let displayService = DisplayControlService(
            ddcController: DDCController(settingsManager: SettingsManager(directory: directory)),
            mutationAdmission: MutationAdmissionGate(),
            discover: { [record] },
            read: { _, _ in (50, 100) },
            readCapabilities: { _ in Self.capabilities },
            readVCP: { _, code in
                code == 0x62 ? (50, 100) : (currentInput.withLock { $0 }, 0x11)
            },
            writeInputOnce: { _, value in
                writeCount.withLock { $0 += 1 }
                if shouldApplyWrite.withLock({ $0 }) {
                    currentInput.withLock { $0 = UInt16(value) }
                }
            },
            discoverSystemDisplays: { [] }
        )

        displayService.start()
        await displayService.probe()
        let unconfirmed = try await displayService.setInput(0x0F, for: identity)

        #expect(unconfirmed == .unconfirmed(
            expected: 0x0F,
            readback: DisplayInputReading(current: 0x11, advertisedValues: [0x0F, 0x11])
        ))
        #expect(writeCount.withLock { $0 } == 1)
        #expect(displayService.inventory.first?.unverifiedWrites == [.input])
        _ = await displayService.readInput(for: identity)
        #expect(displayService.inventory.first?.unverifiedWrites == [.input])

        shouldApplyWrite.withLock { $0 = true }
        let applied = try await displayService.setInput(0x0F, for: identity)

        #expect(applied == .applied(DisplayInputReading(
            current: 0x0F,
            advertisedValues: [0x0F, 0x11]
        )!))
        #expect(writeCount.withLock { $0 } == 2)
        #expect(displayService.inventory.first?.controls.input.value?.current == 0x0F)
        #expect(displayService.inventory.first?.unverifiedWrites.isEmpty == true)
        await displayService.stopAndDrain()
    }

    @Test("Group write reports one result for each requested member")
    @MainActor
    func groupWriteReportsEachTarget() async throws {
        let directory = temporaryDirectory("group-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let missing = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 5)!
        let firstRecord = record(identity: first, registryID: 10, name: "First")
        let secondRecord = record(identity: second, registryID: 11, name: "Second")
        let values = Mutex<[ObjectIdentifier: UInt16]>([
            ObjectIdentifier(firstRecord.service): 20,
            ObjectIdentifier(secondRecord.service): 30,
        ])
        let writes = Mutex(0)
        let displayService = DisplayControlService(
            ddcController: DDCController(settingsManager: SettingsManager(directory: directory)),
            mutationAdmission: MutationAdmissionGate(),
            discover: { [firstRecord, secondRecord] },
            read: { service, feature in
                feature == .brightness
                    ? (values.withLock { $0[ObjectIdentifier(service)]! }, 100)
                    : (50, 100)
            },
            write: { service, feature, value in
                guard feature == .brightness else { return }
                writes.withLock { $0 += 1 }
                values.withLock { $0[ObjectIdentifier(service)] = value }
            },
            readCapabilities: { _ in "(mccs_ver(2.2)vcp(10 12))" },
            readVCP: { _, _ in throw TestError.failed },
            discoverSystemDisplays: { [] }
        )
        let group = DisplayControlGroup(name: "Desk", members: [first, missing, second])

        displayService.start()
        await displayService.probe()
        let report = try await displayService.apply(
            .feature(.brightness, normalized: 0.75),
            to: group
        )

        #expect(report.outcomes.count == 3)
        #expect(report.outcomes[0].identity == first)
        #expect(report.outcomes[0].result == .feature(.applied(
            DisplayFeatureReading(current: 75, maximum: 100)!
        )))
        #expect(report.outcomes[1].identity == missing)
        #expect(report.outcomes[1].result == .feature(.unavailable))
        #expect(report.outcomes[2].identity == second)
        #expect(writes.withLock { $0 } == 2)
        await displayService.stopAndDrain()
    }

    @Test("Group volume and input writes return a result for every display")
    @MainActor
    func groupVolumeAndInputWrites() async throws {
        let directory = temporaryDirectory("group-volume-input")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let records = [
            record(identity: first, registryID: 10, name: "First"),
            record(identity: second, registryID: 11, name: "Second"),
        ]
        let volumes = Mutex<[ObjectIdentifier: UInt16]>(Dictionary(uniqueKeysWithValues: records.map {
            (ObjectIdentifier($0.service), 20)
        }))
        let inputs = Mutex<[ObjectIdentifier: UInt16]>(Dictionary(uniqueKeysWithValues: records.map {
            (ObjectIdentifier($0.service), 0x11)
        }))
        let volumeWrites = Mutex(0)
        let inputWrites = Mutex(0)
        let displayService = DisplayControlService(
            ddcController: DDCController(settingsManager: SettingsManager(directory: directory)),
            mutationAdmission: MutationAdmissionGate(),
            discover: { records },
            read: { _, _ in (50, 100) },
            readCapabilities: { _ in Self.capabilities },
            readVCP: { service, code in
                let id = ObjectIdentifier(service)
                return code == 0x62
                    ? (volumes.withLock { $0[id]! }, 100)
                    : (inputs.withLock { $0[id]! }, 0x11)
            },
            writeVCP: { service, code, value in
                guard code == 0x62 else { return }
                volumeWrites.withLock { $0 += 1 }
                volumes.withLock { $0[ObjectIdentifier(service)] = value }
            },
            writeInputOnce: { service, value in
                inputWrites.withLock { $0 += 1 }
                inputs.withLock { $0[ObjectIdentifier(service)] = UInt16(value) }
            },
            discoverSystemDisplays: { [] }
        )
        let group = DisplayControlGroup(name: "Desk", members: [first, second])

        displayService.start()
        await displayService.probe()
        let volumeReport = try await displayService.apply(.volume(normalized: 0.5), to: group)
        let inputReport = try await displayService.apply(.input(0x0F), to: group)

        #expect(volumeReport.outcomes.count == 2)
        #expect(volumeReport.outcomes.allSatisfy {
            if case .volume(.applied(let reading)) = $0.result {
                return reading.current == 51
            }
            return false
        })
        #expect(inputReport.outcomes.count == 2)
        #expect(inputReport.outcomes.allSatisfy {
            if case .input(.applied(let reading)) = $0.result {
                return reading.current == 0x0F
            }
            return false
        })
        #expect(volumeWrites.withLock { $0 } == 2)
        #expect(inputWrites.withLock { $0 } == 2)
        await displayService.stopAndDrain()
    }

    @Test("Drain cancellation stops before the next monitor capability request")
    @MainActor
    func drainStopsCapabilitySequence() async {
        let directory = temporaryDirectory("cancel-capabilities")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let records = [
            record(identity: first, registryID: 10, name: "First"),
            record(identity: second, registryID: 11, name: "Second"),
        ]
        let readCount = Mutex(0)
        let capabilityStarted = DisplayInventoryThreadSignal()
        let cancellationObserved = DisplayInventoryThreadSignal()
        let releaseCapability = DispatchSemaphore(value: 0)
        let displayService = DisplayControlService(
            ddcController: DDCController(settingsManager: SettingsManager(directory: directory)),
            mutationAdmission: MutationAdmissionGate(),
            discover: { records },
            read: { _, _ in (50, 100) },
            readCapabilities: { request in
                readCount.withLock { $0 += 1 }
                capabilityStarted.send()
                while !request.isCancelled() {
                    usleep(1_000)
                }
                cancellationObserved.send()
                releaseCapability.wait()
                throw CancellationError()
            },
            readVCP: { _, _ in (50, 100) },
            discoverSystemDisplays: { [] }
        )

        displayService.start()
        let probe = Task { @MainActor in await displayService.probe() }
        await capabilityStarted.wait()
        let drain = Task { @MainActor in await displayService.stopAndDrain() }
        await cancellationObserved.wait()
        releaseCapability.signal()
        await drain.value
        await probe.value

        #expect(readCount.withLock { $0 } == 1)
        #expect(!displayService.isRunning)
        #expect(displayService.inventory.isEmpty)
    }

    private nonisolated static let capabilities = "(mccs_ver(2.2)vcp(10 12 60(0f 11) 62))"

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Semper-" + name + "-" + UUID().uuidString, isDirectory: true)
    }

    private func record(
        identity: DisplayIdentity,
        registryID: UInt64,
        name: String
    ) -> DDCExternalDisplayRecord {
        DDCExternalDisplayRecord(
            registryID: DDCDisplayCandidate.ID(rawValue: registryID),
            name: name,
            edid: DDCDisplayEDID(
                vendorID: identity.vendorID,
                productID: identity.productID,
                serialNumber: identity.serialNumber
            ),
            service: DDCService(service: kCFBooleanTrue)
        )
    }
}

#endif
