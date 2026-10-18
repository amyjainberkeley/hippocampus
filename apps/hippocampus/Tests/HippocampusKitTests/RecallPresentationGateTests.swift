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

    /// With memory the window can read, opening Hippocampus shows the window
    /// at once in every state of remembering, a failed start included: it
    /// never waits on the helper and never does nothing (Oct 18).
    func testWithMemoryToReadTheWindowOpensAtOnceInEveryState() {
        let states: [SupervisorState] = [.idle, .starting, .running, .paused, .stopped, .crashed(reason: "x")]
        for state in states {
            var gate = RecallPresentationGate()
            XCTAssertTrue(gate.request(initialLaunch: false, state: state, memoryReady: true), "\(state)")
            XCTAssertFalse(gate.consumeIfReady(state: .running, memoryReady: true), "once, in \(state)")
            XCTAssertFalse(gate.consumeIfBlocked(state: .crashed(reason: "x"), memoryReady: true), "\(state)")
        }
    }

    /// A launch whose key is still being checked waits, then opens the
    /// moment it is, before remembering has started.
    func testARequestWaitingForTheKeyOpensWhenMemoryIsReady() {
        var gate = RecallPresentationGate()
        XCTAssertFalse(gate.request(initialLaunch: true, state: .starting, memoryReady: false))
        XCTAssertTrue(gate.consumeIfReady(state: .starting, memoryReady: true))
        XCTAssertFalse(gate.consumeIfReady(state: .running, memoryReady: true))
        XCTAssertFalse(gate.request(initialLaunch: true, state: .running, memoryReady: true), "the launch opens once")
    }

    /// A failed start ends the request only while there is no memory to
    /// show; with memory, the window shows instead of Preferences.
    func testAFailedStartWithMemoryShowsTheWindowNotPreferences() {
        var gate = RecallPresentationGate()
        XCTAssertFalse(gate.request(initialLaunch: false, state: .starting))
        XCTAssertFalse(gate.consumeIfBlocked(state: .crashed(reason: "x"), memoryReady: true))
        XCTAssertTrue(gate.consumeIfReady(state: .crashed(reason: "x"), memoryReady: true))
    }
}
