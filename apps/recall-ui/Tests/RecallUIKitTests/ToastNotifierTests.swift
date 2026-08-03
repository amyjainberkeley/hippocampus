// ToastNotifierTests.swift — lifecycle coverage for the shared toast
// notifier used by ⌘R "Brain refreshed" feedback (cycle 8.51 PR #74
// follow-up).
//
// The AppKit NSPanel path is skipped by setting `testMode = true`;
// what we assert is the observable state machine: enqueue → present →
// hold → drain → present next.

import XCTest
@testable import RecallUIKit

@MainActor
final class ToastNotifierTests: XCTestCase {
    private func freshNotifier() -> ToastNotifier {
        let n = ToastNotifier()
        n.testMode = true
        return n
    }

    func testNotifyPresentsMessage() {
        let n = freshNotifier()
        XCTAssertNil(n.currentMessage)
        n.notify("Brain refreshed", hold: 0.05)
        XCTAssertEqual(n.currentMessage, "Brain refreshed")
    }

    /// Wait until `condition` holds, or fail after `timeout`.
    ///
    /// These tests used to sleep a fixed amount and then assert, which
    /// races the pump: each transition is a `Task.sleep` plus a hop back
    /// to the main actor, and on a loaded CI runner that lands late.
    /// Tuning the sleeps does not fix it, it just moves which test is
    /// flaky, so wait for the state instead of guessing at the clock.
    ///
    /// Correctness is unchanged. A transition that never happens still
    /// fails, it just takes `timeout` to say so instead of asserting on
    /// whatever the value happened to be at one arbitrary instant.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        XCTFail("timed out after \(timeout)s waiting for: \(description)")
    }

    func testHoldThenClears() async throws {
        let n = freshNotifier()
        n.notify("Brain refreshed", hold: 0.05)
        XCTAssertEqual(n.currentMessage, "Brain refreshed")
        await waitUntil("the message to clear after its hold") {
            n.currentMessage == nil
        }
    }

    func testBurstQueuesAndDrains() async throws {
        let n = freshNotifier()
        n.notify("first", hold: 0.05)
        n.notify("second", hold: 0.05)
        n.notify("third", hold: 0.05)

        // The first is presented synchronously by notify(); the rest are
        // pumped as each hold expires. Order is the contract, not timing.
        XCTAssertEqual(n.currentMessage, "first")
        await waitUntil("second to be presented") { n.currentMessage == "second" }
        await waitUntil("third to be presented") { n.currentMessage == "third" }
        await waitUntil("the queue to drain") { n.currentMessage == nil }
    }

    func testResetClearsQueueAndCurrent() {
        let n = freshNotifier()
        n.notify("a", hold: 5)
        n.notify("b", hold: 5)
        n.notify("c", hold: 5)
        n.reset()
        XCTAssertNil(n.currentMessage)
        // Follow-up notify shouldn't replay any dropped messages.
        n.notify("fresh", hold: 5)
        XCTAssertEqual(n.currentMessage, "fresh")
    }
}
