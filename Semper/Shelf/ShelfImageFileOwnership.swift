import Darwin
import Foundation
import Synchronization

nonisolated struct ShelfImageTemporaryCopy: Equatable, Sendable {
    let url: URL
    let device: Int32?
    let inode: UInt64?
    let parentDevice: Int32
    let parentInode: UInt64
    var recoveryLocations: [URL] { owner?.recoveryLocations ?? [url] }
    let owner: ShelfImageFileOwner?

    init(
        url: URL, device: Int32?, inode: UInt64?, parentDevice: Int32, parentInode: UInt64,
        owner: ShelfImageFileOwner? = nil
    ) {
        self.url = url
        self.device = device
        self.inode = inode
        self.parentDevice = parentDevice
        self.parentInode = parentInode
        self.owner = owner
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.device == rhs.device && lhs.inode == rhs.inode
            && lhs.parentDevice == rhs.parentDevice && lhs.parentInode == rhs.parentInode
            && lhs.owner?.id == rhs.owner?.id
    }
}

nonisolated struct ShelfImagePublishedCopy: Equatable, Sendable {
    let requestedURL: URL
    let dimensions: ShelfImageDimensions
    var lastKnownURL: URL? { owner?.lastKnownURL }
    var recoveryLocations: [URL] { owner?.recoveryLocations ?? [] }
    let owner: ShelfImageFileOwner?

    init(requestedURL: URL, dimensions: ShelfImageDimensions, owner: ShelfImageFileOwner? = nil) {
        self.requestedURL = requestedURL
        self.dimensions = dimensions
        self.owner = owner
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestedURL == rhs.requestedURL && lhs.dimensions == rhs.dimensions && lhs.owner?.id == rhs.owner?.id
    }
}

nonisolated enum ShelfImageFileCheckpoint: Equatable, Sendable {
    case beforeStageIdentity, beforePublication, afterPublication, beforeClaim, afterClaim, beforeRestore, beforeReceipt
}

nonisolated struct ShelfImageFileContext: Sendable {
    let stage: URL
    let claim: URL
    let destination: URL
}

nonisolated struct ShelfImageFileOperations: Sendable {
    var makePrivateDirectory: @Sendable (URL) throws -> URL
    var clone: @Sendable (Int32, Int32, String) throws -> Void
    var path: @Sendable (Int32) throws -> URL
    var checkpoint: @Sendable (ShelfImageFileCheckpoint, ShelfImageFileContext) throws -> Void = { _, _ in }

    static let native = Self(
        makePrivateDirectory: {
            try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: $0, create: true)
        },
        clone: { source, parent, name in
            guard fclonefileat(source, parent, name, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
                switch errno {
                case EEXIST: throw ShelfImageCopyFailure.destinationExists
                case ENOTSUP, EXDEV: throw ShelfImageCopyFailure.cloningUnsupported
                default: throw ShelfImageCopyFailure.writeFailed
                }
            }
        },
        path: { descriptor in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw ShelfImageCopyFailure.destinationChanged }
            return try buffer.withUnsafeBufferPointer {
                guard let base = $0.baseAddress else { throw ShelfImageCopyFailure.destinationChanged }
                return URL(fileURLWithFileSystemRepresentation: base, isDirectory: false, relativeTo: nil)
            }
        })
}

nonisolated final class ShelfImageFileOwner: Sendable {
    let id = UUID()
    let stageDescriptor: Int32
    private let destination: URL
    private let privateDirectory: URL
    private let parentID: ShelfImageFileID
    private let privateID: ShelfImageFileID
    private let stageIdentity: Result<ShelfImageFileID, any Error>
    private let operations: ShelfImageFileOperations
    private let state: Mutex<State>
    private let stageName = "image.tmp"
    private let claimName = "cleanup-claim.tmp"

    private struct State {
        var destinationFD: Int32
        var privateFD: Int32
        var stageFD: Int32
        var publishedFD: Int32 = -1
        var claimExists = false
        var expected: Data?
        var dimensions = ShelfImageDimensions(width: 0, height: 0)
        var published = false
        var cleaned = false
        var location: URL?
    }

    init(destination: URL, operations: ShelfImageFileOperations) throws {
        self.destination = destination.standardizedFileURL
        self.operations = operations
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw ShelfImageCopyFailure.invalidDestination }
        do {
            parentID = try ShelfImageFileID(descriptor: parentFD, kind: S_IFDIR)
            privateDirectory = try operations.makePrivateDirectory(destination).standardizedFileURL
            let privateFD = open(privateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard privateFD >= 0 else { throw ShelfImageCopyFailure.writeFailed }
            do {
                guard fchmod(privateFD, 0o700) == 0 else { throw ShelfImageCopyFailure.writeFailed }
                privateID = try ShelfImageFileID(descriptor: privateFD, kind: S_IFDIR)
                guard privateID.device == parentID.device else { throw ShelfImageCopyFailure.cloningUnsupported }
                let fileFD = openat(privateFD, "image.tmp", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fileFD >= 0 else { throw ShelfImageCopyFailure.writeFailed }
                stageDescriptor = fileFD
                do {
                    try operations.checkpoint(
                        .beforeStageIdentity,
                        ShelfImageFileContext(
                            stage: privateDirectory.appendingPathComponent("image.tmp"),
                            claim: privateDirectory.appendingPathComponent("cleanup-claim.tmp"),
                            destination: destination))
                    stageIdentity = .success(try ShelfImageFileID(descriptor: fileFD, kind: S_IFREG))
                } catch {
                    stageIdentity = .failure(error)
                }
                state = Mutex(State(destinationFD: parentFD, privateFD: privateFD, stageFD: fileFD))
            } catch {
                close(privateFD)
                throw error
            }
        } catch {
            close(parentFD)
            throw error
        }
    }

    deinit {
        state.withLock { state in
            for descriptor in [state.stageFD, state.privateFD, state.destinationFD, state.publishedFD]
            where descriptor >= 0 {
                close(descriptor)
            }
        }
    }

    var temporaryCopy: ShelfImageTemporaryCopy {
        let identity: ShelfImageFileID?
        switch stageIdentity {
        case .success(let value): identity = value
        case .failure: identity = nil
        }
        return ShelfImageTemporaryCopy(
            url: privateDirectory.appendingPathComponent(stageName), device: identity?.device,
            inode: identity?.inode, parentDevice: privateID.device, parentInode: privateID.inode,
            owner: self)
    }

    var publishedCopy: ShelfImagePublishedCopy {
        state.withLock { ShelfImagePublishedCopy(requestedURL: destination, dimensions: $0.dimensions, owner: self) }
    }

    func validateForWriting() throws {
        _ = try stageIdentity.get()
    }

    var hasPublished: Bool { state.withLock { $0.published } }
    var lastKnownURL: URL? { state.withLock { $0.location } }
    var recoveryLocations: [URL] {
        state.withLock {
            let directory = ((try? operations.path($0.privateFD)) ?? privateDirectory).standardizedFileURL
            var locations = $0.location.map { [$0] } ?? []
            if !$0.cleaned { locations.append(directory.appendingPathComponent(stageName)) }
            if $0.claimExists { locations.append(directory.appendingPathComponent(claimName)) }
            if $0.stageFD >= 0, let current = try? operations.path($0.stageFD).standardizedFileURL,
                !locations.contains(current)
            {
                locations.append(current)
            }
            return locations
        }
    }

    func publish(encoded: Data, dimensions: ShelfImageDimensions) throws -> ShelfImageCopyReceipt {
        try state.withLock { state in
            guard !state.published, !state.cleaned else { throw ShelfImageCopyFailure.writeFailed }
            try operations.checkpoint(.beforePublication, context)
            try checkCancellation()
            guard
                try ShelfImageFileID(
                    path: destination.deletingLastPathComponent().resolvingSymlinksInPath(), kind: S_IFDIR
                ) == parentID
            else {
                throw ShelfImageCopyFailure.destinationChanged
            }
            try operations.clone(state.stageFD, state.destinationFD, destination.lastPathComponent)
            state.published = true
            state.expected = encoded
            state.dimensions = dimensions
            do {
                try capturePublishedDescriptor(&state)
                try operations.checkpoint(.afterPublication, context)
                return try recover(&state)
            } catch {
                throw ShelfImageCopyFailure.publicationUncertain(
                    ShelfImagePublishedCopy(requestedURL: destination, dimensions: dimensions, owner: self))
            }
        }
    }

    func recoverPublication() throws -> ShelfImageCopyReceipt {
        try state.withLock { state in
            guard state.published else { throw ShelfImageCopyFailure.writeFailed }
            do {
                if state.publishedFD < 0 { try capturePublishedDescriptor(&state) }
                return try recover(&state)
            } catch {
                throw ShelfImageCopyFailure.publicationUncertain(
                    ShelfImagePublishedCopy(requestedURL: destination, dimensions: state.dimensions, owner: self))
            }
        }
    }

    func acknowledgeUnverifiedCopy() throws {
        try state.withLock { state in
            guard state.published else { throw ShelfImageCopyFailure.writeFailed }
            try cleanUp(&state)
        }
    }

    func cleanUp() throws {
        try state.withLock { state in
            do { try cleanUp(&state) } catch { throw ShelfImageCopyFailure.cleanupFailed(temporaryCopy) }
        }
    }

    private var context: ShelfImageFileContext {
        ShelfImageFileContext(
            stage: privateDirectory.appendingPathComponent(stageName),
            claim: privateDirectory.appendingPathComponent(claimName), destination: destination)
    }

    private func capturePublishedDescriptor(_ state: inout State) throws {
        let descriptor = openat(
            state.destinationFD, destination.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ShelfImageCopyFailure.destinationChanged }
        do {
            _ = try ShelfImageFileID(descriptor: descriptor, kind: S_IFREG)
            try verifyBytes(descriptor, expected: state.expected)
            state.publishedFD = descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func recover(_ state: inout State) throws -> ShelfImageCopyReceipt {
        let location = try operations.path(state.publishedFD).standardizedFileURL
        state.location = location
        try verifyBytes(state.publishedFD, expected: state.expected)
        try operations.checkpoint(.beforeReceipt, context)
        let identity = try ShelfImageFileID(descriptor: state.publishedFD, kind: S_IFREG)
        guard try ShelfImageFileID(path: location, kind: S_IFREG) == identity else {
            throw ShelfImageCopyFailure.destinationChanged
        }
        try cleanUp(&state)
        let finalLocation = try operations.path(state.publishedFD).standardizedFileURL
        guard try ShelfImageFileID(path: finalLocation, kind: S_IFREG) == identity else {
            throw ShelfImageCopyFailure.destinationChanged
        }
        state.location = finalLocation
        let receipt = ShelfImageCopyReceipt(url: finalLocation, dimensions: state.dimensions)
        return receipt
    }

    private func cleanUp(_ state: inout State) throws {
        if state.cleaned { return }
        guard try ShelfImageFileID(path: privateDirectory, kind: S_IFDIR) == privateID else {
            throw ShelfImageCopyFailure.cleanupFailed(temporaryCopy)
        }
        let stageID: ShelfImageFileID
        switch stageIdentity {
        case .success(let identity): stageID = identity
        case .failure: stageID = try ShelfImageFileID(descriptor: state.stageFD, kind: S_IFREG)
        }
        if !state.claimExists {
            try operations.checkpoint(.beforeClaim, context)
            if renameatx_np(state.privateFD, stageName, state.privateFD, claimName, UInt32(RENAME_EXCL)) == 0 {
                state.claimExists = true
            } else if errno != ENOENT {
                throw ShelfImageCopyFailure.cleanupFailed(temporaryCopy)
            }
        }
        if state.claimExists {
            try operations.checkpoint(.afterClaim, context)
            let claimed = try ShelfImageFileID(parent: state.privateFD, name: claimName)
            if claimed != stageID {
                try operations.checkpoint(.beforeRestore, context)
                if renameatx_np(state.privateFD, claimName, state.privateFD, stageName, UInt32(RENAME_EXCL)) == 0 {
                    state.claimExists = false
                }
                throw ShelfImageCopyFailure.cleanupFailed(temporaryCopy)
            }
            // The pinned private namespace is exclusively managed by this operation.
            var retained = stat()
            guard fstat(state.stageFD, &retained) == 0, retained.st_nlink == 1,
                unlinkat(state.privateFD, claimName, 0) == 0
            else {
                throw ShelfImageCopyFailure.cleanupFailed(temporaryCopy)
            }
            state.claimExists = false
        }
        var stage = stat()
        guard fstat(state.stageFD, &stage) == 0, stage.st_nlink == 0,
            try FileManager.default.contentsOfDirectory(atPath: privateDirectory.path).isEmpty
        else { throw ShelfImageCopyFailure.cleanupFailed(temporaryCopy) }
        state.cleaned = true
        close(state.stageFD)
        state.stageFD = -1
        // Leave the empty system replacement directory; its parent name is not privately owned.
    }

    private func verifyBytes(_ descriptor: Int32, expected: Data?) throws {
        guard let expected, lseek(descriptor, 0, SEEK_SET) == 0 else { throw ShelfImageCopyFailure.verificationFailed }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_size == expected.count,
            before.st_flags & UInt32(SF_DATALESS) == 0
        else { throw ShelfImageCopyFailure.verificationFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var offset = 0
        while offset < expected.count {
            let data = try file.read(upToCount: min(ShelfLimits.chunkBytes, expected.count - offset)) ?? Data()
            guard !data.isEmpty, data == expected[offset..<(offset + data.count)] else {
                throw ShelfImageCopyFailure.verificationFailed
            }
            offset += data.count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw ShelfImageCopyFailure.verificationFailed }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ShelfFailure.cancelled }
    }
}

nonisolated private struct ShelfImageFileID: Equatable, Sendable {
    let device: Int32
    let inode: UInt64

    init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
    init(descriptor: Int32, kind: mode_t) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == kind, info.st_ino != 0 else {
            throw ShelfImageCopyFailure.writeFailed
        }
        self.init(device: info.st_dev, inode: info.st_ino)
    }
    init(path: URL, kind: mode_t) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == kind, info.st_ino != 0 else {
            throw ShelfImageCopyFailure.destinationChanged
        }
        self.init(device: info.st_dev, inode: info.st_ino)
    }
    init(parent: Int32, name: String) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_ino != 0
        else { throw ShelfImageCopyFailure.writeFailed }
        self.init(device: info.st_dev, inode: info.st_ino)
    }
}
