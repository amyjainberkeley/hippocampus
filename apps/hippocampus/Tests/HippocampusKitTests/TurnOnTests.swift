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

    private func rig(captureEnabled: Bool = false, receipts: ReceiptSource? = nil) -> Rig {
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
            keyCustodyPreparer: FakeKeyCustodyPreparer(), captureConsentAuthority: consent,
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

    /// The fresh helper a turn-on starts finds a permission off and says so
    /// on its way up, as `helper_health tcc_revoked=…` read by the tail.
    private func helperReports(
        _ permission: TCCRevokedReason, to rig: Rig, while setting: PermissionSwitch = PermissionSwitch()
    ) {
        rig.topology.onReadinessWait = { [weak supervisor = rig.supervisor] plan in
            guard setting.off, plan.helperArguments.contains("--capture") else { return }
            supervisor?.tccRevokedSurface = permission
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
        XCTAssertNil(row(rig.supervisor).action, "nothing is on to pause yet")
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

    /// Nothing is left running to see the permission come back, and this
    /// process's own answer can stay "no" after the person allows it, so the
    /// menu opening tries Turn On again with a fresh helper (RULINGS S10).
    func test_after_a_permission_stops_turn_on_the_menu_opening_tries_again() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let screenRecording = PermissionSwitch()
        helperReports(.screenRecording, to: rig, while: screenRecording)
        press(.turnOn, on: rig.supervisor)
        await eventually { !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))

        // Still off: it looks again and still says so.
        rig.supervisor.retryIfPermissionMayBeBack()
        await eventually { !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertEqual(rig.topology.launchPlans.filter { $0.helperArguments.contains("--capture") }.count, 2)

        // The person allows it in System Settings.
        screenRecording.off = false
        rig.supervisor.retryIfPermissionMayBeBack()
        await eventually { rig.supervisor.captureEnabled && !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.state, .running)
        XCTAssertNil(rig.supervisor.tccRevokedSurface)
        XCTAssertNil(rig.supervisor.turnOnFailure)
        XCTAssertEqual(rig.config.captureWrites, [true])
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

    /// The reason lives in the supervisor, so Preferences' switch and setup's
    /// Start Remembering say it too.
    func test_the_preferences_switch_leaves_the_same_reason_in_the_status_row() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        rig.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.readinessTimedOut), .success(())]
        let controller = CapturePreferenceController(applier: rig.supervisor)

        await controller.setCaptureEnabled(true)

        XCTAssertFalse(controller.captureEnabled)
        XCTAssertEqual(controller.errorMessage, CapturePreferenceController.couldNotChange)
        XCTAssertEqual(row(rig.supervisor).title, "Couldn’t turn on")
        XCTAssertEqual(row(rig.supervisor).action, .tryAgain)
        try await rig.supervisor.shutdownAndWait()
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
