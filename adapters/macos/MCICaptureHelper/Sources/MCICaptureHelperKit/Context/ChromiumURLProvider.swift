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
// - Cache the last result (success-string or `nil`) for ≤1 s. The
//   ADR-0015 §3 snapshot actor polls at 1 Hz; the cache caps
//   AppleScript invocations to ~1/s per provider in the worst case.
// - Per-bundle dispatch: the cache key is the bundle id. Two calls
//   in quick succession for *different* bundle ids (e.g. user app-
//   switched from Chrome to Brave within the TTL) each invoke the
//   runner once; one cached value per bundle id.

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

    /// Cache TTL. ADR-0015 §3 sets the snapshot poll at 1 Hz; this
    /// TTL caps AppleScript invocations to ~1/s worst case (per
    /// bundle id).
    internal static let cacheTTL: TimeInterval = 1.0

    /// Bounded AppleScript execution. NSAppleScript blocks the
    /// dispatching thread; a stuck call should not stall the
    /// snapshot poll forever.
    internal static let timeoutMs: Int = 250

    private let runner: AppleScriptRunner
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    /// Per-bundle-id cache. Key is the bundle id; value is the
    /// (timestamp, resolved URL?) pair from the most recent runner
    /// call for that bundle. A bundle-id miss in this table means
    /// "no prior call cached" and forces a fresh runner invocation.
    private var cache: [String: (at: Date, value: String?)] = [:]

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
        guard let source = Self.scripts[bundleId] else { return nil }

        let now = clock()

        lock.lock()
        if let entry = cache[bundleId],
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
        cache[bundleId] = (at: now, value: resolved)
        lock.unlock()
        return resolved
    }
}
