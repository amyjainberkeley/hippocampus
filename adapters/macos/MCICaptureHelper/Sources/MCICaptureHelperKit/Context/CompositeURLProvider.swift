// SPDX-License-Identifier: TBD-private
//
// CompositeURLProvider — `URLProvider` composite that walks a list
// of single-browser providers and returns the first non-nil result.
// ADR-0015 §1.3 + §2 + §6 P2.4 ("`AppleScriptURLProvider` — composite.
// Holds an array of single-browser `URLProvider`s …; dispatches by
// frontmost bundle id; falls back to `nil` cleanly when no impl
// matches").
//
// PROTECTED-SET per AGENT_PROTOCOL §5. This file owns NO AppleScript
// of its own and reads NO context. It is purely a dispatch
// composition over already-protected single-browser providers. The
// ADR-0015 §4 privacy invariants flow through unchanged: each
// underlying provider remains responsible for context-as-content,
// no auto-grant, and the rest. The composite's only contribution is
// the per-call ordered walk.
//
// ## Behaviour summary
//
// - `activeTabURL(forFrontmost:)` walks the configured providers in
//   construction order. For each provider it calls
//   `activeTabURL(forFrontmost: bundleId)`; the FIRST non-nil result
//   is returned. If every provider returns nil → return nil.
//
// - Document order is meaningful only for completeness. By design
//   each underlying provider answers for a DISJOINT set of bundle
//   ids (Safari only / Chromium-family only / Firefox-family only /
//   Arc only — ADR-0015 §1.3). For any single `bundleId` argument,
//   AT MOST ONE underlying provider will return non-nil; the walk
//   order is therefore semantically immaterial on the disjoint
//   bundle set. The walk is kept simple (linear, no priority,
//   no ordering metadata) because there are at most four entries.
//
// - If a future provider were added that overlaps another's bundle
//   id (it shouldn't — the per-browser providers are written to be
//   exclusive), the first match in construction order would win.
//   This is documented for future maintainers; today no overlap
//   exists. See `CompositeURLProviderTests.testReorderingIsSemantically
//   Equivalent` for the property-pin.
//
// - The composite does NOT cache. Each underlying provider owns its
//   own ≤1 s TTL cache; layering a second cache here would only
//   complicate the ADR-0015 §3 staleness contract.

import Foundation

/// Composite `URLProvider` that dispatches by walking a list of
/// single-browser impls. ADR-0015 §6 P2.4.
public final class CompositeURLProvider: URLProvider, @unchecked Sendable {
    private let providers: [URLProvider]

    /// Compose the supplied providers. Construction order = walk
    /// order. By ADR-0015 §1.3 the providers should answer for
    /// disjoint bundle-id sets; on a disjoint set the walk order is
    /// semantically immaterial.
    public init(providers: [URLProvider]) {
        self.providers = providers
    }

    /// Production convenience: assemble the canonical four-provider
    /// composite (Safari + Chromium-family + Firefox-family + Arc).
    /// Equivalent to constructing each with its zero-arg
    /// `init()` and passing them in.
    public convenience init() {
        self.init(providers: [
            SafariURLProvider(),
            ChromiumURLProvider(),
            FirefoxURLProvider(),
            ArcURLProvider(),
        ])
    }

    public func activeTabURL(forFrontmost bundleId: String) -> String? {
        activeTabURL(forFrontmost: bundleId, focusedWindowId: nil)
    }

    /// V2-P2 focus-aware overload. Forwards `focusedWindowId` to each
    /// inner provider so the per-provider `(bundleId, focusedWindowId)`
    /// cache key invalidates correctly on a focus change to a
    /// different browser window.
    public func activeTabURL(
        forFrontmost bundleId: String,
        focusedWindowId: UInt32?
    ) -> String? {
        for p in providers {
            if let url = p.activeTabURL(
                forFrontmost: bundleId,
                focusedWindowId: focusedWindowId
            ) {
                return url
            }
        }
        return nil
    }
}
