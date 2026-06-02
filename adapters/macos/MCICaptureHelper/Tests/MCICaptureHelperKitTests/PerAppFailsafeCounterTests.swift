// SPDX-License-Identifier: TBD-private
//
// PerAppFailsafeCounterTests — coverage for the wire-0x09
// `failsafe_by_app` per-app counter map (PR #226 §5.1 (1) + Phase 6
// PR 6).
//
// Asserts the cap-8 LRU discipline + content-free struct shape
// required by the dispatch §"3-row mini-audit":
//   Row 1: cap-8 fixed-cardinality — no PII via cardinality leak.
//   Row 2: counter struct never includes OCR text content; bundle id
//          + numeric counters only.

import XCTest

@testable import MCICaptureHelperKit

final class PerAppFailsafeCounterTests: XCTestCase {
    /// Recording a new bundle id adds it as a fresh entry with
    /// counter = 1.
    func testRecordNewBundleAddsEntryWithCounterOne() async {
        let counters = HelperHealthCounters()
        await counters.recordFailsafeByApp(bundleId: "com.example.app")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.failsafeByApp.count, 1)
        XCTAssertEqual(snap.failsafeByApp[0].bundleId, "com.example.app")
        XCTAssertEqual(snap.failsafeByApp[0].counter, 1)
    }

    /// Recording an existing bundle id bumps the counter AND moves
    /// the entry to the front of the LRU array.
    func testRecordExistingBundleBumpsCounterAndMovesToFront() async {
        let counters = HelperHealthCounters()
        await counters.recordFailsafeByApp(bundleId: "com.a.app")
        await counters.recordFailsafeByApp(bundleId: "com.b.app")
        // Bump com.a.app → it should move to the front (LRU).
        await counters.recordFailsafeByApp(bundleId: "com.a.app")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.failsafeByApp.count, 2)
        XCTAssertEqual(snap.failsafeByApp[0].bundleId, "com.a.app")
        XCTAssertEqual(snap.failsafeByApp[0].counter, 2)
        XCTAssertEqual(snap.failsafeByApp[1].bundleId, "com.b.app")
        XCTAssertEqual(snap.failsafeByApp[1].counter, 1)
    }

    /// At the cap (8 entries), adding a 9th evicts the tail entry
    /// (least-recently-bumped). This is the load-bearing cap-eviction
    /// test cited in the PR body's 3-row mini-audit row 1.
    func testCapEightLeastRecentBumpEviction() async {
        let counters = HelperHealthCounters()
        // Record 8 distinct bundles — at cap.
        for i in 0..<maxFailsafeByAppEntries {
            await counters.recordFailsafeByApp(bundleId: "com.example.app\(i)")
        }
        let snapAtCap = await counters.snapshot()
        XCTAssertEqual(snapAtCap.failsafeByApp.count, maxFailsafeByAppEntries)
        // The first-bumped (com.example.app0) is at the tail.
        XCTAssertEqual(
            snapAtCap.failsafeByApp.last?.bundleId,
            "com.example.app0",
            "least-recent-bump is at tail of LRU array"
        )

        // Record a 9th bundle — should evict com.example.app0.
        await counters.recordFailsafeByApp(bundleId: "com.example.newbie")
        let snapAfterEviction = await counters.snapshot()
        XCTAssertEqual(
            snapAfterEviction.failsafeByApp.count,
            maxFailsafeByAppEntries,
            "cap MUST hold at maxFailsafeByAppEntries after eviction"
        )
        XCTAssertEqual(
            snapAfterEviction.failsafeByApp[0].bundleId,
            "com.example.newbie",
            "newest bundle at front"
        )
        XCTAssertFalse(
            snapAfterEviction.failsafeByApp.contains(where: { $0.bundleId == "com.example.app0" }),
            "least-recent-bump entry (com.example.app0) MUST be evicted"
        )
    }

    /// Bumping an existing entry while at cap MUST NOT evict — only
    /// new-entry insertions trigger eviction.
    func testBumpAtCapDoesNotEvict() async {
        let counters = HelperHealthCounters()
        for i in 0..<maxFailsafeByAppEntries {
            await counters.recordFailsafeByApp(bundleId: "com.example.app\(i)")
        }
        // Bump com.example.app0 (currently at tail). It moves to
        // front; nothing evicts.
        await counters.recordFailsafeByApp(bundleId: "com.example.app0")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.failsafeByApp.count, maxFailsafeByAppEntries)
        XCTAssertEqual(snap.failsafeByApp[0].bundleId, "com.example.app0")
        XCTAssertEqual(snap.failsafeByApp[0].counter, 2)
        // The bundle that WAS at index 1 is now at tail.
        XCTAssertEqual(snap.failsafeByApp.last?.bundleId, "com.example.app1")
    }

    /// Content-free struct shape — the `FailsafeAppCounter` struct
    /// MUST carry ONLY a bundleId + counter pair. NO ocr text field,
    /// NO text length, NO recognized text. This is the dispatch's
    /// "3-row mini-audit row 2" trip-wire: a future careless edit
    /// that adds a `text` / `text_snippet` / `text_len` property
    /// would break this test.
    func testFailsafeAppCounterStructShapeIsContentFree() {
        let entry = FailsafeAppCounter(bundleId: "com.example.app", counter: 42)
        // Mirror reflects all stored properties — the assertion is
        // that EXACTLY two are present (bundleId + counter) and the
        // types are String + UInt64.
        let mirror = Mirror(reflecting: entry)
        let labels = mirror.children.compactMap(\.label)
        XCTAssertEqual(
            Set(labels),
            ["bundleId", "counter"],
            "FailsafeAppCounter MUST have exactly bundleId + counter properties — "
                + "see PR body 3-row mini-audit row 2 (content-free wire field)"
        )
        // Reject specific OCR-content field names that a future
        // careless edit might introduce.
        for forbidden in [
            "text", "textSnippet", "textLen", "ocrText", "recognizedText",
            "windowTitle", "url",
        ] {
            XCTAssertFalse(
                labels.contains(forbidden),
                "FailsafeAppCounter MUST NOT have \(forbidden) — content-free invariant"
            )
        }
    }

    /// The cap is exactly 8 — pinned by the canonical PR #226 §5.1
    /// (1) "(cap at 8 entries, deterministic eviction by least-
    /// recent-bump, content-free)". Drift here would mean the wire
    /// shape contract has drifted away from the memo's load-bearing
    /// addition.
    func testMaxFailsafeByAppEntriesEqualsEight() {
        XCTAssertEqual(maxFailsafeByAppEntries, 8)
    }

    /// Empty bundle id ("") is recorded as a single cap entry, never
    /// silently dropped. This matches the cascade-twice emitter's
    /// `context.appBundleId ?? ""` fallback — a stub context with no
    /// bundle id still surfaces as one observability data point.
    func testEmptyBundleIdRecordedAsExplicitEntry() async {
        let counters = HelperHealthCounters()
        await counters.recordFailsafeByApp(bundleId: "")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.failsafeByApp.count, 1)
        XCTAssertEqual(snap.failsafeByApp[0].bundleId, "")
        XCTAssertEqual(snap.failsafeByApp[0].counter, 1)
    }

    /// Snapshot is a value copy — mutating the counter actor after a
    /// snapshot does NOT mutate the snapshot.
    func testSnapshotIsValueCopy() async {
        let counters = HelperHealthCounters()
        await counters.recordFailsafeByApp(bundleId: "com.a.app")
        let snap1 = await counters.snapshot()
        await counters.recordFailsafeByApp(bundleId: "com.a.app")
        XCTAssertEqual(snap1.failsafeByApp[0].counter, 1, "snapshot must NOT see post-snapshot bump")
        let snap2 = await counters.snapshot()
        XCTAssertEqual(snap2.failsafeByApp[0].counter, 2)
    }
}
