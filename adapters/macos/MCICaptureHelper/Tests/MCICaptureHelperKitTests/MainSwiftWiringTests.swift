// SPDX-License-Identifier: TBD-private
//
// MainSwiftWiringTests — race-gate sentinel fail-close decision matrix
// + V2-P1 third-lift construction-graph wiring proof.
//
// ## History
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
// want. The V2-P1 production wiring was reverted.
//
// The 2026-06-01 redesign memo (`docs/research/v2-p1-redesign-
// architecture-2026-06-01.md`) rebound the design to the correct
// `SCContentFilter(display:including:exceptingWindows:)` shape with a
// non-empty include list (FORK 3 = B). Cycle 8.35 PR #20 landed the
// scaffold factory (`SCContentFilterFactory.makeMultiWindowFilter`);
// THIS PR (Phase 7 PR 13) wires that factory into the live capture
// path via `SCStreamCaptureSession`. Per [[project-v2p1-unit-tests-
// passed-but-never-wired]] discipline + redesign memo §2.3, the
// construction-graph wiring at `main.swift` is MANDATORY and pinned
// here by a grep-in-place assertion — a future refactor that drops the
// wiring or reintroduces the cycle 8.27 antipattern fails CI before
// merge.
//
// ## What remains (race-gate matrix)
//
// The §5.2 race-gate sentinel fail-close at `SCStreamCaptureSession.swift`
// still encodes the `installedFocusGeneration == 0` fail-close branch.
// That is a defensive hardening that's correct regardless of whether
// the focused-window machinery is wired in production. The matrix
// tests below pin the pure-logic decision the race-gate predicate
// makes; the SCStream callback itself remains `// UNVERIFIED — needs
// live macOS`.

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

    // MARK: - V2-P1 third-lift construction-graph wiring proof

    /// Locate `main.swift` relative to this test file. `#filePath` is
    /// the on-disk path of THIS test file at compile time; the test
    /// walks up to the package root and points at the executable
    /// target's `main.swift`. Any refactor that relocates `main.swift`
    /// out of `Sources/MCICaptureHelper/main.swift` must update this
    /// helper — a deliberate coupling per [[project-v2p1-unit-tests-
    /// passed-but-never-wired]] discipline.
    private static func readMainSwift() throws -> String {
        // Tests/MCICaptureHelperKitTests/MainSwiftWiringTests.swift
        //   → ../../..                                            = package root
        //   → Sources/MCICaptureHelper/main.swift
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()   // MCICaptureHelperKitTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
        let mainSwiftURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MCICaptureHelper")
            .appendingPathComponent("main.swift")
        return try String(contentsOf: mainSwiftURL, encoding: .utf8)
    }

    func testProductionFocusBindingIsIndependentOfDisplayOrder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/MCICaptureHelperKit/Capture/SCStreamCaptureSession.swift"
        ), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "SCContentFilterFactory.makeFocusedWindowFilter(").count - 1, 3,
                       "Startup, focus rebind, and permission recovery must bind the actual window, on any display")
        XCTAssertFalse(source.contains("SCContentFilterFactory.makeMultiWindowFilter("),
                       "A first-display include list can return blank pixels for a window on another display")
    }

    /// The wiring PR's mandatory grep-in-place assertion — pins the
    /// construction-graph shape at `main.swift`. Redesign memo §2.3 +
    /// §5.1 + [[project-v2p1-unit-tests-passed-but-never-wired]] make
    /// this an MANDATORY gate on the wiring PR: without it, the
    /// unit-tested factory could be shipped without a caller, exactly
    /// the cycle 8.25 shape.
    ///
    /// The assertions are structural — the test greps the source text
    /// for the specific construction-graph shape. A future refactor
    /// that renames the store/tracker (e.g. to `FocusedWindowSetStore`
    /// per redesign memo §2.1) MUST update this test in lockstep or CI
    /// fails.
    func test_main_swift_multi_window_filter_wiring() throws {
        let src = try Self.readMainSwift()

        // Positive assertion 1: `main.swift` constructs a
        // `FocusedWindowStore`. Redesign memo §2.3 + §5.1 wiring
        // shape.
        XCTAssertTrue(
            src.contains("FocusedWindowStore()"),
            "main.swift MUST construct a FocusedWindowStore (redesign memo §2.3 wiring)."
        )

        // Positive assertion 2: `main.swift` constructs a `FocusTracker`
        // and passes the store to it. Redesign memo §2.3 wiring shape.
        XCTAssertTrue(
            src.contains("FocusTracker(\n        store: focusedWindowStore,"),
            "main.swift MUST construct a FocusTracker(store: focusedWindowStore)."
        )

        // Positive assertion 3: both the store and the tracker are
        // passed into `SCStreamCaptureSession`. The literal argument
        // labels are the pinned interface.
        XCTAssertTrue(
            src.contains("focusedWindowStore: focusedWindowStore"),
            "main.swift MUST pass focusedWindowStore into SCStreamCaptureSession."
        )
        XCTAssertTrue(
            src.contains("focusTracker: focusTracker"),
            "main.swift MUST pass focusTracker into SCStreamCaptureSession."
        )

        // Negative assertion 1: `main.swift` MUST NOT reintroduce the
        // cycle 8.27 antipattern `exceptingWindows: [focusedWindow]`.
        // Redesign memo §2.3 + §5.2 [[project-v2p1-exceptingwindows-
        // misuse]] lesson: FORK 3 = B binds `including:` with a
        // non-empty list, never `exceptingWindows:` with the focused
        // window.
        XCTAssertFalse(
            src.contains("exceptingWindows: [focusedWindow]"),
            "main.swift MUST NOT reintroduce the cycle 8.27 antipattern (exceptingWindows: [focusedWindow])."
        )

        // Negative assertion 2: `main.swift` MUST NOT construct
        // `SCContentFilter(desktopIndependentWindow:)` — the single-
        // window form REJECTED by FORK 3 = B CEO ratification.
        XCTAssertFalse(
            src.contains("desktopIndependentWindow:"),
            "main.swift MUST NOT use SCContentFilter(desktopIndependentWindow:) — FORK 3 = B rejects single-window form."
        )
    }

    func test_main_swift_has_one_capture_authority_and_publishes_readiness_after_stream_start() throws {
        let src = try Self.readMainSwift()

        XCTAssertFalse(src.contains("HIPPOCAMPUS_ENABLE_V2P1"))
        XCTAssertFalse(src.contains("MciV2P1Gate"))
        guard let startRange = src.range(of: "try await captureSession.start()"),
              let publishRange = src.range(of: "try readiness?.publish()")
        else {
            return XCTFail("main.swift must start capture and publish readiness")
        }
        XCTAssertLessThan(startRange.lowerBound, publishRange.lowerBound)
        XCTAssertTrue(src.contains("exit(78)"), "Keychain startup failure must exit nonzero")
        XCTAssertTrue(src.contains("exit(79)"), "SCStream startup failure must exit nonzero")
    }

    func test_main_swift_wires_tcc_monitor_into_capture_session() throws {
        let src = try Self.readMainSwift()

        XCTAssertTrue(
            src.contains("let tccStatusMonitor = TCCStatusMonitor()"),
            "main.swift MUST construct the live TCC monitor."
        )
        XCTAssertTrue(
            src.contains("tccStatusMonitor: tccStatusMonitor"),
            "main.swift MUST pass the TCC monitor into SCStreamCaptureSession."
        )
    }

    func test_main_uses_no_op_encoder_without_an_undrained_hevc_queue() throws {
        let src = try Self.readMainSwift()

        XCTAssertTrue(src.contains("NoOpFrameEncoder()"))
        XCTAssertFalse(src.contains("InMemoryEncodedSampleQueue()"))
        XCTAssertFalse(src.contains("VideoToolboxHEVCEncoder("))
    }

    /// Grep-in-place assertion on `SCStreamPipeline.swift` — the
    /// factory (which `main.swift` now wires) MUST call
    /// `SCContentFilter(display:including:exceptingWindows:)` with the
    /// FORK 3 = B ratified `including:` labeled argument. Redesign
    /// memo §2.4 regression-guard.
    func test_content_filter_factory_uses_including_labeled_argument() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let factoryURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MCICaptureHelperKit")
            .appendingPathComponent("Capture")
            .appendingPathComponent("SCStreamPipeline.swift")
        let src = try String(contentsOf: factoryURL, encoding: .utf8)

        // Positive: the factory constructs
        // `SCContentFilter(display:including:exceptingWindows:)` with
        // the `including:` labeled argument (redesign memo §1.1
        // BINDING API shape).
        XCTAssertTrue(
            src.contains("including: includingSet"),
            "SCContentFilterFactory MUST call SCContentFilter(display:including:exceptingWindows:) with 'including:' labeled argument (FORK 3 = B)."
        )

        // Negative: the factory MUST NOT contain a call that passes
        // the focused window via `exceptingWindows:` alone. Grep for
        // the cycle 8.27 pattern.
        XCTAssertFalse(
            src.contains("exceptingWindows: [focusedWindow]"),
            "SCContentFilterFactory MUST NOT contain the cycle 8.27 antipattern (exceptingWindows: [focusedWindow])."
        )
    }

    /// Standalone Phase 7 PR 14 guard: the production default lifts only
    /// after the signed live-Mac privacy/resource qualification passes.
    func test_production_default_has_lifted_killOcrEmit() {
        XCTAssertFalse(
            CascadeTwiceOCREmitter.killOcrEmit,
            "The qualified production capture path must emit privacy-cleared OCR."
        )
    }

    func test_production_startup_does_not_mutate_the_source_controlled_ocr_gate() throws {
        let src = try Self.readMainSwift()

        XCTAssertFalse(
            src.contains("CascadeTwiceOCREmitter.activateM4Lift"),
            "Production startup must not mutate the source-controlled emergency OCR switch."
        )
    }

    func test_race_gate_fails_closed_on_observed_nil_when_installed_is_nonzero() {
        XCTAssertTrue(Self.raceGateFailsClosed(installedGen: 7, observedGen: nil))
    }
}
