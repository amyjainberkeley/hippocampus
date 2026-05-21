// SPDX-License-Identifier: TBD-private
import Foundation

struct LogRotator: Sendable {
    let path: URL
    let maxBytes: UInt64

    init(path: URL, maxBytes: UInt64 = 10 * 1024 * 1024) {
        self.path = path
        self.maxBytes = maxBytes
    }

    func fileHandle() throws -> FileHandle {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil)
        }

        rotateIfNeeded()

        guard let handle = FileHandle(forWritingAtPath: path.path) else {
            throw NSError(domain: "LogRotator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot open \(path.path) for writing"
            ])
        }
        handle.seekToEndOfFile()
        return handle
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? UInt64,
              size > maxBytes
        else { return }

        let rotated = path.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: path, to: rotated)
        fm.createFile(atPath: path.path, contents: nil)
    }
}
