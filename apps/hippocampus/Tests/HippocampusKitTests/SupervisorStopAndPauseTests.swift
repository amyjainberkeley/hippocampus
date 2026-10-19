// SPDX-License-Identifier: Apache-2.0
//
// The supervisor's side of a status that tells the truth (spec-shell S5,
// RULINGS S5, S8 and S10, critique-shell-engineering 5 and 6): Stop Sharing
// is remembered and the next launch stays off; a pause and its time outlive a
// relaunch and turning on ends it; opening the app shows the window when
// remembering is off; a failed stop says so until the next committed change;
// Try Again restarts at once; a skip shows only once it has held.

import XCTest
@testable import HippocampusKit

final class RecordingStopNote: CaptureStopNoting, @unchecked Sendable {
    var stoppedSharingAt: Date?
    private(set) var records: [Date] = []
    private(set) var clears = 0

    init(_ date: Date? = nil) { stoppedSharingAt = date }

    func record(_ date: Date) {
        records.append(date)
        stoppedSharingAt = date
    }

    func clear() {
        clears += 1
        stoppedSharingAt = nil
    }
}

/// A settings file with a known modification time.
final class DatedRuntimeConfig: RuntimeConfiguring, @unchecked Sendable {
    var captureEnabled: Bool
    var crashReportOptedIn = false
    var modifiedAt: Date?
    var captureWriteError: Error?
    private(set) var captureWrites: [Bool] = []

    init(captureEnabled: Bool, modifiedAt: Date?) {
        self.captureEnabled = captureEnabled
        self.modifiedAt = modifiedAt
    }

    func setCaptureEnabled(_ value: Bool) throws {
        captureWrites.append(value)
        if let captureWriteError { throw captureWriteError }
        captureEnabled = value
    }

    func setCrashReportOptedIn(_ value: Bool) throws { crashReportOptedIn = value }
}

/// What the agent's receipt says, changed by a test as time goes on.
@MainActor
final class ReceiptSource {
    var saved: Date
    var reason: String?
    let clock: TestClock

    init(clock: TestClock, saved: Date, reason: String?) {
        self.clock = clock
        self.saved = saved
        self.reason = reason
    }

    var receipt: CaptureStatusReceipt? {
        let formatter = ISO8601DateFormatter()
        let json: [String: Any] = [
            "schema_version": 1, "updated_at": formatter.string(from: clock.now),
            "stored_frame_count": 3, "stored_screenshot_count": 3,
            "last_stored_frame_at": formatter.string(from: saved),
            "suppression_reason": reason as Any,
        ]
        return try? CaptureStatusReceipt.decode(JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor
final class SupervisorStopAndPauseTests: XCTestCase {
    private enum TestError: LocalizedError {
        case writeFailed, stopFailed, denied
        var errorDescription: String? { String(describing: self) }
    }

    private let clock = TestClock()
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("supervisor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func make(
        config: any RuntimeConfiguring,
        note: any CaptureStopNoting = NoCaptureStopNote(),
        pauses: UserPauseController = UserPauseController(),
        receipts: ReceiptSource? = nil
    ) -> (ProcessSupervisor, FakeBinaryLocator, FakeSupervisorTopology) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let clock = self.clock
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: config, topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, receipts?.receipt) },
            captureStopNote: note, pauses: pauses, clock: { clock.now }
        )
        return (supervisor, locator, topology)
    }

    /// A stand-in for the window's executable that writes the tab it was
    /// opened on, so a test can see the window open.
    private func watchWindow(_ locator: FakeBinaryLocator) throws -> URL {
        let marker = scratch.appendingPathComponent("opened")
        let script = scratch.appendingPathComponent("recall-ui")
        try "#!/bin/sh\nprintf '%s' \"$MCI_INITIAL_TAB\" > '\(marker.path)'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        locator.recallURL = script
        return marker
    }

    private func openedTab(_ marker: URL, within seconds: TimeInterval = 2) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let tab = try? String(contentsOf: marker, encoding: .utf8) { return tab }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func eventually(_ condition: @MainActor () -> Bool, within seconds: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Stop Sharing (spec-shell S5)

    func test_stop_sharing_is_remembered_with_its_time() async throws {
        let note = RecordingStopNote()
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true), note: note)
        try await supervisor.startAndWaitForReadiness()

        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 82)
        await eventually { supervisor.state == .stopped }

        XCTAssertEqual(supervisor.stoppedSharingAt, clock.now)
        XCTAssertEqual(note.records, [clock.now])
        XCTAssertEqual(supervisor.menuBarStatus, .idle)
        let row = supervisor.statusRow(setupFinished: true, now: clock.now)
        XCTAssertEqual(row.title, "Off")
        XCTAssertTrue(row.detail?.hasPrefix("You stopped it at ") == true, row.detail ?? "nil")
        XCTAssertEqual(row.action, .turnOn)
    }

    func test_stop_sharing_seen_while_starting_is_remembered_too() async throws {
        let note = RecordingStopNote()
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true), note: note)
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(82))]

        try? await supervisor.startAndWaitForReadiness()
        await eventually { supervisor.state == .stopped }

        XCTAssertEqual(note.records, [clock.now])
        XCTAssertEqual(supervisor.stoppedSharingAt, clock.now)
    }

    func test_other_exits_are_not_stop_sharing() async throws {
        let note = RecordingStopNote()
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true), note: note)
        try await supervisor.startAndWaitForReadiness()
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "agent", status: 82)
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 81)
        XCTAssertTrue(note.records.isEmpty)
        XCTAssertNil(supervisor.stoppedSharingAt)
        try await supervisor.shutdownAndWait()
    }

    func test_turning_on_again_forgets_stop_sharing() async throws {
        let note = RecordingStopNote()
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true), note: note)
        try await supervisor.startAndWaitForReadiness()
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 82)
        await eventually { supervisor.state == .stopped }

        try await supervisor.applyCaptureEnabled(true)

        XCTAssertNil(supervisor.stoppedSharingAt)
        XCTAssertNil(note.stoppedSharingAt)
        XCTAssertEqual(note.clears, 1)
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    /// Saving "off" failed when Stop Sharing was pressed and fails again:
    /// the next launch still stays off (D8).
    func test_a_kept_note_keeps_the_next_launch_off_when_saving_off_fails_again() async throws {
        let stopped = clock.now.addingTimeInterval(-3600)
        let config = DatedRuntimeConfig(captureEnabled: true, modifiedAt: stopped.addingTimeInterval(-60))
        config.captureWriteError = TestError.writeFailed
        let (supervisor, _, topology) = make(config: config, note: RecordingStopNote(stopped))

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        supervisor.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(topology.launchPlans.isEmpty, "latched off for this session")
        XCTAssertEqual(supervisor.menuBarStatus, .idle)
        XCTAssertEqual(supervisor.statusRow(setupFinished: true, now: clock.now).action, .turnOn)
    }

    func test_a_kept_note_saves_off_at_the_next_launch_when_it_can() async throws {
        let stopped = clock.now.addingTimeInterval(-3600)
        let config = DatedRuntimeConfig(captureEnabled: true, modifiedAt: stopped.addingTimeInterval(-60))
        let (supervisor, _, topology) = make(config: config, note: RecordingStopNote(stopped))

        XCTAssertFalse(config.captureEnabled)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertNotEqual(supervisor.state, .stopped)
        try await supervisor.startAndWaitForReadiness()
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.launchPlans[0].helperArguments.contains("--capture"))
        XCTAssertEqual(supervisor.stoppedSharingAt, stopped, "the menu still says why it is off")
        try await supervisor.shutdownAndWait()
    }

    /// Remembering was turned on elsewhere after Stop Sharing, so the old
    /// note no longer applies (critique-shell-engineering 13).
    func test_a_note_older_than_the_settings_file_is_dropped() async throws {
        let stopped = clock.now.addingTimeInterval(-3600)
        let note = RecordingStopNote(stopped)
        let config = DatedRuntimeConfig(captureEnabled: true, modifiedAt: stopped.addingTimeInterval(60))
        let (supervisor, _, topology) = make(config: config, note: note)

        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertNil(supervisor.stoppedSharingAt)
        XCTAssertNil(note.stoppedSharingAt)
        XCTAssertEqual(config.captureWrites, [])
        try await supervisor.startAndWaitForReadiness()
        XCTAssertTrue(topology.launchPlans[0].helperArguments.contains("--capture"))
        try await supervisor.shutdownAndWait()
    }

    // MARK: Pause (spec-shell S5, critique-shell-engineering 5)

    /// Pause, then Off, then On used to leave a running capture that said
    /// "Resume" and could not recover from a crash (D10).
    func test_turning_on_ends_a_pause() async throws {
        let pauses = UserPauseController()
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true), pauses: pauses)
        topology.readinessResults = Array(repeating: .success(()), count: 6)
        try await supervisor.startAndWaitForReadiness()
        supervisor.setPaused(true)
        await eventually { supervisor.state == .paused }
        XCTAssertTrue(pauses.isPaused)

        try await supervisor.applyCaptureEnabled(false)
        try await supervisor.applyCaptureEnabled(true)

        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(pauses.isPaused)
        XCTAssertNil(supervisor.pausedSince)
        XCTAssertNotEqual(supervisor.menuBarStatus, .paused)
        let launches = topology.launchPlans.count
        topology.fireUnexpectedExit(forLaunchAt: launches - 1, label: "helper", status: 9)
        await eventually { topology.launchPlans.count > launches }
        XCTAssertGreaterThan(topology.launchPlans.count, launches, "a crash is recovered again")
        try await supervisor.shutdownAndWait()
    }

    func test_a_pause_keeps_its_time_for_the_menu() async throws {
        let pauses = UserPauseController(clock: { Date(timeIntervalSince1970: 1_791_929_040) })
        let (supervisor, _, _) = make(config: FakeRuntimeConfig(captureEnabled: true), pauses: pauses)
        try await supervisor.startAndWaitForReadiness()
        supervisor.setPaused(true)
        await eventually { supervisor.state == .paused }
        XCTAssertEqual(supervisor.pausedSince, Date(timeIntervalSince1970: 1_791_929_040))
        let row = supervisor.statusRow(setupFinished: true, now: clock.now)
        XCTAssertEqual(row.title, "Paused")
        XCTAssertTrue(row.detail?.hasPrefix("Since ") == true, row.detail ?? "nil")
        XCTAssertEqual(row.action, .resume)
        supervisor.setPaused(false)
        await eventually { supervisor.state == .running }
        XCTAssertNil(supervisor.pausedSince)
        try await supervisor.shutdownAndWait()
    }

    /// A launch after a pause goes straight to Paused, launches nothing, and
    /// still shows the window it was asked for.
    func test_a_kept_pause_starts_paused_and_still_shows_the_window() async throws {
        let suite = "ai.hippocampus.tests.supervisor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UserPauseController(defaults: defaults).setPaused(true)

        let (supervisor, locator, topology) = make(
            config: FakeRuntimeConfig(captureEnabled: true), pauses: UserPauseController(defaults: defaults)
        )
        let marker = try watchWindow(locator)
        supervisor.openRecallWhenReady(initialLaunch: true)
        try await supervisor.startAndWaitForReadiness()

        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertTrue(topology.launchPlans.isEmpty)
        let tab = await openedTab(marker)
        XCTAssertEqual(tab, "overview")
    }

    // MARK: The window (spec-shell S5, D9)

    func test_opening_the_app_shows_the_window_when_remembering_is_stopped() async throws {
        let (supervisor, locator, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        let marker = try watchWindow(locator)
        try await supervisor.startAndWaitForReadiness()
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 82)
        await eventually { supervisor.state == .stopped }
        XCTAssertNil(try? String(contentsOf: marker, encoding: .utf8))

        supervisor.openRecallWhenReady()

        let tab = await openedTab(marker)
        XCTAssertEqual(tab, "overview")
    }

    /// A request made while starting is kept, and the window opens the
    /// moment the run commits (critique-shell-engineering 5).
    func test_a_window_asked_for_while_starting_opens_once_running() async throws {
        let (supervisor, locator, _) = make(config: FakeRuntimeConfig(captureEnabled: true))
        let marker = try watchWindow(locator)
        supervisor.openRecallWhenReady(initialLaunch: true)
        XCTAssertNil(try? String(contentsOf: marker, encoding: .utf8))

        try await supervisor.startAndWaitForReadiness()

        let tab = await openedTab(marker)
        XCTAssertEqual(tab, "overview")
        try await supervisor.shutdownAndWait()
    }

    func test_a_window_asked_for_during_quit_never_opens() async throws {
        let (supervisor, locator, _) = make(config: FakeRuntimeConfig(captureEnabled: true))
        let marker = try watchWindow(locator)
        try await supervisor.startAndWaitForReadiness()
        try await supervisor.shutdownAndWait()

        supervisor.openRecallWhenReady()

        let tab = await openedTab(marker, within: 0.4)
        XCTAssertNil(tab)
    }

    /// A start that failed before there was memory to read (here, nothing on
    /// disk yet) cannot show the window: the app shows Preferences, where the
    /// reason and the fix are. With memory to read, the window shows instead
    /// (`SupervisorWindowOpeningTests`).
    func test_a_failed_start_hands_the_request_to_preferences() async throws {
        let (supervisor, locator, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        let marker = try watchWindow(locator)
        var blocked = 0
        supervisor.onPresentationBlocked = { blocked += 1 }
        topology.readinessResults = [.failure(TestError.denied)]

        supervisor.openRecallWhenReady(initialLaunch: true)
        try? await supervisor.startAndWaitForReadiness()

        XCTAssertEqual(blocked, 1)
        supervisor.openRecallWhenReady()
        XCTAssertEqual(blocked, 2, "opening the app again while it is failed shows Preferences again")
        let tab = await openedTab(marker, within: 0.4)
        XCTAssertNil(tab)
    }

    // MARK: Off only once stopped (RULINGS B1 and S7)

    /// Remember my screen, turned off: the setting flips at once, but the
    /// screen may be read until the stop is done, so the icon keeps the
    /// solid dot until then and reaches Off by itself.
    func test_turning_off_keeps_the_solid_dot_until_the_stop_is_done() async throws {
        let receipts = ReceiptSource(clock: clock, saved: clock.now, reason: nil)
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true), receipts: receipts)
        try await supervisor.startAndWaitForReadiness()
        supervisor.refreshCaptureStatus()
        XCTAssertEqual(supervisor.menuBarStatus.markState, .remembering)

        let hung = TestSuspension()
        topology.stopSuspensionOnCall = topology.stopCalls + 1
        topology.stopSuspension = hung
        let turningOff = Task { try await supervisor.applyCaptureEnabled(false) }
        await hung.waitUntilEntered()
        XCTAssertFalse(supervisor.captureEnabled, "the setting is off at once")
        XCTAssertEqual(supervisor.menuBarStatus.markState, .remembering, "the stop is not done")
        XCTAssertNotEqual(supervisor.statusRow(setupFinished: true, now: clock.now).title, "Off")

        hung.resume()
        try await turningOff.value
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(supervisor.menuBarStatus, .idle)
        XCTAssertEqual(supervisor.menuBarStatus.markState, .off)
        try await supervisor.shutdownAndWait()
    }

    // MARK: Couldn't stop (product critique 3, RULINGS S10)

    func test_a_failed_turn_off_says_couldnt_stop_until_the_next_commit() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await supervisor.startAndWaitForReadiness()
        topology.stopResults = [.failure(TestError.stopFailed)]

        try? await supervisor.applyCaptureEnabled(false)

        XCTAssertTrue(supervisor.stopFailed)
        guard case .stopFailed = supervisor.menuBarStatus else {
            return XCTFail("expected Couldn’t stop, got \(supervisor.menuBarStatus)")
        }
        let row = supervisor.statusRow(setupFinished: true, now: clock.now)
        XCTAssertEqual(row.title, "Couldn’t stop")
        XCTAssertEqual(row.detail, "Hippocampus may still be reading the screen.")
        XCTAssertEqual(row.action, .quit)
        // It may still be reading, so the dot stays solid (RULINGS B1).
        XCTAssertEqual(supervisor.menuBarStatus.markState, .remembering)

        try await supervisor.applyCaptureEnabled(true)
        XCTAssertFalse(supervisor.stopFailed, "a committed change ends it")
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    func test_a_failed_pause_says_couldnt_stop() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await supervisor.startAndWaitForReadiness()
        topology.stopResults = [.failure(TestError.stopFailed)]

        try? await supervisor.setPausedAndWait(true)

        XCTAssertTrue(supervisor.stopFailed)
        guard case .stopFailed = supervisor.menuBarStatus else {
            return XCTFail("expected Couldn’t stop, got \(supervisor.menuBarStatus)")
        }
    }

    func test_a_failed_quit_says_couldnt_stop() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await supervisor.startAndWaitForReadiness()
        topology.stopResults = [.failure(TestError.stopFailed)]

        try? await supervisor.shutdownAndWait()

        XCTAssertTrue(supervisor.stopFailed)
        guard case .stopFailed = supervisor.menuBarStatus else {
            return XCTFail("expected Couldn’t stop, got \(supervisor.menuBarStatus)")
        }
    }

    func test_a_failed_start_is_not_a_failed_stop() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        topology.readinessResults = [.failure(TestError.denied)]

        try? await supervisor.startAndWaitForReadiness()

        XCTAssertFalse(supervisor.stopFailed)
        XCTAssertEqual(supervisor.statusRow(setupFinished: true, now: clock.now).title, "Not saving")
        XCTAssertEqual(supervisor.statusRow(setupFinished: true, now: clock.now).action, .tryAgain)
    }

    // MARK: Try Again (spec-shell S2, critique-shell-engineering 6)

    func test_try_again_restarts_now() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        topology.readinessResults = [.failure(TestError.denied), .success(())]
        try? await supervisor.startAndWaitForReadiness()
        XCTAssertEqual(topology.launchPlans.count, 1)

        supervisor.retryNow()

        await eventually { supervisor.state == .running }
        XCTAssertEqual(topology.launchPlans.count, 2)
        try await supervisor.shutdownAndWait()
    }

    /// Try Again stops the run first. When the capture helper will not stop
    /// it may still be reading, so the row says "Couldn’t stop" with Quit,
    /// never "It stopped and couldn’t start again". Wake recovery and the
    /// automatic retries restart the same way.
    func test_try_again_whose_stop_fails_says_couldnt_stop() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await supervisor.startAndWaitForReadiness()
        clock.now = clock.now.addingTimeInterval(120)
        XCTAssertEqual(supervisor.statusRow(setupFinished: true, now: clock.now).action, .tryAgain)
        topology.stopResults = [.failure(TestError.stopFailed)]

        supervisor.performAskStatusAction(.tryAgain, setupFinished: true) { _ in }
        await eventually { if case .crashed = supervisor.state { return true } else { return false } }

        XCTAssertTrue(topology.captureHelperAlive)
        XCTAssertTrue(supervisor.stopFailed)
        let row = supervisor.statusRow(setupFinished: true, now: clock.now)
        XCTAssertEqual(row.title, "Couldn’t stop")
        XCTAssertEqual(row.action, .quit)
        XCTAssertEqual(supervisor.menuBarStatus.markState, .remembering)
        try? await supervisor.shutdownAndWait()
    }

    /// No helper is left to say a permission came back, so Try Again clears
    /// it; the menu opening or the app becoming active looks again on its
    /// own while "Needs permission" shows.
    func test_a_permission_turned_off_with_nothing_running_is_looked_at_again() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        topology.readinessResults = [.success(()), .success(())]
        try await supervisor.startAndWaitForReadiness()
        supervisor.tccRevokedSurface = .screenRecording
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 9)
        guard case .crashed = supervisor.state else { return XCTFail("the helper is gone") }
        XCTAssertEqual(supervisor.menuBarStatus, .needsPermission(.screenRecording))

        supervisor.retryIfPermissionMayBeBack()

        await eventually { supervisor.state == .running }
        XCTAssertNil(supervisor.tccRevokedSurface)
        XCTAssertEqual(topology.launchPlans.count, 2)
        try await supervisor.shutdownAndWait()
    }

    /// A running helper reports the permission coming back by itself.
    func test_the_permission_retry_leaves_a_running_helper_alone() async throws {
        let (supervisor, _, topology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await supervisor.startAndWaitForReadiness()
        supervisor.tccRevokedSurface = .accessibility

        supervisor.retryIfPermissionMayBeBack()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertEqual(supervisor.tccRevokedSurface, .accessibility)
        try await supervisor.shutdownAndWait()
    }

    func test_try_again_never_overrides_stop_sharing_a_pause_or_quit() async throws {
        let (stopped, _, stoppedTopology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await stopped.startAndWaitForReadiness()
        stoppedTopology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 82)
        await eventually { stopped.state == .stopped }
        stopped.retryNow()

        let (paused, _, pausedTopology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await paused.startAndWaitForReadiness()
        try await paused.setPausedAndWait(true)
        paused.setPaused(true)
        paused.retryNow()

        let (quit, _, quitTopology) = make(config: FakeRuntimeConfig(captureEnabled: true))
        try await quit.startAndWaitForReadiness()
        try await quit.shutdownAndWait()
        quit.retryNow()

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stoppedTopology.launchPlans.count, 1)
        XCTAssertEqual(pausedTopology.launchPlans.count, 1)
        XCTAssertEqual(quitTopology.launchPlans.count, 1)
    }

    // MARK: Skipping this window (RULINGS S8)

    /// The preview install on Oct 13 showed Ask's footer "Not saving" with
    /// the h! picture while it was saving: a privacy skip in the receipt
    /// counted as a failure. This is that receipt, a save a few seconds old
    /// and `suppression_reason: denylist-source`, as the agent writes it.
    func test_the_oct_13_receipt_never_reads_not_saving() async throws {
        let start = clock.now
        let clock = self.clock
        let stamp = ISO8601DateFormatter()
        func receipt() -> CaptureStatusReceipt? {
            let json = """
            {"schema_version":1,"updated_at":"\(stamp.string(from: clock.now))",\
            "last_stored_frame_at":"\(stamp.string(from: start.addingTimeInterval(3)))",\
            "stored_frame_count":1862,"stored_screenshot_count":214,\
            "suppression_reason":"denylist-source","blocked_reason":null}
            """
            return try? CaptureStatusReceipt.decode(Data(json.utf8))
        }
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: FakeSupervisorTopology(), keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, receipt()) }, clock: { clock.now }
        )
        try await supervisor.startAndWaitForReadiness()

        var seen: [String] = []
        for seconds in [5, 9, 30, 60] as [TimeInterval] {
            clock.now = start.addingTimeInterval(seconds)
            XCTAssertNotNil(receipt(), "the receipt decodes")
            supervisor.refreshCaptureStatus()
            let footer = supervisor.askPanelStatus(setupFinished: true)
            let row = supervisor.statusRow(setupFinished: true, now: clock.now)
            XCTAssertNotEqual(footer.text, "Not saving", "after \(seconds) s")
            XCTAssertNotEqual(row.title, "Not saving", "after \(seconds) s")
            XCTAssertEqual(footer.mark, .remembering, "the solid dot after \(seconds) s, never h!")
            XCTAssertEqual(supervisor.menuBarStatus.markState, .remembering)
            seen.append(footer.text)
        }
        // Remembering while the skip is young; once it has held with no
        // newer save, "Skipping this window", still with the solid dot.
        XCTAssertEqual(seen, ["On this Mac", "On this Mac", "Skipping this window", "Skipping this window"])
        XCTAssertEqual(supervisor.statusRow(setupFinished: true, now: clock.now).detail, "This window is never read.")
        try await supervisor.shutdownAndWait()
    }

    func test_a_skip_shows_once_the_same_skip_has_held_ten_seconds() async throws {
        let start = clock.now
        let receipts = ReceiptSource(clock: clock, saved: start.addingTimeInterval(2), reason: "private_browsing")
        let (supervisor, _, _) = make(config: FakeRuntimeConfig(captureEnabled: true), receipts: receipts)
        try await supervisor.startAndWaitForReadiness()
        clock.now = start.addingTimeInterval(5)
        supervisor.refreshCaptureStatus()
        XCTAssertEqual(supervisor.menuBarStatus, .recording, "not yet")

        clock.now = start.addingTimeInterval(14)
        supervisor.refreshCaptureStatus()
        XCTAssertEqual(supervisor.menuBarStatus, .recording, "nine seconds is not ten")

        clock.now = start.addingTimeInterval(16)
        supervisor.refreshCaptureStatus()
        XCTAssertEqual(supervisor.menuBarStatus, .skipping(reason: "private_browsing"))

        // A newer save starts the wait again.
        receipts.saved = start.addingTimeInterval(15)
        clock.now = start.addingTimeInterval(17)
        supervisor.refreshCaptureStatus()
        XCTAssertEqual(supervisor.menuBarStatus, .recording)

        // A different skip starts it again too.
        clock.now = start.addingTimeInterval(30)
        supervisor.refreshCaptureStatus()
        XCTAssertEqual(supervisor.menuBarStatus, .skipping(reason: "private_browsing"))
        receipts.reason = "denylist-source"
        clock.now = start.addingTimeInterval(31)
        supervisor.refreshCaptureStatus()
        XCTAssertEqual(supervisor.menuBarStatus, .recording)
        try await supervisor.shutdownAndWait()
    }
}
