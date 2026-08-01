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

    func testHoldThenClears() async throws {
        let n = freshNotifier()
        n.notify("Brain refreshed", hold: 0.05)
        XCTAssertEqual(n.currentMessage, "Brain refreshed")
        // Wait past hold + a small buffer for the scheduled fade-out
        // task to fire.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(n.currentMessage)
    }

    func testBurstQueuesAndDrains() async throws {
        // Wall-clock test, so the hold has to be longer than the gap
        // between checks or the queue drains past the message being
        // asserted. It used to hold each message 50ms and then sleep
        // 120ms before checking, which is more than two holds per step:
        // by the third check the whole queue had drained and the
        // assertion saw nil.
        //
        // Hold 300ms and check every 400ms. Each check then lands in the
        // middle of its message's window with ~100ms of slack on either
        // side, which survives a loaded CI runner.
        let hold = 0.3
        let step: UInt64 = 400_000_000
        let n = freshNotifier()
        n.notify("first", hold: hold)
        n.notify("second", hold: hold)
        n.notify("third", hold: hold)
        XCTAssertEqual(n.currentMessage, "first")
        try await Task.sleep(nanoseconds: step)
        XCTAssertEqual(n.currentMessage, "second")
        try await Task.sleep(nanoseconds: step)
        XCTAssertEqual(n.currentMessage, "third")
        try await Task.sleep(nanoseconds: step)
        XCTAssertNil(n.currentMessage)
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
