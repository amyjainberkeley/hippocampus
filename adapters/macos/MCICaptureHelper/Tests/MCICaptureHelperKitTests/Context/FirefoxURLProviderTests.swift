// SPDX-License-Identifier: TBD-private
//
// FirefoxURLProviderTests — headless coverage of `FirefoxURLProvider`.
// ADR-0015 §6 P2.4 + §7.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These tests do NOT touch
// `NSAppleScript`; they exercise the provider's bundle-id dispatch
// (release / Developer Edition / Nightly), outcome → return mapping,
// cache semantics, and the URL-of-front-window script source via the
// internal `AppleScriptRunner` seam.

import Foundation
import XCTest

@testable import MCICaptureHelperKit

// MARK: – Test doubles

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

final class FirefoxURLProviderTests: XCTestCase {
    // MARK: – bundle-id mismatch

    /// Non-Firefox bundle ids → nil. AppleScript never runs.
    func testReturnsNilForNonFirefoxBundleIds() {
        let runner = StubAppleScriptRunner(
            always: .success("https://example.com/")
        )
        let clock = FakeClock()
        let p = FirefoxURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.apple.Safari"))
        XCTAssertNil(p.activeTabURL(forFrontmost: "com.google.Chrome"))
        XCTAssertNil(p.activeTabURL(forFrontmost: "company.thebrowser.Browser"))
        XCTAssertNil(p.activeTabURL(forFrontmost: ""))
        XCTAssertEqual(
            runner.invocationCount, 0,
            "AppleScript must not run for non-Firefox bundle ids"
        )
    }

    // MARK: – happy paths across the three accepted bundles

    /// Release-channel bundle id + success → URL.
    func testReturnsURLForReleaseFirefoxBundle() {
        let runner = StubAppleScriptRunner(
            always: .success("https://mozilla.org/")
        )
        let clock = FakeClock()
        let p = FirefoxURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: "org.mozilla.firefox"),
            "https://mozilla.org/"
        )
        XCTAssertEqual(runner.invocationCount, 1)
        XCTAssertEqual(runner.lastSource, FirefoxURLProvider.script)
        XCTAssertEqual(runner.lastTimeoutMs, FirefoxURLProvider.timeoutMs)
    }

    /// Developer Edition + success → URL (same script, same Apple
    /// Events surface — both register as "Firefox" with the system).
    func testReturnsURLForDeveloperEditionBundle() {
        let runner = StubAppleScriptRunner(
            always: .success("https://nightly.example/")
        )
        let clock = FakeClock()
        let p = FirefoxURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: "org.mozilla.firefoxdeveloperedition"),
            "https://nightly.example/"
        )
    }

    /// Nightly + success → URL.
    func testReturnsURLForNightlyBundle() {
        let runner = StubAppleScriptRunner(
            always: .success("https://nightly.mozilla/")
        )
        let clock = FakeClock()
        let p = FirefoxURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: "org.mozilla.nightly"),
            "https://nightly.mozilla/"
        )
    }

    // MARK: – error + timeout legs

    func testReturnsNilOnRunnerScriptError() {
        let runner = StubAppleScriptRunner(always: .scriptError)
        let clock = FakeClock()
        let p = FirefoxURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "org.mozilla.firefox"))
        XCTAssertEqual(runner.invocationCount, 1)
    }

    func testReturnsNilOnRunnerTimeout() {
        let runner = StubAppleScriptRunner(always: .timeout)
        let clock = FakeClock()
        let p = FirefoxURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "org.mozilla.firefox"))
        XCTAssertEqual(runner.invocationCount, 1)
    }

    // MARK: – cache semantics

    /// Two reads within `cacheTTL` → one runner invocation.
    func testCachedWithinTTL() {
        let runner = StubAppleScriptRunner(
            outcomes: [
                .success("https://first/"),
                .success("https://second/"),
            ],
            fallback: .scriptError
        )
        let clock = FakeClock()
        let p = FirefoxURLProvider(runner: runner, clock: clock.reader())

        let a = p.activeTabURL(forFrontmost: "org.mozilla.firefox")
        clock.advance(FirefoxURLProvider.cacheTTL - 0.1)
        let b = p.activeTabURL(forFrontmost: "org.mozilla.firefox")

        XCTAssertEqual(a, "https://first/")
        XCTAssertEqual(b, "https://first/")
        XCTAssertEqual(runner.invocationCount, 1)
    }

    // MARK: – static-shape pins

    /// AppleScript source is the ADR-0015 §1.3 URL-of-front-window
    /// one-liner exactly. Pins what the user is consenting to.
    func testAppleScriptSourceMatchesADR0015() {
        XCTAssertEqual(
            FirefoxURLProvider.script,
            "tell application \"Firefox\" to get URL of front window"
        )
    }

    /// Supported bundle ids: release + Developer Edition + Nightly.
    func testSupportedBundleIds() {
        XCTAssertEqual(
            FirefoxURLProvider.supportedBundleIds,
            [
                "org.mozilla.firefox",
                "org.mozilla.firefoxdeveloperedition",
                "org.mozilla.nightly",
            ]
        )
    }
}
