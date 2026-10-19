// SPDX-License-Identifier: Apache-2.0
//
// Turn On never fails silently. A person pressed Turn On and nothing visible
// happened: the press ran `try? await applyCaptureEnabled(true)`, a failed
// start rolled back to the verified off topology, and the menu read "Off,
// Turn On" again with no reason. A press during another change was dropped,
// and a permission an earlier run reported off made every press fail.
//
// Now Starting… shows while it starts (its helper may read before the setting
// is on), and if it cannot turn on the status says why while remembering
// stays off: a permission macOS has off, with Open System Settings…, or that
// it didn't start, with Try Again. A press during another change waits for it.

import UserNotifications
import XCTest
@testable import HippocampusKit

@MainActor
final class TurnOnTests: XCTestCase {
    private let clock = TestClock()

    private struct Rig {
        let supervisor: ProcessSupervisor
        let topology: FakeSupervisorTopology
        let config: FakeRuntimeConfig
        let consent: FakeCaptureConsentAuthority
    }

    private func rig(
        captureEnabled: Bool = false, receipts: ReceiptSource? = nil,
        custody: FakeKeyCustodyPreparer = FakeKeyCustodyPreparer()
    ) -> Rig {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let config = FakeRuntimeConfig(captureEnabled: captureEnabled)
        let topology = FakeSupervisorTopology()
        let consent = FakeCaptureConsentAuthority()
        let clock = self.clock
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: config, topology: topology,
            keyCustodyPreparer: custody, captureConsentAuthority: consent,
            readinessTimeout: 0.1,
            captureStatusReader: { (nil, receipts?.receipt) },
            clock: { clock.now }
        )
        return Rig(supervisor: supervisor, topology: topology, config: config, consent: consent)
    }

    /// The status row's button, pressed after setup, as the menu does.
    private func press(_ action: CaptureStatusAction, on supervisor: ProcessSupervisor) {
        supervisor.performAskStatusAction(action, setupFinished: true) { _ in }
    }

    private func row(_ supervisor: ProcessSupervisor) -> StatusRow {
        supervisor.statusRow(setupFinished: true, now: clock.now)
    }

    /// Whether macOS has the permission off, as a test changes it.
    private final class PermissionSwitch {
        var off = true
    }

    /// The fresh helper a turn-on starts finds a permission off as it starts,
    /// pauses on it and says so in its readiness receipt, as the real capture
    /// helper does. (Its `helper_health tcc_revoked=…` line on stderr reaches
    /// the tail up to a second later, usually after readiness.)
    private func helperReports(
        _ permission: TCCRevokedReason, to rig: Rig, while setting: PermissionSwitch = PermissionSwitch()
    ) {
        rig.topology.permissionOffInReceipt = { plan in
            setting.off && plan.helperArguments.contains("--capture") ? permission : nil
        }
    }

    private func eventually(
        _ condition: @MainActor () -> Bool, within seconds: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: Turned on

    func test_turn_on_shows_starting_while_it_starts_then_remembering() async throws {
        let receipts = ReceiptSource(clock: clock, saved: clock.now, reason: nil)
        let rig = rig(receipts: receipts)
        try await rig.supervisor.startAndWaitForReadiness()
        XCTAssertEqual(rig.supervisor.menuBarStatus, .idle)
        XCTAssertEqual(row(rig.supervisor).action, .turnOn)
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness

        press(.turnOn, on: rig.supervisor)
        await readiness.waitUntilEntered()

        // Its helper may read before the setting is on: Starting… with the
        // solid dot, never Off (RULINGS B1).
        XCTAssertTrue(rig.topology.launchPlans.last?.helperArguments.contains("--capture") == true)
        XCTAssertFalse(rig.supervisor.captureEnabled, "not on until verified")
        XCTAssertEqual(rig.supervisor.menuBarStatus, .starting)
        XCTAssertEqual(row(rig.supervisor).title, "Starting…")
        XCTAssertEqual(row(rig.supervisor).action, .turnOff, "nothing is on to pause yet, but it can be turned off")
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .remembering)

        rig.topology.readinessSuspension = nil
        readiness.resume()
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertEqual(rig.config.captureWrites, [true])
        XCTAssertEqual(rig.consent.enabledGenerationID, rig.topology.generations.last?.id)
        XCTAssertNil(rig.supervisor.turnOnFailure)

        // The agent's receipt shows a save from this run.
        clock.now = clock.now.addingTimeInterval(5)
        receipts.saved = clock.now
        rig.supervisor.refreshCaptureStatus()
        XCTAssertEqual(rig.supervisor.menuBarStatus, .recording)
        XCTAssertEqual(row(rig.supervisor).title, "Remembering")
        try await rig.supervisor.shutdownAndWait()
    }

    // MARK: A permission is off

    func test_turn_on_with_screen_recording_off_says_so_and_offers_system_settings() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        helperReports(.screenRecording, to: rig)

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        let row = row(rig.supervisor)
        XCTAssertEqual(row.title, "Needs permission")
        XCTAssertEqual(row.detail, "Screen Recording is off for Hippocampus.")
        XCTAssertEqual(row.action, .openSystemSettings(.screenRecording))
        XCTAssertEqual(rig.supervisor.askPanelStatus(setupFinished: true).action, .openSystemSettings(.screenRecording))
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .needsYou)
        // Remembering stayed off: nothing saved, no consent, nothing running.
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [])
        XCTAssertTrue(rig.consent.enabledGenerations.isEmpty)
        XCTAssertFalse(rig.topology.isRunning)

        var opened: [URL] = []
        rig.supervisor.performAskStatusAction(.openSystemSettings(.screenRecording), setupFinished: true) {
            opened.append($0)
        }
        XCTAssertEqual(opened, [URL(string: TCCRevokedReason.screenRecording.settingsPaneURLString)!])
        try await rig.supervisor.shutdownAndWait()
    }

    /// The real pipeline, in the real order: the helper writes its
    /// `tcc_revoked` line and then reports ready at once, and the tail reads
    /// the log once a second. The report used to arrive after the turn-on had
    /// committed: runtime.toml said on, and a capture helper waited on the
    /// permission to start reading by itself. The receipt decides first now.
    func test_turn_on_with_screen_recording_off_stays_off_when_the_report_comes_after_readiness() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("turn-on-tcc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let log = scratch.appendingPathComponent("helper.stderr.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let notifications = RecordingNotificationCenter()
        let tail = TCCHelperStderrTail(
            sink: TCCNotifierAndSupervisorSink(
                notifier: TCCRevokedNotifier(center: notifications), supervisor: rig.supervisor
            ),
            logPath: log
        )
        tail.start()
        defer { tail.stop() }
        helperReports(.screenRecording, to: rig)
        rig.topology.onReadinessWait = { plan in
            guard plan.helperArguments.contains("--capture"), let handle = try? FileHandle(forWritingTo: log) else {
                return
            }
            handle.seekToEndOfFile()
            handle.write(Data("mci-capture-helper: helper_health tcc_revoked=screenRecording\n".utf8))
            try? handle.close()
        }

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [])
        XCTAssertTrue(rig.consent.enabledGenerations.isEmpty)
        XCTAssertFalse(rig.topology.captureHelperAlive, "no helper waits on the permission")
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertEqual(rig.supervisor.turnOnFailure, .permission(.screenRecording))

        // The tail's report lands later and changes nothing. Its notification
        // says what is needed: nothing stopped remembering, it was off.
        await eventually({ notifications.added.count == 1 }, within: 4)
        XCTAssertEqual(notifications.added.first?.content.title, "Hippocampus needs permission")
        XCTAssertEqual(
            notifications.added.first?.content.body, "Screen Recording is off for Hippocampus. Click to open System Settings."
        )
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [])
        XCTAssertFalse(rig.topology.captureHelperAlive)
        XCTAssertEqual(row(rig.supervisor).title, "Needs permission")
        XCTAssertEqual(row(rig.supervisor).action, .openSystemSettings(.screenRecording))
        try await rig.supervisor.shutdownAndWait()
    }

    /// Remembering that starts with every permission withdraws a permission
    /// notification still up: a helper that has the permission never
    /// reports it restored. A start whose helper is paused on one keeps it.
    func test_remembering_that_starts_withdraws_permission_notifications() async throws {
        let rig = rig()
        var started = 0
        rig.supervisor.onRememberingStarted = { started += 1 }
        try await rig.supervisor.startAndWaitForReadiness()
        XCTAssertEqual(started, 0, "remembering is off")
        let screenRecording = PermissionSwitch()
        helperReports(.screenRecording, to: rig, while: screenRecording)
        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }
        XCTAssertEqual(started, 0, "the turn-on found the permission off")

        screenRecording.off = false
        press(.openSystemSettings(.screenRecording), on: rig.supervisor)
        rig.supervisor.retryIfPermissionMayBeBack()
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        XCTAssertEqual(started, 1)

        screenRecording.off = true
        rig.supervisor.retryNow()
        await eventually { rig.topology.launchPlans.count == 4 && rig.supervisor.state == .running }
        XCTAssertEqual(started, 1, "a restart paused on the permission keeps it")
        try await rig.supervisor.shutdownAndWait()
    }

    /// The rarer order, the tail's report landing while the helper is still
    /// getting ready, ends the same way.
    func test_a_permission_reported_before_readiness_ends_the_same_way() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        rig.topology.onReadinessWait = { [weak supervisor = rig.supervisor] plan in
            guard plan.helperArguments.contains("--capture") else { return }
            supervisor?.tccRevokedSurface = .screenRecording
        }

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [])
        XCTAssertFalse(rig.topology.captureHelperAlive)
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        try await rig.supervisor.shutdownAndWait()
    }

    func test_turn_on_with_accessibility_off_names_accessibility() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        helperReports(.accessibility, to: rig)

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.accessibility))
        XCTAssertEqual(row(rig.supervisor).detail, "Accessibility is off for Hippocampus.")
        XCTAssertEqual(row(rig.supervisor).action, .openSystemSettings(.accessibility))
        XCTAssertFalse(rig.supervisor.captureEnabled)
        try await rig.supervisor.shutdownAndWait()
    }

    private func captureLaunches(_ rig: Rig) -> Int {
        rig.topology.launchPlans.filter { $0.helperArguments.contains("--capture") }.count
    }

    /// A look at the menu or the app is not a press. After a turn-on stopped
    /// on a permission, opening the menu (to quit, say) once the permission
    /// is allowed for some other reason used to press Turn On again, and
    /// could save remembering on.
    func test_a_failed_permission_turn_on_is_not_pressed_again_by_opening_the_menu() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let screenRecording = PermissionSwitch()
        helperReports(.screenRecording, to: rig, while: screenRecording)
        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))

        screenRecording.off = false
        rig.supervisor.retryIfPermissionMayBeBack()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(captureLaunches(rig), 1)
        XCTAssertFalse(rig.supervisor.turningOn)
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [])
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        try await rig.supervisor.shutdownAndWait()
    }

    /// Choosing Open System Settings… is a step toward turning on: the next
    /// look (the menu opening, the app becoming active) tries Turn On again
    /// with a fresh helper, the only reliable judge, once per choice.
    func test_after_open_system_settings_the_next_look_tries_turn_on_once() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let screenRecording = PermissionSwitch()
        helperReports(.screenRecording, to: rig, while: screenRecording)
        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        // Still off when the person comes back: one look, which still says so.
        press(.openSystemSettings(.screenRecording), on: rig.supervisor)
        rig.supervisor.retryIfPermissionMayBeBack()
        XCTAssertTrue(rig.supervisor.turningOn, "the look shows as Starting…")
        XCTAssertEqual(row(rig.supervisor).title, "Starting…", "the menu the look opens says what it started")
        XCTAssertEqual(row(rig.supervisor).action, .turnOff, "and it can be dropped")
        await eventually { !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertEqual(captureLaunches(rig), 2)
        rig.supervisor.retryIfPermissionMayBeBack()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(captureLaunches(rig), 2, "one look per Open System Settings…")

        // The person allows it in System Settings and comes back.
        press(.openSystemSettings(.screenRecording), on: rig.supervisor)
        screenRecording.off = false
        rig.supervisor.retryIfPermissionMayBeBack()
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertNil(rig.supervisor.tccRevokedSurface)
        XCTAssertNil(rig.supervisor.turnOnFailure)
        XCTAssertEqual(rig.config.captureWrites, [true])
        try await rig.supervisor.shutdownAndWait()
    }

    /// The menu builds its items right after the look (menuNeedsUpdate). The
    /// permission the last turn-on found off stayed in the status until the
    /// new attempt began, a turn later, so the menu the look opened read
    /// "Needs permission / Open System Settings…" while its turn-on launched
    /// and landed, with no way to drop it.
    func test_the_menu_a_look_opens_shows_the_turn_on_it_started_with_turn_off() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let screenRecording = PermissionSwitch()
        helperReports(.screenRecording, to: rig, while: screenRecording)
        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }
        press(.openSystemSettings(.screenRecording), on: rig.supervisor)
        screenRecording.off = false
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness

        rig.supervisor.retryIfPermissionMayBeBack()
        let menu = StatusMenuModel.items(
            row: row(rig.supervisor), setupComplete: true, askLabel: nil, aiToolsConnected: false
        )
        XCTAssertEqual(menu.first?.title, "Starting…", "\(menu.map(\.title))")
        XCTAssertTrue(menu.contains { $0.role == .action(.turnOff) }, "\(menu.map(\.title))")
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .remembering)

        // While that menu is open the turn-on launches; Turn Off drops it.
        await readiness.waitUntilEntered()
        press(.turnOff, on: rig.supervisor)
        rig.topology.readinessSuspension = nil
        readiness.resume()
        await eventually { rig.supervisor.state == .stopped && !rig.supervisor.turningOn }
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertFalse(rig.topology.captureHelperAlive)
        XCTAssertEqual(rig.config.captureWrites, [false])
        try await rig.supervisor.shutdownAndWait()
    }

    /// A permission reported off by an earlier run used to make every press
    /// fail: nothing reports permissions while remembering is off, so it
    /// could never clear. Turn On asks the fresh helper instead.
    func test_a_permission_an_earlier_run_reported_off_no_longer_blocks_turn_on() async throws {
        let rig = rig(captureEnabled: true)
        try await rig.supervisor.startAndWaitForReadiness()
        rig.supervisor.tccRevokedSurface = .screenRecording
        try await rig.supervisor.applyCaptureEnabled(false)
        XCTAssertEqual(rig.supervisor.tccRevokedSurface, .screenRecording)
        // Off by the person's choice reads Off: nothing nags while it is off.
        XCTAssertEqual(rig.supervisor.menuBarStatus, .idle)
        XCTAssertEqual(row(rig.supervisor).action, .turnOn)

        // The person has allowed it since.
        press(.turnOn, on: rig.supervisor)
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }

        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertNil(rig.supervisor.tccRevokedSurface)
        XCTAssertEqual(rig.config.captureWrites, [false, true])
        try await rig.supervisor.shutdownAndWait()
    }

    /// After a turn-off, a latch keeps the usual cleanup away from the stop.
    /// A turn-on a permission stopped must still not leave its helper
    /// waiting on that permission, to start reading on its own once allowed.
    func test_a_turn_on_a_permission_stopped_leaves_no_helper_running_after_a_turn_off() async throws {
        let rig = rig(captureEnabled: true)
        try await rig.supervisor.startAndWaitForReadiness()
        try await rig.supervisor.applyCaptureEnabled(false)
        helperReports(.screenRecording, to: rig)

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertFalse(rig.topology.isRunning)
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [false])
        try await rig.supervisor.shutdownAndWait()
    }

    // MARK: It didn't start

    func test_turn_on_that_cannot_start_says_couldnt_turn_on_and_try_again_turns_it_on() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        // The capture helper exits during startup; the off topology comes back.
        rig.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79)), .success(())]

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        guard case .turnOnFailed = rig.supervisor.menuBarStatus else {
            return XCTFail("expected Couldn’t turn on, got \(rig.supervisor.menuBarStatus)")
        }
        let row = row(rig.supervisor)
        XCTAssertEqual(row.title, "Couldn’t turn on")
        XCTAssertEqual(row.detail, "It didn’t start, so remembering is still off.")
        XCTAssertEqual(row.action, .tryAgain)
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .needsYou)
        XCTAssertEqual(rig.supervisor.askPanelStatus(setupFinished: true).text, "Couldn’t turn on")
        XCTAssertEqual(rig.supervisor.askPanelStatus(setupFinished: true).action, .tryAgain)
        // Off, on the verified off topology, with nothing saved.
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertEqual(rig.topology.launchPlans.map { $0.helperArguments.contains("--capture") }, [false, true, false])
        XCTAssertEqual(rig.config.captureWrites, [])

        // Try Again turns it on, rather than restarting the off topology.
        press(.tryAgain, on: rig.supervisor)
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertNil(rig.supervisor.turnOnFailure)
        XCTAssertEqual(rig.topology.launchPlans.map { $0.helperArguments.contains("--capture") },
                       [false, true, false, true])
        XCTAssertEqual(rig.config.captureWrites, [true])
        try await rig.supervisor.shutdownAndWait()
    }

    /// The real capture helper exits during startup (exit 79), and its agent
    /// drains and exits after it. Both stay held until a stop, and a launch
    /// refuses until then, so a rollback that skipped the stop because
    /// nothing was running hit "Couldn’t stop", with only Quit.
    func test_turn_on_whose_capture_helper_exits_at_startup_rolls_back_and_says_couldnt_turn_on() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        rig.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertEqual(row(rig.supervisor).title, "Couldn’t turn on")
        XCTAssertEqual(row(rig.supervisor).action, .tryAgain)
        XCTAssertFalse(rig.supervisor.stopFailed)
        XCTAssertEqual(rig.supervisor.state, .running, "the off topology is back")
        XCTAssertEqual(rig.topology.refusedLaunches, 0)
        XCTAssertEqual(rig.topology.launchPlans.map { $0.helperArguments.contains("--capture") }, [false, true, false])
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [])
        try await rig.supervisor.shutdownAndWait()
    }

    /// The agent exits during startup (another writer holds the memory) while
    /// the capture helper lives on, waiting. Helper AND agent are no longer
    /// both running, so every "stop if running" check skipped that helper.
    func test_turn_on_whose_agent_exits_at_startup_stops_its_capture_helper() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        rig.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.agentExited(21))]

        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertFalse(rig.topology.captureHelperAlive, "a failed turn-on leaves no capture helper")
        XCTAssertEqual(row(rig.supervisor).title, "Couldn’t turn on")
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertEqual(rig.topology.refusedLaunches, 0)
        XCTAssertFalse(rig.supervisor.captureEnabled)
        try await rig.supervisor.shutdownAndWait()
    }

    /// The reason lives in the supervisor, so Preferences' switch and setup's
    /// Start Remembering say it too. The status row is the one voice: the
    /// switch used to add a red "Couldn’t change that. Try again.", which
    /// stayed under the switch after Try Again had turned remembering on.
    func test_the_preferences_switch_says_why_only_in_the_status_row() async throws {
        let receipts = ReceiptSource(clock: clock, saved: clock.now, reason: nil)
        let rig = rig(receipts: receipts)
        try await rig.supervisor.startAndWaitForReadiness()
        rig.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.readinessTimedOut), .success(())]
        let controller = CapturePreferenceController(applier: rig.supervisor)

        await controller.setCaptureEnabled(true)
        await eventually { !rig.supervisor.turningOn }

        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(row(rig.supervisor).title, "Couldn’t turn on")
        XCTAssertEqual(row(rig.supervisor).action, .tryAgain)

        press(.tryAgain, on: rig.supervisor)
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        clock.now = clock.now.addingTimeInterval(5)
        receipts.saved = clock.now
        rig.supervisor.refreshCaptureStatus()
        XCTAssertEqual(row(rig.supervisor).title, "Remembering")
        try await rig.supervisor.shutdownAndWait()
    }

    /// The switch, turned on while the app's own start ran at launch (the
    /// key check can wait on a Keychain prompt), cancelled that start before
    /// it was refused: "Couldn’t change that. Try again." under the switch,
    /// and "Not saving" with nothing running, though remembering had been
    /// off. It waits for the start, as the menu's Turn On does.
    func test_the_switch_turned_on_during_the_launch_start_waits_for_it() async throws {
        let custody = FakeKeyCustodyPreparer()
        let rig = rig(custody: custody)
        let supervisor = rig.supervisor
        let keyCheck = TestSuspension()
        custody.suspension = keyCheck
        supervisor.start()
        await keyCheck.waitUntilEntered()
        let controller = CapturePreferenceController(applier: supervisor)

        await controller.setCaptureEnabled(true)
        XCTAssertTrue(supervisor.turningOn)
        custody.suspension = nil
        keyCheck.resume()
        await eventually { supervisor.captureEnabled && !supervisor.turningOn }

        XCTAssertEqual(supervisor.state, .running)
        XCTAssertEqual(rig.topology.launchPlans.map { $0.helperArguments.contains("--capture") }, [false, true])
        XCTAssertEqual(rig.config.captureWrites, [true])
        try await supervisor.shutdownAndWait()
    }

    /// Setup's Start Remembering asks for the change directly. When another
    /// start holds the gate it is refused, and the start it met runs on.
    func test_a_refused_direct_turn_on_leaves_the_start_under_way_alone() async throws {
        let custody = FakeKeyCustodyPreparer()
        let rig = rig(custody: custody)
        let supervisor = rig.supervisor
        let keyCheck = TestSuspension()
        custody.suspension = keyCheck
        supervisor.start()
        await keyCheck.waitUntilEntered()

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(true))
        custody.suspension = nil
        keyCheck.resume()
        await eventually { supervisor.state != .starting }

        XCTAssertEqual(supervisor.state, .running, "not crashed by a cancelled start")
        XCTAssertEqual(rig.topology.launchPlans.count, 1)
        try await supervisor.shutdownAndWait()
    }

    // MARK: A press during another change

    /// At launch, remembering is still starting (off) when Turn On is
    /// pressed. A turn-on then is refused, which used to drop the press.
    func test_turn_on_pressed_during_another_change_waits_for_it() async throws {
        let rig = rig()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        let launch = Task { try await rig.supervisor.startAndWaitForReadiness() }
        await readiness.waitUntilEntered()
        await XCTAssertThrowsErrorAsync(try await rig.supervisor.applyCaptureEnabled(true))
        XCTAssertNil(rig.supervisor.turnOnFailure, "nothing was tried, so there is nothing to say")

        press(.turnOn, on: rig.supervisor)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(rig.supervisor.turningOn, "the press is kept")
        XCTAssertEqual(rig.supervisor.menuBarStatus, .starting)
        XCTAssertEqual(rig.topology.launchPlans.count, 1, "it waits for the change under way")

        rig.topology.readinessSuspension = nil
        readiness.resume()
        try await launch.value
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertEqual(rig.topology.launchPlans.map { $0.helperArguments.contains("--capture") }, [false, true])
        XCTAssertEqual(rig.config.captureWrites, [true])
        try await rig.supervisor.shutdownAndWait()
    }

    /// Off in Preferences, then Turn On in the menu while the stop is still
    /// under way: the latest word wins once the stop is done.
    func test_turn_on_pressed_while_a_turn_off_is_stopping_turns_on_after_it() async throws {
        let rig = rig(captureEnabled: true)
        try await rig.supervisor.startAndWaitForReadiness()
        let stopping = TestSuspension()
        rig.topology.stopSuspensionOnCall = rig.topology.stopCalls + 1
        rig.topology.stopSuspension = stopping
        let turningOff = Task { try await rig.supervisor.applyCaptureEnabled(false) }
        await stopping.waitUntilEntered()

        press(.turnOn, on: rig.supervisor)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.supervisor.menuBarStatus, .starting, "the stop isn't done and the press is kept")
        XCTAssertEqual(rig.topology.launchPlans.count, 1)

        stopping.resume()
        try await turningOff.value
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertEqual(rig.config.captureWrites, [false, true])
        try await rig.supervisor.shutdownAndWait()
    }

    /// A turn-off during a turn-on is the newer word: no reason shows.
    func test_turning_off_during_a_turn_on_ends_it_quietly() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        press(.turnOn, on: rig.supervisor)
        await readiness.waitUntilEntered()

        try await rig.supervisor.applyCaptureEnabled(false)
        rig.topology.readinessSuspension = nil
        readiness.resume()
        await eventually { !rig.supervisor.turningOn }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(rig.supervisor.turnOnFailure)
        XCTAssertEqual(rig.supervisor.menuBarStatus, .idle)
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertFalse(rig.topology.isRunning)
        XCTAssertEqual(rig.config.captureWrites, [false])
        try await rig.supervisor.shutdownAndWait()
    }

    /// While a turn-on is under way its helper may read, and the switch in
    /// Preferences used to read Off with nothing anywhere to turn it off but
    /// Quit. The row offers Turn Off, wired to the turn-off that supersedes.
    func test_turn_off_while_turning_on_drops_it() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        press(.turnOn, on: rig.supervisor)
        await readiness.waitUntilEntered()
        XCTAssertEqual(row(rig.supervisor).action, .turnOff)
        XCTAssertEqual(rig.supervisor.askPanelStatus(setupFinished: true).action, .turnOff)

        press(.turnOff, on: rig.supervisor)
        await eventually { rig.supervisor.state == .stopped }
        rig.topology.readinessSuspension = nil
        readiness.resume()
        await eventually { !rig.supervisor.turningOn }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(rig.supervisor.turnOnFailure, "the person's word, not a failure")
        XCTAssertEqual(row(rig.supervisor).title, "Off")
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertFalse(rig.topology.captureHelperAlive)
        XCTAssertFalse(rig.topology.holdsProcesses)
        XCTAssertEqual(rig.config.captureWrites, [false])
        try await rig.supervisor.shutdownAndWait()
    }

    /// A press still waiting out another change drops the same way.
    func test_turn_off_drops_a_press_still_waiting() async throws {
        let rig = rig()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        let launch = Task { try await rig.supervisor.startAndWaitForReadiness() }
        await readiness.waitUntilEntered()
        press(.turnOn, on: rig.supervisor)
        XCTAssertTrue(rig.supervisor.turningOn)
        XCTAssertEqual(row(rig.supervisor).action, .turnOff)

        press(.turnOff, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }
        rig.topology.readinessSuspension = nil
        readiness.resume()
        _ = try? await launch.value
        await eventually { rig.supervisor.state == .stopped }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.topology.launchPlans.count, 1, "the waiting press never launched")
        XCTAssertNil(rig.supervisor.turnOnFailure)
        try await rig.supervisor.shutdownAndWait()
    }

    /// Stop Sharing during a turn-on: the stop is under way, so the row still
    /// reads Starting…, with nothing to press. It offered Pause, which would
    /// record a pause the person did not mean.
    func test_stop_sharing_during_a_turn_on_offers_nothing_until_off() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        press(.turnOn, on: rig.supervisor)
        await readiness.waitUntilEntered()
        let stopping = TestSuspension()
        rig.topology.stopSuspensionOnCall = rig.topology.stopCalls + 1
        rig.topology.stopSuspension = stopping

        rig.topology.fireUnexpectedExit(forLaunchAt: rig.topology.launchPlans.count - 1, label: "helper", status: 82)
        await stopping.waitUntilEntered()

        XCTAssertEqual(row(rig.supervisor).title, "Starting…")
        XCTAssertNil(row(rig.supervisor).action)
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .remembering)
        stopping.resume()
        rig.topology.readinessSuspension = nil
        readiness.resume()
        await eventually { rig.supervisor.state == .stopped }
        XCTAssertEqual(row(rig.supervisor).title, "Off")
        XCTAssertEqual(row(rig.supervisor).action, .turnOn)
    }

    /// A pause that stops a turn-on is the person's word, not a failure.
    func test_a_pause_that_stops_a_turn_on_is_not_called_a_failure() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        press(.turnOn, on: rig.supervisor)
        await readiness.waitUntilEntered()

        rig.supervisor.setPaused(true)
        await eventually { rig.supervisor.state == .paused }
        rig.topology.readinessSuspension = nil
        readiness.resume()
        await eventually { !rig.supervisor.turningOn }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(rig.supervisor.turnOnFailure)
        XCTAssertEqual(row(rig.supervisor).title, "Off")
        XCTAssertFalse(rig.supervisor.captureEnabled)
        XCTAssertFalse(rig.topology.isRunning)
        XCTAssertEqual(rig.config.captureWrites, [])
        try await rig.supervisor.shutdownAndWait()
    }

    /// Quit during a turn-on drops the press at once, but the turn-on's
    /// capture helper may read until Quit's stop is done: the picture stays
    /// Starting…, with nothing to press, and reaches Off by itself. It showed
    /// "Off / Turn On" with the off picture for the whole stop.
    func test_quit_during_a_turn_on_shows_off_only_once_its_helper_has_stopped() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        press(.turnOn, on: rig.supervisor)
        await readiness.waitUntilEntered()
        XCTAssertTrue(rig.topology.captureHelperAlive)
        let stopping = TestSuspension()
        rig.topology.stopSuspensionOnCall = rig.topology.stopCalls + 1
        rig.topology.stopSuspension = stopping

        let quit = Task { try await rig.supervisor.shutdownAndWait() }
        await stopping.waitUntilEntered()

        XCTAssertFalse(rig.supervisor.turningOn)
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .remembering, "not Off before the stop is done")
        XCTAssertEqual(row(rig.supervisor).title, "Starting…")
        XCTAssertNil(row(rig.supervisor).action)

        stopping.resume()
        rig.topology.readinessSuspension = nil
        readiness.resume()
        try await quit.value
        XCTAssertEqual(rig.supervisor.state, .stopped)
        XCTAssertEqual(rig.supervisor.menuBarStatus, .idle)
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .off)
    }

    /// A turn-on whose capture launch failed outright left nothing behind,
    /// and the rollback restored the off topology: a later Quit has no
    /// capture helper to wait for, so it reads Off at once.
    func test_quit_after_a_turn_on_whose_launch_failed_reads_off_at_once() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        rig.topology.launchErrors = [CocoaError(.executableNotLoadable)]
        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }
        XCTAssertEqual(row(rig.supervisor).title, "Couldn’t turn on")
        let stopping = TestSuspension()
        rig.topology.stopSuspensionOnCall = rig.topology.stopCalls + 1
        rig.topology.stopSuspension = stopping

        let quit = Task { try await rig.supervisor.shutdownAndWait() }
        await stopping.waitUntilEntered()

        XCTAssertEqual(rig.supervisor.menuBarStatus, .idle)
        stopping.resume()
        try await quit.value
    }

    /// Quit while remembering is off has no capture helper to wait for: Off.
    func test_quit_while_off_reads_off_at_once() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let stopping = TestSuspension()
        rig.topology.stopSuspensionOnCall = rig.topology.stopCalls + 1
        rig.topology.stopSuspension = stopping

        let quit = Task { try await rig.supervisor.shutdownAndWait() }
        await stopping.waitUntilEntered()

        XCTAssertEqual(rig.supervisor.menuBarStatus, .idle)
        stopping.resume()
        try await quit.value
    }

    /// Quit wins over a press that is waiting.
    func test_quit_drops_a_waiting_press_without_a_reason() async throws {
        let rig = rig()
        let readiness = TestSuspension()
        rig.topology.readinessSuspension = readiness
        let launch = Task { try await rig.supervisor.startAndWaitForReadiness() }
        await readiness.waitUntilEntered()
        press(.turnOn, on: rig.supervisor)
        XCTAssertTrue(rig.supervisor.turningOn)

        let quit = Task { try await rig.supervisor.shutdownAndWait() }
        while rig.topology.stopCalls == 0 { await Task.yield() }
        rig.topology.readinessSuspension = nil
        readiness.resume()
        try await quit.value
        _ = try? await launch.value
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(rig.supervisor.turningOn)
        XCTAssertNil(rig.supervisor.turnOnFailure)
        XCTAssertEqual(rig.supervisor.state, .stopped)
        XCTAssertEqual(rig.topology.launchPlans.count, 1, "nothing starts after Quit")
    }
}

/// A notification center that only records: nothing reaches the person's
/// Notification Center.
final class RecordingNotificationCenter: UserNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private var _removedDelivered: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _added.append(request) }
    }

    func removePendingNotificationRequests(withIdentifiers ids: [String]) {}

    func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        lock.withLock { _removedDelivered.append(contentsOf: ids) }
    }

    var added: [UNNotificationRequest] { lock.withLock { _added } }
    var removedDelivered: [String] { lock.withLock { _removedDelivered } }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
