// SPDX-License-Identifier: TBD-private
//
// URLProvider — active-tab URL extraction trait for Phase 2 context
// join. ADR-0015 §2 ("`ContextProvider` trait — OS-free protocol,
// headless testability"). One impl per supported browser; the
// frontmost-bundle-id dispatch happens in the composite that wraps
// these impls (composite lands in P2.4).
//
// PROTECTED-SET per AGENT_PROTOCOL §5. URLs are user content. The
// values produced by impls of this trait flow into `WorkflowContext`
// and through the ADR-0013 suppression cascade BEFORE storage (ADR-
// 0015 §4 invariants 1 + 2: "context-as-content" + "cascade-before-
// storage"). No raw URL from this trait may be written to disk, IPC,
// or any sink ahead of a `.allow` cascade decision.

import Foundation

/// Active-tab URL for a specific frontmost browser.
///
/// One impl per supported browser (Safari, Chromium-family,
/// Firefox, Arc). The composite that consumes a set of these is
/// responsible for dispatching by frontmost bundle id. This trait
/// itself is intentionally narrow.
///
/// ## Trait-level invariants (binding on every impl)
///
/// - **MUST be non-blocking on the hot path.** The cascade snapshot
///   actor (ADR-0015 §3) polls at 1 Hz on a dedicated background
///   `Task`; the SCStream callback never invokes this trait
///   directly. Even so, impls must not block the calling thread on
///   the order of seconds — see the bounded-execution clause.
/// - **MUST return `nil` cleanly on every failure mode.** Permission
///   denial (TCC Automation pane), browser-not-running, no-front-
///   document, unsupported bundle id, AppleScript timeout, AppleScript
///   syntax/runtime error — every one of these resolves to `nil`.
///   Impls do not throw, do not log noisily, do not retry within the
///   same call. ADR-0015 §4 invariant 4 ("no auto-grant Apple Events"):
///   the OS dialog firing on first call IS the consent UX; denial
///   → `nil`-forever (cache the denial within a session).
/// - **MUST be `Sendable`.** Phase 2 polling runs on a detached
///   background `Task`; the snapshot actor receives the produced
///   value across an isolation boundary.
///
/// ## V2-P2 focus-aware overload
///
/// The focus-aware overload `activeTabURL(forFrontmost:focusedWindowId:)`
/// lets production providers re-key their TTL cache by `(bundleId,
/// focusedWindowId)` so an inter-window browser focus change (two Safari
/// windows with different active tabs) invalidates the cache. Combined
/// with the TTL drop from 1.0 s → 100 ms (PR V2-P2), the stale-URL
/// window after a tab switch shrinks to ≤100 ms (memo §3, file
/// `docs/research/tab-attribution-mix-2026-05-29.md`).
///
/// The simple `activeTabURL(forFrontmost:)` is preserved for back-
/// compat (test stubs, callers that have no focus snapshot). It
/// delegates internally to the focus-aware overload with
/// `focusedWindowId: nil` on production providers, which collapses to
/// "key cache by bundleId only" — the legacy behaviour with the new
/// 100 ms TTL.
public protocol URLProvider: Sendable {
    /// Active-tab URL for the supplied frontmost bundle id, or `nil`
    /// if this provider does not handle that bundle, the browser is
    /// not running, AppleScript fails, or Apple Events permission is
    /// denied / revoked.
    ///
    /// MUST be non-blocking on the hot path. MUST return `nil`
    /// cleanly (not throw, not block, not retry-storm) on permission
    /// denial / browser-not-running / unsupported-bundle.
    func activeTabURL(forFrontmost bundleId: String) -> String?

    /// V2-P2 focus-aware overload. `focusedWindowId` is the CGWindowID
    /// (cast to `UInt32` to avoid CoreGraphics coupling on non-Apple
    /// platforms) of the focused window from the FocusTracker
    /// snapshot (ADR-0031). When supplied, production providers
    /// re-key their TTL cache by `(bundleId, focusedWindowId)` so a
    /// focus change to a different browser window (which may carry a
    /// different active tab) invalidates the cached URL.
    ///
    /// Default implementation in the protocol extension forwards to
    /// the simple variant for back-compat. Production providers
    /// override.
    func activeTabURL(forFrontmost bundleId: String, focusedWindowId: UInt32?) -> String?
}

extension URLProvider {
    /// Default impl: ignore `focusedWindowId` and delegate to the
    /// simple variant. Lets tests and legacy callers conform with a
    /// single method; production providers override the focus-aware
    /// variant directly.
    public func activeTabURL(forFrontmost bundleId: String, focusedWindowId: UInt32?) -> String? {
        _ = focusedWindowId
        return activeTabURL(forFrontmost: bundleId)
    }
}
