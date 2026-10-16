import Foundation

/// An inherited read descriptor whose EOF means the owning app disappeared.
///
/// The parent retains the write end for its lifetime. Normal quit closes it
/// explicitly; crash, Force Quit, and SIGKILL close it in the kernel. The
/// capture helper can therefore drain and exit even when AppKit cleanup never
/// runs.
///
/// While it lives, the app may write single-byte requests on it
/// (`FreshReadRequest.byte` when Ask opens). Only the app that started the
/// helper holds the write end, so no other process can ask for a read.
public enum ParentLifetimeLease {
    public static func waitForEOF(
        on handle: FileHandle = .standardInput,
        onByte: @Sendable (UInt8) -> Void = { _ in }
    ) async throws {
        for try await byte in handle.bytes {
            try Task.checkCancellation()
            onByte(byte)
        }
    }
}
