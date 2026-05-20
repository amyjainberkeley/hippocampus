// SPDX-License-Identifier: TBD-private
//
// AXWindowTitleProviderTests — headless coverage of
// `AXWindowTitleProvider`'s decision matrix. ADR-0015 §6 P2.2 + §7.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These tests do NOT touch the
// Accessibility API; they exercise the provider's bundle-id dispatch
// + AX-outcome → return-value mapping via the internal
// `RunningAppPidSource` + `AXTitleReader` seams. Same shape PRs #36/
// #38 used for `StubSecureEventInputProbe` / `StubAXSecureSubroleProbe`
// and PR P2.3 used for `StubAppleScriptRunner`.
//
// Coverage (from the P2.2 acceptance brief):
//   (a) no permission (reader → .error)        → nil
//   (b) nil focused window (reader → .noTitle) → nil
//   (c) success (reader → .success)            → string
//   (d) timeout (reader → .timeout)            → nil
//   (e) bundleId mismatch (pidSource → nil)    → nil — AX never read
// Plus static-shape pins (timeout value, trait-conformance pin).

import Foundation
import XCTest

@testable import MCICaptureHelperKit

// MARK: – Test doubles

/// Programmable, invocation-counting `AXTitleReader`.
///
/// Outcomes are consumed from a queue per call so a single stub can
/// model "first call errors, second call succeeds" sequences if
/// needed. When the queue is exhausted the configured `fallback`
/// outcome repeats indefinitely. Mirrors the
/// `StubAppleScriptRunner` shape from `SafariURLProviderTests`.
private final class StubAXTitleReader: AXTitleReader, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [WindowTitleOutcome]
    private let fallback: WindowTitleOutcome
    private(set) var invocationCount: Int = 0
    private(set) var lastPid: pid_t?
    private(set) var lastTimeoutMs: Int?

    init(
        outcomes: [WindowTitleOutcome] = [],
        fallback: WindowTitleOutcome = .error
    ) {
        self.queue = outcomes
        self.fallback = fallback
    }

    convenience init(always outcome: WindowTitleOutcome) {
        self.init(outcomes: [], fallback: outcome)
    }

    func read(pid: pid_t, timeoutMs: Int) -> WindowTitleOutcome {
        lock.lock()
        invocationCount += 1
        lastPid = pid
        lastTimeoutMs = timeoutMs
        let next: WindowTitleOutcome
        if !queue.isEmpty {
            next = queue.removeFirst()
        } else {
            next = fallback
        }
        lock.unlock()
        return next
    }
}

/// Programmable `RunningAppPidSource`. A `nil` entry simulates
/// "no running app matches that bundle id" (the (e) leg).
private final class StubRunningAppPidSource: RunningAppPidSource,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var map: [String: pid_t]
    private(set) var lookupCount: Int = 0
    private(set) var lastBundleId: String?

    init(_ map: [String: pid_t] = [:]) {
        self.map = map
    }

    /// Set `bundleId → pid` (or pass `nil` to remove).
    func set(_ bundleId: String, pid: pid_t?) {
        lock.lock()
        if let pid { map[bundleId] = pid } else { map.removeValue(forKey: bundleId) }
        lock.unlock()
    }

    func pid(forBundleId bundleId: String) -> pid_t? {
        lock.lock()
        lookupCount += 1
        lastBundleId = bundleId
        let v = map[bundleId]
        lock.unlock()
        return v
    }
}

final class AXWindowTitleProviderTests: XCTestCase {
    // MARK: – (a) no permission

    /// Reader returns `.error` (the "AX permission not granted /
    /// apiDisabled / notImplemented" leg) → provider returns nil.
    /// Pins ADR-0015 §4 invariant: missing AX permission resolves to
    /// `nil` cleanly, not a thrown error or a noisy log.
    func testReturnsNilOnReaderError() {
        let pidSource = StubRunningAppPidSource(["com.apple.Safari": 1234])
        let reader = StubAXTitleReader(always: .error)
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        XCTAssertNil(p.title(forFrontmost: "com.apple.Safari"))
        XCTAssertEqual(reader.invocationCount, 1)
        XCTAssertEqual(
            reader.lastPid, 1234,
            "Reader must be called with the pid resolved from the bundle id"
        )
        XCTAssertEqual(
            reader.lastTimeoutMs, AXWindowTitleProvider.timeoutMs,
            "Provider must pass its configured timeout to the reader"
        )
    }

    // MARK: – (b) no focused window

    /// Reader returns `.noTitle` (the "app has no focused window /
    /// focused window has no title" leg) → provider returns nil.
    /// Pins the legitimate-empty-shape vs error-shape distinction at
    /// the reader/provider boundary even though both collapse to
    /// `nil` externally.
    func testReturnsNilOnReaderNoTitle() {
        let pidSource = StubRunningAppPidSource(["com.apple.Safari": 5678])
        let reader = StubAXTitleReader(always: .noTitle)
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        XCTAssertNil(p.title(forFrontmost: "com.apple.Safari"))
        XCTAssertEqual(reader.invocationCount, 1)
    }

    // MARK: – (c) success

    /// Reader returns `.success(title)` → provider returns that
    /// title. Pins the happy-path return mapping.
    func testReturnsTitleOnReaderSuccess() {
        let pidSource = StubRunningAppPidSource(["com.apple.Safari": 4321])
        let reader = StubAXTitleReader(
            always: .success("Apple — Official Site")
        )
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        XCTAssertEqual(
            p.title(forFrontmost: "com.apple.Safari"),
            "Apple — Official Site"
        )
        XCTAssertEqual(reader.invocationCount, 1)
        XCTAssertEqual(reader.lastPid, 4321)
    }

    /// Reader returns a `.success` carrying a single-character title.
    /// Pins that the provider does not impose its own min-length /
    /// trimming policy — the cascade decides what to do with short
    /// titles. (Empty-string success is filtered to `.noTitle`
    /// inside `RealAXTitleReader.readSync`; that path is exercised
    /// indirectly by the `.noTitle` test above.)
    func testReturnsSingleCharacterTitle() {
        let pidSource = StubRunningAppPidSource(["com.example.app": 9])
        let reader = StubAXTitleReader(always: .success("X"))
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        XCTAssertEqual(p.title(forFrontmost: "com.example.app"), "X")
    }

    // MARK: – (d) timeout

    /// Reader returns `.timeout` (AX call exceeded the 250 ms cap)
    /// → provider returns nil. Pins the bounded-execution clause:
    /// a stuck AX server cannot wedge the 1 Hz poll.
    func testReturnsNilOnReaderTimeout() {
        let pidSource = StubRunningAppPidSource(["com.apple.Safari": 100])
        let reader = StubAXTitleReader(always: .timeout)
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        XCTAssertNil(p.title(forFrontmost: "com.apple.Safari"))
        XCTAssertEqual(reader.invocationCount, 1)
    }

    // MARK: – (e) bundleId mismatch — no running app

    /// pidSource has no entry for the supplied bundle id → provider
    /// returns nil WITHOUT calling the reader. Pins the (e) leg of
    /// the brief: bundleId-mismatch falls through cleanly, no AX
    /// read attempted, no telemetry noise.
    func testReturnsNilWhenPidSourceHasNoRunningApp() {
        let pidSource = StubRunningAppPidSource([:])
        let reader = StubAXTitleReader(always: .success("should-not-be-read"))
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        XCTAssertNil(p.title(forFrontmost: "com.never.installed.app"))
        XCTAssertEqual(
            reader.invocationCount, 0,
            "Reader must NOT be invoked when bundleId has no running app"
        )
        XCTAssertEqual(
            pidSource.lookupCount, 1,
            "Provider must still consult the pid source exactly once"
        )
    }

    /// Empty-string bundle id → pidSource lookup returns nil → nil.
    /// Pins the defensive-input shape; an empty bundle id is not a
    /// crash, not an AX call, just `nil`.
    func testReturnsNilForEmptyBundleId() {
        let pidSource = StubRunningAppPidSource([:])
        let reader = StubAXTitleReader(always: .success("ignored"))
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        XCTAssertNil(p.title(forFrontmost: ""))
        XCTAssertEqual(reader.invocationCount, 0)
    }

    // MARK: – pid plumbing

    /// pidSource has an entry → provider passes that exact pid to
    /// the reader. Pins the data path: a stale / wrong pid here is
    /// what would surface "title of wrong app" in production.
    func testProviderPassesResolvedPidToReader() {
        let pidSource = StubRunningAppPidSource([
            "com.apple.Safari": 1111,
            "com.google.Chrome": 2222,
        ])
        let reader = StubAXTitleReader(always: .success("t"))
        let p = AXWindowTitleProvider(pidSource: pidSource, reader: reader)

        _ = p.title(forFrontmost: "com.google.Chrome")
        XCTAssertEqual(reader.lastPid, 2222)
        _ = p.title(forFrontmost: "com.apple.Safari")
        XCTAssertEqual(reader.lastPid, 1111)
    }

    // MARK: – static-shape pins

    /// Timeout cap matches the ADR-0015 P2.2 acceptance brief
    /// (matches the P2.3 `SafariURLProvider.timeoutMs` precedent).
    /// Changing this is a CSO-protected change — it loosens the
    /// upper bound on how long a single AX call can stall the
    /// 1 Hz poll.
    func testTimeoutIs250ms() {
        XCTAssertEqual(AXWindowTitleProvider.timeoutMs, 250)
    }

    /// Provider conforms to `WindowTitleProvider`. Pins the public
    /// trait surface so a refactor that accidentally drops
    /// conformance fails at the test layer (not at the eventual
    /// P2.5 wiring site).
    func testConformsToWindowTitleProvider() {
        let p: WindowTitleProvider = AXWindowTitleProvider(
            pidSource: StubRunningAppPidSource([:]),
            reader: StubAXTitleReader(always: .error)
        )
        XCTAssertNil(p.title(forFrontmost: "com.unknown"))
    }
}
