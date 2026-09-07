import Darwin
import Foundation
import Testing
@testable import Semper

@Suite("App instance lock")
struct AppInstanceLockTests {
    @Test("Only one owner can hold the process lock")
    func rejectsSecondOwner() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try AppInstanceLock.acquire(in: directory)
        guard case .acquired(let lock) = first else {
            Issue.record("First acquisition did not own the lock")
            return
        }

        let second = try AppInstanceLock.acquire(in: directory)
        guard case .alreadyRunning = second else {
            Issue.record("Second acquisition was not rejected")
            return
        }

        withExtendedLifetime(lock) {}
    }

    @Test("Releasing the owner permits another acquisition")
    func permitsAcquisitionAfterRelease() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var firstLock: AppInstanceLock?
        do {
            let first = try AppInstanceLock.acquire(in: directory)
            if case .acquired(let lock) = first {
                firstLock = lock
            } else {
                Issue.record("First acquisition did not own the lock")
                return
            }
        }

        #expect(firstLock != nil)
        firstLock = nil

        let second = try AppInstanceLock.acquire(in: directory)
        guard case .acquired(let lock) = second else {
            Issue.record("Lock remained held after its owner was released")
            return
        }
        withExtendedLifetime(lock) {}
    }

    @Test("Lock descriptor closes across exec")
    func marksDescriptorCloseOnExec() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let acquisition = try AppInstanceLock.acquire(in: directory)
        guard case .acquired(let lock) = acquisition else {
            Issue.record("First acquisition did not own the lock")
            return
        }

        let descriptorFlags = fcntl(lock.fileDescriptorForTesting, F_GETFD)
        #expect(descriptorFlags >= 0)
        #expect(descriptorFlags & FD_CLOEXEC == FD_CLOEXEC)

        withExtendedLifetime(lock) {}
    }

    @Test("A second process cannot take the lock")
    func rejectsAnotherProcess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let acquisition = try AppInstanceLock.acquire(in: directory)
        guard case .acquired(let lock) = acquisition else {
            Issue.record("First acquisition did not own the lock")
            return
        }

        let lockPath = directory
            .appendingPathComponent("systems.semper.Semper", isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false)
            .path
        let blockedResult = try childLockAttempt(path: lockPath)
        #expect(blockedResult.terminationStatus == 23)

        withExtendedLifetime(lock) {}
    }

    private func childLockAttempt(path: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl, os, sys; fd = os.open(sys.argv[1], os.O_RDWR); "
                + "\ntry: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)"
                + "\nexcept BlockingIOError: sys.exit(23)"
                + "\nsys.exit(0)",
            path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
