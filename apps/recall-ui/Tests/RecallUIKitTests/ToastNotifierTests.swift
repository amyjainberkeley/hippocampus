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
        let n = freshNotifier()
        n.notify("first", hold: 0.05)
        n.notify("second", hold: 0.05)
        n.notify("third", hold: 0.05)
        XCTAssertEqual(n.currentMessage, "first")
        // First message clears after ~50ms; second should immediately
        // take over on the next pump.
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(n.currentMessage, "second")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(n.currentMessage, "third")
        try await Task.sleep(nanoseconds: 120_000_000)
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
