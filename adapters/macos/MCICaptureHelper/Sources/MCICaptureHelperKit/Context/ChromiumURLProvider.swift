// SPDX-License-Identifier: TBD-private
//
// ChromiumURLProvider — `URLProvider` impl for the Chromium family of
// browsers that share the same AppleScript dialect:
//
//   - Google Chrome      (com.google.Chrome)
//   - Brave Browser      (com.brave.Browser)
//   - Microsoft Edge     (com.microsoft.edgemac)
//
// ADR-0015 §1.3 + §6 P2.4. The bundle-id → app-name mapping is held
// internally; the AppleScript source is parameterized by app name but
// computed ONCE per bundle id from string-literal constants — never
// from any runtime URL string (see PROTECTED-SET note below).
//
// PROTECTED-SET per AGENT_PROTOCOL §5. The ADR-0015 §4 privacy
// invariants govern every behaviour in this file:
//
//   1. context-as-content — produced URL strings are user content;
//      this file reads them only into the return value of
//      `activeTabURL(forFrontmost:)`. Callers route them through the
//      ADR-0013 cascade before any storage / IPC sink (cascade wiring
//      is ADR-0015 §6 P2.5, not this PR).
//   2. cascade-before-storage — vacuous this PR (no cascade wiring;
//      provider ships in isolation per ADR-0015 §6).
//   3. no auto-grant Apple Events — NO `tccutil` call, NO programmatic
//      permission API. The OS Automation-pane dialog firing on the
//      first `NSAppleScript` execution per (helper → browser) pair IS
//      the consent UX. Each browser bundle id is its own consent
//      dialog. Denial → `nil`; no retry-storm (single invocation per
//      cache window). Safari granted + Chrome denied → Safari works,
//      Chrome returns `nil` cleanly (per-browser graceful failure).
//   4. real `appBundleId` in tombstone — vacuous this PR (cascade
//      wiring at P2.5).
//
// ## Script-injection safety (CRS security-signal scan, 2026-05-20)
//
// The AppleScript source for each supported browser is held as a
// string-literal table value (`scripts` static-let). The provider
// NEVER interpolates the returned URL (or any other runtime value)
// back into an `NSAppleScript(source:)` call. The only runtime input
// influencing script selection is the frontmost bundle id, which is
// matched against the static `scripts` table by equality; mismatches
// resolve to `nil` without any AppleScript invocation. This makes
// the AppleScript surface area equivalent to a hand-written one-
// liner per browser, with no concat / format-string / interpolation
// of URL data anywhere in the path.
//
// ## Behaviour summary
//
// - `bundleId` not in the supported set → `nil` (this provider does
//   not handle that browser; the composite at P2.4 dispatches by
//   bundle id).
// - Otherwise: look up the AppleScript source for that bundle id and
//   run it via the supplied `AppleScriptRunner` (production wiring:
//   `RealAppleScriptRunner` from `SafariURLProvider.swift`). On
//   success with a non-empty string → return the URL. On any error
//   (permission denial, browser not running, no front window /
//   active tab, AppleScript syntax / runtime error) → `nil`. On
//   execution exceeding 250 ms → `nil` (the AppleScript may still
//   complete on its dispatch queue; its result is discarded). Never
//   retry within the same call.
// - Cache the last result (success-string or `nil`) for ≤100 ms.
//   V2-P2 dropped the TTL from 1.0 s → 100 ms per memo
//   `docs/research/tab-attribution-mix-2026-05-29.md` §3 — the prior
//   1.0 s window caused the OCREvent stamped with a prior tab's URL
//   for up to 1 s after an intra-browser tab switch.
// - Cache is keyed by `(bundleId, focusedWindowId)`. The focus-aware
//   overload `activeTabURL(forFrontmost:focusedWindowId:)` reads the
//   FocusTracker snapshot's `CGWindowID` (ADR-0031 / V2-P1) so a
//   focus change to a different browser window (which may carry a
//   different active tab) invalidates the cache even within the
//   100 ms TTL. Intra-window tab switches don't change `windowId`;
//   the 100 ms TTL bounds the staleness in that case.
// - Per-(bundle,window) dispatch: the cache key is the
//   `(bundleId, focusedWindowId)` pair. Two calls in quick succession
//   for *different* bundle ids (user app-switched from Chrome to
//   Brave within the TTL) OR *different* focused window ids each
//   invoke the runner once.

import Foundation

/// Active-tab URL provider for the Chromium browser family. ADR-0015
/// §6 P2.4.
public final class ChromiumURLProvider: URLProvider, @unchecked Sendable {
    /// Supported (bundle id → AppleScript source) table. Values are
    /// string literals; bundle ids are matched by equality. See the
    /// "Script-injection safety" file note above.
    ///
    /// AppleScript dialect (shared across Chrome / Brave / Edge):
    ///     tell application "<app>" to URL of active tab of front window
    internal static let scripts: [String: String] = [
        "com.google.Chrome":
            "tell application \"Google Chrome\" to URL of active tab of front window",
        "com.brave.Browser":
            "tell application \"Brave Browser\" to URL of active tab of front window",
        "com.microsoft.edgemac":
            "tell application \"Microsoft Edge\" to URL of active tab of front window",
    ]

    /// Supported bundle ids. Convenience view over `scripts.keys` for
    /// the composite at P2.4 + tests; the table is the source of
    /// truth.
    public static var supportedBundleIds: Set<String> {
        Set(scripts.keys)
    }

    /// Cache TTL. V2-P2 dropped from 1.0 s → 100 ms to shrink the
    /// stale-URL window after an intra-browser tab switch (memo
    /// `docs/research/tab-attribution-mix-2026-05-29.md` §3 +
    /// `brain-architecture-v2-vision-2026-05-29.md` §7.1 V2-P2).
    internal static let cacheTTL: TimeInterval = 0.100

    /// Bounded AppleScript execution. NSAppleScript blocks the
    /// dispatching thread; a stuck call should not stall the
    /// snapshot poll forever.
    internal static let timeoutMs: Int = 250

    private let runner: AppleScriptRunner
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    /// Per-`(bundleId, focusedWindowId)` cache. The composite key
    /// invalidates the cached value when EITHER the bundle id OR the
    /// focused window id changes — handles app-switch (different
    /// bundle) AND inter-window focus changes (same bundle, different
    /// CGWindowID, possibly different active tab). `focusedWindowId
    /// = nil` is its own key; legacy callers via the simple overload
    /// land here.
    private var cache: [CacheKey: (at: Date, value: String?)] = [:]

    /// Composite key (`bundleId, focusedWindowId`). `Hashable`
    /// derives from the field-by-field hash.
    private struct CacheKey: Hashable {
        let bundleId: String
        let windowId: UInt32?
    }

    /// Production initializer. Wires the real `NSAppleScript`-backed
    /// runner + the system clock.
    public convenience init() {
        self.init(runner: RealAppleScriptRunner(), clock: { Date() })
    }

    /// Test initializer. Internal so tests in the same module can
    /// inject a stub runner + synthetic clock; production callers
    /// use the convenience init above.
    internal init(
        runner: AppleScriptRunner,
        clock: @escaping @Sendable () -> Date
    ) {
        self.runner = runner
        self.clock = clock
    }

    public func activeTabURL(forFrontmost bundleId: String) -> String? {
        activeTabURL(forFrontmost: bundleId, focusedWindowId: nil)
    }

    public func activeTabURL(
        forFrontmost bundleId: String,
        focusedWindowId: UInt32?
    ) -> String? {
        guard let source = Self.scripts[bundleId] else { return nil }

        let now = clock()
        let key = CacheKey(bundleId: bundleId, windowId: focusedWindowId)

        lock.lock()
        if let entry = cache[key],
           now.timeIntervalSince(entry.at) <= Self.cacheTTL {
            let cached = entry.value
            lock.unlock()
            return cached
        }
        lock.unlock()

        let outcome = runner.run(source, timeoutMs: Self.timeoutMs)
        let resolved: String?
        switch outcome {
        case .success(let url):
            resolved = url.isEmpty ? nil : url
        case .scriptError, .timeout:
            resolved = nil
        }

        lock.lock()
        cache[key] = (at: now, value: resolved)
        lock.unlock()
        return resolved
    }
}
