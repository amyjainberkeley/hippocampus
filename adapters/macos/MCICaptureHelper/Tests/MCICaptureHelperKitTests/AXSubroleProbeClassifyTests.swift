// SPDX-License-Identifier: TBD-private
//
// AXSubroleProbeClassifyTests — synthetic-input coverage of the pure
// `AXSubroleProbe.classify(...)` mapping factored out for
// STEP-2-FINDING-001 (`docs/audit/2026-05-19-step2-sec-7-corpus.md`).
//
// Scope honesty: this file does NOT touch ApplicationServices /
// AXUIElementCreateSystemWide / AXUIElementCopyAttributeValue — those
// are exercised live on a real Mac via `mci-capture-helper --capture
// --probe-debug`. These tests pin the pure (AXError, subrole string,
// subrole AXError) → cascade-input mapping so a future refactor cannot
// silently widen `nil`/`false`/`true` semantics. Follows the existing
// stub patterns in `SCStreamCaptureSessionLifetimeTests.swift`
// (OS-API-free, headless, fast).
//
// Required matrix (from the STEP-2-FINDING-001 acceptance brief):
//   - .success + kAXSecureTextFieldSubrole      → true
//   - .success + other subrole string           → false
//   - .success + .noValue subrole result        → false
//   - focus .noValue                            → false
//   - .apiDisabled                              → nil
//
// Plus the cascade-fail-safe paths the original switch arms guard
// (hostile non-AXUIElement CFType, subrole .attributeUnsupported,
// generic AX failure, .notImplemented) so the pin doubles as the
// regression net for the §4 fail-safe contract.

import ApplicationServices
import XCTest

@testable import MCICaptureHelperKit

final class AXSubroleProbeClassifyTests: XCTestCase {
    // ───────── happy-path matrix ─────────

    /// `.success + kAXSecureTextFieldSubrole → true`. Cascade §4 fires.
    func testSuccessWithSecureSubroleClassifiesAsTrue() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .success,
            subroleValue: kAXSecureTextFieldSubrole as String
        )
        XCTAssertEqual(r, true)
    }

    /// `.success + non-secure subrole string → false`. Cascade §4 does
    /// NOT fire; later layers / §7 still decide.
    func testSuccessWithNonSecureSubroleClassifiesAsFalse() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .success,
            subroleValue: "AXStandardWindow"
        )
        XCTAssertEqual(r, false)
    }

    /// `.success + .noValue on the subrole read → false`. Many AX
    /// elements legitimately have no subrole attribute (buttons,
    /// generic groups); that is a positive "not secure" answer.
    func testSuccessWithNoValueSubroleClassifiesAsFalse() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .noValue,
            subroleValue: nil
        )
        XCTAssertEqual(r, false)
    }

    /// `focus .noValue → false`. No focused element on the system —
    /// nothing to classify; the rest of the cascade (denylist,
    /// secure-event-input) still has a chance to fire.
    func testFocusNoValueClassifiesAsFalse() {
        let r = AXSubroleProbe.classify(
            focusResult: .noValue,
            focusedRefMatched: false,
            subroleResult: .success,  // moot — not consulted
            subroleValue: nil
        )
        XCTAssertEqual(r, false)
    }

    /// `.apiDisabled → nil`. Accessibility permission was not granted
    /// (or revoked mid-run). MUST be `nil` — the cascade redacts via §7
    /// fail-safe. Anything other than `nil` here would silently allow
    /// capture on an AX-revoked host — a privacy regression.
    func testApiDisabledClassifiesAsNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .apiDisabled,
            focusedRefMatched: false,
            subroleResult: .success,  // moot
            subroleValue: nil
        )
        XCTAssertNil(r)
    }

    // ───────── fail-safe matrix (defence in depth) ─────────

    /// `.notImplemented → nil`. Same shape as `.apiDisabled` — the
    /// cascade redacts. Pinned explicitly so a future refactor doesn't
    /// accidentally collapse it to `false`.
    func testNotImplementedClassifiesAsNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .notImplemented,
            focusedRefMatched: false,
            subroleResult: .success,
            subroleValue: nil
        )
        XCTAssertNil(r)
    }

    /// `.cannotComplete → nil`. Generic AX failure on the focus read —
    /// cannot classify, fail-safe.
    func testCannotCompleteOnFocusReadClassifiesAsNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .cannotComplete,
            focusedRefMatched: false,
            subroleResult: .success,
            subroleValue: nil
        )
        XCTAssertNil(r)
    }

    /// `.success` focus + hostile non-AXUIElement CFType (the
    /// defensive check in the production path) → `nil`. The cascade
    /// redacts rather than misclassify.
    func testSuccessButFocusedRefDoesNotMatchClassifiesAsNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: false,  // CFGetTypeID mismatch
            subroleResult: .success,
            subroleValue: kAXSecureTextFieldSubrole as String
        )
        XCTAssertNil(r)
    }

    /// `.success` focus + `.attributeUnsupported` on the subrole read
    /// → `false`. Documented as a positive "not secure" answer in
    /// `AXSubroleProbe`.
    func testSuccessWithAttributeUnsupportedSubroleClassifiesAsFalse() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .attributeUnsupported,
            subroleValue: nil
        )
        XCTAssertEqual(r, false)
    }

    /// `.success` focus + arbitrary AX failure on the subrole read
    /// → `nil`. Anything other than `.success/.noValue/
    /// .attributeUnsupported` on the subrole read is unclassifiable.
    func testSuccessWithFailureOnSubroleReadClassifiesAsNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .cannotComplete,
            subroleValue: nil
        )
        XCTAssertNil(r)
    }

    /// Subrole-read `.success` but the AX-returned value is not a
    /// String (e.g. a number, a hostile shim) → `nil`. Matches the
    /// production `as? String` guard in the probe.
    func testSuccessWithNonStringSubroleValueClassifiesAsNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .success,
            subroleValue: nil  // production: `subroleRef as? String` failed
        )
        XCTAssertNil(r)
    }
}

// MARK: - `--probe-debug` sink wiring

/// Wiring contract for the dev-only `--probe-debug` sink: when wired,
/// the probe still returns the same classification AND the sink
/// observes one structured snapshot per call. Without the sink the
/// classification is unchanged (the sink is purely additive).
///
/// Verifying the *observation contents* requires real AX state and is
/// the human Step-2 re-run's job; here we pin (a) the closure is
/// invoked exactly once per call, (b) the classification it observes
/// equals the value the probe returns, and (c) the steady-state path
/// (`nil` sink) is byte-equivalent on return value.
final class AXSubroleProbeDebugSinkTests: XCTestCase {
    /// Thread-safe observation log. The production `DebugSink` is
    /// invoked synchronously on the calling thread inside
    /// `focusedHasSecureSubrole()` (no `Task`, no detached work), but
    /// the closure is `@Sendable` so the recorder must be Sendable
    /// too. A class with an `NSLock`-guarded array is the simplest
    /// shape that satisfies Swift 6 strict concurrency without
    /// pretending the writes are async.
    private final class ObservationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _observations: [AXProbeObservation] = []
        func record(_ o: AXProbeObservation) {
            lock.lock(); defer { lock.unlock() }
            _observations.append(o)
        }
        func snapshot() -> [AXProbeObservation] {
            lock.lock(); defer { lock.unlock() }
            return _observations
        }
    }

    /// (a) + (b): one call → one observation → observation's
    /// classification matches the returned `Bool?`.
    func testDebugSinkFiresOncePerCallAndAgreesOnClassification() {
        let log = ObservationLog()
        let probe = AXSubroleProbe(debugLog: { o in log.record(o) })

        let returned = probe.focusedHasSecureSubrole()
        let snapshot = log.snapshot()

        XCTAssertEqual(snapshot.count, 1, "sink must observe exactly one call")
        XCTAssertEqual(
            snapshot.first?.classification, returned,
            "sink-observed classification must equal the probe's return value"
        )
    }

    /// Calling the probe N times invokes the sink exactly N times in
    /// the same order. Pins the "no batching, no dedupe" contract —
    /// `--probe-debug` is supposed to be one stderr line per probe call.
    func testDebugSinkFiresOncePerCallAcrossManyCalls() {
        let log = ObservationLog()
        let probe = AXSubroleProbe(debugLog: { o in log.record(o) })
        let n = 8
        var returns: [Bool?] = []
        for _ in 0..<n { returns.append(probe.focusedHasSecureSubrole()) }
        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.count, n, "sink must observe exactly one call per probe invocation")
        XCTAssertEqual(snapshot.map { $0.classification }, returns)
    }

    /// (c): no sink ⇒ probe returns the same `Bool?` it would with a
    /// sink wired. The sink is purely diagnostic; it never changes the
    /// cascade input.
    func testNoSinkPathReturnsSameClassificationAsSinkPath() {
        let bare = AXSubroleProbe()
        let withSink = AXSubroleProbe(debugLog: { _ in })
        // In xctest both paths return `nil` (AX disabled), but we
        // assert equality rather than the value so the test stays
        // honest if a future run grants the bundle AX.
        XCTAssertEqual(
            bare.focusedHasSecureSubrole(),
            withSink.focusedHasSecureSubrole(),
            "wiring a debug sink must NOT change the cascade-facing classification"
        )
    }
}
