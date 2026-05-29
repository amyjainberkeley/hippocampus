// SPDX-License-Identifier: TBD-private
//
// SafariURLProviderTests — headless coverage of `SafariURLProvider`'s
// decision matrix. ADR-0015 §6 P2.3 + §7.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These tests do NOT touch
// `NSAppleScript`; they exercise the provider's bundle-id dispatch,
// outcome → return mapping, and cache semantics via the internal
// `AppleScriptRunner` seam.
//
// Coverage (from the P2.3 acceptance brief):
//   (a) bundleId mismatch                       → nil
//   (b) runner returns success(url)             → url returned
//   (c) runner returns scriptError              → nil
//   (d) runner returns timeout                  → nil
//   (e) two calls within 1s — one underlying invocation
//   (f) two calls >1s apart — re-invoke

import Foundation
import XCTest

@testable import MCICaptureHelperKit

// MARK: – Test doubles

/// Programmable, invocation-counting `AppleScriptRunner`.
///
/// Outcomes are consumed from a queue per call so a single stub can
/// model "first call succeeds, second call times out" sequences if
/// needed. When the queue is exhausted the configured `default`
/// outcome repeats indefinitely.
private final class StubAppleScriptRunner: AppleScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [AppleScriptOutcome]
    private let fallback: AppleScriptOutcome
    private(set) var invocationCount: Int = 0
    private(set) var lastSource: String?
    private(set) var lastTimeoutMs: Int?

    init(
        outcomes: [AppleScriptOutcome] = [],
        fallback: AppleScriptOutcome = .scriptError
    ) {
        self.queue = outcomes
        self.fallback = fallback
    }

    /// Convenience: single-outcome stub that repeats.
    convenience init(always outcome: AppleScriptOutcome) {
        self.init(outcomes: [], fallback: outcome)
    }

    func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
        lock.lock()
        invocationCount += 1
        lastSource = source
        lastTimeoutMs = timeoutMs
        let next: AppleScriptOutcome
        if !queue.isEmpty {
            next = queue.removeFirst()
        } else {
            next = fallback
        }
        lock.unlock()
        return next
    }
}

/// Manually-advanceable clock. Tests poke `now` directly to simulate
/// time passing without sleeping in test runtime.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self._now = start
    }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
    }
    /// Captures the current value for use as the SafariURLProvider
    /// `clock` closure. Captures `self` weakly via a value snapshot
    /// at read time so the closure stays `@Sendable`.
    func reader() -> @Sendable () -> Date {
        let ref = self
        return { ref.now }
    }
}

final class SafariURLProviderTests: XCTestCase {
    // MARK: – (a) bundle-id mismatch

    /// Non-Safari bundle id → nil. AppleScript is never invoked.
    /// Pins the "this provider only handles Safari" leg of the trait
    /// contract (composite at P2.4 dispatches by bundle id).
    func testReturnsNilForNonSafariBundleId() {
        let runner = StubAppleScriptRunner(
            always: .success("https://example.com/")
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.google.Chrome"))
        XCTAssertNil(p.activeTabURL(forFrontmost: "org.mozilla.firefox"))
        XCTAssertNil(p.activeTabURL(forFrontmost: ""))
        XCTAssertEqual(
            runner.invocationCount, 0,
            "AppleScript must not run for non-Safari bundle ids"
        )
    }

    // MARK: – (b) success leg

    /// Runner returns `.success(url)` → provider returns that URL.
    /// Pins the happy-path return mapping.
    func testReturnsURLOnRunnerSuccess() {
        let runner = StubAppleScriptRunner(
            always: .success("https://www.apple.com/")
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: SafariURLProvider.bundleId),
            "https://www.apple.com/"
        )
        XCTAssertEqual(runner.invocationCount, 1)
        XCTAssertEqual(runner.lastSource, SafariURLProvider.script)
        XCTAssertEqual(
            runner.lastTimeoutMs,
            SafariURLProvider.timeoutMs,
            "Provider must pass its configured timeout to the runner"
        )
    }

    /// Empty-string success is treated as `nil` (degenerate clean
    /// run — Safari was queried but produced no URL).
    func testEmptyStringSuccessCollapsesToNil() {
        let runner = StubAppleScriptRunner(always: .success(""))
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: SafariURLProvider.bundleId))
    }

    // MARK: – (c) error leg

    /// Runner returns `.scriptError` → provider returns nil.
    /// Pins the "AppleScript denial / no front document / runtime
    /// error all collapse to nil" leg.
    func testReturnsNilOnRunnerScriptError() {
        let runner = StubAppleScriptRunner(always: .scriptError)
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(
            p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)
        )
        XCTAssertEqual(runner.invocationCount, 1)
    }

    // MARK: – (d) timeout leg

    /// Runner returns `.timeout` → provider returns nil. Pins ADR-
    /// 0015 §1.3 "AppleScript bounded; on timeout return nil."
    func testReturnsNilOnRunnerTimeout() {
        let runner = StubAppleScriptRunner(always: .timeout)
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(
            p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)
        )
        XCTAssertEqual(runner.invocationCount, 1)
    }

    // MARK: – (e) cache-freshness leg

    /// Two calls within `cacheTTL` (= 1s) → one underlying runner
    /// invocation; both calls see the same value. Pins the 1Hz
    /// cascade-floor / snapshot-poll budget cap from ADR-0015 §3.
    func testCachedWithinTTL() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://first.example.com/"),
                .success("https://second.example.com/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        let a = p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)
        // advance below TTL — cache must serve.
        clock.advance(SafariURLProvider.cacheTTL - 0.1)
        let b = p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)

        XCTAssertEqual(a, "https://first.example.com/")
        XCTAssertEqual(b, "https://first.example.com/")
        XCTAssertEqual(
            runner.invocationCount, 1,
            "Two reads within TTL must invoke the runner exactly once"
        )
    }

    /// Cache survives a `nil`-resolved outcome too — a denied first
    /// call does not retry-storm during the cache window. Pins the
    /// "no retry within the same call AND no retry within the cache
    /// window" half of the ADR-0015 §4 no-auto-grant invariant.
    func testNilOutcomeAlsoCachedWithinTTL() {
        let runner = StubAppleScriptRunner(
            outcomes: [.scriptError, .success("https://later.example/")],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(
            p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)
        )
        clock.advance(SafariURLProvider.cacheTTL - 0.1)
        XCTAssertNil(
            p.activeTabURL(forFrontmost: SafariURLProvider.bundleId),
            "Cached nil must persist across the TTL window"
        )
        XCTAssertEqual(runner.invocationCount, 1)
    }

    // MARK: – (f) re-invoke after TTL

    /// Two calls more than `cacheTTL` apart → the runner is re-
    /// invoked, the new outcome is returned. Pins the cache
    /// freshness ceiling.
    func testReInvokedAfterTTL() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://first.example.com/"),
                .success("https://second.example.com/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        let a = p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)
        clock.advance(SafariURLProvider.cacheTTL + 0.1)
        let b = p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)

        XCTAssertEqual(a, "https://first.example.com/")
        XCTAssertEqual(b, "https://second.example.com/")
        XCTAssertEqual(
            runner.invocationCount, 2,
            "Reads spanning the TTL must invoke the runner once per"
            + " window"
        )
    }

    // MARK: – static-shape pins

    /// AppleScript source is the ADR-0015 §1.3 one-liner exactly.
    /// Pins the wire-level invariant: changing the script source is
    /// a CSO-protected change (it changes what the user is asked to
    /// consent to via the Automation pane).
    func testAppleScriptSourceMatchesADR0015() {
        XCTAssertEqual(
            SafariURLProvider.script,
            "tell application \"Safari\" to URL of front document"
        )
    }

    /// Bundle id is the canonical Safari id. Pins the dispatch key
    /// for the P2.4 composite.
    func testBundleIdIsSafari() {
        XCTAssertEqual(SafariURLProvider.bundleId, "com.apple.Safari")
    }

    /// V2-P2: cache TTL dropped 1.0 s → 100 ms to shrink the
    /// stale-URL window after intra-browser tab switches (memo
    /// `docs/research/tab-attribution-mix-2026-05-29.md` §3).
    func testCacheTTLIs100Milliseconds() {
        XCTAssertEqual(SafariURLProvider.cacheTTL, 0.100)
    }

    // MARK: – (V2-P2) focus-key invalidation

    /// Two calls within the 100 ms TTL but with DIFFERENT
    /// `focusedWindowId` values invoke the runner twice — a focus
    /// change to a different Safari window (different CGWindowID,
    /// possibly a different active tab) invalidates the cache even
    /// inside the TTL.
    func testFocusedWindowChangeInvalidatesCacheWithinTTL() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://window-a.example.com/"),
                .success("https://window-b.example.com/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        // First call binds (bundle, windowA).
        let a = p.activeTabURL(
            forFrontmost: SafariURLProvider.bundleId,
            focusedWindowId: 100
        )
        // Same bundle, DIFFERENT window id — still inside TTL but
        // the key changed, so the runner must be invoked again.
        clock.advance(SafariURLProvider.cacheTTL / 2)
        let b = p.activeTabURL(
            forFrontmost: SafariURLProvider.bundleId,
            focusedWindowId: 200
        )

        XCTAssertEqual(a, "https://window-a.example.com/")
        XCTAssertEqual(b, "https://window-b.example.com/")
        XCTAssertEqual(
            runner.invocationCount, 2,
            "Focus change to a different windowId must invalidate"
            + " the cache within the TTL"
        )
    }

    /// Two calls within the TTL with the SAME `focusedWindowId`
    /// hit the cache (single runner invocation). Pins the cache key
    /// is `(bundleId, focusedWindowId)` not just `bundleId`.
    func testCachedWithinTTLForSameFocusedWindow() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://first.example.com/"),
                .success("https://second.example.com/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        let a = p.activeTabURL(
            forFrontmost: SafariURLProvider.bundleId,
            focusedWindowId: 42
        )
        clock.advance(SafariURLProvider.cacheTTL - 0.010)
        let b = p.activeTabURL(
            forFrontmost: SafariURLProvider.bundleId,
            focusedWindowId: 42
        )

        XCTAssertEqual(a, "https://first.example.com/")
        XCTAssertEqual(b, "https://first.example.com/")
        XCTAssertEqual(runner.invocationCount, 1)
    }

    /// Calling the simple `activeTabURL(forFrontmost:)` overload
    /// keys the cache under `(bundleId, nil)`. A subsequent call
    /// with the focus-aware overload using `focusedWindowId: nil`
    /// MUST hit the same cache slot.
    func testSimpleAndFocusAwareOverloadsShareTheNilWindowSlot() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://shared.example.com/"),
                .success("https://different.example.com/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = SafariURLProvider(runner: runner, clock: clock.reader())

        // Simple overload → (bundle, nil) slot.
        let a = p.activeTabURL(forFrontmost: SafariURLProvider.bundleId)
        clock.advance(SafariURLProvider.cacheTTL / 2)
        // Focus-aware overload with nil → SAME slot.
        let b = p.activeTabURL(
            forFrontmost: SafariURLProvider.bundleId,
            focusedWindowId: nil
        )

        XCTAssertEqual(a, "https://shared.example.com/")
        XCTAssertEqual(b, "https://shared.example.com/")
        XCTAssertEqual(
            runner.invocationCount, 1,
            "Simple overload and focus-aware overload with nil window"
            + " id must share the same cache slot"
        )
    }

    /// Timeout bound matches the ADR-0015 P2.3 acceptance brief.
    func testTimeoutIs250ms() {
        XCTAssertEqual(SafariURLProvider.timeoutMs, 250)
    }
}
