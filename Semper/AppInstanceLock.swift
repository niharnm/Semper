import Darwin
import Foundation

enum AppInstanceLockError: Error {
    case applicationSupportDirectoryUnavailable
    case invalidLockFile
}

enum AppInstanceLockAcquisition {
    case acquired(AppInstanceLock)
    case alreadyRunning
}

final class AppInstanceLock {
    private static let directoryName = "systems.semper.Semper"
    private let fileDescriptor: Int32

    #if DEBUG
    var fileDescriptorForTesting: Int32 {
        fileDescriptor
    }
    #endif

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        close(fileDescriptor)
    }

    static func acquire() throws -> AppInstanceLockAcquisition {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppInstanceLockError.applicationSupportDirectoryUnavailable
        }

        return try acquire(in: applicationSupportDirectory)
    }

    static func acquire(in applicationSupportDirectory: URL) throws -> AppInstanceLockAcquisition {
        let lockDirectory = applicationSupportDirectory.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let lockURL = lockDirectory.appendingPathComponent("instance.lock", isDirectory: false)
        let fileDescriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0 else {
            let errorCode = errno
            close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
        guard fileStatus.st_uid == geteuid(),
              fileStatus.st_nlink == 1,
              (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(fileDescriptor)
            throw AppInstanceLockError.invalidLockFile
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorCode = errno
            close(fileDescriptor)
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                return .alreadyRunning
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }

        return .acquired(AppInstanceLock(fileDescriptor: fileDescriptor))
    }
}
