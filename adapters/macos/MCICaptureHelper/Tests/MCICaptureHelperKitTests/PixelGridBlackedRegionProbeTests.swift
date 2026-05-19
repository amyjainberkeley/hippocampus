// SPDX-License-Identifier: TBD-private
//
// PixelGridBlackedRegionProbeTests — headless XCTest coverage for the
// ADR-0013 §2 production probe.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These tests pin the §2
// detector's decision contract so a future refactor cannot regress
// it silently:
//
//   (a) returns true on a deliberately-blacked synthetic grid;
//   (b) returns false on a normal synthetic grid;
//   (c) thread-safe under concurrent update/read;
//   (d) cost is O(constant-pixels) — analytical bound asserted as a
//       wall-clock ceiling so a future "let me scan the whole frame"
//       refactor breaks here, not on a real machine under load;
//   (e) fail-safe initial state (no update ⇒ `false`);
//   (f) `reset()` returns to fail-safe.
//
// The cascade ordering tests (`SuppressionCascadeTests`) already
// cover that a `true` from this probe triggers `.osBlackedRegion`
// suppression at the right cascade slot and that §1 fires before §2;
// this file is the probe-internal contract, not the cascade
// integration contract.
//
// Inputs use the same 72-byte grid format the live callback already
// produces — `CapturedSampleExtractor.dhashGridCount = 72`, row-major
// 9×8 — so the test fixtures match the production data shape
// exactly.

import XCTest

@testable import MCICaptureHelperKit

private let gridCount = CapturedSampleExtractor.dhashGridCount

private func uniformGrid(_ value: UInt8) -> [UInt8] {
    [UInt8](repeating: value, count: gridCount)
}

/// Grid where `blackCount` of the 72 cells are at luma 0 and the
/// remainder are at luma 200 (well above the default threshold of 4).
/// Used to drive the ratio threshold exactly.
private func gridWithBlackCount(_ blackCount: Int) -> [UInt8] {
    precondition(blackCount >= 0 && blackCount <= gridCount)
    var grid = [UInt8](repeating: 200, count: gridCount)
    for i in 0 ..< blackCount {
        grid[i] = 0
    }
    return grid
}

final class PixelGridBlackedRegionProbeTests: XCTestCase {
    // MARK: - (a) all-black synthetic surface ⇒ true

    func test_allBlackGridReportsBlackedRegion() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(0))
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "every sampled pixel at luma 0 ⇒ §2 must fire"
        )
    }

    func test_nearBlackGridAtOrBelowLumaThresholdReportsBlackedRegion() {
        let probe = PixelGridBlackedRegionProbe()  // threshold luma = 4
        probe.update(grayscale: uniformGrid(4))
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "luma ≤ thresholdLuma counts as black — boundary inclusive"
        )
    }

    // MARK: - (b) normal synthetic surface ⇒ false

    func test_allWhiteGridReportsNoBlackedRegion() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(255))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "every sampled pixel at luma 255 ⇒ §2 must not fire"
        )
    }

    func test_midGrayGridReportsNoBlackedRegion() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(128))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "mid-gray content ⇒ §2 must not fire"
        )
    }

    /// Just above the threshold luma — must NOT count as black. Catches
    /// an "≤ vs <" off-by-one regression on the luma comparator.
    func test_oneAboveLumaThresholdDoesNotCountAsBlack() {
        let probe = PixelGridBlackedRegionProbe()  // luma = 4
        probe.update(grayscale: uniformGrid(5))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "luma 5 with threshold 4 ⇒ no pixel counts as black ⇒ §2 must not fire"
        )
    }

    // MARK: - Threshold-ratio boundary

    /// Default ratio is 0.85. With 72 cells the smallest integer count
    /// that meets ≥ 0.85 is `ceil(0.85 * 72) = 62`.
    func test_exactlyAtRatioThresholdFires() {
        let probe = PixelGridBlackedRegionProbe()  // ratio = 0.85
        probe.update(grayscale: gridWithBlackCount(62))
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "62 / 72 = 0.861… ≥ 0.85 ⇒ §2 must fire (boundary inclusive)"
        )
    }

    func test_oneBelowRatioThresholdDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: gridWithBlackCount(61))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "61 / 72 = 0.847… < 0.85 ⇒ §2 must not fire"
        )
    }

    func test_customLowerRatioFiresOnMajorityBlack() {
        let probe = PixelGridBlackedRegionProbe(thresholdLuma: 4, thresholdRatio: 0.5)
        probe.update(grayscale: gridWithBlackCount(36))  // exactly 50%
        XCTAssertTrue(probe.hasBlackedRegion())
        let stricter = PixelGridBlackedRegionProbe(thresholdLuma: 4, thresholdRatio: 0.95)
        stricter.update(grayscale: gridWithBlackCount(36))
        XCTAssertFalse(stricter.hasBlackedRegion())
    }

    // MARK: - (e) Fail-safe initial state

    func test_freshProbeIsFalseBeforeAnyUpdate() {
        let probe = PixelGridBlackedRegionProbe()
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "ADR-0013 §3 / §7: unknown ⇒ fail-safe to false (never true) before any frame"
        )
    }

    // MARK: - (f) reset() returns to fail-safe

    func test_resetClearsTrueVerdict() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(0))
        XCTAssertTrue(probe.hasBlackedRegion())
        probe.reset()
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "reset() must clear a prior true verdict — session start/stop discipline"
        )
    }

    func test_updateAfterResetReFires() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(0))
        probe.reset()
        XCTAssertFalse(probe.hasBlackedRegion())
        probe.update(grayscale: uniformGrid(0))
        XCTAssertTrue(probe.hasBlackedRegion())
    }

    /// Subsequent updates must be able to flip the verdict back to
    /// false — verdict is per-frame, not sticky.
    func test_normalFrameAfterBlackFrameFlipsVerdictFalse() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(0))
        XCTAssertTrue(probe.hasBlackedRegion())
        probe.update(grayscale: uniformGrid(200))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "verdict is per-frame — last update wins"
        )
    }

    // MARK: - (c) Thread-safety

    /// Concurrent writers from many threads + many concurrent readers.
    /// XCTest's main success criterion: no crash and the final
    /// verdict matches one of the writers' actual inputs. The lock is
    /// the contract; this test asserts it under contention.
    func test_concurrentUpdateAndReadDoNotCrashAndConverge() {
        let probe = PixelGridBlackedRegionProbe()
        let writerIterations = 256
        let readerIterations = 256

        let blackGrid = uniformGrid(0)
        let whiteGrid = uniformGrid(200)

        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)

        group.enter()
        q.async {
            DispatchQueue.concurrentPerform(iterations: writerIterations) { i in
                probe.update(grayscale: i.isMultiple(of: 2) ? blackGrid : whiteGrid)
            }
            group.leave()
        }

        group.enter()
        q.async {
            DispatchQueue.concurrentPerform(iterations: readerIterations) { _ in
                _ = probe.hasBlackedRegion()
            }
            group.leave()
        }

        group.wait()

        // Pin the final state deterministically so the assertion isn't
        // racing the readers. Per-frame verdict semantics: last write
        // wins.
        probe.update(grayscale: blackGrid)
        XCTAssertTrue(probe.hasBlackedRegion())
        probe.update(grayscale: whiteGrid)
        XCTAssertFalse(probe.hasBlackedRegion())
    }

    // MARK: - (d) Analytical O(constant) bound — wall-clock ceiling

    /// `update(grayscale:)` is O(72): one comparator + one
    /// conditional increment per byte. The ADR-0013 hot-path budget
    /// is 100 µs per frame on the suppression cascade. We exercise
    /// 100 000 updates — analytically ≤ 100 000 × 72 = 7.2 M
    /// comparators — and assert a generous wall-clock ceiling of one
    /// second on the run. On Apple Silicon this completes in tens of
    /// milliseconds; CI VMs are a small multiple slower. A failure
    /// here means someone replaced the bounded grid scan with a
    /// frame-sized one — caught here, not on a real Mac under load.
    func test_updateThroughputIsBoundedConstant() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = uniformGrid(0)
        let iterations = 100_000
        let start = DispatchTime.now()
        for _ in 0 ..< iterations {
            probe.update(grayscale: grid)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedSec = Double(elapsedNs) / 1e9
        XCTAssertLessThan(
            elapsedSec, 1.0,
            "\(iterations) updates took \(elapsedSec)s — expected ≪ 1s under O(72)/call"
        )
        // Per-call envelope is informational, not asserted at a tight
        // bound: CI variance dominates a single-microsecond budget.
        // The 1s ceiling on 100k calls is the load-bearing assertion.
        let nsPerCall = Double(elapsedNs) / Double(iterations)
        XCTAssertLessThan(
            nsPerCall, 100_000.0,
            "average ns/call \(nsPerCall) exceeds 100 µs/frame ADR-0013 hot-path budget"
        )
    }

    func test_hasBlackedRegionIsConstantTimeLockedRead() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(0))
        let iterations = 100_000
        let start = DispatchTime.now()
        for _ in 0 ..< iterations {
            _ = probe.hasBlackedRegion()
        }
        let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertLessThan(
            elapsedSec, 1.0,
            "hasBlackedRegion read of one Bool is O(1); \(iterations) calls took \(elapsedSec)s"
        )
    }

    // MARK: - Precondition guards (defensive — wrong-sized grid)

    /// The probe MUST be fed the canonical 9×8 grid; a wrong-sized
    /// input is a contract breach and the precondition fires. Asserted
    /// indirectly: a 0-length grid path is the precondition trigger
    /// the production code never reaches because
    /// `CapturedSampleExtractor.grayscale9x8` always returns the exact
    /// grid size. The compile-time `precondition` would crash in a
    /// debug build; we cover the negative case via the size-stable
    /// happy path instead so the contract stays explicit without
    /// fatal-erroring the test process.
    func test_canonicalGridSizeIsExactlyDhashGridCount() {
        XCTAssertEqual(CapturedSampleExtractor.dhashGridCount, 72)
        let probe = PixelGridBlackedRegionProbe()
        // Confirm the canonical-size grid is accepted and produces a
        // deterministic verdict — this is the production contract.
        probe.update(grayscale: uniformGrid(0))
        XCTAssertTrue(probe.hasBlackedRegion())
    }
}

// MARK: - Cascade integration (synthetic)

/// One belt-and-suspenders test against the cascade with the real
/// production probe wired in (not a mock). Verifies the §2 slot
/// actually fires `.osBlackedRegion` when the probe says so, and
/// stays out of the way when it says no. Cascade ordering itself is
/// covered exhaustively in `SuppressionCascadeTests`; this is the
/// "the real probe plugs into the real cascade" smoke test.
final class PixelGridBlackedRegionProbeCascadeIntegrationTests: XCTestCase {
    private struct SEIOff: SecureEventInputProbe {
        func isSecureEventInputEnabled() -> Bool { false }
    }
    private struct AXNonSecure: AXSecureSubroleProbe {
        func focusedHasSecureSubrole() -> Bool? { false }
    }
    private struct NoApps: DenylistProbe {
        func appIsDenied(bundleId _: String) -> Bool { false }
        func urlIsDenied(_: String) -> Bool { false }
        func windowTitleIsDenied(_: String) -> Bool { false }
    }

    private func cascade(probe: PixelGridBlackedRegionProbe) -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: SEIOff(),
            axSecureSubrole: AXNonSecure(),
            denylist: NoApps(),
            blackedRegion: probe,
            knownSafeAppBundles: ["com.apple.Safari"]
        )
    }

    func test_realProbeFedWithBlackGridProducesOsBlackedRegion() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: [UInt8](repeating: 0, count: CapturedSampleExtractor.dhashGridCount))
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(
            cascade(probe: probe).decide(context: ctx),
            .suppress(reason: .osBlackedRegion)
        )
    }

    func test_realProbeFedWithBrightGridFallsThroughToAllow() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: [UInt8](repeating: 200, count: CapturedSampleExtractor.dhashGridCount))
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        // Known-safe app + AX positively non-secure + no other signal
        // ⇒ the ONE allow path.
        XCTAssertEqual(cascade(probe: probe).decide(context: ctx), .allow)
    }

    func test_unfedProbeFailsSafeToCascadeFallThrough() {
        let probe = PixelGridBlackedRegionProbe()
        // No `update(...)` call: probe is in fail-safe initial state.
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        // Cascade falls through §2 (probe says false) → §3 / §4 → the
        // allow path because the app is known-safe + AX non-secure.
        // The point of this test is that the probe DOES NOT itself
        // produce a §2 suppression when no frame has been seen — the
        // "unknown ⇒ redact" semantics belong to §7, not §2.
        XCTAssertEqual(cascade(probe: probe).decide(context: ctx), .allow)
    }
}
