import Darwin
import Foundation

nonisolated enum SafeEjectAPFSError: Error, Equatable, LocalizedError {
    case inputTooLarge, invalidPlist, invalidSchema, tooManyEntries
    case invalidIdentifier, invalidUUID, duplicateIdentifier, duplicateUUID
    case launchFailed, readFailed, processFailed, timedOut, cancelled, cleanupFailed

    var errorDescription: String? {
        switch self {
        case .inputTooLarge: "APFS metadata exceeded the supported size limit."
        case .invalidPlist, .invalidSchema: "macOS returned unsupported APFS metadata."
        case .tooManyEntries: "APFS metadata exceeded the supported entry limit."
        case .invalidIdentifier, .invalidUUID, .duplicateIdentifier, .duplicateUUID:
            "APFS device identities could not be verified."
        case .launchFailed: "The APFS metadata query could not start."
        case .readFailed: "The APFS metadata query could not be read."
        case .processFailed: "macOS could not complete the APFS metadata query."
        case .timedOut: "The APFS metadata query timed out."
        case .cancelled: "The APFS metadata query was cancelled."
        case .cleanupFailed: "The APFS metadata query did not finish its cleanup."
        }
    }
}

nonisolated struct SafeEjectAPFSTopology: Sendable, Equatable {
    let containers: [Container]

    struct Container: Sendable, Equatable {
        let bsdName: String
        let uuid: UUID
        let volumes: [Volume]
        let stores: [Store]
    }

    struct Volume: Sendable, Equatable {
        let bsdName: String
        let uuid: UUID
    }

    struct Store: Sendable, Equatable {
        let bsdName: String
        let uuid: UUID
    }

    static let maximumBytes = 1_048_576
    static let maximumContainers = 128
    static let maximumVolumesPerContainer = 1_024
    static let maximumStoresPerContainer = 32
    static let maximumTotalEntries = 4_096

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SafeEjectAPFSError.inputTooLarge }
        let value: Any
        do { value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) } catch {
            throw SafeEjectAPFSError.invalidPlist
        }
        guard let root = value as? [String: Any], let entries = root["Containers"] as? [[String: Any]] else {
            throw SafeEjectAPFSError.invalidSchema
        }
        guard entries.count <= maximumContainers else { throw SafeEjectAPFSError.tooManyEntries }
        var identifiers: Set<String> = []
        var uuids: Set<UUID> = []
        var total = 0
        func identity(_ fields: [String: Any], nameKey: String, uuidKey: String) throws -> (String, UUID) {
            guard let name = fields[nameKey] as? String, let rawUUID = fields[uuidKey] as? String else {
                throw SafeEjectAPFSError.invalidSchema
            }
            guard name.utf8.count <= 64,
                name.range(of: #"\Adisk[0-9]+(?:s[0-9]+)*\z"#, options: .regularExpression) != nil
            else { throw SafeEjectAPFSError.invalidIdentifier }
            guard rawUUID.utf8.count == 36, let uuid = UUID(uuidString: rawUUID) else {
                throw SafeEjectAPFSError.invalidUUID
            }
            guard identifiers.insert(name).inserted else { throw SafeEjectAPFSError.duplicateIdentifier }
            guard uuids.insert(uuid).inserted else { throw SafeEjectAPFSError.duplicateUUID }
            total += 1
            guard total <= maximumTotalEntries else { throw SafeEjectAPFSError.tooManyEntries }
            return (name, uuid)
        }
        let containers = try entries.map { fields in
            guard let volumes = fields["Volumes"] as? [[String: Any]],
                let stores = fields["PhysicalStores"] as? [[String: Any]], !stores.isEmpty
            else { throw SafeEjectAPFSError.invalidSchema }
            guard volumes.count <= maximumVolumesPerContainer, stores.count <= maximumStoresPerContainer else {
                throw SafeEjectAPFSError.tooManyEntries
            }
            let (name, uuid) = try identity(fields, nameKey: "ContainerReference", uuidKey: "APFSContainerUUID")
            return Container(
                bsdName: name, uuid: uuid,
                volumes: try volumes.map { fields in
                    let (name, uuid) = try identity(fields, nameKey: "DeviceIdentifier", uuidKey: "APFSVolumeUUID")
                    return Volume(bsdName: name, uuid: uuid)
                },
                stores: try stores.map { fields in
                    let (name, uuid) = try identity(fields, nameKey: "DeviceIdentifier", uuidKey: "DiskUUID")
                    return Store(bsdName: name, uuid: uuid)
                })
        }
        return Self(containers: containers)
    }
}

nonisolated enum SafeEjectAPFSReadChunk {
    case bytes(Data)
    case waiting, end
}

// One worker owns the process and all pipe access, including termination and closing.
nonisolated protocol SafeEjectAPFSProcessControlling {
    func launch() throws
    func read(maximumBytes: Int) throws -> SafeEjectAPFSReadChunk
    var isRunning: Bool { get }
    var exitedSuccessfully: Bool { get }
    func terminate()
    func forceTerminate() throws
    func close() throws
}

nonisolated struct SafeEjectAPFSReader: Sendable {
    private let makeProcess: @Sendable () -> any SafeEjectAPFSProcessControlling
    private let timeout: Duration
    private let terminationGrace: Duration

    init() {
        self.init(makeProcess: { SafeEjectAPFSNativeProcess() })
    }

    init(
        makeProcess: @escaping @Sendable () -> any SafeEjectAPFSProcessControlling,
        timeout: Duration = .seconds(3), terminationGrace: Duration = .milliseconds(250)
    ) {
        self.makeProcess = makeProcess
        self.timeout = min(.seconds(3), max(.zero, timeout))
        self.terminationGrace = min(.milliseconds(250), max(.zero, terminationGrace))
    }

    func read() async throws -> SafeEjectAPFSTopology {
        guard !Task.isCancelled else { throw SafeEjectAPFSError.cancelled }
        let task = Task.detached(priority: .utility) {
            let process = makeProcess()
            let result: Result<Data, SafeEjectAPFSError>
            do {
                result = .success(try Self.collect(process, timeout: timeout))
            } catch let error as SafeEjectAPFSError {
                result = .failure(error)
            } catch {
                result = .failure(.readFailed)
            }
            try Self.cleanUp(process, grace: terminationGrace)
            guard !Task.isCancelled else { throw SafeEjectAPFSError.cancelled }
            let topology = try SafeEjectAPFSTopology.parse(result.get())
            guard !Task.isCancelled else { throw SafeEjectAPFSError.cancelled }
            return topology
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func collect(_ process: any SafeEjectAPFSProcessControlling, timeout: Duration) throws -> Data {
        guard !Task.isCancelled else { throw SafeEjectAPFSError.cancelled }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do { try process.launch() } catch { throw SafeEjectAPFSError.launchFailed }
        var output = Data()
        var reachedEnd = false
        while true {
            if Task.isCancelled { throw SafeEjectAPFSError.cancelled }
            guard ContinuousClock.now < deadline else { throw SafeEjectAPFSError.timedOut }
            if !reachedEnd {
                switch try process.read(
                    maximumBytes: min(16_384, SafeEjectAPFSTopology.maximumBytes - output.count + 1))
                {
                case .bytes(let data):
                    guard data.count <= SafeEjectAPFSTopology.maximumBytes - output.count else {
                        throw SafeEjectAPFSError.inputTooLarge
                    }
                    output.append(data)
                    continue
                case .end: reachedEnd = true
                case .waiting: break
                }
            }
            if reachedEnd, !process.isRunning {
                guard process.exitedSuccessfully else { throw SafeEjectAPFSError.processFailed }
                return output
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func cleanUp(_ process: any SafeEjectAPFSProcessControlling, grace: Duration) throws {
        var failed = false
        if process.isRunning {
            process.terminate()
            let deadline = ContinuousClock.now.advanced(by: grace)
            while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning {
                do { try process.forceTerminate() } catch { failed = true }
                let deadline = ContinuousClock.now.advanced(by: grace)
                while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
                if process.isRunning { failed = true }
            }
        }
        do { try process.close() } catch { failed = true }
        if failed { throw SafeEjectAPFSError.cleanupFailed }
    }
}

nonisolated private final class SafeEjectAPFSNativeProcess: SafeEjectAPFSProcessControlling {
    private let process = Process()
    private let output = Pipe()
    private var null: FileHandle?
    private var launched = false
    private var writerOpen = true

    var isRunning: Bool { launched && process.isRunning }
    var exitedSuccessfully: Bool { launched && !process.isRunning && process.terminationStatus == 0 }

    func launch() throws {
        guard let null = FileHandle(forUpdatingAtPath: "/dev/null") else { throw SafeEjectAPFSError.launchFailed }
        self.null = null
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw SafeEjectAPFSError.launchFailed
        }
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        process.standardInput = null
        process.standardOutput = output
        process.standardError = null
        try process.run()
        launched = true
        writerOpen = false
        try output.fileHandleForWriting.close()
    }

    func read(maximumBytes: Int) throws -> SafeEjectAPFSReadChunk {
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, maximumBytes)
        if count > 0 { return .bytes(Data(buffer.prefix(count))) }
        if count == 0 { return .end }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return .waiting }
        throw SafeEjectAPFSError.readFailed
    }

    func terminate() { if isRunning { process.terminate() } }

    func forceTerminate() throws {
        guard isRunning else { return }
        guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else {
            throw SafeEjectAPFSError.cleanupFailed
        }
    }

    func close() throws {
        var failed = false
        do { try output.fileHandleForReading.close() } catch { failed = true }
        if writerOpen {
            writerOpen = false
            do { try output.fileHandleForWriting.close() } catch { failed = true }
        }
        if let null {
            self.null = nil
            do { try null.close() } catch { failed = true }
        }
        if failed { throw SafeEjectAPFSError.cleanupFailed }
    }
}
