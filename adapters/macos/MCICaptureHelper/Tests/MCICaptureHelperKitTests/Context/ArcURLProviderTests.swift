// SPDX-License-Identifier: TBD-private
//
// ArcURLProviderTests — headless coverage of `ArcURLProvider`.
// ADR-0015 §6 P2.4 + §7.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These tests do NOT touch
// `NSAppleScript`; they exercise the provider's bundle-id dispatch,
// outcome → return mapping, cache semantics, and the Arc-shaped
// AppleScript source via the internal `AppleScriptRunner` seam.

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

final class ArcURLProviderTests: XCTestCase {
    // MARK: – bundle-id mismatch

    /// Non-Arc bundle ids → nil. AppleScript never runs.
    func testReturnsNilForNonArcBundleIds() {
        let runner = StubAppleScriptRunner(
            always: .success("https://example.com/")
        )
        let clock = FakeClock()
        let p = ArcURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: "com.apple.Safari"))
        XCTAssertNil(p.activeTabURL(forFrontmost: "com.google.Chrome"))
        XCTAssertNil(p.activeTabURL(forFrontmost: "org.mozilla.firefox"))
        XCTAssertNil(p.activeTabURL(forFrontmost: ""))
        XCTAssertEqual(
            runner.invocationCount, 0,
            "AppleScript must not run for non-Arc bundle ids"
        )
    }

    // MARK: – happy path

    /// Arc bundle + success → URL; runner saw the Arc-shaped script
    /// and the configured timeout.
    func testReturnsURLForArcBundle() {
        let runner = StubAppleScriptRunner(
            always: .success("https://arc.net/")
        )
        let clock = FakeClock()
        let p = ArcURLProvider(runner: runner, clock: clock.reader())

        XCTAssertEqual(
            p.activeTabURL(forFrontmost: ArcURLProvider.bundleId),
            "https://arc.net/"
        )
        XCTAssertEqual(runner.invocationCount, 1)
        XCTAssertEqual(runner.lastSource, ArcURLProvider.script)
        XCTAssertEqual(runner.lastTimeoutMs, ArcURLProvider.timeoutMs)
    }

    /// Empty-string success → nil (e.g. Arc running but no active
    /// tab / new-window state).
    func testEmptyStringSuccessCollapsesToNil() {
        let runner = StubAppleScriptRunner(always: .success(""))
        let clock = FakeClock()
        let p = ArcURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: ArcURLProvider.bundleId))
    }

    // MARK: – error + timeout legs

    func testReturnsNilOnRunnerScriptError() {
        let runner = StubAppleScriptRunner(always: .scriptError)
        let clock = FakeClock()
        let p = ArcURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: ArcURLProvider.bundleId))
        XCTAssertEqual(runner.invocationCount, 1)
    }

    func testReturnsNilOnRunnerTimeout() {
        let runner = StubAppleScriptRunner(always: .timeout)
        let clock = FakeClock()
        let p = ArcURLProvider(runner: runner, clock: clock.reader())

        XCTAssertNil(p.activeTabURL(forFrontmost: ArcURLProvider.bundleId))
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
        let p = ArcURLProvider(runner: runner, clock: clock.reader())

        let a = p.activeTabURL(forFrontmost: ArcURLProvider.bundleId)
        clock.advance(ArcURLProvider.cacheTTL - 0.1)
        let b = p.activeTabURL(forFrontmost: ArcURLProvider.bundleId)

        XCTAssertEqual(a, "https://first/")
        XCTAssertEqual(b, "https://first/")
        XCTAssertEqual(runner.invocationCount, 1)
    }

    // MARK: – static-shape pins

    /// Bundle id is the canonical Arc id.
    func testBundleIdIsArc() {
        XCTAssertEqual(ArcURLProvider.bundleId, "company.thebrowser.Browser")
    }

    /// AppleScript source is the ADR-0015 §1.3 Chromium-shape one-
    /// liner addressed to "Arc". Pins what the user is consenting to.
    func testAppleScriptSourceMatchesADR0015() {
        XCTAssertEqual(
            ArcURLProvider.script,
            "tell application \"Arc\" to URL of active tab of front window"
        )
    }
}
