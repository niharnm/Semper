import Foundation
import Testing

@testable import Semper

@Suite("APFS metadata")
struct SafeEjectAPFSTopologyTests {
    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func parsesContainersAndSnapshotIdentifiers(format: PropertyListSerialization.PropertyListFormat) throws {
        let internalContainer = apfsContainer(1, volumes: ["disk1s1", "disk1s1s1"], stores: ["disk0s2"])
        let externalContainer = apfsContainer(8, volumes: ["disk8s1"], stores: ["disk7s2"])
        let value = try SafeEjectAPFSTopology.parse(apfsData([internalContainer, externalContainer], format: format))
        #expect(value.containers.map(\.bsdName) == ["disk1", "disk8"])
        #expect(value.containers[0].volumes.map(\.bsdName) == ["disk1s1", "disk1s1s1"])
        #expect(value.containers[1].stores.map(\.bsdName) == ["disk7s2"])
        let expectedUUID = try #require(internalContainer["APFSContainerUUID"] as? String)
        #expect(value.containers[0].uuid == UUID(uuidString: expectedUUID))
    }

    @Test func preservesAllPhysicalStores() throws {
        let value = try SafeEjectAPFSTopology.parse(apfsData([apfsContainer(9, stores: ["disk2s2", "disk3s2"])]))
        #expect(value.containers[0].stores.map(\.bsdName) == ["disk2s2", "disk3s2"])
    }

    @Test func permitsEmptyTopologyAndUnpopulatedVolumes() throws {
        #expect(try SafeEjectAPFSTopology.parse(apfsData([])).containers.isEmpty)
        let value = try SafeEjectAPFSTopology.parse(apfsData([apfsContainer(1, volumes: [])]))
        #expect(value.containers[0].volumes.isEmpty)
    }

    @Test func rejectsMissingAndWronglyTypedFields() throws {
        for root: Any in [[:], ["Containers": "invalid"], ["Containers": [1]], ["Containers": true]] {
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            #expect(throws: SafeEjectAPFSError.invalidSchema) { try SafeEjectAPFSTopology.parse(data) }
        }
        let fields = ["ContainerReference", "APFSContainerUUID", "Volumes", "PhysicalStores"]
        for key in fields {
            for replacement: Any? in [nil, 17, true] {
                var container = apfsContainer(1)
                container[key] = replacement
                let data = try apfsData([container])
                #expect(throws: SafeEjectAPFSError.invalidSchema) { try SafeEjectAPFSTopology.parse(data) }
            }
        }
        for (arrayKey, uuidKey) in [("Volumes", "APFSVolumeUUID"), ("PhysicalStores", "DiskUUID")] {
            for missingKey in ["DeviceIdentifier", uuidKey] {
                var container = apfsContainer(1)
                var member: [String: Any] = ["DeviceIdentifier": "disk2s2", uuidKey: UUID().uuidString]
                member[missingKey] = nil
                container[arrayKey] = [member]
                let data = try apfsData([container])
                #expect(throws: SafeEjectAPFSError.invalidSchema) { try SafeEjectAPFSTopology.parse(data) }
            }
        }
        var container = apfsContainer(1)
        container["PhysicalStores"] = [[String: Any]]()
        #expect(throws: SafeEjectAPFSError.invalidSchema) { try SafeEjectAPFSTopology.parse(apfsData([container])) }
    }

    @Test(arguments: ["disk", "rdisk1", "disk1s", "disk-1", "disk1\n", " disk1", "disk1/../disk2", "disk１"])
    func rejectsInvalidIdentifiers(identifier: String) throws {
        var container = apfsContainer(1)
        container["ContainerReference"] = identifier
        #expect(throws: SafeEjectAPFSError.invalidIdentifier) { try SafeEjectAPFSTopology.parse(apfsData([container])) }
    }

    @Test func rejectsOversizedIdentifierAndInvalidUUIDs() throws {
        var container = apfsContainer(1)
        container["ContainerReference"] = "disk" + String(repeating: "1", count: 61)
        #expect(throws: SafeEjectAPFSError.invalidIdentifier) { try SafeEjectAPFSTopology.parse(apfsData([container])) }
        for uuid in ["", "not-a-uuid", String(repeating: "x", count: 36), UUID().uuidString + "\n"] {
            container = apfsContainer(1)
            container["APFSContainerUUID"] = uuid
            #expect(throws: SafeEjectAPFSError.invalidUUID) { try SafeEjectAPFSTopology.parse(apfsData([container])) }
        }
    }

    @Test func rejectsDuplicateIdentitiesAcrossRolesAndContainers() throws {
        let first = apfsContainer(1)
        #expect(throws: SafeEjectAPFSError.duplicateIdentifier) {
            try SafeEjectAPFSTopology.parse(apfsData([first, first]))
        }
        var second = apfsContainer(2, stores: ["disk4s2"])
        second["APFSContainerUUID"] = first["APFSContainerUUID"]
        #expect(throws: SafeEjectAPFSError.duplicateUUID) {
            try SafeEjectAPFSTopology.parse(apfsData([first, second]))
        }
        var container = apfsContainer(1, volumes: ["disk0s2"])
        #expect(throws: SafeEjectAPFSError.duplicateIdentifier) {
            try SafeEjectAPFSTopology.parse(apfsData([container]))
        }
        container = apfsContainer(1)
        let containerUUID = try #require(container["APFSContainerUUID"] as? String)
        container["Volumes"] = [["DeviceIdentifier": "disk1s1", "APFSVolumeUUID": containerUUID]]
        #expect(throws: SafeEjectAPFSError.duplicateUUID) { try SafeEjectAPFSTopology.parse(apfsData([container])) }
    }

    @Test func rejectsMalformedAndOversizedInput() throws {
        #expect(throws: SafeEjectAPFSError.invalidPlist) { try SafeEjectAPFSTopology.parse(Data("no plist".utf8)) }
        #expect(throws: SafeEjectAPFSError.inputTooLarge) {
            try SafeEjectAPFSTopology.parse(Data(repeating: 0, count: SafeEjectAPFSTopology.maximumBytes + 1))
        }
    }

    @Test func rejectsContainerVolumeStoreAndAggregateLimits() throws {
        let containers = (1...129).map { apfsContainer($0, stores: ["disk\($0 + 1_000)s2"]) }
        #expect(throws: SafeEjectAPFSError.tooManyEntries) { try SafeEjectAPFSTopology.parse(apfsData(containers)) }
        let volumes = (1...1_025).map { "disk1s\($0)" }
        #expect(throws: SafeEjectAPFSError.tooManyEntries) {
            try SafeEjectAPFSTopology.parse(apfsData([apfsContainer(1, volumes: volumes)]))
        }
        let stores = (1...33).map { "disk\($0 + 100)s2" }
        #expect(throws: SafeEjectAPFSError.tooManyEntries) {
            try SafeEjectAPFSTopology.parse(apfsData([apfsContainer(1, stores: stores)]))
        }
        let many = (1...4).map { index in
            apfsContainer(index, volumes: (1...1_024).map { "disk\(index)s\($0)" }, stores: ["disk\(index + 100)s2"])
        }
        let data = try apfsData(many)
        #expect(data.count < SafeEjectAPFSTopology.maximumBytes)
        #expect(throws: SafeEjectAPFSError.tooManyEntries) { try SafeEjectAPFSTopology.parse(data) }
    }

    @Test func readerRunsOffMainActorAndClosesAfterSuccess() async throws {
        let data = try apfsData([apfsContainer(1)])
        let process = APFSProcessFixture(output: data)
        let result = try await SafeEjectAPFSReader(makeProcess: { process }).read()
        #expect(result == (try SafeEjectAPFSTopology.parse(data)))
        let state = process.snapshot
        #expect(state.launched && !state.launchedOnMainThread)
        #expect(state.closes == 1 && state.terminations == 0 && state.forceTerminations == 0)
        #expect(state.maximumRead <= 16_384)
    }

    @Test func readerReportsFailuresAfterCleanup() async throws {
        for failure in APFSProcessFixture.Failure.allCases {
            let process = APFSProcessFixture(output: try apfsData([]), failure: failure)
            let expected: SafeEjectAPFSError =
                switch failure {
                case .launch: .launchFailed
                case .read: .readFailed
                case .exit: .processFailed
                case .close: .cleanupFailed
                }
            await #expect(throws: expected) { try await SafeEjectAPFSReader(makeProcess: { process }).read() }
            #expect(process.snapshot.closes == 1)
            #expect(!process.snapshot.running)
        }
        let malformed = APFSProcessFixture(output: Data("invalid plist".utf8))
        await #expect(throws: SafeEjectAPFSError.invalidPlist) {
            try await SafeEjectAPFSReader(makeProcess: { malformed }).read()
        }
        #expect(malformed.snapshot.closes == 1)
    }

    @Test func readerCapsOutputBeforeAppendingAndTerminates() async throws {
        let process = APFSProcessFixture(output: Data(repeating: 0, count: SafeEjectAPFSTopology.maximumBytes + 1))
        await #expect(throws: SafeEjectAPFSError.inputTooLarge) {
            try await SafeEjectAPFSReader(makeProcess: { process }).read()
        }
        let state = process.snapshot
        #expect(state.closes == 1 && state.terminations == 1 && !state.running)
        #expect(state.bytesRead == SafeEjectAPFSTopology.maximumBytes + 1)
        #expect(state.maximumRead <= 16_384)
    }

    @Test func timeoutTerminatesAndEscalatesWithinCleanupBound() async throws {
        for ignoresTermination in [false, true] {
            let process = APFSProcessFixture(waits: true, ignoresTermination: ignoresTermination)
            let reader = SafeEjectAPFSReader(
                makeProcess: { process }, timeout: .milliseconds(20), terminationGrace: .milliseconds(10))
            let start = ContinuousClock.now
            await #expect(throws: SafeEjectAPFSError.timedOut) { try await reader.read() }
            #expect(start.duration(to: .now) < .seconds(1))
            let state = process.snapshot
            #expect(state.closes == 1 && state.terminations == 1 && !state.running)
            #expect(state.forceTerminations == (ignoresTermination ? 1 : 0))
        }
    }

    @Test func cleanupFailureIsExplicitAndDoesNotWaitIndefinitely() async throws {
        let process = APFSProcessFixture(waits: true, ignoresTermination: true, ignoresForce: true)
        let reader = SafeEjectAPFSReader(
            makeProcess: { process }, timeout: .milliseconds(20), terminationGrace: .milliseconds(10))
        let start = ContinuousClock.now
        await #expect(throws: SafeEjectAPFSError.cleanupFailed) { try await reader.read() }
        #expect(start.duration(to: .now) < .seconds(1))
        let state = process.snapshot
        #expect(state.closes == 1 && state.terminations == 1 && state.forceTerminations == 1)
    }

    @Test func cancellationWaitsForOwnedProcessCleanup() async throws {
        let process = APFSProcessFixture(waits: true, ignoresTermination: true)
        let reader = SafeEjectAPFSReader(makeProcess: { process }, terminationGrace: .milliseconds(10))
        let task = Task { try await reader.read() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !process.snapshot.launched, ContinuousClock.now < deadline { await Task.yield() }
        #expect(process.snapshot.launched)
        task.cancel()
        await #expect(throws: SafeEjectAPFSError.cancelled) { try await task.value }
        let state = process.snapshot
        #expect(state.closes == 1 && state.terminations == 1 && state.forceTerminations == 1 && !state.running)
    }

    @Test func alreadyCancelledReadDoesNotLaunch() async throws {
        let process = APFSProcessFixture(waits: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SafeEjectAPFSReader(makeProcess: { process }).read()
        }
        await #expect(throws: SafeEjectAPFSError.cancelled) { try await task.value }
        #expect(!process.snapshot.launched)
    }
}

nonisolated private func apfsContainer(
    _ disk: Int, volumes: [String]? = nil, stores: [String] = ["disk0s2"]
) -> [String: Any] {
    [
        "ContainerReference": "disk\(disk)", "APFSContainerUUID": UUID().uuidString,
        "Volumes": (volumes ?? ["disk\(disk)s1"]).map {
            ["DeviceIdentifier": $0, "APFSVolumeUUID": UUID().uuidString]
        },
        "PhysicalStores": stores.map { ["DeviceIdentifier": $0, "DiskUUID": UUID().uuidString] },
    ]
}

nonisolated private func apfsData(
    _ containers: [[String: Any]], format: PropertyListSerialization.PropertyListFormat = .binary
) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["Containers": containers], format: format, options: 0)
}

nonisolated private final class APFSProcessFixture: SafeEjectAPFSProcessControlling, @unchecked Sendable {
    enum Failure: CaseIterable { case launch, read, exit, close }
    struct State {
        var launched = false
        var launchedOnMainThread = false
        var running = false
        var closes = 0
        var terminations = 0
        var forceTerminations = 0
        var bytesRead = 0
        var maximumRead = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let output: Data
    private let waits: Bool
    private let failure: Failure?
    private let ignoresTermination: Bool
    private let ignoresForce: Bool

    init(
        output: Data = Data(), waits: Bool = false, failure: Failure? = nil,
        ignoresTermination: Bool = false, ignoresForce: Bool = false
    ) {
        self.output = output
        self.waits = waits
        self.failure = failure
        self.ignoresTermination = ignoresTermination
        self.ignoresForce = ignoresForce
    }

    var snapshot: State { lock.withLock { state } }
    var isRunning: Bool { snapshot.running }
    var exitedSuccessfully: Bool { !isRunning && failure != .exit }

    func launch() throws {
        try lock.withLock {
            if failure == .launch { throw SafeEjectAPFSError.launchFailed }
            state.launched = true
            state.launchedOnMainThread = Thread.isMainThread
            state.running = true
        }
    }

    func read(maximumBytes: Int) throws -> SafeEjectAPFSReadChunk {
        try lock.withLock {
            state.maximumRead = max(state.maximumRead, maximumBytes)
            if failure == .read { throw SafeEjectAPFSError.readFailed }
            if waits { return .waiting }
            guard state.bytesRead < output.count else {
                state.running = false
                return .end
            }
            let end = min(state.bytesRead + maximumBytes, output.count)
            let chunk = output.subdata(in: state.bytesRead..<end)
            state.bytesRead = end
            return .bytes(chunk)
        }
    }

    func terminate() {
        lock.withLock {
            state.terminations += 1
            if !ignoresTermination { state.running = false }
        }
    }

    func forceTerminate() throws {
        lock.withLock {
            state.forceTerminations += 1
            if !ignoresForce { state.running = false }
        }
    }

    func close() throws {
        try lock.withLock {
            state.closes += 1
            if failure == .close { throw SafeEjectAPFSError.cleanupFailed }
        }
    }
}
