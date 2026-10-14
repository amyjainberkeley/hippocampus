// SPDX-License-Identifier: Apache-2.0
//
// CaptureStopNote.swift — remembers that the person pressed macOS's Stop
// Sharing, and when (spec-shell S5). The menu then says why remembering is
// off ("You stopped it at 3:04 PM."), and the next launch stays off even if
// writing `capture_enabled = false` to runtime.toml failed.
//
// The note lives on the same disk as runtime.toml, so a full disk defeats
// both: it covers a refused write (a permission error), not a disk with no
// room (critique-shell-engineering 13).

import Foundation

public protocol CaptureStopNoting: Sendable {
    /// When the person last pressed Stop Sharing; nil once remembering was
    /// turned back on.
    var stoppedSharingAt: Date? { get }
    func record(_ date: Date)
    func clear()
}

/// Remembers nothing: the default, so tests never touch a real defaults
/// domain.
public struct NoCaptureStopNote: CaptureStopNoting {
    public init() {}
    public var stoppedSharingAt: Date? { nil }
    public func record(_ date: Date) {}
    public func clear() {}
}

/// The app's note, in its own defaults (`defaults read ai.hippocampus
/// ai.hippocampus.capture.stoppedSharingAt` prints the time as a number).
public final class UserDefaultsCaptureStopNote: CaptureStopNoting, @unchecked Sendable {
    public static let key = "ai.hippocampus.capture.stoppedSharingAt"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var stoppedSharingAt: Date? {
        (defaults.object(forKey: Self.key) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    public func record(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
