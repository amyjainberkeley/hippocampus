// SPDX-License-Identifier: TBD-private
//
// ArcURLProvider — `URLProvider` impl for Arc (bundle id
// `company.thebrowser.Browser`).
//
// Arc is Chromium-based and exposes the Chromium-shaped AppleScript
// dictionary; the one-liner shape mirrors `ChromiumURLProvider`:
//
//     tell application "Arc" to URL of active tab of front window
//
// Arc gets its own provider rather than sharing `ChromiumURLProvider`
// because (a) the Apple Events consent dialog is per-application
// bundle (granting Chrome does not grant Arc), (b) Arc's process
// name / Apple Events name is "Arc" not "Google Chrome", and
// (c) ADR-0015 §1.3 calls Arc out as its own provider so a future
// dialect divergence can be absorbed in this file without touching
// the Chromium provider.
//
// ADR-0015 §1.3 + §6 P2.4. Bundle id: `company.thebrowser.Browser`.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. The ADR-0015 §4 privacy
// invariants govern every behaviour in this file:
//
//   1. context-as-content — produced URL strings are user content;
//      this file reads them only into the return value of
//      `activeTabURL(forFrontmost:)`. Callers route them through the
//      ADR-0013 cascade before any storage / IPC sink (cascade
//      wiring is ADR-0015 §6 P2.5, not this PR).
//   2. cascade-before-storage — vacuous this PR (no cascade wiring;
//      provider ships in isolation per ADR-0015 §6).
//   3. no auto-grant Apple Events — NO `tccutil` call, NO programmatic
//      permission API. The OS Automation-pane dialog firing on the
//      first `NSAppleScript` execution per (helper → Arc) pair IS the
//      consent UX. Denial → `nil`; no retry-storm.
//   4. real `appBundleId` in tombstone — vacuous this PR (cascade
//      wiring at P2.5).
//
// ## Script-injection safety (CRS security-signal scan, 2026-05-20)
//
// The AppleScript source is a `static let` string literal. The
// provider NEVER interpolates the returned URL (or any runtime
// value) back into an `NSAppleScript(source:)` call. The only
// runtime input influencing dispatch is the frontmost bundle id,
// which is matched against the static `bundleId` constant by
// equality; mismatches resolve to `nil` without any AppleScript
// invocation.
//
// ## Behaviour summary
//
// Identical structure to `SafariURLProvider` / `FirefoxURLProvider`:
//
// - `bundleId != "company.thebrowser.Browser"` → `nil`.
// - Otherwise: run the Arc AppleScript via the supplied
//   `AppleScriptRunner` (production wiring: `RealAppleScriptRunner`
//   from `SafariURLProvider.swift`). On success non-empty → URL.
//   On any error / empty / timeout → `nil`.
// - Cache last result for ≤1 s.

import Foundation

/// Active-tab URL provider for Arc. ADR-0015 §6 P2.4.
public final class ArcURLProvider: URLProvider, @unchecked Sendable {
    /// `company.thebrowser.Browser` — the only bundle id this
    /// provider answers for. The Browser Company has shipped Arc
    /// under this bundle id since first public release.
    public static let bundleId: String = "company.thebrowser.Browser"

    /// AppleScript source. Chromium-shape one-liner; ADR-0015 §1.3.
    internal static let script: String =
        "tell application \"Arc\" to URL of active tab of front window"

    /// Cache TTL. ADR-0015 §3 sets the snapshot poll at 1 Hz; this
    /// TTL caps AppleScript invocations to ~1/s worst case.
    internal static let cacheTTL: TimeInterval = 1.0

    /// Bounded AppleScript execution. NSAppleScript blocks the
    /// dispatching thread; a stuck call should not stall the
    /// snapshot poll forever.
    internal static let timeoutMs: Int = 250

    private let runner: AppleScriptRunner
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedAt: Date?
    private var cachedValue: String?

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
        guard bundleId == Self.bundleId else { return nil }

        let now = clock()

        lock.lock()
        if let at = cachedAt,
           now.timeIntervalSince(at) <= Self.cacheTTL {
            let cached = cachedValue
            lock.unlock()
            return cached
        }
        lock.unlock()

        let outcome = runner.run(Self.script, timeoutMs: Self.timeoutMs)
        let resolved: String?
        switch outcome {
        case .success(let url):
            resolved = url.isEmpty ? nil : url
        case .scriptError, .timeout:
            resolved = nil
        }

        lock.lock()
        cachedAt = now
        cachedValue = resolved
        lock.unlock()
        return resolved
    }
}
