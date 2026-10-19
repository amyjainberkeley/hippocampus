// SPDX-License-Identifier: Apache-2.0
//
// Remembering never runs with a permission off. A capture helper that finds
// one off pauses itself, but only itself: the agent still took pages from the
// browser extensions, Safari's consent stayed on, and (before the helper's
// own fix) whole-screen reading went on, all under "Needs permission" and
// "Hippocampus stopped remembering". And a helper paused on Screen Recording
// cannot see the grant, since its own answer stays "no", so an already-on
// start that kept one was stuck until the person happened to choose the
// status row's Open System Settings…. Which of that a person got depended on
// whether the helper's stderr report beat its readiness.
//
// Now a start that meets a permission ends, and so does a run: nothing is
// left reading, the status says Needs permission, and since remembering is
// on, the next look (the menu opening, the app becoming active) starts a
// fresh helper.

import XCTest
@testable import HippocampusKit

@MainActor
final class PermissionOffTests: XCTestCase {
    private let clock = TestClock()

    private struct Rig {
        let supervisor: ProcessSupervisor
        let topology: FakeSupervisorTopology
        let config: FakeRuntimeConfig
        let consent: FakeCaptureConsentAuthority
    }

    private final class PermissionSwitch {
        var off = true
    }

    private func rig(captureEnabled: Bool = true) -> Rig {
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
            readinessTimeout: 0.1, captureStatusReader: { (nil, nil) }, clock: { clock.now }
        )
        return Rig(supervisor: supervisor, topology: topology, config: config, consent: consent)
    }

    /// The real capture helper: one started while the permission is off names
    /// it in its readiness receipt.
    private func helperReports(_ permission: TCCRevokedReason, to rig: Rig, while setting: PermissionSwitch) {
        rig.topology.permissionOffInReceipt = { plan in
            setting.off && plan.helperArguments.contains("--capture") ? permission : nil
        }
    }

    private func captureLaunches(_ rig: Rig) -> Int {
        rig.topology.launchPlans.filter { $0.helperArguments.contains("--capture") }.count
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

    private func row(_ supervisor: ProcessSupervisor) -> StatusRow {
        supervisor.statusRow(setupFinished: true, now: clock.now)
    }

    // MARK: A start that meets a permission

    /// Remembering is on and the launch's helper finds Screen Recording off.
    /// The person allows it in System Settings directly (or picks Later on
    /// macOS's Quit & Reopen prompt) and comes back: the next look starts a
    /// fresh helper, which sees the grant.
    func test_a_start_that_finds_screen_recording_off_ends_and_the_next_look_starts_it_again() async throws {
        let rig = rig()
        let screenRecording = PermissionSwitch()
        helperReports(.screenRecording, to: rig, while: screenRecording)

        try? await rig.supervisor.startAndWaitForReadiness()

        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertEqual(row(rig.supervisor).action, .openSystemSettings(.screenRecording))
        XCTAssertTrue(rig.consent.enabledGenerations.isEmpty, "consent never went on")
        XCTAssertFalse(rig.topology.holdsProcesses, "no helper is kept waiting on the permission")
        XCTAssertNil(rig.supervisor.safariInboxStats)
        XCTAssertTrue(rig.supervisor.captureEnabled, "remembering stays on in the setting")
        XCTAssertEqual(rig.config.captureWrites, [])

        screenRecording.off = false
        rig.supervisor.retryIfPermissionMayBeBack()
        await eventually { rig.supervisor.state == .running }

        XCTAssertEqual(captureLaunches(rig), 2)
        XCTAssertNil(rig.supervisor.tccRevokedSurface)
        XCTAssertEqual(rig.consent.enabledGenerations.count, 1)
        try await rig.supervisor.shutdownAndWait()
    }

    /// Every look tries while it is still off; none keeps a helper.
    func test_every_look_tries_a_fresh_helper_while_the_permission_stays_off() async throws {
        let rig = rig()
        helperReports(.screenRecording, to: rig, while: PermissionSwitch())
        try? await rig.supervisor.startAndWaitForReadiness()

        for expected in 2...3 {
            rig.supervisor.retryIfPermissionMayBeBack()
            await eventually { captureLaunches(rig) == expected && !rig.topology.holdsProcesses }
            await eventually { rig.supervisor.menuBarStatus == .needsPermission(.screenRecording) }
        }
        XCTAssertTrue(rig.consent.enabledGenerations.isEmpty)
        try await rig.supervisor.shutdownAndWait()
    }

    /// The other order, the helper's stderr report landing while the start
    /// still waits for readiness, ends the same way.
    func test_both_orders_of_the_report_end_the_same_way() async throws {
        let rig = rig()
        rig.topology.onReadinessWait = { [weak supervisor = rig.supervisor] plan in
            guard plan.helperArguments.contains("--capture") else { return }
            supervisor?.tccRevokedSurface = .screenRecording
        }

        try? await rig.supervisor.startAndWaitForReadiness()

        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertTrue(rig.consent.enabledGenerations.isEmpty)
        XCTAssertFalse(rig.topology.holdsProcesses)
        rig.topology.onReadinessWait = nil
        rig.supervisor.retryIfPermissionMayBeBack()
        await eventually { rig.supervisor.state == .running }
        try await rig.supervisor.shutdownAndWait()
    }

    /// Accessibility off at launch, Screen Recording on: the start used to
    /// commit, with consent on and the agent taking pages, and whole-screen
    /// reading went on, under "Needs permission".
    func test_a_start_that_finds_accessibility_off_never_runs_or_turns_consent_on() async throws {
        let rig = rig()
        helperReports(.accessibility, to: rig, while: PermissionSwitch())

        try? await rig.supervisor.startAndWaitForReadiness()

        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.accessibility))
        XCTAssertEqual(rig.supervisor.menuBarStatus.markState, .needsYou)
        XCTAssertTrue(rig.consent.enabledGenerations.isEmpty)
        XCTAssertFalse(rig.topology.holdsProcesses)
        XCTAssertFalse(rig.supervisor.requestFreshRead())
        try await rig.supervisor.shutdownAndWait()
    }

    /// A resume, Try Again's restart and a crash's retry are starts too.
    func test_a_restart_that_finds_a_permission_off_ends_the_same_way() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        XCTAssertEqual(rig.supervisor.state, .running)
        helperReports(.screenRecording, to: rig, while: PermissionSwitch())

        rig.supervisor.retryNow()
        await eventually { rig.supervisor.menuBarStatus == .needsPermission(.screenRecording) }

        await eventually { !rig.topology.holdsProcesses }
        XCTAssertEqual(rig.consent.enabledGenerations.count, 1, "only the first run turned consent on")
        XCTAssertNil(rig.consent.enabledGenerationID)
        try await rig.supervisor.shutdownAndWait()
    }

    // MARK: A run that meets a permission

    /// The person turns Accessibility off while remembering runs. The helper
    /// pauses itself and says so on stderr; the run ends, so nothing reads:
    /// Safari's consent and pages stop at once, and the helper and agent stop.
    func test_a_permission_turned_off_while_remembering_runs_ends_the_run() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        XCTAssertNotNil(rig.consent.enabledGenerationID)
        XCTAssertNotNil(rig.supervisor.safariInboxStats)

        // What the stderr tail's sink does with the helper's line.
        rig.supervisor.tccRevokedSurface = .accessibility

        XCTAssertNil(rig.consent.enabledGenerationID, "consent goes off at once")
        XCTAssertNil(rig.supervisor.safariInboxStats, "Safari's pages stop at once")
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.accessibility))
        XCTAssertFalse(rig.supervisor.requestFreshRead())
        await eventually { !rig.topology.holdsProcesses }
        XCTAssertFalse(rig.supervisor.stopFailed)
        XCTAssertTrue(rig.supervisor.captureEnabled)
        XCTAssertEqual(rig.config.captureWrites, [])

        // Allowed again: the next look starts a fresh helper.
        try await Task.sleep(for: .milliseconds(50))
        rig.supervisor.retryIfPermissionMayBeBack()
        await eventually { rig.supervisor.state == .running }
        XCTAssertNil(rig.supervisor.tccRevokedSurface)
        XCTAssertEqual(rig.topology.launchPlans.count, 2)
        try await rig.supervisor.shutdownAndWait()
    }

    // MARK: Allowed again, with nobody looking

    /// Whether this process sees the permission on, as a test changes it.
    private final class Trust: @unchecked Sendable {
        var accessibility = false
    }

    private func rig(trust: Trust) -> Rig {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let config = FakeRuntimeConfig(captureEnabled: true)
        let topology = FakeSupervisorTopology()
        let consent = FakeCaptureConsentAuthority()
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: config, topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(), captureConsentAuthority: consent,
            readinessTimeout: 0.1, captureStatusReader: { (nil, nil) },
            permissionProbe: { permission in permission == .accessibility ? trust.accessibility : nil },
            permissionPollSleep: { try await Task.sleep(for: .milliseconds(20)) }
        )
        return Rig(supervisor: supervisor, topology: topology, config: config, consent: consent)
    }

    /// A helper paused on Accessibility used to resume by itself once it was
    /// allowed. The run ends now, so the app watches the one permission it
    /// can see for itself, and looks again once it comes back on.
    func test_a_run_accessibility_ended_starts_again_by_itself_once_it_is_allowed() async throws {
        let trust = Trust()
        let rig = rig(trust: trust)
        try await rig.supervisor.startAndWaitForReadiness()
        rig.supervisor.tccRevokedSurface = .accessibility
        await eventually { !rig.topology.holdsProcesses }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.topology.launchPlans.count, 1, "nothing tries while it is off")

        trust.accessibility = true
        await eventually { rig.supervisor.state == .running }

        XCTAssertEqual(rig.topology.launchPlans.count, 2)
        XCTAssertNil(rig.supervisor.tccRevokedSurface)
        try await rig.supervisor.shutdownAndWait()
    }

    /// Only a change it saw counts: when this process already says yes while
    /// the helper says no, it never tries again and again.
    func test_a_permission_this_process_already_sees_on_is_not_tried_over_and_over() async throws {
        let trust = Trust()
        trust.accessibility = true
        let rig = rig(trust: trust)
        try await rig.supervisor.startAndWaitForReadiness()

        rig.supervisor.tccRevokedSurface = .accessibility
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(rig.topology.launchPlans.count, 1)
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.accessibility))
        try await rig.supervisor.shutdownAndWait()
    }

    /// Screen Recording cannot be seen from here: only a look tries again.
    func test_screen_recording_is_left_to_the_next_look() async throws {
        let trust = Trust()
        let rig = rig(trust: trust)
        try await rig.supervisor.startAndWaitForReadiness()

        rig.supervisor.tccRevokedSurface = .screenRecording
        trust.accessibility = true
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(rig.topology.launchPlans.count, 1)
        XCTAssertEqual(rig.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        try await rig.supervisor.shutdownAndWait()
    }

    /// A run whose stop fails says so.
    func test_a_run_a_permission_ended_whose_stop_fails_says_couldnt_stop() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        rig.topology.stopResults = [.failure(SupervisorProcessRuntimeError.partialStop)]

        rig.supervisor.tccRevokedSurface = .screenRecording

        await eventually { rig.supervisor.stopFailed }
        XCTAssertEqual(row(rig.supervisor).title, "Couldn’t stop")
        XCTAssertEqual(row(rig.supervisor).action, .quit)
    }

    /// A turn-off already stopping the run is left to finish: the setting is
    /// off, so a permission report changes nothing.
    func test_a_permission_report_during_a_turn_off_leaves_it_to_finish() async throws {
        let rig = rig()
        try await rig.supervisor.startAndWaitForReadiness()
        let stopping = TestSuspension()
        rig.topology.stopSuspensionOnCall = rig.topology.stopCalls + 1
        rig.topology.stopSuspension = stopping
        let off = Task { try await rig.supervisor.applyCaptureEnabled(false) }
        await stopping.waitUntilEntered()

        rig.supervisor.tccRevokedSurface = .screenRecording
        stopping.resume()
        try await off.value

        XCTAssertEqual(rig.supervisor.state, .stopped)
        XCTAssertEqual(rig.topology.stopCalls, 1, "the turn-off's own stop, and no other")
        XCTAssertFalse(rig.supervisor.stopFailed)
        XCTAssertEqual(row(rig.supervisor).title, "Off")
        try await rig.supervisor.shutdownAndWait()
    }
}
