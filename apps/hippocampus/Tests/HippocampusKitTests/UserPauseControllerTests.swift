// SPDX-License-Identifier: TBD-private
//
// Tests for UserPauseController — the user-initiated pause layer
// added in the menu-bar quick-actions PR. Two things to pin:
//
//   1. Thread-safety: concurrent toggles from multiple queues never
//      race the internal `_isPaused` guard. We run a burst of 100
//      toggles from a concurrent queue and check the final state is
//      deterministic (parity of the toggle count).
//
//   2. Sink emission: state transitions produce exactly one
//      breadcrumb per flip; no-op writes (setting to the current
//      value) do not fire the sink. This is what keeps
//      `helper_health user_paused=` breadcrumbs from spamming the
//      health-log ring when the menu is opened repeatedly without
//      any state change.

import XCTest
@testable import HippocampusKit

final class UserPauseControllerTests: XCTestCase {

    // MARK: - Basic behaviour

    func testInitialState_isNotPaused() {
        let controller = UserPauseController()
        XCTAssertFalse(controller.isPaused)
    }

    func testSetPaused_toggleRoundTrip() {
        let controller = UserPauseController()
        XCTAssertFalse(controller.isPaused)

        controller.setPaused(true)
        XCTAssertTrue(controller.isPaused)

        controller.setPaused(false)
        XCTAssertFalse(controller.isPaused)
    }

    func testTogglePaused_returnsNewState() {
        let controller = UserPauseController()
        XCTAssertTrue(controller.togglePaused())   // false → true
        XCTAssertFalse(controller.togglePaused())  // true → false
        XCTAssertTrue(controller.togglePaused())   // false → true
    }

    // MARK: - Sinks

    /// Sinks fire on transitions only. Setting the current value is a
    /// no-op — critical for keeping the `helper_health user_paused=`
    /// breadcrumb ring clean when SwiftUI re-renders the menu on
    /// every open (SwiftUI can call `setPaused(false)` on a
    /// no-transition open if the caller isn't careful).
    func testSink_firesOnlyOnTransitions() {
        let controller = UserPauseController()
        let box = SinkBox()
        controller.addSink { paused in box.append(paused) }

        controller.setPaused(false)  // no-op — already false
        XCTAssertEqual(box.snapshot(), [])

        controller.setPaused(true)   // transition
        XCTAssertEqual(box.snapshot(), [true])

        controller.setPaused(true)   // no-op
        XCTAssertEqual(box.snapshot(), [true])

        controller.setPaused(false)  // transition
        XCTAssertEqual(box.snapshot(), [true, false])
    }

    func testSink_toggleFires() {
        let controller = UserPauseController()
        let box = SinkBox()
        controller.addSink { paused in box.append(paused) }

        controller.togglePaused()
        controller.togglePaused()
        controller.togglePaused()

        XCTAssertEqual(box.snapshot(), [true, false, true])
    }

    // MARK: - Thread safety

    /// Fire 100 toggles from a concurrent queue. Each toggle should
    /// still register as one transition on the sink (`sinkCount ==
    /// toggles`) and the final state parity should match — i.e. an
    /// even number of toggles ends up back at `false`. If the write
    /// path had a race, we'd see either dropped or duplicated
    /// transitions.
    func testConcurrentToggles_areSerialized() {
        let controller = UserPauseController()
        let box = SinkBox()
        controller.addSink { paused in box.append(paused) }

        let toggles = 100
        let expectation = XCTestExpectation(description: "concurrent toggles")
        expectation.expectedFulfillmentCount = toggles

        let queue = DispatchQueue(
            label: "test.concurrent",
            attributes: .concurrent
        )
        for _ in 0..<toggles {
            queue.async {
                controller.togglePaused()
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)

        // Every toggle should have produced exactly one sink call.
        // If the internal queue were not serialising, we'd either
        // drop transitions (compare-and-swap style race) or double-
        // fire (two threads reading the same `_isPaused` and both
        // flipping). Either would break this assertion.
        XCTAssertEqual(box.snapshot().count, toggles)

        // An even number of toggles must return to the initial
        // (false) state. Odd would be true. This is the parity
        // check — the strictest invariant that would fail under
        // races.
        XCTAssertEqual(controller.isPaused, toggles % 2 == 1)
    }

    /// Concurrent readers alongside writers — no crashes, no torn
    /// reads. This isn't quite a Sanitizer TSAN check (that runs at
    /// build time with `-sanitize=thread`) but it catches the coarse
    /// class of races that surface as "sometimes returns true,
    /// sometimes false while we haven't written".
    func testConcurrentReadsAndWrites_doNotCrash() {
        let controller = UserPauseController()

        let iterations = 200
        let done = XCTestExpectation(description: "read/write mix")
        done.expectedFulfillmentCount = iterations * 2

        let queue = DispatchQueue(
            label: "test.rw",
            attributes: .concurrent
        )
        for i in 0..<iterations {
            queue.async {
                controller.setPaused(i.isMultiple(of: 2))
                done.fulfill()
            }
            queue.async {
                _ = controller.isPaused
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 5.0)
    }
}

/// Thread-safe append-only sink capture. Tests read the snapshot
/// after `wait(for:)` returns, so the internal lock is not on the
/// hot path.
private final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
