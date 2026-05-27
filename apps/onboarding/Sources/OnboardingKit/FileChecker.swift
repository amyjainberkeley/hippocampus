import Foundation

/// Minimal seam for file-presence probes so detectors can be unit-tested
/// against an in-memory set of "existing" paths rather than the live FS.
public protocol FileChecker: Sendable {
    func fileExists(atPath path: String) -> Bool
}

public struct FoundationFileChecker: FileChecker {
    public init() {}
    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
