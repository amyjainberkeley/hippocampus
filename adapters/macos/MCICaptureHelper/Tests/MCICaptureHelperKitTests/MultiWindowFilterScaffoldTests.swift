// SPDX-License-Identifier: TBD-private
//
// MultiWindowFilterScaffoldTests — headless coverage for the ADR-0031
// V2-P1 third-lift multi-window filter scaffold:
//   - `SCContentFilterFactory.selectMultiWindowIncludingSet(...)` —
//     the pure OS-free selection helper that determines which visible
//     windows enter the include-set for
//     `SCContentFilter(display:including:exceptingWindows:)`.
//   - `SCStreamPipelineError.emptyIncludeSet` — the refuse-to-construct
//     discipline per ADR-0031 §Status third-lift condition 1 +
//     redesign memo §1.1.
//
// Production OS calls (`SCShareableContent.current`, the Apple
// `SCContentFilter(display:including:exceptingWindows:)` initializer,
// `SCStream.updateContentFilter`) are `// UNVERIFIED — needs live macOS`
// and are covered by the live-Mac corpus (redesign memo §3) — out of
// scope for this scaffold. This test file covers the OS-free decision
// surface — the auditable part per the redesign memo §2.4
// regression-guard discipline.
//
// SCOPE FENCE: this scaffold does NOT wire the multi-window filter
// into `SCStreamCaptureSession` (no `main.swift` change; no
// `killOcrEmit` flip). Phase 7 PR 13 lands the wiring + the live-Mac
// corpus; Phase 7 PR 14 is the standalone M4 lift. Per ADR-0031
// §Status "M4 lift is a SEPARATE standalone PR…no compounding under
// any circumstance."

import CoreGraphics
import Foundation
import XCTest

@testable import MCICaptureHelperKit

private func denylist(_ deny: Set<String> = []) -> Denylist {
    Denylist(entries: deny.map { DenylistEntry(kind: .appBundle, pattern: $0) })
}

// MARK: - selectMultiWindowIncludingSet(...) — the pure selection helper

final class SelectMultiWindowIncludingSetTests: XCTestCase {

    // FORK 3 = B invariant: the returned include-set is NEVER empty
    // post-select (redesign memo §1.1 + selection helper's post-
    // condition precondition). If we return non-nil, it has ≥1 element.

    func test_returns_seed_only_when_no_coview_candidates() {
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.apple.Safari"),
            SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.apple.Terminal"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: 1,
            coViewWindowIds: [],
            denylist: denylist()
        )
        // FORK 3 = B guarantees a non-empty include-set (per redesign
        // memo §1.1) — the seed alone is a valid include-set of size 1.
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?[0].windowId, 1)
        XCTAssertEqual(result?[0].bundleId, "com.apple.Safari")
    }

    func test_returns_seed_plus_coview_candidates_in_order() {
        // The CEO's canonical "2 windows side-by-side" workflow
        // (redesign memo §3.2.4 H9′ + PR #236 §0 vision quote):
        // Safari focused, Messages co-viewed. The include-set must
        // contain both, with the seed first.
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 10, bundleId: "com.apple.Safari"),
            SCContentFilterFactory.WindowDescriptor(windowId: 20, bundleId: "com.apple.MobileSMS"),
            SCContentFilterFactory.WindowDescriptor(windowId: 30, bundleId: "com.apple.Terminal"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: 10,
            coViewWindowIds: [20],
            denylist: denylist()
        )
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].windowId, 10)                       // seed FIRST
        XCTAssertEqual(result?[0].bundleId, "com.apple.Safari")
        XCTAssertEqual(result?[1].windowId, 20)
        XCTAssertEqual(result?[1].bundleId, "com.apple.MobileSMS")
    }

    func test_returns_nil_when_focused_seed_missing_from_descriptors() {
        // Fail-closed per redesign memo §1.1: seed missing ⇒ no rebind.
        // The caller (SCStreamCaptureSession) treats nil as "keep the
        // prior installed filter"; NOT "capture nothing".
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.apple.Safari"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: 99,
            coViewWindowIds: [1],
            denylist: denylist()
        )
        XCTAssertNil(result)
    }

    func test_returns_nil_when_focused_seed_is_denylisted() {
        // ADR-0013 §1 composition: a denylisted app's window never
        // becomes the SCStream's bound window. When the focused window
        // is denylisted, the whole rebind is refused — even if allowed
        // co-view candidates exist, we do not silently promote a
        // co-view to seed.
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.1password.1password"),
            SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.apple.Safari"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: 1,
            coViewWindowIds: [2],
            denylist: denylist(["com.1password.1password"])
        )
        XCTAssertNil(result)
    }

    func test_denylist_subtracts_coview_candidates_silently() {
        // Redesign memo §1.3.1 step 4 "denylist subtract" — a
        // denylisted co-view candidate is dropped from the include-set
        // (NOT added to `exceptingWindows:`); the seed still binds and
        // the rebind proceeds.
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 10, bundleId: "com.apple.Safari"),
            SCContentFilterFactory.WindowDescriptor(windowId: 20, bundleId: "com.1password.1password"),
            SCContentFilterFactory.WindowDescriptor(windowId: 30, bundleId: "com.apple.Terminal"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: 10,
            coViewWindowIds: [20, 30],
            denylist: denylist(["com.1password.1password"])
        )
        // 1Password dropped; Safari + Terminal remain.
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].windowId, 10)
        XCTAssertEqual(result?[1].windowId, 30)
        XCTAssertFalse(result?.contains(where: { $0.bundleId == "com.1password.1password" }) ?? true)
    }

    func test_coview_candidate_missing_from_descriptors_is_skipped() {
        // Bounded race: the include-set heuristic proposed a co-view
        // candidate but the window closed between heuristic recompute
        // and this call. The candidate is silently skipped; the seed +
        // remaining candidates proceed.
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 10, bundleId: "com.apple.Safari"),
            SCContentFilterFactory.WindowDescriptor(windowId: 30, bundleId: "com.apple.Terminal"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: 10,
            coViewWindowIds: [99, 30], // 99 has closed
            denylist: denylist()
        )
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].windowId, 10)
        XCTAssertEqual(result?[1].windowId, 30)
    }

    func test_seed_passed_as_coview_is_deduplicated() {
        // Defensive: the co-view heuristic may (buggily) include the
        // seed in its co-view list. The include-set must not carry a
        // duplicate — Apple's SCStream behavior on duplicate windows in
        // the `including:` list is unspecified.
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 10, bundleId: "com.apple.Safari"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: 10,
            coViewWindowIds: [10, 10],
            denylist: denylist()
        )
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?[0].windowId, 10)
    }

    func test_empty_descriptors_yields_nil() {
        // No visible windows at all (login window / fast-user-switch
        // transient) — fail-closed.
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: [],
            focusedWindowId: 1,
            coViewWindowIds: [2, 3],
            denylist: denylist()
        )
        XCTAssertNil(result)
    }

    func test_result_is_guaranteed_nonempty_when_nonnil() {
        // The FORK 3 = B invariant expressed as a property test over
        // all the branches above: when the helper returns non-nil, the
        // returned array is non-empty. This is the load-bearing
        // pre-condition for `SCContentFilter(display:including:
        // exceptingWindows:)` — an empty `including:` list is the
        // cycle 8.27 `-3815` antipattern.
        let cases: [(descriptors: [SCContentFilterFactory.WindowDescriptor],
                     focused: CGWindowID,
                     coView: [CGWindowID],
                     deny: Set<String>)] = [
            ([SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.a")],
             1, [], []),
            ([SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.a"),
              SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.b")],
             1, [2], []),
            ([SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.a"),
              SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.b")],
             1, [2], ["com.b"]),
        ]
        for c in cases {
            let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
                from: c.descriptors,
                focusedWindowId: c.focused,
                coViewWindowIds: c.coView,
                denylist: denylist(c.deny)
            )
            if let r = result {
                XCTAssertFalse(r.isEmpty, "include-set must be non-empty when non-nil (FORK 3 = B invariant)")
            }
        }
    }
}

// MARK: - Error surface — refuse-to-construct discipline

final class MultiWindowFilterErrorTests: XCTestCase {

    func test_emptyIncludeSet_error_is_distinct_and_equatable() {
        // The scaffold's refuse-to-construct signal — surfaced when the
        // resolved include-set would be empty (defense-in-depth against
        // a future refactor that regresses the selection helper's
        // non-empty post-condition). Distinct from `noDisplay` and
        // `encodeBeforeCascade` so the caller can route it separately
        // (fall back to prior filter, NOT throw or degrade silently).
        XCTAssertEqual(SCStreamPipelineError.emptyIncludeSet, SCStreamPipelineError.emptyIncludeSet)
        XCTAssertNotEqual(SCStreamPipelineError.emptyIncludeSet, SCStreamPipelineError.noDisplay)
        XCTAssertNotEqual(SCStreamPipelineError.emptyIncludeSet, SCStreamPipelineError.encodeBeforeCascade)
    }
}

// MARK: - Scope-fence guards — assert the scaffold did NOT flip defaults

final class MultiWindowFilterScopeFenceTests: XCTestCase {

    // The scaffold discipline: multi-window path exists as CODE READY
    // TO BE FLIPPED. It must NOT be reachable from the shipping capture
    // path until Phase 7 PR 13 wires it in. These tests are structural
    // guards asserting the scope-fence held in this PR.

    func test_killOcrEmit_default_is_still_true() {
        // ADR-0031 §Status "M4 SECOND LIFT REVERTED" keeps the OCR-emit
        // kill-switch RE-ENGAGED until the third-lift conditions all
        // hold. This scaffold is one of those conditions (the
        // implementing PR path); it must NOT flip the kill-switch. The
        // M4 lift is a strictly separate standalone PR (Phase 7 PR 14).
        XCTAssertTrue(CascadeTwiceOCREmitter.killOcrEmit,
                      "V2-P1 third-lift scaffold MUST NOT flip killOcrEmit — that's Phase 7 PR 14.")
    }
}
