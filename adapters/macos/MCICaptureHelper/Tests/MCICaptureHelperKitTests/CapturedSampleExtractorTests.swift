// SPDX-License-Identifier: TBD-private
//
// CapturedSampleExtractorTests — OS-FREE proof of the pure in-callback
// extraction core (enabler PR-1). These tests deliberately touch no
// `ScreenCaptureKit` / `CoreVideo` / `CoreMedia` — the live session
// (`SCStreamCaptureSession`) is `// UNVERIFIED` and is NOT exercised
// here. What IS proven: the dHash fold is correct + deterministic and
// its output flows into the existing `SmartCaptureFilter` dual
// threshold without an OS in the loop.

import XCTest

@testable import MCICaptureHelperKit

final class CapturedSampleExtractorTests: XCTestCase {
    private func uniformGrid(_ v: UInt8) -> [UInt8] {
        [UInt8](repeating: v, count: CapturedSampleExtractor.dhashGridCount)
    }

    func test_all_equal_grid_yields_zero_bits() {
        let h = CapturedSampleExtractor.computeDHash9x8(grayscale: uniformGrid(128))
        XCTAssertEqual(h.bits, 0, "no left>right anywhere ⇒ all 64 bits clear")
        XCTAssertEqual(h.distance(to: h), 0)
    }

    func test_strictly_decreasing_rows_yield_all_ones_and_max_distance() {
        // Each 9-wide row strictly decreasing ⇒ every one of the 64
        // adjacent comparisons is left>right ⇒ all bits set.
        var grid = [UInt8]()
        for _ in 0 ..< CapturedSampleExtractor.dhashGridHeight {
            grid.append(contentsOf: [9, 8, 7, 6, 5, 4, 3, 2, 1])
        }
        let h = CapturedSampleExtractor.computeDHash9x8(grayscale: grid)
        XCTAssertEqual(h.bits, UInt64.max, "every comparison left>right ⇒ 0xFFFF…")
        let zero = CapturedSampleExtractor.computeDHash9x8(grayscale: uniformGrid(50))
        XCTAssertEqual(h.distance(to: zero), 64, "all-ones vs all-zero ⇒ Hamming 64")
    }

    func test_single_comparison_sets_only_bit_zero() {
        // All equal except grid[0] brighter than grid[1] ⇒ ONLY the
        // (row0,col0) comparison, which is bitIndex 0.
        var grid = uniformGrid(10)
        grid[0] = 20
        let h = CapturedSampleExtractor.computeDHash9x8(grayscale: grid)
        XCTAssertEqual(h.bits, 1, "only bit 0 set")
    }

    func test_bit_ordering_is_row_major_8_per_row() {
        // Make ONLY (row1,col0) fire. Its bitIndex is 1*8 + 0 = 8.
        // grid index for (row1,col0) left operand = 1*9 + 0 = 9.
        var grid = uniformGrid(10)
        grid[9] = 20
        let h = CapturedSampleExtractor.computeDHash9x8(grayscale: grid)
        XCTAssertEqual(h.bits, UInt64(1) << 8, "row-major: row1 col0 ⇒ bit 8")
    }

    func test_identical_grids_have_distance_zero() {
        let a = CapturedSampleExtractor.computeDHash9x8(grayscale: uniformGrid(77))
        let b = CapturedSampleExtractor.computeDHash9x8(grayscale: uniformGrid(77))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.distance(to: b), 0)
    }

    func test_makeCandidateFrame_is_a_faithful_value_passthrough() {
        let dh = DHash(bits: 0xABCD)
        let prior = DHash(bits: 0x1234)
        let rects = [DirtyRect(x: 1, y: 2, width: 3, height: 4)]
        let f = CapturedSampleExtractor.makeCandidateFrame(
            userIdle: true,
            frameStatusComplete: false,
            dirtyRects: rects,
            dhash: dh,
            priorDhash: prior
        )
        XCTAssertEqual(f.userIdle, true)
        XCTAssertEqual(f.frameStatusComplete, false)
        XCTAssertEqual(f.dirtyRects, rects)
        XCTAssertEqual(f.dhash, dh)
        XCTAssertEqual(f.priorDhash, prior)
    }

    func test_makeWorkflowContext_maps_every_field() {
        let ctx = CapturedSampleExtractor.makeWorkflowContext(
            appBundleId: "com.example.app",
            windowTitle: "Title",
            url: "https://x.test",
            pageText: "body"
        )
        XCTAssertEqual(ctx.appBundleId, "com.example.app")
        XCTAssertEqual(ctx.windowTitle, "Title")
        XCTAssertEqual(ctx.url, "https://x.test")
        XCTAssertEqual(ctx.pageText, "body")
    }

    // The whole point of factoring the dHash out: its output feeds the
    // EXISTING dual-threshold filter with no OS in the loop.
    func test_extractor_output_drives_SmartCaptureFilter_dual_threshold() {
        let filter = SmartCaptureFilter() // .default thresholds: low 4, high 12
        let prior = CapturedSampleExtractor.computeDHash9x8(grayscale: uniformGrid(10))

        // Identical content ⇒ distance 0 ≤ low ⇒ near-duplicate drop.
        let same = CapturedSampleExtractor.computeDHash9x8(grayscale: uniformGrid(10))
        XCTAssertEqual(
            filter.decide(frame: CapturedSampleExtractor.makeCandidateFrame(
                userIdle: false,
                frameStatusComplete: true,
                dirtyRects: [DirtyRect(x: 0, y: 0, width: 1, height: 1)],
                dhash: same,
                priorDhash: prior
            )),
            .dropNearDuplicate
        )

        // Maximally different content ⇒ distance 64 ≥ high ⇒ forward.
        var decreasing = [UInt8]()
        for _ in 0 ..< CapturedSampleExtractor.dhashGridHeight {
            decreasing.append(contentsOf: [9, 8, 7, 6, 5, 4, 3, 2, 1])
        }
        let novel = CapturedSampleExtractor.computeDHash9x8(grayscale: decreasing)
        XCTAssertEqual(
            filter.decide(frame: CapturedSampleExtractor.makeCandidateFrame(
                userIdle: false,
                frameStatusComplete: true,
                dirtyRects: [DirtyRect(x: 0, y: 0, width: 1, height: 1)],
                dhash: novel,
                priorDhash: prior
            )),
            .forward
        )
    }
}
