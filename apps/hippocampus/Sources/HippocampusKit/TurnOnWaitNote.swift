// SPDX-License-Identifier: Apache-2.0
//
// TurnOnWaitNote.swift — a Turn On that a permission macOS had off refused,
// kept for the next launch. A refused Turn On saves nothing on (cbff16c), and
// what it was waiting on lived in memory only. When the person allows Screen
// Recording for a running app, System Settings offers to Quit & Reopen it,
// and the relaunch read a plain "Off", as if nothing had been pressed: the
// silent Off the Turn On series set out to remove.
//
// The next launch presses Turn On again, once, with a fresh helper: it lands
// only if that helper finds every permission on, and otherwise says Needs
// permission again. The note is honoured for ten minutes, and goes when Turn
// On lands or fails for another reason, on a turn-off, and when the person
// quits Hippocampus themselves (System Settings' Quit & Reopen keeps it).

import Foundation

public protocol TurnOnWaitNoting: Sendable {
    /// When a Turn On last stopped on a permission macOS had off; nil once
    /// it landed, failed for another reason, was turned off or was dropped.
    var refusedAt: Date? { get }
    func record(_ date: Date)
    func clear()
}

public enum TurnOnWaitNote {
    /// How long the next launch honours a note.
    public static let honouredFor: TimeInterval = 10 * 60

    static func honours(_ refusedAt: Date?, now: Date) -> Bool {
        guard let refusedAt else { return false }
        let age = now.timeIntervalSince(refusedAt)
        return age >= 0 && age <= honouredFor
    }
}

/// Remembers nothing: the default, so tests never touch a real defaults
/// domain.
public struct NoTurnOnWaitNote: TurnOnWaitNoting {
    public init() {}
    public var refusedAt: Date? { nil }
    public func record(_ date: Date) {}
    public func clear() {}
}

/// The app's note, in its own defaults.
public final class UserDefaultsTurnOnWaitNote: TurnOnWaitNoting, @unchecked Sendable {
    public static let key = "ai.hippocampus.turnOn.refusedForPermissionAt"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var refusedAt: Date? {
        (defaults.object(forKey: Self.key) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    public func record(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
