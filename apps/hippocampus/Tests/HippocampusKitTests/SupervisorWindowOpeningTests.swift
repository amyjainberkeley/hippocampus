// SPDX-License-Identifier: Apache-2.0
//
// Opening Hippocampus never does nothing (Oct 18). Opening it again shows the
// window at once whatever remembering is doing: on, off in the setting,
// turned off, paused, starting, or after a start that failed, because the
// window reads memory itself and lets the person turn remembering on. Only a
// first run waits, for the agent to make the memory, and a start that failed
// before there was any memory still hands over to Preferences (spec-shell S5,
// D9). A login launch opens nothing (07fedaf). While setup is unfinished,
// opening the app brings setup forward instead of starting a second one.

import XCTest
@testable import HippocampusKit

@MainActor
final class SupervisorWindowOpeningTests: XCTestCase {
    private enum TestError: LocalizedError {
        case denied
        var errorDescription: String? { "denied" }
    }

    private struct Harness {
        let supervisor: ProcessSupervisor
        let topology: FakeSupervisorTopology
        let preparer: FakeKeyCustodyPreparer
        /// One line per launch of the window: the place it opened on.
        let windows: URL
    }

    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("window-opening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A supervisor whose window is a stand-in that writes the place it was
    /// opened on. `memoryOnDisk` false is a first run, before the agent has
    /// made the memory. Nothing reads the person's own status files, and the
    /// orphan sweep, when given, signals nothing.
    private func make(
        captureEnabled: Bool, memoryOnDisk: Bool = true, sweeper: (any CaptureOrphanSweeping)? = nil
    ) throws -> Harness {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let windows = scratch.appendingPathComponent("windows")
        let script = scratch.appendingPathComponent("recall-ui")
        try "#!/bin/sh\nprintf '%s\\n' \"$MCI_INITIAL_TAB\" >> '\(windows.path)'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        locator.recallURL = script
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let preparer = FakeKeyCustodyPreparer()
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: captureEnabled),
            topology: topology, keyCustodyPreparer: preparer, readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, orphanSweeper: sweeper, memoryOnDisk: { memoryOnDisk }
        )
        return Harness(supervisor: supervisor, topology: topology, preparer: preparer, windows: windows)
    }

    /// The places the window was opened on, once at least `count` launches
    /// were seen or `seconds` passed. A stand-in's shell can take a while to
    /// start on a busy machine, so the wait for one to show is generous; a
    /// check that nothing opened passes its own short `seconds`.
    private func opened(_ windows: URL, count: Int = 1, within seconds: TimeInterval = 5) async -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var lines: [String] = []
        repeat {
            lines = ((try? String(contentsOf: windows, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            if lines.count >= count { return lines }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        return lines
    }

    private func eventually(_ condition: @MainActor () -> Bool, within seconds: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Reopen, whatever remembering is doing

    func test_reopen_with_remembering_off_in_the_setting_shows_the_window_at_once() async throws {
        let h = try make(captureEnabled: false)
        try await h.supervisor.startAndWaitForReadiness()
        XCTAssertFalse(h.topology.launchPlans[0].helperArguments.contains("--capture"))

        h.supervisor.reopenWindow()

        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        try await h.supervisor.shutdownAndWait()
    }

    func test_reopen_after_turning_remembering_off_shows_the_window_and_leaves_it_off() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        try await h.supervisor.applyCaptureEnabled(false)
        XCTAssertEqual(h.supervisor.state, .stopped)
        let launches = h.topology.launchPlans.count

        h.supervisor.reopenWindow()

        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.topology.launchPlans.count, launches, "turned off stays off")
        XCTAssertFalse(h.supervisor.captureEnabled)
        XCTAssertEqual(h.supervisor.state, .stopped)
    }

    func test_reopen_with_remembering_on_shows_the_window_at_once() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        XCTAssertTrue(h.topology.launchPlans[0].helperArguments.contains("--capture"))

        h.supervisor.reopenWindow()

        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        XCTAssertEqual(h.topology.launchPlans.count, 1, "nothing restarts while it runs")
        XCTAssertEqual(h.supervisor.state, .running)
        try await h.supervisor.shutdownAndWait()
    }

    func test_reopen_while_paused_shows_the_window_and_keeps_the_pause() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        h.supervisor.setPaused(true)
        await eventually { h.supervisor.state == .paused }

        h.supervisor.reopenWindow()

        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        XCTAssertEqual(h.supervisor.state, .paused)
        XCTAssertEqual(h.topology.launchPlans.count, 1, "a pause is not resumed by opening the app")
    }

    /// A pause whose stop failed says "Couldn’t stop": the helper may still be
    /// reading. Opening the app again shows the window and leaves that as it
    /// is. It used to start, take the kept pause's shortcut to "Paused" (the
    /// off picture) without stopping anything, and end "Couldn’t stop".
    func test_reopen_after_a_pause_that_could_not_stop_still_says_couldnt_stop() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        h.topology.stopResults = [.failure(TestError.denied)]
        h.supervisor.setPaused(true)
        await eventually { h.supervisor.stopFailed }
        XCTAssertTrue(h.supervisor.stopFailed)

        h.supervisor.reopenWindow()

        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        try await Task.sleep(for: .milliseconds(150))
        let row = h.supervisor.statusRow(setupFinished: true)
        XCTAssertEqual(row.title, "Couldn’t stop")
        XCTAssertEqual(row.action, .quit)
        XCTAssertEqual(h.supervisor.menuBarStatus.markState, .remembering)
        XCTAssertNotEqual(h.supervisor.state, .paused)
        XCTAssertTrue(h.topology.captureHelperAlive)
        XCTAssertEqual(h.topology.stopCalls, 1)
        XCTAssertEqual(h.topology.launchPlans.count, 1)
    }

    /// A turn-on whose capture helper would not stop says "Couldn’t stop".
    /// Opening the app again used to start the off topology, and while that
    /// start ran (the key check, the Keychain) the row read "Couldn’t turn
    /// on: It didn’t start, so remembering is still off." with that helper
    /// alive.
    func test_reopen_after_a_turn_on_that_could_not_stop_never_says_still_off() async throws {
        let h = try make(captureEnabled: false)
        try await h.supervisor.startAndWaitForReadiness()
        h.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.readinessTimedOut)]
        h.topology.stopResults = [.success(()), .failure(TestError.denied), .failure(TestError.denied)]
        h.supervisor.turnOn()
        await eventually { !h.supervisor.turningOn }
        XCTAssertEqual(h.supervisor.statusRow(setupFinished: true).title, "Couldn’t stop")
        let keyChecks = h.preparer.calls.count
        let keyCheck = TestSuspension()
        h.preparer.suspension = keyCheck

        h.supervisor.reopenWindow()
        try await Task.sleep(for: .milliseconds(150))

        let row = h.supervisor.statusRow(setupFinished: true)
        XCTAssertEqual(row.title, "Couldn’t stop", "while the helper may read: \(row.title) / \(row.detail ?? "-")")
        XCTAssertEqual(h.supervisor.menuBarStatus.markState, .remembering)
        XCTAssertEqual(h.preparer.calls.count, keyChecks, "nothing starts over a stop that failed")
        XCTAssertTrue(h.topology.captureHelperAlive)
        h.preparer.suspension = nil
        keyCheck.resume()
    }

    /// A kept pause goes straight to Paused, which owns no processes. A run
    /// that ended and left its processes held is stopped first, so Paused
    /// never shows over something that may still be reading.
    func test_a_kept_pause_stops_what_an_ended_run_left_before_it_reads_paused() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        // The helper exits, and Screen Recording is reported off before its
        // retry: no retry, and the exited processes stay held.
        h.topology.isRunning = false
        h.topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 9)
        h.supervisor.tccRevokedSurface = .screenRecording
        guard case .crashed = h.supervisor.state else { return XCTFail("the helper is gone") }
        XCTAssertTrue(h.topology.holdsProcesses)
        h.supervisor.setPaused(true)

        h.supervisor.reopenWindow()

        await eventually { h.supervisor.state == .paused }
        XCTAssertEqual(h.supervisor.state, .paused)
        XCTAssertFalse(h.topology.holdsProcesses, "stopped before Paused")
        XCTAssertEqual(h.topology.stopCalls, 1)
        XCTAssertEqual(h.topology.launchPlans.count, 1)
    }

    /// The window does not wait for the helper: once this launch has checked
    /// the key, it opens while remembering is still starting.
    func test_reopen_while_starting_shows_the_window_before_the_helper_is_ready() async throws {
        let h = try make(captureEnabled: true)
        let readiness = TestSuspension()
        h.topology.readinessSuspension = readiness
        let starting = Task { try await h.supervisor.startAndWaitForReadiness() }
        await readiness.waitUntilEntered()
        XCTAssertEqual(h.supervisor.state, .starting)

        h.supervisor.reopenWindow()

        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        XCTAssertEqual(h.supervisor.state, .starting)
        readiness.resume()
        try await starting.value
        let afterRunning = await opened(h.windows, count: 2, within: 0.3)
        XCTAssertEqual(afterRunning, ["overview"], "running does not open it a second time")
        try await h.supervisor.shutdownAndWait()
    }

    /// A start that failed after the key was checked leaves memory to read:
    /// opening the app shows it, not Preferences, and tries the start again.
    func test_reopen_after_a_failed_start_shows_the_window_not_preferences() async throws {
        let h = try make(captureEnabled: true)
        var blocked = 0
        h.supervisor.onPresentationBlocked = { blocked += 1 }
        h.topology.readinessResults = [.failure(TestError.denied)]
        try? await h.supervisor.startAndWaitForReadiness()
        guard case .crashed = h.supervisor.state else { return XCTFail("the start failed") }

        h.supervisor.reopenWindow()

        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        XCTAssertEqual(blocked, 0)
        await eventually { h.supervisor.state == .running }
        XCTAssertEqual(h.topology.launchPlans.count, 2, "opening the app tries the start again")
        try await h.supervisor.shutdownAndWait()
    }

    /// A start whose capture helper exited during startup left it, and its
    /// agent, held: the reopen's start was refused ("The prior helper
    /// topology did not stop completely") until Try Again stopped first.
    func test_reopen_after_a_start_whose_helper_exited_starts_again() async throws {
        let h = try make(captureEnabled: true)
        h.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        try? await h.supervisor.startAndWaitForReadiness()
        guard case .crashed = h.supervisor.state else { return XCTFail("the start failed") }

        h.supervisor.reopenWindow()

        await eventually { h.supervisor.state == .running }
        XCTAssertEqual(h.supervisor.state, .running)
        XCTAssertEqual(h.topology.refusedLaunches, 0)
        XCTAssertEqual(h.topology.launchPlans.count, 2)
        try await h.supervisor.shutdownAndWait()
    }

    /// The window's process ends with its window, so opening Hippocampus
    /// again starts a fresh one, on Overview.
    func test_a_closed_window_opens_again_on_the_next_reopen() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        h.supervisor.reopenWindow()
        let first = await opened(h.windows)
        XCTAssertEqual(first, ["overview"])
        // The stand-in has ended by now, as the window's process does once
        // its window is closed.
        try await Task.sleep(for: .milliseconds(300))

        h.supervisor.reopenWindow()

        let places = await opened(h.windows, count: 2)
        XCTAssertEqual(places, ["overview", "overview"])
        try await h.supervisor.shutdownAndWait()
    }

    // MARK: Launch

    /// The person's launch opens the window the moment its key is checked,
    /// not after the helper is ready, and never before the key is checked.
    func test_a_launch_opens_the_window_as_soon_as_the_key_is_checked() async throws {
        let h = try make(captureEnabled: true)
        let keyCheck = TestSuspension()
        h.preparer.suspension = keyCheck
        let readiness = TestSuspension()
        h.topology.readinessSuspension = readiness
        h.supervisor.openRecallWhenReady(initialLaunch: true)
        let starting = Task { try await h.supervisor.startAndWaitForReadiness() }
        await keyCheck.waitUntilEntered()

        let beforeTheKey = await opened(h.windows, within: 0.3)
        XCTAssertEqual(beforeTheKey, [], "not before the key is checked")
        keyCheck.resume()
        await readiness.waitUntilEntered()
        let beforeTheHelper = await opened(h.windows)
        XCTAssertEqual(beforeTheHelper, ["overview"])

        readiness.resume()
        try await starting.value
        try await h.supervisor.shutdownAndWait()
    }

    /// A first run has no memory until the agent makes it: the window waits
    /// for remembering to start, so it never opens onto nothing.
    func test_a_first_run_opens_the_window_once_remembering_has_started() async throws {
        let h = try make(captureEnabled: true, memoryOnDisk: false)
        let readiness = TestSuspension()
        h.topology.readinessSuspension = readiness
        h.supervisor.openRecallWhenReady(initialLaunch: true)
        let starting = Task { try await h.supervisor.startAndWaitForReadiness() }
        await readiness.waitUntilEntered()

        let whileStarting = await opened(h.windows, within: 0.3)
        XCTAssertEqual(whileStarting, [])
        readiness.resume()
        try await starting.value
        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        try await h.supervisor.shutdownAndWait()
    }

    /// Setup's Start Remembering, and the window asked for as setup closes,
    /// on a first run: the capture start fails and the off topology comes
    /// back. The failed start used to publish a crash before the rollback,
    /// which ended the request as a failed start and opened Preferences, so
    /// whether the window opened depended on when setup closed.
    func test_a_first_run_window_request_survives_a_turn_on_that_rolls_back() async throws {
        let h = try make(captureEnabled: false, memoryOnDisk: false)
        var blocked = 0
        h.supervisor.onPresentationBlocked = { blocked += 1 }
        let readiness = TestSuspension()
        h.topology.readinessSuspension = readiness
        h.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.readinessTimedOut)]
        let turningOn = Task { try? await h.supervisor.applyCaptureEnabled(true) }
        await readiness.waitUntilEntered()
        h.supervisor.openRecallWhenReady(initialLaunch: true)

        h.topology.readinessSuspension = nil
        readiness.resume()
        await turningOn.value

        let places = await opened(h.windows)
        XCTAssertEqual(blocked, 0)
        XCTAssertEqual(places, ["overview"])
        XCTAssertEqual(h.supervisor.state, .running)
        XCTAssertEqual(h.supervisor.statusRow(setupFinished: true).title, "Couldn’t turn on")
        try await h.supervisor.shutdownAndWait()
    }

    /// A start that failed before there was any memory to read shows
    /// Preferences, where the reason and the fix are (spec-shell S5, D9).
    func test_a_start_that_failed_before_the_key_was_checked_still_shows_preferences() async throws {
        let h = try make(captureEnabled: true)
        h.preparer.error = TestError.denied
        var blocked = 0
        h.supervisor.onPresentationBlocked = { blocked += 1 }

        h.supervisor.openRecallWhenReady(initialLaunch: true)
        try? await h.supervisor.startAndWaitForReadiness()

        XCTAssertEqual(blocked, 1)
        let places = await opened(h.windows, within: 0.3)
        XCTAssertEqual(places, [])
    }

    /// A login launch only starts remembering: the window stays shut, exactly
    /// as the app delegate decides it (07fedaf).
    func test_a_login_launch_starts_remembering_and_opens_nothing() async throws {
        let h = try make(captureEnabled: true)
        let opening = AppOpening.atLaunch(.login, setupFinished: true, hasSetup: true)
        if opening == .window { h.supervisor.openRecallWhenReady(initialLaunch: true) }

        try await h.supervisor.startAndWaitForReadiness()

        XCTAssertEqual(h.supervisor.state, .running)
        let places = await opened(h.windows, within: 0.3)
        XCTAssertEqual(places, [])
        try await h.supervisor.shutdownAndWait()
    }

    /// Opening the app twice quickly, or opening it and pressing Turn On,
    /// asks to start twice before the first start has run. The second
    /// cancelled the first, which then failed with CancellationError: a
    /// brief crash that, on a first run, ended the window request as a
    /// failed start and showed Preferences instead.
    func test_two_starts_in_a_row_start_once_and_keep_the_window_request() async throws {
        let h = try make(captureEnabled: true, memoryOnDisk: false)
        var blocked = 0
        h.supervisor.onPresentationBlocked = { blocked += 1 }
        h.supervisor.openRecallWhenReady(initialLaunch: true)

        h.supervisor.reopenWindow()
        h.supervisor.turnOn()

        await eventually { h.supervisor.state == .running }
        XCTAssertEqual(h.supervisor.state, .running)
        XCTAssertEqual(blocked, 0)
        XCTAssertEqual(h.topology.launchPlans.count, 1)
        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        try await h.supervisor.shutdownAndWait()
    }

    // MARK: The launch's orphan sweep

    /// The launch sweep can wait up to 15 s for an orphaned writer. Opening
    /// the app again meanwhile used to start capture at once, beside what the
    /// sweep was ending; with the writer still holding the memory, the new
    /// agent exited and the launch's own start was refused. Nothing starts
    /// until the sweep is done; the window request waits for the key check.
    func test_reopen_during_the_launch_sweep_starts_nothing_until_it_ends() async throws {
        let gate = SweepGate()
        let h = try make(captureEnabled: true, sweeper: GatedSweeper(gate: gate))
        // As the app delegate does at a person's launch.
        let launch = Task { @MainActor in
            await h.supervisor.sweepOrphans(.launch)
            h.supervisor.openRecallWhenReady(initialLaunch: true)
            h.supervisor.start()
        }
        while !(await gate.hasEntered()) { await Task.yield() }

        h.supervisor.reopenWindow()
        h.supervisor.turnOn()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(h.topology.launchPlans.count, 0, "nothing starts before the sweep ends")
        XCTAssertEqual(h.supervisor.state, .idle)
        let early = await opened(h.windows, within: 0.2)
        XCTAssertEqual(early, [], "the window waits for the key check")

        await gate.release()
        await launch.value
        await eventually { h.supervisor.state == .running }
        XCTAssertEqual(h.supervisor.state, .running)
        XCTAssertEqual(h.topology.launchPlans.count, 1)
        XCTAssertEqual(h.topology.refusedLaunches, 0)
        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"])
        try await h.supervisor.shutdownAndWait()
    }

    /// Turn On during the launch sweep waits for it, and then turns on.
    func test_turn_on_during_the_launch_sweep_waits_for_it() async throws {
        let gate = SweepGate()
        let h = try make(captureEnabled: false, sweeper: GatedSweeper(gate: gate))
        let launch = Task { @MainActor in
            await h.supervisor.sweepOrphans(.launch)
            h.supervisor.start()
        }
        while !(await gate.hasEntered()) { await Task.yield() }

        h.supervisor.turnOn()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(h.supervisor.turningOn, "the press is kept")
        XCTAssertEqual(h.topology.launchPlans.count, 0)

        await gate.release()
        await launch.value
        await eventually { h.supervisor.captureEnabled && !h.supervisor.turningOn }
        XCTAssertTrue(h.supervisor.captureEnabled)
        XCTAssertEqual(h.supervisor.state, .running)
        XCTAssertTrue(h.topology.launchPlans.last?.helperArguments.contains("--capture") == true)
        XCTAssertEqual(h.topology.refusedLaunches, 0)
        try await h.supervisor.shutdownAndWait()
    }

    // MARK: A Restart that stayed open

    /// Preferences' Restart. The verified stop outlasted the coordinator's
    /// bound, so the restart failed ("Couldn’t restart … stayed open") while
    /// the stop was still running, and the quit intent stayed set: once the
    /// stop landed the row read "Off / Turn On", but Turn On returned at its
    /// first guard and opening the app showed nothing, until Quit.
    func test_a_restart_whose_stop_outlasted_its_bound_leaves_turn_on_and_opening_the_app_working() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        let stopping = TestSuspension()
        h.topology.stopSuspensionOnCall = h.topology.stopCalls + 1
        h.topology.stopSuspension = stopping
        var failures = 0
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: h.supervisor, restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 0.05, extrasTimeout: 0.05, cleanup: {}, onFailure: { _ in failures += 1 }
        )

        let restarted = await coordinator.terminate(intent: .restart) { _ in }
        XCTAssertFalse(restarted)
        XCTAssertEqual(failures, 1, "the person saw “Couldn’t restart”")
        stopping.resume()
        await eventually { h.supervisor.state == .stopped }
        XCTAssertFalse(h.supervisor.stopFailed)
        let row = h.supervisor.statusRow(setupFinished: true)
        XCTAssertEqual(row.title, "Off")
        XCTAssertEqual(row.action, .turnOn)

        h.supervisor.performAskStatusAction(.turnOn, setupFinished: true) { _ in }
        await eventually { h.supervisor.state == .running }
        XCTAssertEqual(h.supervisor.state, .running, "Turn On did nothing")
        XCTAssertEqual(h.topology.launchPlans.count, 2)

        h.supervisor.reopenWindow()
        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"], "opening Hippocampus showed nothing")
        try await h.supervisor.shutdownAndWait()
    }

    /// The same Restart whose stop threw: "Couldn’t stop", with Quit, and
    /// nothing starts over it. Opening the app still shows the window, as it
    /// does after a pause that could not stop.
    func test_a_restart_whose_stop_failed_still_opens_the_window_and_starts_nothing() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        h.topology.stopResults = [.failure(TestError.denied)]
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: h.supervisor, restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 0.1, cleanup: {}
        )

        let restarted = await coordinator.terminate(intent: .restart) { _ in }
        XCTAssertFalse(restarted)
        XCTAssertEqual(h.supervisor.statusRow(setupFinished: true).title, "Couldn’t stop")

        h.supervisor.reopenWindow()
        let places = await opened(h.windows)
        XCTAssertEqual(places, ["overview"], "opening Hippocampus showed nothing")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.topology.launchPlans.count, 1, "nothing starts over a stop that failed")
        XCTAssertEqual(h.supervisor.statusRow(setupFinished: true).title, "Couldn’t stop")
    }

    /// Quit or Restart again after a restart that stayed open is a quit
    /// again: nothing starts while it stops, though the first stop is still
    /// the one under way.
    func test_quit_after_a_restart_that_stayed_open_starts_nothing() async throws {
        let h = try make(captureEnabled: true)
        try await h.supervisor.startAndWaitForReadiness()
        let stopping = TestSuspension()
        h.topology.stopSuspensionOnCall = h.topology.stopCalls + 1
        h.topology.stopSuspension = stopping
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: h.supervisor, restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 0.05, extrasTimeout: 0.05, cleanup: {}
        )
        _ = await coordinator.terminate(intent: .restart) { _ in }

        let quit = Task { try await h.supervisor.shutdownAndWait() }
        try await Task.sleep(for: .milliseconds(20))
        stopping.resume()
        try await quit.value
        h.supervisor.start()
        h.supervisor.performAskStatusAction(.turnOn, setupFinished: true) { _ in }
        h.supervisor.reopenWindow()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(h.supervisor.state, .stopped)
        XCTAssertEqual(h.topology.launchPlans.count, 1, "nothing starts while Hippocampus quits")
        let places = await opened(h.windows, within: 0.3)
        XCTAssertEqual(places, [], "no window opens while Hippocampus quits")
    }

    // MARK: Setup

    /// While setup is unfinished, opening the app again brings the setup that
    /// is open forward; a second one never starts beside it.
    func test_unfinished_setup_comes_forward_instead_of_starting_a_second() async throws {
        let started = scratch.appendingPathComponent("setups")
        let script = scratch.appendingPathComponent("onboarding")
        try "#!/bin/sh\nprintf 'started\\n' >> '\(started.path)'\nexec sleep 30\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let locator = FakeBinaryLocator()
        locator.onboardingURL = script
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: FakeKeyStore(), runtimeConfig: FakeRuntimeConfig(captureEnabled: false),
            topology: FakeSupervisorTopology(), keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }
        )
        XCTAssertEqual(AppOpening.atReopen(setupFinished: false, hasSetup: supervisor.hasOnboarding), .setup)

        XCTAssertTrue(supervisor.showOnboarding())
        XCTAssertTrue(supervisor.showOnboarding())

        XCTAssertTrue(supervisor.onboardingIsRunning)
        let first = await opened(started, count: 2, within: 1)
        XCTAssertEqual(first, ["started"], "one setup, brought forward the second time")

        await supervisor.stopWindowsForQuit(timeout: 1)
        XCTAssertFalse(supervisor.onboardingIsRunning)
        XCTAssertTrue(supervisor.showOnboarding(), "once it is closed, opening the app starts setup again")
        let again = await opened(started, count: 2)
        XCTAssertEqual(again, ["started", "started"])
        await supervisor.stopWindowsForQuit(timeout: 1)
    }
}

/// Holds the launch's sweep open, as when it waits out an orphaned writer.
private actor SweepGate {
    private var released = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func hasEntered() -> Bool { entered }
}

/// A sweep that signals nothing: the launch's waits on the gate.
private struct GatedSweeper: CaptureOrphanSweeping {
    let gate: SweepGate

    func run(
        _ moment: CaptureOrphanSweep.Moment,
        liveChildren: (@Sendable () async -> Set<pid_t>)?
    ) async -> CaptureOrphanSweep.Outcome {
        if moment == .launch { await gate.wait() }
        return CaptureOrphanSweep.Outcome()
    }
}
