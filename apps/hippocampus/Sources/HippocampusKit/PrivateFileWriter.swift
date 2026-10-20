// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Writes a file that only this user can read from the moment it exists: a
/// temporary file created mode 0600 beside the target, synced, then renamed
/// over it (storage-security review S9). Foundation's atomic write creates
/// its temporary with the umask's mode (0644), so a file it writes is
/// readable by other accounts until a later chmod, if one comes.
package enum PrivateFileWriter {
    package enum WriteError: Error, Equatable {
        case couldNotCreate(Int32)
        case couldNotWrite(Int32)
        case couldNotReplace(Int32)
    }

    /// Writes `data` to `url`, mode 0600. The folder must exist.
    package static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WriteError.couldNotCreate(errno) }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            while written < buffer.count {
                let result = Darwin.write(descriptor, base + written, buffer.count - written)
                if result <= 0 { return false }
                written += result
            }
            return true
        }
        let writeErrno = errno
        _ = fchmod(descriptor, 0o600)
        _ = fsync(descriptor)
        Darwin.close(descriptor)
        guard ok else {
            _ = Darwin.unlink(temporary.path)
            throw WriteError.couldNotWrite(writeErrno)
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let renameErrno = errno
            _ = Darwin.unlink(temporary.path)
            throw WriteError.couldNotReplace(renameErrno)
        }
    }

    /// `write(_:to:)` for text.
    package static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }
}
