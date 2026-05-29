// SPDX-License-Identifier: TBD-private
//
// FocusTrackerTests — headless coverage for the ADR-0031 focused-window
// observation primitive.
//
// Production AX / NSWorkspace / CGWindowList reads are `// UNVERIFIED —
// needs live macOS`; these tests drive the decision matrix via injected
// stubs so the tracker's logic (generation discipline, no-op tick
// suppression, nil-on-failure-mode contract) is exercisable in CI.
//
// Test matrix:
//   (a) nil frontmost                → snapshot.focused = nil, gen=0
//   (b) frontmost present + AX rect  → snapshot.focused = (bundleId, wid, rect), gen=1
//   (c) consecutive identical reads  → generation does NOT bump on no-op ticks
//   (d) focus change                 → generation bumps exactly once per change
//   (e) AX rect timeout              → snapshot.focused with axRect = nil
//   (f) windowId resolver fails      → snapshot.focused = nil
//   (g) empty bundleId               → snapshot.focused = nil

import CoreGraphics
import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class FocusTrackerTests: XCTestCase {
    // MARK: - StubFocusedWindowReader (full readFocusedWindow path)

    private struct StubReader: FocusedWindowReader {
        let result: FocusedWindow?
        func readFocusedWindow() -> FocusedWindow? { result }
    }

    // MARK: - Test (a): nil frontmost → snapshot stays nil

    func test_nil_frontmost_yields_nil_snapshot() async {
        let store = FocusedWindowStore()
        let reader = StubReader(result: nil)
        await FocusTracker.tickOnce(reader: reader, store: store)
        let snap = store.currentSync()
        XCTAssertNil(snap.focused)
        // No change from initial → generation stays at 0.
        XCTAssertEqual(snap.generation, 0)
    }

    // MARK: - Test (b): focused-window read produces a populated snapshot

    func test_focused_window_populates_snapshot_and_bumps_generation() async {
        let store = FocusedWindowStore()
        let fw = FocusedWindow(
            bundleId: "com.apple.Safari",
            windowId: CGWindowID(42),
            axRect: CGRect(x: 100, y: 200, width: 800, height: 600)
        )
        let reader = StubReader(result: fw)
        await FocusTracker.tickOnce(reader: reader, store: store)
        let snap = store.currentSync()
        XCTAssertEqual(snap.focused, fw)
        XCTAssertEqual(snap.generation, 1)
    }

    // MARK: - Test (c): no-op tick does not bump generation

    func test_repeated_identical_reads_do_not_bump_generation() async {
        let store = FocusedWindowStore()
        let fw = FocusedWindow(
            bundleId: "com.apple.Terminal",
            windowId: CGWindowID(7),
            axRect: nil
        )
        let reader = StubReader(result: fw)
        await FocusTracker.tickOnce(reader: reader, store: store)
        await FocusTracker.tickOnce(reader: reader, store: store)
        await FocusTracker.tickOnce(reader: reader, store: store)
        let snap = store.currentSync()
        XCTAssertEqual(snap.focused, fw)
        // Three ticks, one real change ⇒ generation == 1, NOT 3.
        XCTAssertEqual(snap.generation, 1)
    }

    // MARK: - Test (d): focus change bumps generation exactly once

    func test_focus_change_bumps_generation_exactly_once() async {
        let store = FocusedWindowStore()
        let safari = FocusedWindow(
            bundleId: "com.apple.Safari",
            windowId: CGWindowID(1),
            axRect: nil
        )
        let term = FocusedWindow(
            bundleId: "com.apple.Terminal",
            windowId: CGWindowID(2),
            axRect: nil
        )
        await FocusTracker.tickOnce(reader: StubReader(result: safari), store: store)
        XCTAssertEqual(store.currentSync().generation, 1)
        // No-op tick.
        await FocusTracker.tickOnce(reader: StubReader(result: safari), store: store)
        XCTAssertEqual(store.currentSync().generation, 1)
        // Focus change.
        await FocusTracker.tickOnce(reader: StubReader(result: term), store: store)
        XCTAssertEqual(store.currentSync().generation, 2)
        XCTAssertEqual(store.currentSync().focused, term)
    }

    // MARK: - Test (e): AX rect timeout → snapshot has nil rect but still populated

    func test_ax_rect_timeout_yields_focused_with_nil_rect() {
        struct TimingOutAX: AXFocusedWindowRectReader {
            func readRect(pid _: pid_t, timeoutMs _: Int) -> CGRect? { nil }
        }
        struct StubPid: FrontmostPidSource {
            func frontmostPidAndBundle() -> (pid_t, String)? {
                (pid_t(123), "com.apple.Safari")
            }
        }
        struct StubWid: FocusedWindowIDSource {
            func focusedWindowID(pid _: pid_t) -> CGWindowID? { CGWindowID(9) }
        }
        let reader = AXFocusedWindowReader(
            pidSource: StubPid(),
            axRectReader: TimingOutAX(),
            windowIdSource: StubWid()
        )
        let result = reader.readFocusedWindow()
        XCTAssertEqual(result?.bundleId, "com.apple.Safari")
        XCTAssertEqual(result?.windowId, CGWindowID(9))
        XCTAssertNil(result?.axRect)
    }

    // MARK: - Test (f): windowId resolver fails → reader returns nil

    func test_windowid_missing_yields_nil_focused() {
        struct StubPid: FrontmostPidSource {
            func frontmostPidAndBundle() -> (pid_t, String)? {
                (pid_t(456), "com.example.Electron")
            }
        }
        struct NoWid: FocusedWindowIDSource {
            func focusedWindowID(pid _: pid_t) -> CGWindowID? { nil }
        }
        struct AnyRect: AXFocusedWindowRectReader {
            func readRect(pid _: pid_t, timeoutMs _: Int) -> CGRect? { .zero }
        }
        let reader = AXFocusedWindowReader(
            pidSource: StubPid(),
            axRectReader: AnyRect(),
            windowIdSource: NoWid()
        )
        XCTAssertNil(reader.readFocusedWindow())
    }

    // MARK: - Test (g): empty bundleId → reader returns nil

    func test_empty_bundle_id_yields_nil_focused() {
        struct EmptyPid: FrontmostPidSource {
            func frontmostPidAndBundle() -> (pid_t, String)? {
                (pid_t(789), "")
            }
        }
        struct AnyWid: FocusedWindowIDSource {
            func focusedWindowID(pid _: pid_t) -> CGWindowID? { CGWindowID(1) }
        }
        struct AnyRect: AXFocusedWindowRectReader {
            func readRect(pid _: pid_t, timeoutMs _: Int) -> CGRect? { .zero }
        }
        let reader = AXFocusedWindowReader(
            pidSource: EmptyPid(),
            axRectReader: AnyRect(),
            windowIdSource: AnyWid()
        )
        XCTAssertNil(reader.readFocusedWindow())
    }

    // MARK: - Lifecycle: start/stop idempotency

    func test_start_and_stop_are_idempotent() {
        let tracker = FocusTracker(
            reader: StubReader(result: nil),
            intervalMs: 10_000 // 10 s — we won't await a tick
        )
        tracker.start()
        tracker.start() // no-op
        tracker.stop()
        tracker.stop() // no-op
        XCTAssertTrue(true)
    }
}
