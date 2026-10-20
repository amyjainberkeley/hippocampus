// SPDX-License-Identifier: Apache-2.0
//
// Remembering held still for a window's forget (SPEC 3.11): the hold never
// writes the person's pause, starts remembering again only if it was on,
// and ends when the window's process does and on its own after 30 seconds.

import XCTest
@testable import HippocampusKit

@MainActor
final class CaptureHoldTests: XCTestCase {
    /// What the hold stops and starts, recorded.
    private final class Target: CaptureHolding {
        var isRememberingForHold = true
        var stopError: Error?
        var stopTakes: Duration = .zero
        private(set) var stops = 0
        private(set) var restarts = 0
        private(set) var holdStates: [Bool] = []

        func stopForHold() async throws {
            stops += 1
            if stopTakes > .zero { try await Task.sleep(for: stopTakes) }
            if let stopError { throw stopError }
            isRememberingForHold = false
        }

        func restartAfterHold() async throws {
            restarts += 1
            isRememberingForHold = true
        }

        func holdChanged(_ holding: Bool) { holdStates.append(holding) }
    }

    private struct Refused: Error {}

    /// A sleep a test ends by hand: the 30-second limit, here.
    private final class Gate: @unchecked Sendable {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private let lock = NSLock()

        func sleep() async {
            await withCheckedContinuation { continuation in
                lock.withLock { waiting.append(continuation) }
            }
        }

        func open() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiting = [] }
                return waiting
            }
            for continuation in all { continuation.resume() }
        }
    }

    func testAHoldWhileRememberingStopsThenStartsAgainOnRelease() async {
        let target = Target()
        let hold = CaptureHold(target: target)
        let held = await hold.hold()
        XCTAssertTrue(held)
        XCTAssertEqual(target.stops, 1)
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(target.holdStates, [true], "the status says Forgetting…")
        await hold.release()
        XCTAssertEqual(target.restarts, 1)
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.holdStates, [true, false])
    }

    func testWhilePausedOrOffNothingIsStoppedOrStartedAgain() async {
        let target = Target()
        target.isRememberingForHold = false
        let hold = CaptureHold(target: target)
        let held = await hold.hold()
        XCTAssertTrue(held, "the lease is already free: the answer comes at once")
        XCTAssertEqual(target.stops, 0)
        await hold.release()
        XCTAssertEqual(target.restarts, 0, "remembering starts again only if it was on")
    }

    func testOneHoldAtATime() async {
        let hold = CaptureHold(target: Target())
        let first = await hold.hold()
        let second = await hold.hold()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testAStopThatFailsHoldsNothing() async {
        let target = Target()
        target.stopError = Refused()
        let hold = CaptureHold(target: target)
        let held = await hold.hold()
        XCTAssertFalse(held, "\"Couldn't forget it. It's still saved.\"")
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1, "remembering comes back after a hold that couldn't be had")
    }

    func testAStopThatTakesTooLongIsARefusal() async {
        let target = Target()
        target.stopTakes = .seconds(5)
        let hold = CaptureHold(target: target, sleep: { duration in
            // The 10-second wait passes at once; the 30-second limit never.
            if duration == CaptureHold.stopWait { return }
            try await Task.sleep(for: .seconds(60))
        })
        let started = Date()
        let held = await hold.hold()
        XCTAssertFalse(held)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTheHoldEndsWhenTheWindowsProcessDoes() async {
        let target = Target()
        let hold = CaptureHold(target: target)
        _ = await hold.hold()
        await hold.windowEnded()
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1)
    }

    func testTheHoldEndsOnItsOwnAfterThirtySeconds() async throws {
        let target = Target()
        let gate = Gate()
        let hold = CaptureHold(target: target, sleep: { duration in
            // Only the 30-second limit waits on the gate; the stop is quick.
            if duration == CaptureHold.limit {
                await gate.sleep()
            } else {
                try await Task.sleep(for: .seconds(60))
            }
        })
        _ = await hold.hold()
        XCTAssertTrue(hold.isHolding)
        gate.open()
        for _ in 0..<100 where hold.isHolding {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1)
        XCTAssertEqual(CaptureHold.limit, .seconds(30))
        XCTAssertEqual(CaptureHold.stopWait, .seconds(10))
    }

    // MARK: The supervisor's hold

    private func supervisor(pauses: UserPauseController) -> (ProcessSupervisor, FakeSupervisorTopology) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: topology, keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: pauses
        )
        return (supervisor, topology)
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The hold stops remembering the way Pause does, but the person's own
    /// pause is never written, so nothing they see as theirs changes.
    func testTheSupervisorsHoldNeverWritesThePersonsPause() async throws {
        let pauses = UserPauseController()
        let (supervisor, _) = supervisor(pauses: pauses)
        try await supervisor.startAndWaitForReadiness()
        XCTAssertEqual(supervisor.state, .running)

        let held = await supervisor.forgetHold.hold()
        XCTAssertTrue(held)
        XCTAssertEqual(supervisor.state, .paused, "the writer lease is free")
        XCTAssertFalse(pauses.isPaused, "the person's pause is never written")
        XCTAssertNil(supervisor.pausedSince)
        XCTAssertTrue(supervisor.holdingForForget)
        XCTAssertEqual(supervisor.menuRow(setupFinished: true).title, "Forgetting\u{2026}")
        XCTAssertNil(supervisor.menuRow(setupFinished: true).action)

        await supervisor.forgetHold.release()
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running, "it was on, so it comes back")
        XCTAssertFalse(supervisor.holdingForForget)
        try await supervisor.shutdownAndWait()
    }

    /// The person paused during the hold: the release leaves it paused.
    func testAPauseDuringTheHoldIsKept() async throws {
        let pauses = UserPauseController()
        let (supervisor, _) = supervisor(pauses: pauses)
        try await supervisor.startAndWaitForReadiness()
        _ = await supervisor.forgetHold.hold()
        supervisor.setPaused(true)
        await supervisor.forgetHold.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertTrue(pauses.isPaused)
        try await supervisor.shutdownAndWait()
    }

    /// Paused already: the hold stops nothing and starts nothing.
    func testWhilePausedTheHoldLeavesItPaused() async throws {
        let pauses = UserPauseController()
        let (supervisor, topology) = supervisor(pauses: pauses)
        try await supervisor.startAndWaitForReadiness()
        supervisor.setPaused(true)
        await eventually { supervisor.state == .paused }
        let launches = topology.launchPlans.count
        let held = await supervisor.forgetHold.hold()
        XCTAssertTrue(held)
        await supervisor.forgetHold.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertEqual(topology.launchPlans.count, launches, "nothing was started")
        try await supervisor.shutdownAndWait()
    }
}
