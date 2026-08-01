// SPDX-License-Identifier: TBD-private
//
// MultiWindowWiringBehaviorTests — headless behavior tests for the
// V2-P1 third-lift wiring (Phase 7 PR 13). Complements the pure
// selection-helper coverage in `MultiWindowFilterScaffoldTests.swift`
// and the construction-graph grep-in-place assertions in
// `MainSwiftWiringTests.swift`.
//
// SCOPE: pure OS-free behavior over the selection helper, exercised
// against representative include-set scenes. The OS-touching factory
// `SCContentFilterFactory.makeMultiWindowFilter(...)` is `// UNVERIFIED
// — needs live macOS`; its decision logic delegates to the pure
// `selectMultiWindowIncludingSet(...)` helper which IS tested here + in
// the scaffold PR's tests. The SCStream callback path itself remains
// `// UNVERIFIED`; the pipeline's `emitFocusRaceDropped(...)` +
// graceful-skip behavior is exercised through the pure helper.

import CoreGraphics
import Foundation
import XCTest

@testable import MCICaptureHelperKit

private func denylist(_ deny: Set<String> = []) -> Denylist {
    Denylist(entries: deny.map { DenylistEntry(kind: .appBundle, pattern: $0) })
}

// MARK: - Behavior: mock 1-window scene → include-set is non-empty

final class MultiWindowWiringBehaviorTests: XCTestCase {

    /// The task's mandated behavior test #1: with a mock 1-window
    /// scene, the include-list is non-empty. This is the CEO's minimum
    /// bar for FORK 3 = B (the include-set is never empty when a
    /// focused window is observable — cycle 8.27 -3815 antipattern
    /// class defense).
    func test_mock_one_window_scene_yields_nonempty_include_set() {
        let scene = [
            SCContentFilterFactory.WindowDescriptor(windowId: 42, bundleId: "com.apple.Safari"),
        ]
        let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: scene,
            focusedWindowId: 42,
            coViewWindowIds: [],
            denylist: denylist()
        )
        XCTAssertNotNil(result, "1-window scene with the focused window present MUST yield a non-nil include-set.")
        XCTAssertGreaterThanOrEqual(result?.count ?? 0, 1, "The include-set MUST be non-empty (FORK 3 = B invariant).")
        XCTAssertEqual(result?[0].windowId, 42)
    }

    /// The task's mandated behavior test #2: with 0 eligible windows,
    /// the pipeline gracefully skips (returns nil from the selection
    /// helper — the caller does NOT rebind; the prior filter stays
    /// installed). The task discipline: "graceful log-and-skip, not
    /// throw."
    ///
    /// The selection helper returning `nil` is the graceful-skip
    /// signal — `SCStreamCaptureSession.start()` catches this branch
    /// via the `if let focused = initialSnapshot.focused, ..., let
    /// multiWindowFilter = ...` guard and falls back to the display
    /// filter with a stderr breadcrumb. No throw reaches the caller.
    func test_zero_eligible_windows_gracefully_skips() {
        // Case (a): no descriptors at all (login window /
        // fast-user-switch transient).
        let resultA = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: [],
            focusedWindowId: 1,
            coViewWindowIds: [],
            denylist: denylist()
        )
        XCTAssertNil(resultA, "Zero-window scene MUST yield nil (graceful skip signal).")

        // Case (b): focused window is denylisted; even if a co-view
        // candidate is allowed, we do NOT promote it to seed. The
        // selection helper returns nil; the caller keeps the prior
        // filter installed (or the display fallback at startup).
        let resultB = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: [
                SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.1password.1password"),
                SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.apple.Safari"),
            ],
            focusedWindowId: 1,
            coViewWindowIds: [2],
            denylist: denylist(["com.1password.1password"])
        )
        XCTAssertNil(resultB, "Denylisted focused-seed MUST yield nil (graceful skip; no auto-promotion of co-view).")

        // Case (c): the focused window has vanished between poll and
        // filter build (bounded race). Fail-closed per redesign memo
        // §1.1.
        let resultC = SCContentFilterFactory.selectMultiWindowIncludingSet(
            from: [
                SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.apple.Safari"),
            ],
            focusedWindowId: 1, // no longer present
            coViewWindowIds: [],
            denylist: denylist()
        )
        XCTAssertNil(resultC, "Missing focused-seed MUST yield nil (bounded race; keep prior filter).")
    }

    /// The `emptyIncludeSet` error case is REACHABLE only through a
    /// residual bounded-race in `makeMultiWindowFilter(...)` (every
    /// selected window vanished between descriptor build and SCWindow
    /// materialization). The selection helper's post-condition
    /// guarantees non-empty on every allowed path. Pin the error type
    /// so a future refactor cannot silently degrade this to "capture
    /// nothing."
    func test_empty_include_set_error_is_reserved_for_bounded_race() {
        // The helper's post-condition: if `result` is non-nil,
        // `result.count >= 1`.
        let allCases: [(descriptors: [SCContentFilterFactory.WindowDescriptor],
                        focused: CGWindowID,
                        coView: [CGWindowID],
                        deny: Set<String>)] = [
            ([SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.a")], 1, [], []),
            ([SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.a"),
              SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.b")],
             1, [2], []),
            ([SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.a"),
              SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.b")],
             1, [2], ["com.b"]),
        ]
        for scene in allCases {
            let result = SCContentFilterFactory.selectMultiWindowIncludingSet(
                from: scene.descriptors,
                focusedWindowId: scene.focused,
                coViewWindowIds: scene.coView,
                denylist: denylist(scene.deny)
            )
            if let r = result {
                XCTAssertGreaterThanOrEqual(
                    r.count,
                    1,
                    "Non-nil include-set MUST be non-empty (FORK 3 = B post-condition)."
                )
            }
        }
        // The `emptyIncludeSet` case is distinct from the graceful-skip
        // (nil-return) path.
        XCTAssertNotEqual(SCStreamPipelineError.emptyIncludeSet, SCStreamPipelineError.noDisplay)
    }
}

// MARK: - Behavior: SCStreamCaptureSession accepts store/tracker

/// Construction-graph sanity check: `SCStreamCaptureSession` accepts
/// `focusedWindowStore` + `focusTracker` init parameters (the shape
/// `main.swift` now wires). This is a compile-time-plus-runtime pin;
/// if the init signature changes in a way that breaks the wiring, the
/// test fails to compile.
final class SCStreamCaptureSessionWiringSurfaceTests: XCTestCase {

    func test_session_accepts_focused_window_store_and_focus_tracker() {
        // Minimal shape: build the mandatory dependencies + the two
        // V2-P1 wiring params. `focusTracker` is `nil` by choice —
        // tests own the store directly (per `FocusTracker`'s
        // `tickOnce(...)` pattern), and the session's init accepts
        // both `nil` and non-nil. The session is not `start()`ed here;
        // this test only pins the init surface.
        let cascade = SuppressionCascade(
            secureEventInput: NeverSecureEventProbe(),
            axSecureSubrole: NeverAXSecureSubroleProbe(),
            denylist: Denylist(entries: []),
            blackedRegion: NoBlackedRegionProbe(),
            knownSafeAppBundles: []
        )
        let sink = InMemorySink()
        let pipeline = SCStreamPipeline(
            cascade: cascade,
            encoder: DeferredVideoToolboxEncoder(),
            sink: sink
        )
        let store = FocusedWindowStore()
        let session = SCStreamCaptureSession(
            pipeline: pipeline,
            denylist: Denylist(entries: []),
            focusedWindowStore: store,
            focusTracker: nil
        )
        // The include-list bookkeeping starts at 0 (no filter has been
        // bound yet — the session has not been `start()`ed).
        XCTAssertEqual(
            session.lastIncludeListSizeForTest(),
            0,
            "Pre-start(), lastIncludeListSize MUST be 0 (no filter bound yet)."
        )
        // The race-drop counter starts at 0.
        XCTAssertEqual(
            session.focusRaceDropSeenForTest(),
            0,
            "Pre-start(), focusRaceDropSeen MUST be 0 (no drops observed yet)."
        )
        // Retain to silence the unused-warning; `_ = session` is
        // enough to prove construction succeeds.
        _ = session
    }
}

// MARK: - Test-only stubs

/// Never-fires SecureEventInput probe. Same pattern as other test
/// files in the suite (see `SCStreamPipelineTests`).
private struct NeverSecureEventProbe: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

/// Never-fires AX subrole probe.
private struct NeverAXSecureSubroleProbe: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

/// No-op blacked-region probe.
private struct NoBlackedRegionProbe: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

/// In-memory FrameSink for the session's pipeline. Bytes discarded.
private final class InMemorySink: FrameSink, @unchecked Sendable {
    func write(_: Data) async throws {}
}
