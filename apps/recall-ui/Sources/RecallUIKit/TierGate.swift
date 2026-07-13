// TierGate.swift — freemium tier gate stubs for MCI (cycle 8.48).
//
// See `docs/business/tier-structure.md` for the ratified tier boundary
// (Free / Pro / Enterprise) and the trust invariants. Live billing +
// auth is deferred to v1.5+; this file is the stable API surface the
// codebase can grow into without a big-bang refactor when billing lands.
//
// # Contract (do not break without CSO + CEO sign-off)
//
// 1. `TierManager.shared.current` returns `.free` today, always. Any
//    change to that default gates existing v1.0 features and violates
//    trust invariant #1 (nothing in v1.0 ever moves to Pro).
// 2. `TierGate.isPro { … }` runs the closure iff the current tier is
//    `.pro` OR `.enterprise` OR the caller passes `grandfathered: true`
//    (the default). Grandfathered=true is EVERY feature that shipped in
//    v1.0 — Free users keep it forever. New Pro-only features pass
//    `grandfathered: false` at their call site.
// 3. No pricing values live here. `/pricing` is the single source of
//    truth for dollar amounts. The gate only knows tier labels.
// 4. No network I/O. Fully synchronous + Sendable. When real billing
//    lands, tier state is resolvable from a purely local source (signed
//    receipt cached in Keychain, verified offline).

import Foundation

/// Which plan the user is on. `.free` is the only value in v1.0.
///
/// Order is significant for `Comparable`: `.enterprise` > `.pro` >
/// `.free`. Do NOT re-order without also updating `hasProAccess`.
public enum Tier: String, Sendable, Equatable, CaseIterable, Comparable {
    case free
    case pro
    case enterprise

    /// Display label for the menu-bar drop-down + Privacy Dashboard footer.
    public var displayLabel: String {
        switch self {
        case .free: return "Free forever"
        case .pro: return "Pro"
        case .enterprise: return "Enterprise"
        }
    }

    private var rank: Int {
        switch self {
        case .free: return 0
        case .pro: return 1
        case .enterprise: return 2
        }
    }

    public static func < (lhs: Tier, rhs: Tier) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Global tier-state holder. In v1.0 this always reports `.free`. The
/// setter is `internal` on purpose — user code (feature call sites)
/// reads `current` only; the executable target's launch path can flip
/// it when real billing lands, but feature code cannot self-elevate.
public final class TierManager: @unchecked Sendable {
    public static let shared = TierManager()

    private let lock = NSLock()
    private var _current: Tier = .free

    public var current: Tier {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    internal func setCurrent(_ tier: Tier) {
        lock.lock(); defer { lock.unlock() }
        _current = tier
    }

    /// True if the user has Pro-tier entitlements (Pro or Enterprise).
    public var hasProAccess: Bool { current >= .pro }

    private init() {}
}

/// Gate helpers for feature call sites. Prefer these over hand-rolled
/// tier checks — this centralizes the "grandfathered v1.0" rule so we
/// can't accidentally paywall a shipped feature.
public enum TierGate {
    /// Run `body` iff Pro access OR the feature is grandfathered v1.0.
    ///
    /// - Parameter grandfathered: `true` (default) for any v1.0 feature
    ///   — Free users keep it forever (trust invariant #1). New Pro
    ///   features pass `false`.
    /// - Returns: closure's value, or `nil` if the gate is closed.
    @discardableResult
    public static func isPro<T>(
        grandfathered: Bool = true,
        _ body: () throws -> T
    ) rethrows -> T? {
        if grandfathered || TierManager.shared.hasProAccess {
            return try body()
        }
        return nil
    }

    /// Non-throwing convenience for the common `Void` case.
    public static func ifPro(
        grandfathered: Bool = true,
        _ body: () -> Void
    ) {
        if grandfathered || TierManager.shared.hasProAccess {
            body()
        }
    }

    /// Boolean check for callers that need it without running a closure
    /// (e.g. `Menu` disabled-state bindings).
    public static func isUnlocked(grandfathered: Bool = true) -> Bool {
        grandfathered || TierManager.shared.hasProAccess
    }
}
