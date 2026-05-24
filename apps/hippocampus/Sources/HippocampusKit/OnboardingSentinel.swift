// SPDX-License-Identifier: TBD-private
import Foundation

/// Cross-process flag for "the user has finished onboarding at least once."
///
/// Hippocampus.app and the standalone Onboarding executable are two
/// separate processes with different bundle identifiers (and therefore
/// different `UserDefaults` domains by default). Using a file sentinel
/// at `~/Library/Application Support/MCI/.onboarding-complete` is
/// simpler than introducing an App Group entitlement just for this
/// boolean — file presence is the contract, file absence is the
/// "first run" state.
///
/// Write path: the Onboarding executable's `.done` slide → `Finish`
/// button → `OnboardingSentinel.markComplete()` before `NSApp.terminate`.
///
/// Read path: `HippocampusApp` on `applicationDidFinishLaunching` →
/// if `!OnboardingSentinel.isComplete && supervisor.hasOnboarding`,
/// call `supervisor.openOnboarding()`. Otherwise do nothing.
public enum OnboardingSentinel {
    public static let filename = ".onboarding-complete"

    /// Default location inside the MCI app-support directory.
    public static var defaultURL: URL {
        let appSupport = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
        return appSupport.appendingPathComponent(filename)
    }

    /// `true` if the sentinel file exists at the default location.
    public static var isComplete: Bool {
        isComplete(at: defaultURL)
    }

    public static func isComplete(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Idempotently create the sentinel. Creates the parent directory
    /// if missing. Safe to call repeatedly. Returns `true` if the
    /// sentinel is present after the call (whether or not the call
    /// itself wrote it).
    @discardableResult
    public static func markComplete() -> Bool {
        markComplete(at: defaultURL)
    }

    @discardableResult
    public static func markComplete(at url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            // Parent dir creation failed; can't write sentinel.
            return false
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        // The contents don't matter — presence is the signal. We write
        // an ISO timestamp so a tail / `cat` of the file gives a hint
        // when debugging "why isn't onboarding showing".
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "onboarding-completed-at \(stamp)\n"
        return (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// Test helper. Not used in production code paths.
    public static func reset(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
