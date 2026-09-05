import CryptoKit
import Darwin
import Foundation

/// Held for the parent GUI lifetime. Direct executable launches bypass Launch
/// Services' instance reuse; this lock closes concurrent cold-launch races.
public final class ParentApplicationLease {
    public enum Failure: Error { case unsafeLock, unavailable }
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(
        executableURL: URL,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> ParentApplicationLease? {
        let identity = executableURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockURL = directory.appendingPathComponent("hippocampus-parent-\(digest).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        var retained = false
        defer { if !retained { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0
        else { throw Failure.unsafeLock }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw Failure.unavailable
        }
        retained = true
        return ParentApplicationLease(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
