import Foundation

/// Test seam: an in-memory `FileChecker` driven by a set of paths that
/// "exist." Used by `RealBrowserDetectorTests` to drive each per-browser
/// installed/not-installed branch without touching the real filesystem.
public final class StubFileChecker: FileChecker, @unchecked Sendable {
    public var existingPaths: Set<String>
    public private(set) var queriedPaths: [String] = []

    public init(existingPaths: Set<String> = []) {
        self.existingPaths = existingPaths
    }

    public func fileExists(atPath path: String) -> Bool {
        queriedPaths.append(path)
        return existingPaths.contains(path)
    }
}
