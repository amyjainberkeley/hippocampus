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

    func testReopenPresentsReadyOrPausedMemoryWithoutResumingCapture() {
        var gate = RecallPresentationGate()
        XCTAssertTrue(gate.request(initialLaunch: true, state: .running))
        XCTAssertTrue(gate.request(initialLaunch: false, state: .running))
        XCTAssertTrue(gate.request(initialLaunch: false, state: .paused))
        XCTAssertFalse(gate.consumeIfReady(state: .paused))
    }
}
