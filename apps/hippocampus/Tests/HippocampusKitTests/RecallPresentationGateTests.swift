import XCTest
@testable import HippocampusKit

final class RecallPresentationGateTests: XCTestCase {
    func testNormalLaunchWaitsForReadinessAndOpensOnce() {
        var gate = RecallPresentationGate()
        XCTAssertFalse(gate.request(initialLaunch: true, state: .idle))
        XCTAssertFalse(gate.consumeIfReady(state: .starting))
        XCTAssertFalse(gate.consumeIfReady(state: .crashed(reason: "key unavailable")))
        XCTAssertTrue(gate.consumeIfReady(state: .running))
        XCTAssertFalse(gate.consumeIfReady(state: .running))
        XCTAssertFalse(gate.request(initialLaunch: true, state: .running))
    }

    func testOnboardingAndReopenRequestsCoalesceDuringStartup() {
        var gate = RecallPresentationGate()
        XCTAssertFalse(gate.request(initialLaunch: true, state: .starting))
        XCTAssertFalse(gate.request(initialLaunch: false, state: .starting))
        XCTAssertTrue(gate.consumeIfReady(state: .running))
        XCTAssertFalse(gate.consumeIfReady(state: .running))
    }

    /// Opening the app shows the window when remembering is off, too
    /// (spec-shell S5, D9).
    func testOpensWhenRememberingIsStopped() {
        var gate = RecallPresentationGate()
        XCTAssertTrue(gate.request(initialLaunch: false, state: .stopped))
        XCTAssertFalse(gate.request(initialLaunch: true, state: .starting))
        XCTAssertTrue(gate.consumeIfReady(state: .stopped))
    }

    /// A failed start never shows the window; it ends the request once, so
    /// the app can show where the fix is instead.
    func testAFailedStartEndsTheRequestOnce() {
        var gate = RecallPresentationGate()
        XCTAssertFalse(gate.request(initialLaunch: true, state: .starting))
        XCTAssertFalse(gate.consumeIfReady(state: .crashed(reason: "x")))
        XCTAssertFalse(gate.consumeIfBlocked(state: .running))
        XCTAssertTrue(gate.consumeIfBlocked(state: .crashed(reason: "x")))
        XCTAssertFalse(gate.consumeIfBlocked(state: .crashed(reason: "x")))
        XCTAssertFalse(gate.consumeIfReady(state: .running), "the request is over")
        XCTAssertFalse(gate.consumeIfBlocked(state: .crashed(reason: "x")), "nothing pending")
    }

    func testReopenPresentsReadyOrPausedMemoryWithoutResumingCapture() {
        var gate = RecallPresentationGate()
        XCTAssertTrue(gate.request(initialLaunch: true, state: .running))
        XCTAssertTrue(gate.request(initialLaunch: false, state: .running))
        XCTAssertTrue(gate.request(initialLaunch: false, state: .paused))
        XCTAssertFalse(gate.consumeIfReady(state: .paused))
    }
}
