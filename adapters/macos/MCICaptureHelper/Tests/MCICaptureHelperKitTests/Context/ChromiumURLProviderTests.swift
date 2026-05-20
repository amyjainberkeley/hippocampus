// SPDX-License-Identifier: TBD-private
//
// ChromiumURLProviderTests — headless coverage of
// `ChromiumURLProvider`'s decision matrix across the three supported
// browsers (Chrome / Brave / Edge). ADR-0015 §6 P2.4 + §7.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These tests do NOT touch
// `NSAppleScript`; they exercise the provider's bundle-id dispatch,
// outcome → return mapping, cache semantics, and per-bundle script
// source selection via the internal `AppleScriptRunner` seam.
//
// Coverage (from the P2.4 acceptance brief):
//   (a) bundle mismatch                                   → nil
//   (b) Chrome bundle + success                           → URL
//   (c) Brave bundle + success                            → URL
//   (d) Edge bundle + success                             → URL
//   (e) script error                                      → nil
//   (f) timeout                                           → nil
//   (g) cached within TTL
//   (h) per-browser script source matches expected literal
//   plus: re-invoke after TTL; per-bundle cache key independence;
//   denial cached; static-shape pins (supportedBundleIds, TTL,
//   timeout).

import Foundation
import XCTest

@testable import MCICaptureHelperKit

// MARK: – Test doubles

/// Programmable, invocation-counting `AppleScriptRunner` (shape
/// shared with `SafariURLProviderTests` — kept as a local copy so the
/// two test files do not coupling-leak into each other).
private final class StubAppleScriptRunner: AppleScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [AppleScriptOutcome]
    private let fallback: AppleScriptOutcome
    private(set) var invocationCount: Int = 0
    private(set) var lastSource: String?
    private(set) var lastTimeoutMs: Int?
    private(set) var sources: [String] = []

    init(
        outcomes: [AppleScriptOutcome] = [],
        fallback: AppleScriptOutcome = .scriptError
    ) {
        self.queue = outcomes
        self.fallback = fallback
    }

    convenience init(always outcome: AppleScriptOutcome) {
        self.init(outcomes: [], fallback: outcome)
    }

    func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
        lock.lock()
        invocationCount += 1
        lastSource = source
        lastTimeoutMs = timeoutMs
        sources.append(source)
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
    func reader() -> @Sendable () -> Date {
        let ref = self
        return { ref.now }
    }
}

final class ChromiumURLProviderTests: XCTestCase {
    // MARK: – (a) bundle-id mismatch

    /// Non-Chromium-family bundle id → nil. AppleScript is never
    /// invoked. Covers Safari, Firefox, Arc, and arbitrary strings.
    /// Pins the "this provider only handles the configured browsers"
    /// leg of the trait contract (composite at P2.4 dispatches by
    /// bundle id).
    func testReturnsNilForNonChromiumBundleIds() {
        let runner = StubAppleScriptRunner(
            always: .success("https://example.com/")
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.apple.Safari"))
        XCTAssertNil(p.activeTabURL(forFrontmost: "org.mozilla.firefox"))
        XCTAssertNil(p.activeTabURL(forFrontmost: "company.thebrowser.Browser"))
        XCTAssertNil(p.activeTabURL(forFrontmost: ""))
        XCTAssertNil(p.activeTabURL(forFrontmost: "com.unrelated.app"))
        XCTAssertEqual(
            runner.invocationCount, 0,
            "AppleScript must not run for non-Chromium bundle ids"
        )
    }

    // MARK: – (b) Chrome happy path

    /// Chrome bundle + runner success → URL returned; runner saw the
    /// Chrome-shaped AppleScript and the configured timeout.
    func testReturnsURLForChromeBundle() {
        let runner = StubAppleScriptRunner(
            always: .success("https://www.google.com/")
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: "com.google.Chrome"),
            "https://www.google.com/"
        )
        XCTAssertEqual(runner.invocationCount, 1)
        XCTAssertEqual(
            runner.lastSource,
            "tell application \"Google Chrome\" to URL of active tab of front window"
        )
        XCTAssertEqual(runner.lastTimeoutMs, ChromiumURLProvider.timeoutMs)
    }

    // MARK: – (c) Brave happy path

    func testReturnsURLForBraveBundle() {
        let runner = StubAppleScriptRunner(
            always: .success("https://brave.com/")
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: "com.brave.Browser"),
            "https://brave.com/"
        )
        XCTAssertEqual(
            runner.lastSource,
            "tell application \"Brave Browser\" to URL of active tab of front window"
        )
    }

    // MARK: – (d) Edge happy path

    func testReturnsURLForEdgeBundle() {
        let runner = StubAppleScriptRunner(
            always: .success("https://microsoft.com/")
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: "com.microsoft.edgemac"),
            "https://microsoft.com/"
        )
        XCTAssertEqual(
            runner.lastSource,
            "tell application \"Microsoft Edge\" to URL of active tab of front window"
        )
    }

    // MARK: – (e) script-error leg

    func testReturnsNilOnRunnerScriptError() {
        let runner = StubAppleScriptRunner(always: .scriptError)
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.google.Chrome"))
        XCTAssertEqual(runner.invocationCount, 1)
    }

    /// Empty-string success collapses to nil (degenerate clean run —
    /// browser was queried but produced no URL, e.g. an empty tab).
    func testEmptyStringSuccessCollapsesToNil() {
        let runner = StubAppleScriptRunner(always: .success(""))
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.google.Chrome"))
    }

    // MARK: – (f) timeout leg

    func testReturnsNilOnRunnerTimeout() {
        let runner = StubAppleScriptRunner(always: .timeout)
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.brave.Browser"))
        XCTAssertEqual(runner.invocationCount, 1)
    }

    // MARK: – (g) cache-freshness leg

    /// Two reads of the same bundle id within `cacheTTL` → one
    /// runner invocation; both reads see the same value.
    func testCachedWithinTTLForSameBundle() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://first.example.com/"),
                .success("https://second.example.com/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        let a = p.activeTabURL(forFrontmost: "com.google.Chrome")
        clock.advance(ChromiumURLProvider.cacheTTL - 0.1)
        let b = p.activeTabURL(forFrontmost: "com.google.Chrome")

        XCTAssertEqual(a, "https://first.example.com/")
        XCTAssertEqual(b, "https://first.example.com/")
        XCTAssertEqual(runner.invocationCount, 1)
    }

    /// Cache survives a `nil`-resolved outcome too — a denied first
    /// call does not retry-storm during the cache window. Pins the
    /// "no retry within the cache window" half of the ADR-0015 §4
    /// no-auto-grant invariant.
    func testNilOutcomeAlsoCachedWithinTTL() {
        let runner = StubAppleScriptRunner(
            outcomes: [.scriptError, .success("https://later/")],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.microsoft.edgemac"))
        clock.advance(ChromiumURLProvider.cacheTTL - 0.1)
        XCTAssertNil(p.activeTabURL(forFrontmost: "com.microsoft.edgemac"))
        XCTAssertEqual(runner.invocationCount, 1)
    }

    /// Re-invoke after the TTL elapses; the new outcome is returned.
    func testReInvokedAfterTTL() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://first/"),
                .success("https://second/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        let a = p.activeTabURL(forFrontmost: "com.google.Chrome")
        clock.advance(ChromiumURLProvider.cacheTTL + 0.1)
        let b = p.activeTabURL(forFrontmost: "com.google.Chrome")

        XCTAssertEqual(a, "https://first/")
        XCTAssertEqual(b, "https://second/")
        XCTAssertEqual(runner.invocationCount, 2)
    }

    /// Per-bundle cache key independence. Asking for Chrome then
    /// Brave within the TTL invokes the runner twice (once per
    /// bundle), even though both fall within the same TTL window.
    /// Pins the "user app-switched from Chrome to Brave inside the
    /// TTL must get Brave's URL, not Chrome's" leg.
    func testCacheKeyedPerBundleId() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://chrome.example/"),
                .success("https://brave.example/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = ChromiumURLProvider(runner: runner, clock: clock.reader())

        let chrome = p.activeTabURL(forFrontmost: "com.google.Chrome")
        clock.advance(ChromiumURLProvider.cacheTTL - 0.5)
        let brave = p.activeTabURL(forFrontmost: "com.brave.Browser")

        XCTAssertEqual(chrome, "https://chrome.example/")
        XCTAssertEqual(brave, "https://brave.example/")
        XCTAssertEqual(
            runner.invocationCount, 2,
            "Per-bundle cache keys: Chrome read must not satisfy a"
            + " subsequent Brave read"
        )
        XCTAssertEqual(
            runner.sources,
            [
                "tell application \"Google Chrome\" to URL of active tab of front window",
                "tell application \"Brave Browser\" to URL of active tab of front window",
            ]
        )
    }

    // MARK: – (h) script-source pins (each browser)

    /// Per-browser AppleScript sources match the ADR-0015 §1.3
    /// dialect exactly. Pins the wire-level invariant: changing any
    /// script source is a CSO-protected change (it changes what the
    /// user is asked to consent to via the Automation pane).
    func testAppleScriptSourcesMatchADR0015() {
        XCTAssertEqual(
            ChromiumURLProvider.scripts["com.google.Chrome"],
            "tell application \"Google Chrome\" to URL of active tab of front window"
        )
        XCTAssertEqual(
            ChromiumURLProvider.scripts["com.brave.Browser"],
            "tell application \"Brave Browser\" to URL of active tab of front window"
        )
        XCTAssertEqual(
            ChromiumURLProvider.scripts["com.microsoft.edgemac"],
            "tell application \"Microsoft Edge\" to URL of active tab of front window"
        )
    }

    // MARK: – static-shape pins

    /// Supported bundle ids list. Pins the dispatch surface for the
    /// composite at P2.4.
    func testSupportedBundleIds() {
        XCTAssertEqual(
            ChromiumURLProvider.supportedBundleIds,
            ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]
        )
    }

    /// Cache TTL matches the ADR-0015 §3 snapshot-poll period.
    func testCacheTTLIsOneSecond() {
        XCTAssertEqual(ChromiumURLProvider.cacheTTL, 1.0)
    }

    /// Timeout bound matches the ADR-0015 P2.4 acceptance brief.
    func testTimeoutIs250ms() {
        XCTAssertEqual(ChromiumURLProvider.timeoutMs, 250)
    }
}
