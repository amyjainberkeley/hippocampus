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
        // Isolate the fast-path ratio knob from the STEP-2-FINDING-006
        // contiguous-rect path: `gridWithBlackCount(36)` fills the
        // first 36 grid cells (rows 0..3 across the full width) and
        // would otherwise form a 9×4 video-like rectangle. Setting
        // `rectMinCells = 72` disables the contiguous-rect path so
        // this test exercises ONLY the `thresholdRatio` knob, which
        // is the original contract under test.
        let probe = PixelGridBlackedRegionProbe(
            thresholdLuma: 4,
            thresholdRatio: 0.5,
            rectMinCells: 72
        )
        probe.update(grayscale: gridWithBlackCount(36))  // exactly 50%
        XCTAssertTrue(probe.hasBlackedRegion())
        let stricter = PixelGridBlackedRegionProbe(
            thresholdLuma: 4,
            thresholdRatio: 0.95,
            rectMinCells: 72
        )
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

// MARK: - STEP-2-FINDING-006 — contiguous-rectangle detection path

/// Headless coverage for the second detection path added under
/// STEP-2-FINDING-006. The original fast path (`thresholdRatio = 0.85`)
/// cannot fire on real-world FairPlay rendering because Apple's
/// FairPlay protection scopes the OS black-out to the video surface
/// (rectangular hardware overlay plane), not the whole display — menu
/// bar / HUD / cursor / chrome around the video remain visible. These
/// tests pin the new contiguous-rectangle path, which fires when the
/// largest connected near-black region has video-like bounding-box
/// area (≥ `rectMinCells`) AND aspect ratio (`rectAspectMin` ≤ W/H
/// ≤ `rectAspectMax`).
///
/// Privacy direction is strictly-more-redaction: this path can only
/// flip a frame from `.allow` to `.suppress(reason=2)`, or relabel a
/// `reason=7` tombstone to `reason=2`. No frame can move from
/// `.suppress` → `.allow` as a result of this logic. The cascade
/// itself is untouched.
final class PixelGridBlackedRegionContiguousRectTests: XCTestCase {
    private let width = CapturedSampleExtractor.dhashGridWidth   // 9
    private let height = CapturedSampleExtractor.dhashGridHeight // 8

    /// Build a grid filled with `background` (default = bright,
    /// well above thresholdLuma) and stamp a rectangle of `value`
    /// (default = pure black, luma 0) at `(originX, originY)` with
    /// `width × height` cells.
    private func gridWithBlackRect(
        originX: Int,
        originY: Int,
        width rectW: Int,
        height rectH: Int,
        background: UInt8 = 200,
        value: UInt8 = 0
    ) -> [UInt8] {
        precondition(originX >= 0 && originY >= 0)
        precondition(originX + rectW <= self.width)
        precondition(originY + rectH <= self.height)
        var grid = [UInt8](repeating: background, count: gridCount)
        for y in originY ..< (originY + rectH) {
            for x in originX ..< (originX + rectW) {
                grid[y * self.width + x] = value
            }
        }
        return grid
    }

    private func gridWithBlackCells(_ cells: [(x: Int, y: Int)], background: UInt8 = 200) -> [UInt8] {
        var grid = [UInt8](repeating: background, count: gridCount)
        for c in cells {
            precondition(c.x >= 0 && c.x < self.width && c.y >= 0 && c.y < self.height)
            grid[c.y * self.width + c.x] = 0
        }
        return grid
    }

    // MARK: - Regression guard: existing 0.85 fast path

    /// Whole-grid black must still fire via the existing 0.85 ratio
    /// path. Regression guard: the STEP-2-FINDING-006 fix MUST NOT
    /// disturb the original positive path.
    func test_wholeGridBlackStillFiresViaFastPath() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(0))
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "all 72 cells at luma 0 ⇒ 0.85 fast path still fires (regression)"
        )
    }

    /// Letterboxed playback that occupies almost the whole frame
    /// (e.g., a single row of menu-bar chrome at the top, everything
    /// else black) ⇒ fast path fires (63/72 ≈ 0.875 ≥ 0.85).
    func test_letterboxedAlmostFullBlackFiresViaFastPath() {
        let probe = PixelGridBlackedRegionProbe()
        // Black rect 9 wide × 7 tall (covering rows 1..7) on a
        // bright single-row "menu bar" at row 0.
        let grid = gridWithBlackRect(originX: 0, originY: 1, width: 9, height: 7)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "9×7 black + 1-row chrome ⇒ 63/72 = 0.875 ≥ 0.85 fast path fires"
        )
    }

    // MARK: - Contiguous-rectangle path positives (video-like aspect ratios)

    /// 8 wide × 4 tall black rect: aspect 2.0 (16:8 ≈ 16:8 = 2.0),
    /// 32 cells in bbox. Inside both windows ⇒ positive.
    func test_videoLike16to9RectFiresViaContiguousPath() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 0, originY: 2, width: 8, height: 4)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "8×4 black rect (aspect 2.0, 32 cells_in_bbox) ⇒ contiguous-rect path fires"
        )
    }

    /// 8 wide × 5 tall: aspect 1.6 (16:10), 40 cells.
    func test_videoLike16to10RectFires() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 0, originY: 1, width: 8, height: 5)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "8×5 black rect (aspect 1.6 = 16:10, 40 cells) ⇒ contiguous-rect path fires"
        )
    }

    /// 9 wide × 4 tall: aspect 2.25 (close to 21:9 = 2.33), 36 cells.
    func test_videoLike21to9RectFires() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 0, originY: 2, width: 9, height: 4)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "9×4 black rect (aspect 2.25 ≈ 21:9, 36 cells) ⇒ contiguous-rect path fires"
        )
    }

    /// Black rect anchored at (0,0) — not centered. The detector
    /// MUST NOT require centering; FairPlay overlays appear wherever
    /// the OS-positioned video surface lies.
    func test_blackRectAtFrameEdgeFires() {
        let probe = PixelGridBlackedRegionProbe()
        // 7 wide × 3 tall at (0,0): aspect 2.333, 21 cells.
        let grid = gridWithBlackRect(originX: 0, originY: 0, width: 7, height: 3)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "7×3 black rect at (0,0) ⇒ centering not required for contiguous-rect path"
        )
    }

    // MARK: - Contiguous-rectangle path negatives (non-video shapes)

    /// 1 wide × 6 tall (tall narrow sidebar): aspect 0.167, 6 cells.
    /// Fails aspect (≪ 1.3) AND fails cells (< 18). Negative.
    func test_tallNarrowSidebarDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 4, originY: 1, width: 1, height: 6)
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "1×6 black strip (aspect 0.167) ⇒ contiguous-rect path stays negative"
        )
    }

    /// 8 wide × 1 tall (menu-bar strip): aspect 8.0, 8 cells. Fails
    /// aspect (≫ 2.4) AND fails cells. Negative.
    func test_wideHorizontalStripDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 0, originY: 0, width: 8, height: 1)
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "8×1 horizontal strip (aspect 8.0) ⇒ contiguous-rect path stays negative"
        )
    }

    /// Two disconnected 3×2 black regions (each 6 cells). The
    /// detector measures the LARGEST component; 6 cells < 18 ⇒
    /// negative on size, regardless of aspect.
    func test_twoDisconnectedSmallBlackRegionsDoNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        var grid = uniformGrid(200)
        // Rect A at (0,0)..(2,1).
        for y in 0 ... 1 {
            for x in 0 ... 2 {
                grid[y * width + x] = 0
            }
        }
        // Rect B at (6,6)..(8,7) — disconnected from A.
        for y in 6 ... 7 {
            for x in 6 ... 8 {
                grid[y * width + x] = 0
            }
        }
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "two disconnected 3×2 regions ⇒ largest component 6 cells_in_bbox < 18 ⇒ negative"
        )
    }

    /// One stray black cell. Component size 1, bbox 1 cell. Negative.
    func test_singleBlackCellDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackCells([(x: 4, y: 4)])
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "single black cell ⇒ contiguous-rect path stays negative"
        )
    }

    /// All cells well above thresholdLuma. No black region anywhere.
    /// Both the fast path and the contiguous-rect path must return
    /// negative.
    func test_allNonBlackDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: uniformGrid(200))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "all non-black grid ⇒ both detection paths return negative"
        )
    }

    /// Diagonal of 4-connected stair-step black cells from (0,0) to
    /// (8,7). Largest-component bbox covers the whole grid (9×8 =
    /// 72 cells), aspect 1.125 < 1.3 ⇒ negative on aspect — diagonal
    /// is not a video-like shape.
    func test_diagonalStairStepDoesNotFireAspectFails() {
        let probe = PixelGridBlackedRegionProbe()
        var cells: [(x: Int, y: Int)] = []
        // Stair from (0,0) → (8,7): (0,0),(1,0),(1,1),(2,1),(2,2)...
        var x = 0
        var y = 0
        while x < width && y < height {
            cells.append((x: x, y: y))
            if x == width - 1 && y == height - 1 { break }
            // Step right, then down, alternating — 4-connected.
            if x < width - 1 {
                x += 1
                cells.append((x: x, y: y))
            }
            if y < height - 1 {
                y += 1
            } else {
                break
            }
        }
        let grid = gridWithBlackCells(cells)
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "diagonal stair-step ⇒ bbox spans grid but aspect 1.125 ≪ 1.3 ⇒ negative"
        )
    }

    /// Isolated diagonal cells WITHOUT the stair-step bridge — pure
    /// (0,0),(1,1),(2,2)... none touch by 4-connectivity. Each cell
    /// is its own component (size 1) ⇒ negative on cells.
    func test_isolatedDiagonalCellsDoNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        let cells: [(x: Int, y: Int)] = (0 ..< min(width, height)).map { (x: $0, y: $0) }
        let grid = gridWithBlackCells(cells)
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "isolated diagonal cells (8-connected only) ⇒ each component size 1 ⇒ negative"
        )
    }

    // MARK: - Aspect-ratio boundaries

    /// 8 wide × 6 tall: aspect 1.333… ≥ 1.3 (just inside lower bound).
    /// 48 cells_in_bbox. Positive.
    func test_aspectJustAboveLowerBoundFires() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 0, originY: 1, width: 8, height: 6)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "8×6 (aspect 1.333) ≥ 1.3 lower bound ⇒ contiguous-rect path fires"
        )
    }

    /// 5 wide × 4 tall: aspect 1.25 < 1.3 (just below lower bound).
    /// 20 cells (passes size). Negative on aspect.
    func test_aspectJustBelowLowerBoundDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 2, originY: 2, width: 5, height: 4)
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "5×4 (aspect 1.25) < 1.3 lower bound ⇒ contiguous-rect path stays negative"
        )
    }

    /// 7 wide × 3 tall: aspect 2.333 ≤ 2.4 (just inside upper bound).
    /// 21 cells. Positive.
    func test_aspectJustBelowUpperBoundFires() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 1, originY: 2, width: 7, height: 3)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "7×3 (aspect 2.333) ≤ 2.4 upper bound ⇒ contiguous-rect path fires"
        )
    }

    /// 9 wide × 3 tall: aspect 3.0 > 2.4. 27 cells (passes size).
    /// Negative on aspect.
    func test_aspectAboveUpperBoundDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 0, originY: 2, width: 9, height: 3)
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "9×3 (aspect 3.0) > 2.4 upper bound ⇒ contiguous-rect path stays negative"
        )
    }

    // MARK: - cells_in_bbox boundaries

    /// 6 wide × 3 tall: 18 cells exactly (== `rectMinCells`),
    /// aspect 2.0. Boundary inclusive ⇒ positive.
    func test_cellsInBBoxExactlyMinFires() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 1, originY: 2, width: 6, height: 3)
        probe.update(grayscale: grid)
        XCTAssertTrue(
            probe.hasBlackedRegion(),
            "6×3 (18 cells_in_bbox, aspect 2.0) ⇒ boundary inclusive ⇒ fires"
        )
    }

    /// 5 wide × 3 tall: 15 cells_in_bbox (< 18). Aspect 1.667 is
    /// fine, but cells fail ⇒ negative.
    func test_cellsInBBoxBelowMinDoesNotFire() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 2, originY: 2, width: 5, height: 3)
        probe.update(grayscale: grid)
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "5×3 (15 cells_in_bbox < 18) ⇒ size fails ⇒ negative even with valid aspect"
        )
    }

    // MARK: - Defensive / failure-mode

    /// `reset()` after the contiguous-rect path has fired must take
    /// the verdict back to the fail-safe `false` — session start/stop
    /// discipline is unchanged by the new path.
    func test_resetClearsContiguousRectPositive() {
        let probe = PixelGridBlackedRegionProbe()
        let grid = gridWithBlackRect(originX: 0, originY: 2, width: 8, height: 4)
        probe.update(grayscale: grid)
        XCTAssertTrue(probe.hasBlackedRegion())
        probe.reset()
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "reset() must clear a contiguous-rect positive — fail-safe state"
        )
    }

    /// After the contiguous-rect path fires on one frame, a
    /// subsequent normal frame must flip the verdict back to false —
    /// verdict is per-frame, not sticky.
    func test_normalFrameAfterContiguousRectPositiveFlipsFalse() {
        let probe = PixelGridBlackedRegionProbe()
        probe.update(grayscale: gridWithBlackRect(originX: 0, originY: 2, width: 8, height: 4))
        XCTAssertTrue(probe.hasBlackedRegion())
        probe.update(grayscale: uniformGrid(200))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "next bright frame ⇒ verdict per-frame, not sticky"
        )
    }

    /// Custom rectangle window: tightening cells/aspect parameters
    /// MUST be possible without breaking the contract. Pin that a
    /// `rectMinCells = 72` probe never fires on the contiguous-rect
    /// path (a full-grid black region still fires via the 0.85 fast
    /// path — only the contiguous-rect path is suppressed). This
    /// guards against a future regression where the two paths get
    /// accidentally merged.
    func test_customRectMinCellsAtMaxStillAllowsFastPath() {
        let probe = PixelGridBlackedRegionProbe(
            thresholdLuma: 4,
            thresholdRatio: 0.85,
            rectMinCells: 72
        )
        // All-black ⇒ fast path fires regardless of rect tightening.
        probe.update(grayscale: uniformGrid(0))
        XCTAssertTrue(probe.hasBlackedRegion(), "fast path independent of rect knobs")
        // Mid-frame video-shaped rect ⇒ contiguous-rect path
        // suppressed because rectMinCells = 72 unreachable for any
        // sub-grid bbox.
        probe.update(grayscale: gridWithBlackRect(originX: 0, originY: 2, width: 8, height: 4))
        XCTAssertFalse(
            probe.hasBlackedRegion(),
            "tightening rectMinCells to grid size suppresses contiguous-rect path"
        )
    }

    /// Performance ceiling for the combined (fast + flood-fill) path.
    /// The flood-fill is bounded O(72) and the fast path is bounded
    /// O(72); 100 000 updates must comfortably finish well inside
    /// the ADR-0013 §2 100 µs/frame hot-path budget. The aggregate
    /// 5 s ceiling absorbs per-call Swift array allocation overhead
    /// (visited mask + DFS stack are heap-backed); the per-call
    /// 100 µs assertion is the load-bearing bound. A failure here
    /// means someone replaced the bounded grid scan with a frame-
    /// sized one — caught in CI, not on a real Mac under load.
    func test_combinedUpdateThroughputIsBoundedConstant() {
        let probe = PixelGridBlackedRegionProbe()
        // Pick a worst-case-ish grid: contiguous video-shaped rect
        // forces the flood-fill to visit ~half the cells.
        let grid = gridWithBlackRect(originX: 0, originY: 2, width: 8, height: 4)
        let iterations = 100_000
        let start = DispatchTime.now()
        for _ in 0 ..< iterations {
            probe.update(grayscale: grid)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedSec = Double(elapsedNs) / 1e9
        XCTAssertLessThan(
            elapsedSec, 5.0,
            "\(iterations) updates with flood-fill took \(elapsedSec)s — expected ≪ 5s under bounded O(72)/call"
        )
        let nsPerCall = Double(elapsedNs) / Double(iterations)
        XCTAssertLessThan(
            nsPerCall, 100_000.0,
            "average ns/call \(nsPerCall) exceeds 100 µs/frame ADR-0013 §2 hot-path budget"
        )
    }
}
