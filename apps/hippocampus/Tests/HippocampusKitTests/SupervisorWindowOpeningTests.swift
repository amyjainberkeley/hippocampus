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
    /// made the memory. Nothing reads the person's own status files.
    private func make(captureEnabled: Bool, memoryOnDisk: Bool = true) throws -> Harness {
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
            captureStatusReader: { (nil, nil) }, memoryOnDisk: { memoryOnDisk }
        )
        return Harness(supervisor: supervisor, topology: topology, preparer: preparer, windows: windows)
    }

    /// The places the window was opened on, once at least `count` launches
    /// were seen or `seconds` passed.
    private func opened(_ windows: URL, count: Int = 1, within seconds: TimeInterval = 2) async -> [String] {
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
