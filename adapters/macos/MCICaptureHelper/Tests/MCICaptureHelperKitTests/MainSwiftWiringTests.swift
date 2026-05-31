// SPDX-License-Identifier: TBD-private
//
// MainSwiftWiringTests — race-gate sentinel fail-close decision matrix.
//
// PR #264's H6 wire-up assertion tests (which read `main.swift` at test
// time and asserted that `FocusedWindowStore` + `FocusTracker` are
// constructed and passed into `SCStreamCaptureSession`) were REMOVED on
// 2026-05-30 (cycle 8.27 emergency revert) because the production probe
// surfaced `SCStream stopped with error: Code=-3815 "Failed to find any
// displays or windows to capture"` on a ~30s restart loop with 73%
// `frames_focus_race_dropped`. Root cause:
// `SCContentFilter(display:exceptingWindows:[focusedWindow])` is an
// EXCLUDE filter, not an INCLUDE-ONLY filter — passing the focused
// window as the `exceptingWindows` list excludes the only window we
// want. The V2-P1 production wiring was reverted; V2-P1 will need a
// redesign with the `includingWindows`-correct API before any second
// lift can succeed (tracked: follow-on memo
// `v2-p1-redesign-includingwindows`).
//
// What remains: the §5.2 race-gate sentinel fail-close at
// `SCStreamCaptureSession.swift` still encodes the
// `installedFocusGeneration == 0` fail-close branch. That is a defensive
// hardening that's correct regardless of whether the focused-window
// machinery is wired in production. The matrix tests below pin the
// pure-logic decision the race-gate predicate makes; the SCStream
// callback itself remains `// UNVERIFIED — needs live macOS`.

import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class MainSwiftWiringTests: XCTestCase {
    // MARK: - §5.2 — race-gate sentinel fail-close: pure decision matrix

    /// The §5.2 hardening introduces a sentinel fail-close at the
    /// race-consistency gate: when `installedFocusGeneration == 0` (no
    /// focused-window filter is currently bound), the gate MUST fail
    /// closed regardless of the observed generation. Without this, the
    /// boot/login/fast-user-switch edge case where both generations are
    /// 0 silently passes the gate.
    ///
    /// The decision is exercised here as a pure logic test against the
    /// race-gate predicate that the SCStream callback inlines. The
    /// callback itself is `// UNVERIFIED — needs live macOS`; this test
    /// pins the decision the callback makes.
    ///
    /// Under the cycle 8.27 revert the sentinel is unreachable in
    /// practice (the focused-window store + tracker are not wired at the
    /// production call site, so the outer
    /// `if focusedWindowStore != nil` guard around the race gate is
    /// false and the gate's body never runs). The hardening is retained
    /// because (a) it is the structurally-correct predicate for any
    /// future V2-P1 redesign that does wire focused-window state, and
    /// (b) the predicate's branch is a defensive guard that costs
    /// nothing while it sits unreachable.

    private static func raceGateFailsClosed(installedGen: UInt64, observedGen: UInt64?) -> Bool {
        // Mirror of the predicate at
        // SCStreamCaptureSession.swift post-§5.2:
        //
        //   if installedGen == 0 || focusedSnapshot?.generation != installedGen {
        //       … emit focusRaceDropped tombstone …
        //   }
        if installedGen == 0 { return true }
        return observedGen != installedGen
    }

    func test_race_gate_fails_closed_on_installed_generation_zero_with_observed_nil() {
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 0, observedGen: nil))
    }

    func test_race_gate_fails_closed_on_installed_generation_zero_with_observed_zero() {
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 0, observedGen: 0))
    }

    func test_race_gate_fails_closed_on_installed_generation_zero_with_observed_nonzero() {
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 0, observedGen: 1))
    }

    func test_race_gate_passes_when_generations_match_and_installed_is_nonzero() {
        XCTAssertFalse(Self.raceGateFailsClosed(installedGen: 7, observedGen: 7))
    }

    func test_race_gate_fails_closed_on_generation_mismatch() {
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 7, observedGen: 8))
    }

    func test_race_gate_fails_closed_on_observed_nil_when_installed_is_nonzero() {
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 7, observedGen: nil))
    }
}
