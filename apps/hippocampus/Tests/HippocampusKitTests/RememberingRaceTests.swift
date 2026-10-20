// SPDX-License-Identifier: Apache-2.0
//
// Remembering, when two things happen at once: leaving Demo Memory from the
// window, a timed pause that ends while Demo Memory is in use, and a start
// that comes while a forget holds remembering still. On the real
// ProcessSupervisor with fake processes, a moved clock and a synthetic home.
// Nothing here launches, signals or reads anything real.

import Combine
import Foundation
import XCTest
@testable import HippocampusKit

@MainActor
final class RememberingRaceTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// The real host's answers, except that the window and Ask's sessions
    /// are only recorded, never looked for or ended.
    private final class RecordingHost: DemoMemoryHost {
        let real: SupervisorDemoMemoryHost
        private(set) var readerRestarts: [Bool] = []
        init(real: SupervisorDemoMemoryHost) { self.real = real }
        var isPaused: Bool { real.isPaused }
        var pausedUntil: Date? { real.pausedUntil }
        var isQuiet: Bool { real.isQuiet }
        var isConnectingAITools: Bool { false }
        func pauseRemembering() async throws { try await real.pauseRemembering() }
        func pauseRemembering(until end: Date) { real.pauseRemembering(until: end) }
        func resumeRemembering() { real.resumeRemembering() }
        func restartReaders(openWindow: Bool) async { readerRestarts.append(openWindow) }
        func watchRemembering(_ change: @escaping @MainActor () -> Void) -> AnyCancellable {
            real.watchRemembering(change)
        }
        func confirmUse() async -> Bool { true }
        func report(_ message: String) {}
    }

    /// 2:41 PM on Monday, Oct 12, 2026.
    private let start = Date(timeIntervalSince1970: 1_791_841_260)

    private func supervisor(pauses: UserPauseController, clock: Clock, captureEnabled: Bool = true,
                            topology: FakeSupervisorTopology = FakeSupervisorTopology(),
                            memoryOnDisk: Bool = false) -> ProcessSupervisor {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        return ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: captureEnabled),
            topology: topology, keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: pauses, clock: { clock.now },
            memoryOnDisk: { memoryOnDisk },
            // The timed resume's wait: real time does not pass; the test
            // moves the clock.
            timedResumeSleep: { _ in try await Task.sleep(for: .milliseconds(5)) }
        )
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("remembering-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support/Hippocampus", isDirectory: true),
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func demo(_ supervisor: ProcessSupervisor, home: URL, clock: Clock)
        -> (DemoMemoryController, RecordingHost) {
        let host = RecordingHost(real: SupervisorDemoMemoryHost(
            supervisor: supervisor, locator: BundleBinaryLocator(bundle: Bundle(for: Self.self))))
        let controller = DemoMemoryController(host: host, maker: FakeDemoMaker(), folder: .standard(home: home),
                                              home: home, now: { clock.now },
                                              timeZone: { TimeZone(secondsFromGMT: -7 * 3600)! })
        DemoMemory.attach(controller)
        return (controller, host)
    }

    private let leave = WindowChannelRequest(id: "leave-demo", op: .leaveDemo)

    // MARK: Leave Demo Memory, from the window

    /// The window's Leave Demo Memory (its footer and status menu) is the
    /// menu bar's own Leave. With remembering turned off before Demo Memory
    /// the row offers Turn On, and a Resume would be refused: the Leave is
    /// still carried out, and remembering is off again afterwards.
    func testLeaveDemoMemoryFromTheWindowWorksWhenRememberingWasOff() async throws {
        let home = try makeHome()
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock, captureEnabled: false)
        try await supervisor.startAndWaitForReadiness()
        let (controller, _) = demo(supervisor, home: home, clock: clock)
        defer { DemoMemory.detach() }
        let used = await controller.use()
        XCTAssertTrue(used)
        XCTAssertEqual(controller.phase, .on)
        let row = supervisor.menuRow(setupFinished: true)
        XCTAssertTrue(WindowChannelPolicy.allows(leave, row: row, holding: supervisor.forgetHold.isHolding,
                                                 demoMemory: true),
                      "the app refuses the window's Leave Demo Memory: its row is \(row.title), "
                          + "\(String(describing: row.action))")
        let handled = await supervisor.handleWindowRequest(leave, setupFinished: true)
        XCTAssertTrue(handled)
        await eventually { controller.phase == .off && supervisor.state == .running }
        XCTAssertEqual(controller.phase, .off, "the window's Leave Demo Memory left nothing")
        XCTAssertFalse(pauses.isPaused, "remembering is as it was: off, never paused")
        XCTAssertFalse(supervisor.captureEnabled)
        try await supervisor.shutdownAndWait()
    }

    /// The menu's Leave Demo Memory keeps a pause the person made before
    /// Demo Memory (DemoMemorySwitchingTests.testAPauseThePersonMadeStaysAfterLeaving);
    /// so does the window's.
    func testLeaveDemoMemoryFromTheWindowKeepsAPauseThePersonMade() async throws {
        let home = try makeHome()
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock)
        try await supervisor.startAndWaitForReadiness()
        supervisor.pause(until: nil)
        await eventually { supervisor.state == .paused }
        let (controller, _) = demo(supervisor, home: home, clock: clock)
        defer { DemoMemory.detach() }
        let used = await controller.use()
        XCTAssertTrue(used)
        XCTAssertTrue(WindowChannelPolicy.allows(leave, row: supervisor.menuRow(setupFinished: true), holding: false,
                                                 demoMemory: true))
        let handled = await supervisor.handleWindowRequest(leave, setupFinished: true)
        XCTAssertTrue(handled)
        await eventually { controller.phase == .off }
        XCTAssertEqual(controller.phase, .off)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(pauses.isPaused, "leaving Demo Memory from the window took back the pause the person made")
        XCTAssertEqual(pauses.pausedSince, start, "the person's own pause, with its own time")
        XCTAssertEqual(supervisor.state, .paused, "remembering started although the person had paused")
        try await supervisor.shutdownAndWait()
    }

    /// Remembering was on before Demo Memory: the window's Leave turns it
    /// back on, as the menu's does.
    func testLeaveDemoMemoryFromTheWindowTurnsRememberingBackOnWhenItWasOn() async throws {
        let home = try makeHome()
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock)
        try await supervisor.startAndWaitForReadiness()
        let (controller, _) = demo(supervisor, home: home, clock: clock)
        defer { DemoMemory.detach() }
        let used = await controller.use()
        XCTAssertTrue(used)
        XCTAssertEqual(supervisor.state, .paused, "remembering is off while Demo Memory is in use")
        let handled = await supervisor.handleWindowRequest(leave, setupFinished: true)
        XCTAssertTrue(handled)
        await eventually { controller.phase == .off && supervisor.state == .running }
        XCTAssertEqual(controller.phase, .off)
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(pauses.isPaused)
        try await supervisor.shutdownAndWait()
    }

    // MARK: A timed pause while Demo Memory is in use

    /// SPEC-DELTA 6: "While in demo mode, remembering is off." The person
    /// paused For 1 Hour (say, before filming), then chose Use Demo Memory.
    /// When the hour ends, remembering must not start by itself: that would
    /// end Demo Memory and reopen the window on the person's own memory,
    /// mid-take.
    func testATimedPauseEndingWhileDemoMemoryIsInUseKeepsDemoMemory() async throws {
        let home = try makeHome()
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock)
        try await supervisor.startAndWaitForReadiness()
        supervisor.pause(until: start.addingTimeInterval(3_600))
        await eventually { supervisor.state == .paused }
        XCTAssertEqual(supervisor.state, .paused)

        let (controller, host) = demo(supervisor, home: home, clock: clock)
        defer { DemoMemory.detach() }
        let used = await controller.use()
        XCTAssertTrue(used)
        XCTAssertEqual(controller.phase, .on)
        XCTAssertEqual(host.readerRestarts, [true], "the window opened on the made-up week")

        // The hour runs out while the demo is on screen.
        clock.now = start.addingTimeInterval(3_601)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(controller.phase, .on, "Demo Memory ended by itself when a pause made before it ran out")
        XCTAssertEqual(host.readerRestarts, [true],
                       "the window was reopened on the person's own memory: \(host.readerRestarts)")
        XCTAssertEqual(supervisor.state, .paused, "remembering turned on while Demo Memory was in use")
        try await supervisor.shutdownAndWait()
    }

    /// Demo Memory's pause takes the place of a timed one: nothing is due to
    /// resume on its own while the week is in use.
    func testDemoMemorysPauseReplacesATimedPause() async throws {
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock)
        supervisor.showForPreview(state: .paused, captureEnabled: true, receipt: nil, startedAt: nil)
        supervisor.pause(until: start.addingTimeInterval(3_600))
        XCTAssertNotNil(supervisor.pausedUntil)
        let host = SupervisorDemoMemoryHost(supervisor: supervisor, pauseWait: .seconds(1))
        try await host.pauseRemembering()
        XCTAssertNil(supervisor.pausedUntil,
                     "while Demo Memory is in use remembering is still due to resume on its own at the hour's end")
        XCTAssertEqual(supervisor.pausedSince, start, "the person's pause keeps its own time")
    }

    /// Leaving before the hour is up puts the person's timed pause back,
    /// with its end, and remembering then resumes on time.
    func testLeavingPutsBackATimedPauseWithItsEnd() async throws {
        let home = try makeHome()
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock)
        try await supervisor.startAndWaitForReadiness()
        let end = start.addingTimeInterval(3_600)
        supervisor.pause(until: end)
        await eventually { supervisor.state == .paused }
        let (controller, _) = demo(supervisor, home: home, clock: clock)
        defer { DemoMemory.detach() }
        let used = await controller.use()
        XCTAssertTrue(used)
        XCTAssertEqual(DemoMemoryFolder.standard(home: home).readInUse()?.pausedUntil, end,
                       "kept beside the week, so a relaunch after a crash puts it back too")

        clock.now = start.addingTimeInterval(600)
        let handled = await supervisor.handleWindowRequest(leave, setupFinished: true)
        XCTAssertTrue(handled)
        await eventually { controller.phase == .off }
        XCTAssertEqual(supervisor.pausedUntil, end, "the person's own pause, with its own end")
        XCTAssertEqual(pauses.pausedSince, start)
        XCTAssertEqual(supervisor.state, .paused)

        // The hour ends: remembering resumes by itself, as it would have.
        clock.now = end.addingTimeInterval(1)
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(pauses.isPaused)
        try await supervisor.shutdownAndWait()
    }

    /// Leaving after the hour would have ended turns remembering on, as the
    /// timed pause would have.
    func testLeavingAfterATimedPauseWouldHaveEndedTurnsRememberingOn() async throws {
        let home = try makeHome()
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock)
        try await supervisor.startAndWaitForReadiness()
        supervisor.pause(until: start.addingTimeInterval(3_600))
        await eventually { supervisor.state == .paused }
        let (controller, _) = demo(supervisor, home: home, clock: clock)
        defer { DemoMemory.detach() }
        let used = await controller.use()
        XCTAssertTrue(used)

        clock.now = start.addingTimeInterval(2 * 3_600)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.phase, .on)
        controller.requestLeave()
        await eventually { controller.phase == .off && supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(pauses.isPaused)
        XCTAssertNil(supervisor.pausedUntil)
        try await supervisor.shutdownAndWait()
    }

    /// Without Demo Memory in use the window's Leave is refused and changes
    /// nothing: it is never a Resume.
    func testLeaveDemoMemoryFromTheWindowIsRefusedWhenItIsNotInUse() async throws {
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock)
        try await supervisor.startAndWaitForReadiness()
        supervisor.pause(until: nil)
        await eventually { supervisor.state == .paused }
        let refused = await supervisor.handleWindowRequest(leave, setupFinished: true)
        XCTAssertFalse(refused, "nothing attached")
        let (controller, _) = demo(supervisor, home: try makeHome(), clock: clock)
        defer { DemoMemory.detach() }
        XCTAssertEqual(controller.phase, .off)
        let stillRefused = await supervisor.handleWindowRequest(leave, setupFinished: true)
        XCTAssertFalse(stillRefused, "attached, but not in use")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(pauses.isPaused)
        XCTAssertEqual(supervisor.state, .paused)
        try await supervisor.shutdownAndWait()
    }

    // MARK: A start while a forget holds remembering still

    /// A wait a test ends by hand; once opened it stays open.
    private final class Latch: @unchecked Sendable {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if open { return true }
                    waiting.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        var waiters: Int { lock.withLock { waiting.count } }

        func release() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                open = true
                defer { waiting = [] }
                return waiting
            }
            for continuation in all { continuation.resume() }
        }
    }

    /// The launch's sweep, held open until the test ends it.
    private struct LatchedSweep: CaptureOrphanSweeping {
        let latch: Latch

        func run(_ moment: CaptureOrphanSweep.Moment,
                 liveChildren: (@Sendable () async -> Set<pid_t>)?) async -> CaptureOrphanSweep.Outcome {
            if moment == .launch { await latch.wait() }
            return CaptureOrphanSweep.Outcome()
        }
    }

    /// SPEC 3.11: while the window holds remembering still to forget, the
    /// writer lease stays free until `release`. A timed pause that ends
    /// during the hold waits for its end, then resumes, as it would have.
    func testATimedPauseEndingDuringAHoldDoesNotStartRememberingMidForget() async throws {
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let topology = FakeSupervisorTopology()
        let supervisor = supervisor(pauses: pauses, clock: clock, topology: topology)
        try await supervisor.startAndWaitForReadiness()
        supervisor.pause(until: start.addingTimeInterval(3_600))
        await eventually { supervisor.state == .paused }

        // The window's hold: paused, so it is answered at once.
        let held = await supervisor.forgetHold.hold()
        XCTAssertTrue(held)
        XCTAssertEqual(supervisor.menuRow(setupFinished: true), .forgetting)
        let launches = topology.launchPlans.count

        // The hour ends while the window is still deleting.
        clock.now = start.addingTimeInterval(3_601)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertTrue(supervisor.forgetHold.isHolding, "the window has not released yet")
        XCTAssertEqual(supervisor.state, .paused,
                       "remembering started under an active hold (state \(supervisor.state)): the agent takes the writer lease the window deletes under")
        XCTAssertEqual(topology.launchPlans.count, launches, "nothing started under the hold")

        // The forget is done: the pause's end, which came meanwhile, is
        // carried out now.
        await supervisor.forgetHold.release()
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(pauses.isPaused)
        XCTAssertFalse(supervisor.startWaitingForHold)
        try await supervisor.shutdownAndWait()
    }

    /// The window can open, and finish a forget a crash left, while the
    /// launch's sweep still ends a writer that crash left behind. The hold
    /// waits for the sweep, the launch's start waits for the hold, and
    /// remembering starts once the window releases it.
    func testTheLaunchsStartWaitsForAForgetAskedForDuringTheSweep() async throws {
        let clock = Clock(start)
        let latch = Latch()
        let topology = FakeSupervisorTopology()
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: topology, keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: UserPauseController(clock: { clock.now }),
            orphanSweeper: LatchedSweep(latch: latch), clock: { clock.now })
        // The app's launch: the sweep, then the start.
        let launch = Task { @MainActor in
            await supervisor.sweepOrphans(.launch)
            supervisor.start()
        }
        await eventually { latch.waiters == 1 }

        let holding = Task { @MainActor in await supervisor.forgetHold.hold() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(supervisor.holdingForForget)
        XCTAssertTrue(supervisor.isRememberingForHold, "a start follows the sweep")

        latch.release()
        await launch.value
        let held = await holding.value
        XCTAssertTrue(held, "the sweep is done and nothing started: the lease is free")
        XCTAssertTrue(topology.launchPlans.isEmpty, "the launch's start ran under the hold")
        XCTAssertTrue(supervisor.startWaitingForHold)
        XCTAssertEqual(supervisor.menuBarStatus, .starting, "a start is coming: the icon never says Off")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(topology.launchPlans.isEmpty)

        await supervisor.forgetHold.release()
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running, "the launch's start, carried out at the hold's end")
        XCTAssertEqual(topology.launchPlans.count, 1)
        try await supervisor.shutdownAndWait()
    }

    /// A start asked for a moment before the hold, not yet under way, is
    /// remembering for the hold: it waits for the hold's end, never runs in
    /// its middle.
    func testAStartAskedForJustBeforeAHoldWaitsForItsEnd() async throws {
        let clock = Clock(start)
        let topology = FakeSupervisorTopology()
        let supervisor = supervisor(pauses: UserPauseController(clock: { clock.now }), clock: clock,
                                    topology: topology)
        supervisor.start()
        let held = await supervisor.forgetHold.hold()
        XCTAssertTrue(held)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(topology.launchPlans.isEmpty, "the start ran under the hold")
        XCTAssertNotEqual(supervisor.state, .running)

        await supervisor.forgetHold.release()
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    /// Turn On during a forget (Preferences, setup's end) waits for the
    /// hold's end, then turns remembering on.
    func testTurnOnDuringAHoldWaitsForItsEnd() async throws {
        let clock = Clock(start)
        let topology = FakeSupervisorTopology()
        let supervisor = supervisor(pauses: UserPauseController(clock: { clock.now }), clock: clock,
                                    captureEnabled: false, topology: topology)
        try await supervisor.applyCaptureEnabled(false)
        XCTAssertEqual(supervisor.state, .stopped)
        let held = await supervisor.forgetHold.hold()
        XCTAssertTrue(held)

        supervisor.turnOn()
        try await supervisor.applyCaptureEnabled(true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(topology.launchPlans.isEmpty, "remembering turned on under the hold")
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertTrue(supervisor.turningOn, "the press waits; it isn't dropped")

        await supervisor.forgetHold.release()
        await eventually { supervisor.captureEnabled && supervisor.state == .running }
        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    /// A run that ended retries on its own; a retry that comes due during
    /// a forget waits for the hold's end.
    func testARetryDuringAHoldWaitsForItsEnd() async throws {
        let clock = Clock(start)
        let latch = Latch()
        let topology = FakeSupervisorTopology()
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: topology, keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            retrySleep: { _ in await latch.wait() },
            captureStatusReader: { (nil, nil) }, pauses: UserPauseController(clock: { clock.now }),
            clock: { clock.now })
        try await supervisor.startAndWaitForReadiness()
        topology.fireUnexpectedExit(forLaunchAt: 0)
        guard case .crashed = supervisor.state else { return XCTFail("the run ended: \(supervisor.state)") }

        let held = await supervisor.forgetHold.hold()
        XCTAssertTrue(held, "nothing runs: the lease is free")
        latch.release()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(topology.launchPlans.count, 1, "a retry started remembering under the hold")

        await supervisor.forgetHold.release()
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running, "the retry, carried out at the hold's end")
        XCTAssertEqual(topology.launchPlans.count, 2)
        try await supervisor.shutdownAndWait()
    }

    /// A forget right after Pause, while the pause still stops the helper
    /// and agent: the hold waits for the pause to finish, then is granted
    /// with the writer lease free, instead of "Couldn't forget it". The
    /// person's pause stands after.
    func testAForgetJustAfterPauseWaitsForThePauseToFinish() async throws {
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let topology = FakeSupervisorTopology()
        let supervisor = supervisor(pauses: pauses, clock: clock, topology: topology)
        try await supervisor.startAndWaitForReadiness()
        topology.stopDelay = .milliseconds(400)
        supervisor.setPaused(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(supervisor.state, .running, "the pause is still stopping")

        let held = await supervisor.forgetHold.hold()

        XCTAssertTrue(held, "the hold was refused while a pause was under way")
        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertFalse(topology.isRunning, "the lease is free")
        await supervisor.forgetHold.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(supervisor.state, .paused, "the person's pause stands")
        XCTAssertTrue(pauses.isPaused)
        try await supervisor.shutdownAndWait()
    }

    // MARK: Forgetting pictures of other windows while Demo Memory is in use

    @MainActor
    private final class Seen {
        var environment: [String: String]?
    }

    /// Forget Pictures of Other Windows… in Preferences is about the
    /// person's own memory. While Demo Memory is in use remembering is
    /// paused, so the app's one-shot pass carries it out, and it opens the
    /// person's own memory, never the made-up week, whose children get the
    /// week.
    func testForgettingPicturesDuringDemoMemoryOpensThePersonsOwnMemory() async throws {
        let home = try makeHome()
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock, memoryOnDisk: true)
        try await supervisor.startAndWaitForReadiness()
        let (controller, _) = demo(supervisor, home: home, clock: clock)
        defer { DemoMemory.detach() }
        let used = await controller.use()
        XCTAssertTrue(used)
        XCTAssertEqual(supervisor.sanitizedChildEnvironment()["MCI_DB_PATH"], controller.folder.database.path,
                       "the window and Ask read the week")

        let seen = Seen()
        supervisor.sidePicturesPass = { _, _, environment in
            seen.environment = environment
            return true
        }
        let finished = await supervisor.forgetSidePicturesNow()

        XCTAssertTrue(finished)
        XCTAssertEqual(seen.environment?["MCI_DB_PATH"], supervisor.dbPath.path, "the person's own memory")
        XCTAssertNil(seen.environment?["MCI_DEMO_MEMORY"])
        XCTAssertNil(seen.environment?["MCI_DB_KEY_FILE"], "never the week's key")
        XCTAssertEqual(controller.phase, .on, "Demo Memory stays in use")
        XCTAssertEqual(supervisor.state, .paused)
        try await supervisor.shutdownAndWait()
    }
}
