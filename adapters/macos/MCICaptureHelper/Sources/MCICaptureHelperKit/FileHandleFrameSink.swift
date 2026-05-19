// SPDX-License-Identifier: TBD-private
//
// FileHandleFrameSink — concrete FrameSink backed by a Foundation
// FileHandle. Production wraps the AF_UNIX socket the Rust core
// passed to the helper at launch (cycle 3 wires this); tests wrap
// a Pipe's writing end.

import Foundation

/// `FrameSink` implementation backed by a `FileHandle`.
///
/// Writes are synchronous on the underlying syscall — `FileHandle.write`
/// is blocking. The `async` interface lets callers await it from a
/// concurrency context without monopolizing a thread, but the sink
/// does NOT background-thread the write. Production cycle 3+ will
/// front this with a bounded async queue if SCStream callbacks need
/// non-blocking emission, but for HelperHealth (every 30 s) the
/// straight-line write is fine.
public struct FileHandleFrameSink: FrameSink {
    private let handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public func write(_ data: Data) async throws {
        // `FileHandle.write(contentsOf:)` is `throws` on macOS 14+.
        try handle.write(contentsOf: data)
    }
}
