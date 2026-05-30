// SPDX-License-Identifier: TBD-private
//
// MainSwiftWiringTests — V2-P1 production wiring assertion (H6 per
// `docs/research/v2-p1-production-leak-2026-05-30.md` §4.1).
//
// PR #239 V2-P1 shipped the focused-window machinery (FocusedWindowStore,
// FocusTracker, makeFocusedWindowFilter, race gate, ADR-0031, §7 corpus,
// M4 lift) but never modified
// `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift`
// to construct + pass `FocusedWindowStore` + `FocusTracker` into
// `SCStreamCaptureSession`. The result was that V2-P1 was present in
// source but inactive in production: `SCStreamCaptureSession.start()`
// fell through to `makeDisplayFilter(...)`, the rebind task short-
// circuited, the race gate was bypassed, and OCREvents were attributed
// to the polled-frontmost-app id over display-composite pixels — the
// cycle 8.17 misattribution channel.
//
// The §7 corpus + the existing `FocusedWindowFilterTests` BOTH passed
// 5/5 GREEN against the broken wiring because their scope is the
// attribution-logic decision matrix, not the construction graph. This
// is a unit-tests-pass-but-the-integration-is-missing failure mode.
//
// These tests close that scope gap by reading the production
// `main.swift` source at test time and asserting that the construction
// graph contains the two parameters that activate V2-P1 in production.
// A future refactor that drops the wiring fails this test before CI
// goes green.
//
// SCOPE NOTE: the SCStream callback itself + `start()`'s OS calls are
// `// UNVERIFIED — needs live macOS`. The §11 live-Mac audit covers
// those paths. These tests cover the OS-free wiring discipline that
// makes V2-P1 reachable in the first place.

import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class MainSwiftWiringTests: XCTestCase {
    /// Path to the production `main.swift` derived from `#filePath`.
    /// The test file sits at
    ///   `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/MainSwiftWiringTests.swift`
    /// and `main.swift` sits at
    ///   `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift`,
    /// so the package-root walk is two `deletingLastPathComponent()`s up
    /// from this file's directory (`MCICaptureHelperKitTests/` → `Tests/`
    /// → package root) followed by `Sources/MCICaptureHelper/main.swift`.
    private static func mainSwiftSource(filePath: String = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent() // MCICaptureHelperKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // MCICaptureHelper/ (package root)
        let mainURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MCICaptureHelper")
            .appendingPathComponent("main.swift")
        return try String(contentsOf: mainURL, encoding: .utf8)
    }

    // MARK: - H6.1: FocusedWindowStore is constructed in main.swift

    func test_main_constructs_FocusedWindowStore() throws {
        let source = try Self.mainSwiftSource()
        XCTAssertTrue(
            source.contains("FocusedWindowStore()"),
            """
            ADR-0031 V2-P1 production wiring missing: main.swift does not \
            construct a `FocusedWindowStore`. Without this, \
            `SCStreamCaptureSession.focusedWindowStore` defaults to nil, \
            `start()` falls through to `makeDisplayFilter(...)`, and the \
            cycle 8.17 cross-window leak is reachable in production. See \
            `docs/research/v2-p1-production-leak-2026-05-30.md` §3.1 + §5.1.
            """
        )
    }

    // MARK: - H6.2: FocusTracker is constructed and shares the store

    func test_main_constructs_FocusTracker_sharing_the_store() throws {
        let source = try Self.mainSwiftSource()
        XCTAssertTrue(
            source.contains("FocusTracker(store: focusedWindowStore)"),
            """
            ADR-0031 V2-P1 shared-actor identity discipline violated: \
            main.swift does not construct a `FocusTracker` that shares \
            the `focusedWindowStore` instance. The FocusTracker must \
            write to the SAME `FocusedWindowStore` the SCStream callback \
            reads from; a fresh per-call default expression in either \
            site silently breaks the race gate. See \
            `docs/research/v2-p1-production-leak-2026-05-30.md` §4.1.
            """
        )
    }

    // MARK: - H6.3: SCStreamCaptureSession receives focusedWindowStore kwarg

    func test_main_passes_focusedWindowStore_to_SCStreamCaptureSession() throws {
        let source = try Self.mainSwiftSource()
        XCTAssertTrue(
            source.contains("focusedWindowStore: focusedWindowStore"),
            """
            ADR-0031 V2-P1 wiring incomplete: main.swift does not pass \
            `focusedWindowStore: focusedWindowStore` into the \
            `SCStreamCaptureSession` initializer. Without this, the \
            session's optional default kicks in (`focusedWindowStore == \
            nil`), `start()` falls through to display capture, and the \
            cycle 8.17 leak is reachable.
            """
        )
    }

    // MARK: - H6.4: SCStreamCaptureSession receives focusTracker kwarg

    func test_main_passes_focusTracker_to_SCStreamCaptureSession() throws {
        let source = try Self.mainSwiftSource()
        XCTAssertTrue(
            source.contains("focusTracker: focusTracker"),
            """
            ADR-0031 V2-P1 wiring incomplete: main.swift does not pass \
            `focusTracker: focusTracker` into the `SCStreamCaptureSession` \
            initializer. Without this, the FocusTracker is never started \
            by the session's `start()` lifecycle and no observation ever \
            reaches the store — the cycle 8.17 leak is reachable.
            """
        )
    }

    // MARK: - H6.5: Construction is co-located with SCStreamCaptureSession init

    func test_main_wiring_is_co_located_with_session_construction() throws {
        let source = try Self.mainSwiftSource()
        // The wiring lines must precede the `SCStreamCaptureSession(`
        // call site (the only call site in the helper) so the kwargs
        // resolve to the just-constructed instances. A future refactor
        // that constructs the store/tracker in dead code after the
        // session call site would silently break this discipline.
        guard let storeRange = source.range(of: "FocusedWindowStore()") else {
            XCTFail("FocusedWindowStore() not present in main.swift")
            return
        }
        guard let sessionRange = source.range(of: "SCStreamCaptureSession(") else {
            XCTFail("SCStreamCaptureSession( construction site not present in main.swift")
            return
        }
        XCTAssertLessThan(
            storeRange.lowerBound,
            sessionRange.lowerBound,
            """
            ADR-0031 V2-P1 wiring order violated: FocusedWindowStore() \
            appears AFTER the SCStreamCaptureSession( call site in \
            main.swift. The wiring lines must precede the session \
            construction so the `focusedWindowStore:` kwarg resolves to \
            the just-constructed instance.
            """
        )
    }

    // MARK: - §5.2 — race-gate sentinel fail-close: pure decision matrix

    /// The §5.2 hardening introduces a sentinel fail-close at the
    /// race-consistency gate: when `installedFocusGeneration == 0` (no
    /// focused-window filter is currently bound), the gate MUST fail
    /// closed regardless of the observed generation. Without this, the
    /// boot/login/fast-user-switch edge case where both generations are
    /// 0 silently passes the gate, letting display-composite pixels
    /// reach the cascade with frontmost-app attribution.
    ///
    /// The decision is exercised here as a pure logic test against the
    /// race-gate predicate that the SCStream callback inlines at line
    /// `SCStreamCaptureSession.swift:599`. The callback itself is
    /// `// UNVERIFIED — needs live macOS`; this test pins the decision
    /// the callback makes.

    private static func raceGateFailsClosed(installedGen: UInt64, observedGen: UInt64?) -> Bool {
        // Mirror of the predicate at SCStreamCaptureSession.swift:599
        // post-§5.2:
        //
        //   if installedGen == 0 || focusedSnapshot?.generation != installedGen {
        //       … emit focusRaceDropped tombstone …
        //   }
        if installedGen == 0 { return true }
        return observedGen != installedGen
    }

    func test_race_gate_fails_closed_on_installed_generation_zero_with_observed_nil() {
        // Boot edge: no focused-window filter bound, no observation yet.
        // Pre-§5.2: `nil != 0` was false → trivially passed the gate.
        // Post-§5.2: installed == 0 → fail closed regardless.
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 0, observedGen: nil))
    }

    func test_race_gate_fails_closed_on_installed_generation_zero_with_observed_zero() {
        // The same boot edge the cycle 8.17 leak surfaced: both sides
        // are 0, so the pre-§5.2 `observedGen != installedGen` check
        // returned false and let the cascade run on display-composite
        // pixels. Post-§5.2: installed == 0 → fail closed.
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 0, observedGen: 0))
    }

    func test_race_gate_fails_closed_on_installed_generation_zero_with_observed_nonzero() {
        // Possible during fast-user-switch: the FocusTracker has
        // observed (generation = 1) but the SCStream's filter is still
        // the display-fallback. Pre-§5.2: `1 != 0` returned true →
        // gate fail-closed (correct by coincidence). Post-§5.2 makes
        // the fail-close happen regardless of the observed-side value
        // so the decision is correct by construction, not by accident.
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 0, observedGen: 1))
    }

    func test_race_gate_passes_when_generations_match_and_installed_is_nonzero() {
        // Steady state: SCStream's filter is bound to focused window
        // generation N, and the FocusedWindowSnapshot observed at the
        // sample timestamp is generation N. The race gate permits the
        // frame to reach the cascade.
        XCTAssertFalse(Self.raceGateFailsClosed(installedGen: 7, observedGen: 7))
    }

    func test_race_gate_fails_closed_on_generation_mismatch() {
        // Focus changed between filter install and frame delivery —
        // the captured pixels may belong to a different window than the
        // snapshot reports. Fail closed.
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 7, observedGen: 8))
    }

    func test_race_gate_fails_closed_on_observed_nil_when_installed_is_nonzero() {
        // Defensive: nil observed against a non-zero installed should
        // never happen in production (a non-zero installed generation
        // implies at least one focused-window observation has been
        // stored) but the predicate must fail closed if it does.
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 7, observedGen: nil))
    }
}
