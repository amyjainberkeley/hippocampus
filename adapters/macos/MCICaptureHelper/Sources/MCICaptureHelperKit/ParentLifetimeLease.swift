import Foundation

/// An inherited read descriptor whose EOF means the owning app disappeared.
///
/// The parent retains the write end for its lifetime. Normal quit closes it
/// explicitly; crash, Force Quit, and SIGKILL close it in the kernel. The
/// capture helper can therefore drain and exit even when AppKit cleanup never
/// runs.
public enum ParentLifetimeLease {
    public static func waitForEOF(on handle: FileHandle = .standardInput) async throws {
        for try await _ in handle.bytes {
            try Task.checkCancellation()
        }
    }
}
