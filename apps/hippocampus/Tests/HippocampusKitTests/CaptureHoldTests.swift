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
        /// Called as the stop ends, before the hold hears of it.
        var stopEnding: (() -> Void)?
        var startWaitingForHold = false
        private(set) var stops = 0
        private(set) var restarts = 0
        private(set) var holdStates: [Bool] = []

        func stopForHold() async throws {
            stops += 1
            if stopTakes > .zero { try await Task.sleep(for: stopTakes) }
            stopEnding?()
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

        /// Sleeps under way.
        var count: Int { lock.withLock { waiting.count } }

        func open() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiting = [] }
                return waiting
            }
            for continuation in all { continuation.resume() }
        }
    }

    /// Every sleep the hold asks for, in order, each ended by hand: the 30
    /// seconds, the 10-second wait for the stop and the 10-minute cap.
    private final class Sleeps: @unchecked Sendable {
        private var asked: [(duration: Duration, wake: CheckedContinuation<Void, Never>?)] = []
        private let lock = NSLock()

        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { continuation in
                lock.withLock { asked.append((duration, continuation)) }
            }
        }

        /// How many sleeps of `duration` were asked for.
        func count(_ duration: Duration) -> Int {
            lock.withLock { asked.filter { $0.duration == duration }.count }
        }

        /// Ends the `index`th sleep of `duration`, counting from 0.
        func end(_ duration: Duration, _ index: Int) {
            let wake = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let positions = asked.indices.filter { asked[$0].duration == duration }
                guard index < positions.count else { return nil }
                defer { asked[positions[index]].wake = nil }
                return asked[positions[index]].wake
            }
            wake?.resume()
        }

        /// Ends every sleep still under way.
        func endAll() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { for index in asked.indices { asked[index].wake = nil } }
                return asked.compactMap(\.wake)
            }
            for wake in all { wake.resume() }
        }
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
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

    /// Paused when the hold began, and the pause's end came during it: the
    /// start that waited is carried out when the hold ends.
    func testAStartThatWaitedForTheHoldIsCarriedOutAtItsEnd() async {
        let target = Target()
        target.isRememberingForHold = false
        let hold = CaptureHold(target: target)
        _ = await hold.hold()
        target.startWaitingForHold = true
        await hold.release()
        XCTAssertEqual(target.restarts, 1)
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
        // The 30 seconds start once the lease is free; then they pass.
        await until { gate.count == 1 }
        gate.open()
        for _ in 0..<100 where hold.isHolding {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1)
        XCTAssertEqual(CaptureHold.limit, .seconds(30))
        XCTAssertEqual(CaptureHold.stopWait, .seconds(10))
    }

    /// The window's 30 seconds are for deleting: they start once remembering
    /// has stopped and the writer lease is free, never while it stops.
    func testTheThirtySecondsStartOnceTheLeaseIsFree() async {
        let sleeps = Sleeps()
        let target = Target()
        target.stopTakes = .milliseconds(300)
        var startedWhileStopping = -1
        target.stopEnding = { startedWhileStopping = sleeps.count(CaptureHold.limit) }
        let hold = CaptureHold(target: target, sleep: { await sleeps.sleep($0) })
        let held = await hold.hold()
        XCTAssertTrue(held)
        XCTAssertEqual(startedWhileStopping, 0, "the 30 seconds ran while remembering was still stopping")
        await until { sleeps.count(CaptureHold.limit) == 1 }
        XCTAssertEqual(sleeps.count(CaptureHold.limit), 1, "they start once the lease is free")
        XCTAssertTrue(hold.isHolding)
        sleeps.endAll()
    }

    /// While the window still deletes it renews the hold: each renewal moves
    /// the end 30 seconds out, and a hold the window stops renewing ends 30
    /// seconds after the last one.
    func testARenewalMovesTheEndThirtySecondsOut() async throws {
        let sleeps = Sleeps()
        let target = Target()
        let hold = CaptureHold(target: target, sleep: { await sleeps.sleep($0) })
        _ = await hold.hold()
        await until { sleeps.count(CaptureHold.limit) == 1 }
        XCTAssertTrue(hold.renew())
        await until { sleeps.count(CaptureHold.limit) == 2 }

        // The first 30 seconds pass: the renewal stands.
        sleeps.end(CaptureHold.limit, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(hold.isHolding, "the hold ended though the window renewed it")
        XCTAssertEqual(target.restarts, 0)

        // 30 seconds with no word from the window: the hold ends.
        sleeps.end(CaptureHold.limit, 1)
        await until { !hold.isHolding }
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1, "remembering comes back")
        sleeps.endAll()
    }

    func testOnlyAHoldCanBeRenewed() async {
        let hold = CaptureHold(target: Target())
        XCTAssertFalse(hold.renew(), "nothing is held")
        _ = await hold.hold()
        XCTAssertTrue(hold.renew())
        await hold.release()
        XCTAssertFalse(hold.renew(), "a released hold isn't taken again")
        XCTAssertFalse(hold.isHolding)
    }

    /// A window that hangs while its timer still renews never keeps
    /// remembering still for more than 10 minutes.
    func testAHoldNeverLastsLongerThanTenMinutesHoweverOftenItIsRenewed() async {
        let sleeps = Sleeps()
        let target = Target()
        let hold = CaptureHold(target: target, sleep: { await sleeps.sleep($0) })
        _ = await hold.hold()
        await until { sleeps.count(CaptureHold.longest) == 1 && sleeps.count(CaptureHold.limit) == 1 }
        XCTAssertTrue(hold.renew())
        sleeps.end(CaptureHold.longest, 0)
        await until { !hold.isHolding }
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1)
        XCTAssertFalse(hold.renew())
        XCTAssertEqual(CaptureHold.longest, .seconds(600))
        sleeps.endAll()
    }

    /// The app's own pass (Delete Everything, Forget Pictures of Other
    /// Windows… now) holds by itself: no 30 seconds run out under it, the
    /// window's end and the window's release don't end it, and only the
    /// app's release, or the 10 minutes, do.
    func testTheAppsOwnHoldEndsOnlyWithTheAppsReleaseOrTheTenMinutes() async throws {
        let sleeps = Sleeps()
        let target = Target()
        let hold = CaptureHold(target: target, sleep: { await sleeps.sleep($0) })
        let held = await hold.hold(by: .app)
        XCTAssertTrue(held)
        XCTAssertEqual(hold.holder, .app)
        await until { sleeps.count(CaptureHold.longest) == 1 }
        XCTAssertEqual(target.stops, 1, "remembering stopped")
        XCTAssertTrue(hold.renew(), "a renewal is answered")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sleeps.count(CaptureHold.limit), 0, "no 30 seconds run, even after a renewal")

        await hold.windowEnded()
        await hold.release()
        XCTAssertTrue(hold.isHolding, "the window neither ends nor releases the app's pass")
        let windowsOwn = await hold.hold()
        XCTAssertFalse(windowsOwn, "nor takes a hold of its own meanwhile")
        XCTAssertEqual(target.restarts, 0)

        await hold.release(by: .app)
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1, "remembering comes back once the app is done")

        // The cap still holds for the app's own pass.
        let capped = await hold.hold(by: .app)
        XCTAssertTrue(capped)
        await until { sleeps.count(CaptureHold.longest) == 2 }
        sleeps.end(CaptureHold.longest, 1)
        await until { !hold.isHolding }
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 2)
        sleeps.endAll()
    }

    /// The app never releases a window's hold by mistake, and a window's hold
    /// is the window's as before.
    func testTheAppsReleaseNeverEndsTheWindowsHold() async {
        let target = Target()
        let hold = CaptureHold(target: target)
        _ = await hold.hold()
        XCTAssertEqual(hold.holder, .window)
        await hold.release(by: .app)
        XCTAssertTrue(hold.isHolding)
        await hold.windowEnded()
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(target.restarts, 1)
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
