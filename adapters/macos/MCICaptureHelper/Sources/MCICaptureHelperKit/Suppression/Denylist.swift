// SPDX-License-Identifier: TBD-private
//
// Denylist — pattern matcher for app bundle IDs, URLs, and window
// titles. PROTECTED-SET per AGENT_PROTOCOL §5 (sensitive-capture
// denylist). Implements `DenylistProbe`.
//
// The denylist is loaded from `core::store::denylist` (rows shipped to
// the helper at start-up + on user-edit). The helper holds a
// thread-safe copy and matches per state-transition.

import Foundation

/// Pattern shape for a denylist entry.
public enum DenylistPatternKind: Sendable, Equatable {
    /// Exact app bundle ID match.
    case appBundle
    /// URL prefix match (e.g. `"https://accounts.google.com/"`).
    case urlPrefix
    /// Substring match against the window title.
    case windowTitleSubstring
}

/// A single denylist entry.
public struct DenylistEntry: Sendable, Equatable {
    public let kind: DenylistPatternKind
    public let pattern: String

    public init(kind: DenylistPatternKind, pattern: String) {
        self.kind = kind
        self.pattern = pattern
    }
}

/// Concrete `DenylistProbe` implementation backed by an immutable
/// snapshot of denylist entries.
///
/// The helper rebuilds the `Denylist` value when `core` pushes a new
/// snapshot; matching is read-only and lock-free.
public struct Denylist: Sendable, DenylistProbe {
    private let appBundles: Set<String>
    private let urlPrefixes: [String]
    private let windowTitleSubstrings: [String]

    public init(entries: [DenylistEntry]) {
        var apps: Set<String> = []
        var urls: [String] = []
        var titles: [String] = []
        for e in entries {
            switch e.kind {
            case .appBundle: apps.insert(e.pattern)
            case .urlPrefix: urls.append(e.pattern)
            case .windowTitleSubstring: titles.append(e.pattern)
            }
        }
        self.appBundles = apps
        self.urlPrefixes = urls
        self.windowTitleSubstrings = titles
    }

    public func appIsDenied(bundleId: String) -> Bool {
        appBundles.contains(bundleId)
    }

    public func urlIsDenied(_ url: String) -> Bool {
        urlPrefixes.contains(where: { url.hasPrefix($0) })
    }

    public func windowTitleIsDenied(_ title: String) -> Bool {
        windowTitleSubstrings.contains(where: { title.contains($0) })
    }
}
