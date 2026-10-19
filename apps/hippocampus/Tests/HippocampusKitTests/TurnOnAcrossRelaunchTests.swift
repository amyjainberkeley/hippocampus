// SPDX-License-Identifier: Apache-2.0
//
// A Turn On that a permission refused, across macOS's Quit & Reopen. Turn On
// found Screen Recording off and saved nothing on; the person chose Open
// System Settings…, allowed it, and System Settings offered to Quit & Reopen
// Hippocampus. The relaunch read a plain "Off", as if nothing was pressed.

import XCTest
@testable import HippocampusKit

final class RecordingTurnOnWaitNote: TurnOnWaitNoting, @unchecked Sendable {
    var refusedAt: Date?
    private(set) var clears = 0

    init(_ date: Date? = nil) { refusedAt = date }

    func record(_ date: Date) { refusedAt = date }

    func clear() {
        clears += 1
        refusedAt = nil
    }
}

@MainActor
final class TurnOnAcrossRelaunchTests: XCTestCase {
    private let clock = TestClock()

    private struct Rig {
        let supervisor: ProcessSupervisor
        let topology: FakeSupervisorTopology
    }

    private func launch(
        config: FakeRuntimeConfig, note: RecordingTurnOnWaitNote, screenRecordingOff: @escaping () -> Bool
    ) -> Rig {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        topology.permissionOffInReceipt = { plan in
            screenRecordingOff() && plan.helperArguments.contains("--capture") ? .screenRecording : nil
        }
        let clock = self.clock
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: config, topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, clock: { clock.now }, turnOnWaitNote: note
        )
        return Rig(supervisor: supervisor, topology: topology)
    }

    private func eventually(_ condition: @MainActor () -> Bool, within seconds: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func captureLaunches(_ rig: Rig) -> Int {
        rig.topology.launchPlans.filter { $0.helperArguments.contains("--capture") }.count
    }

    /// The relaunch System Settings offers presses Turn On again, once,
    /// with a fresh helper, which sees the grant: it comes back remembering.
    func test_a_turn_on_a_permission_refused_lands_after_macOS_quits_and_reopens_it() async throws {
        let config = FakeRuntimeConfig(captureEnabled: false)
        let note = RecordingTurnOnWaitNote()
        var off = true
        let first = launch(config: config, note: note) { off }
        try await first.supervisor.startAndWaitForReadiness()
        first.supervisor.performAskStatusAction(.turnOn, setupFinished: true) { _ in }
        await eventually { !first.supervisor.turningOn }
        XCTAssertEqual(first.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertEqual(note.refusedAt, clock.now, "the press is kept")
        XCTAssertEqual(config.captureWrites, [])
        try await first.supervisor.shutdownAndWait()

        // Allowed in System Settings; Quit & Reopen, a minute later.
        off = false
        clock.now = clock.now.addingTimeInterval(60)
        let relaunched = launch(config: config, note: note) { off }
        relaunched.supervisor.start()
        await eventually { relaunched.supervisor.captureEnabled && !relaunched.supervisor.turningOn }

        XCTAssertTrue(relaunched.supervisor.captureEnabled)
        XCTAssertEqual(relaunched.supervisor.state, .running)
        XCTAssertEqual(config.captureWrites, [true])
        XCTAssertNil(note.refusedAt, "it landed")
        try await relaunched.supervisor.shutdownAndWait()
    }

    /// Still off at the relaunch: Needs permission again, never on, and the
    /// press is kept for the next one.
    func test_the_kept_turn_on_still_needs_every_permission() async throws {
        let config = FakeRuntimeConfig(captureEnabled: false)
        let note = RecordingTurnOnWaitNote(clock.now.addingTimeInterval(-30))
        let relaunched = launch(config: config, note: note) { true }

        relaunched.supervisor.start()
        await eventually { captureLaunches(relaunched) == 1 && !relaunched.supervisor.turningOn }

        XCTAssertFalse(relaunched.supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [])
        XCTAssertEqual(relaunched.supervisor.menuBarStatus, .needsPermission(.screenRecording))
        XCTAssertEqual(note.refusedAt, clock.now)
        try await relaunched.supervisor.shutdownAndWait()
    }

    /// Honoured for ten minutes only: an older note is dropped, and the
    /// launch stays off as the setting says.
    func test_an_old_press_is_not_pressed_again() async throws {
        let config = FakeRuntimeConfig(captureEnabled: false)
        let note = RecordingTurnOnWaitNote(clock.now.addingTimeInterval(-11 * 60))
        let relaunched = launch(config: config, note: note) { false }

        relaunched.supervisor.start()
        await eventually { relaunched.supervisor.state == .running }

        XCTAssertEqual(captureLaunches(relaunched), 0)
        XCTAssertFalse(relaunched.supervisor.captureEnabled)
        XCTAssertNil(note.refusedAt)
        try await relaunched.supervisor.shutdownAndWait()
    }

    /// Only the first start of a launch honours it: a reopen later is not a
    /// press.
    func test_only_the_launch_honours_it() async throws {
        let config = FakeRuntimeConfig(captureEnabled: false)
        let note = RecordingTurnOnWaitNote()
        let rig = launch(config: config, note: note) { true }
        try await rig.supervisor.startAndWaitForReadiness()
        rig.supervisor.performAskStatusAction(.turnOn, setupFinished: true) { _ in }
        await eventually { !rig.supervisor.turningOn }
        XCTAssertNotNil(note.refusedAt)
        let launches = captureLaunches(rig)

        rig.supervisor.reopenWindow()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(captureLaunches(rig), launches)
        try await rig.supervisor.shutdownAndWait()
    }

    /// A turn-off, a turn-on that failed for another reason, and the person
    /// quitting Hippocampus themselves each drop it.
    func test_a_turn_off_another_failure_or_quitting_drops_it() async throws {
        let config = FakeRuntimeConfig(captureEnabled: false)
        let note = RecordingTurnOnWaitNote()
        let rig = launch(config: config, note: note) { true }
        try await rig.supervisor.startAndWaitForReadiness()
        rig.supervisor.performAskStatusAction(.turnOn, setupFinished: true) { _ in }
        await eventually { !rig.supervisor.turningOn }
        XCTAssertNotNil(note.refusedAt)

        try await rig.supervisor.applyCaptureEnabled(false)
        XCTAssertNil(note.refusedAt, "a turn-off")

        note.record(clock.now)
        rig.topology.permissionOffInReceipt = nil
        rig.topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        rig.supervisor.performAskStatusAction(.turnOn, setupFinished: true) { _ in }
        await eventually { !rig.supervisor.turningOn }
        XCTAssertEqual(rig.supervisor.statusRow(setupFinished: true).title, "Couldn’t turn on")
        XCTAssertNil(note.refusedAt, "another failure")

        note.record(clock.now)
        rig.supervisor.forgetTurnOnWaitingOnPermission()
        XCTAssertNil(note.refusedAt, "the person quit Hippocampus")
        try await rig.supervisor.shutdownAndWait()
    }

    /// Quit from the menu, ⌘Q and the status row's Quit are the person's
    /// own and drop it; macOS's Quit & Reopen arrives as a quit Apple event,
    /// which keeps it.
    func test_only_the_persons_own_quit_drops_it() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Hippocampus/HippocampusApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains("Button(\"Quit Hippocampus\") { appDelegate.requestQuit(fromHippocampus: true) }"))
        XCTAssertTrue(app.contains("quit: { [weak self] in self?.requestQuit(fromHippocampus: true) }"))
        XCTAssertTrue(app.contains("if action == .quit {\n            requestQuit(fromHippocampus: true)"))
        XCTAssertTrue(app.contains("if fromHippocampus { supervisor.forgetTurnOnWaitingOnPermission() }"))
        let appleEvent = try XCTUnwrap(app.range(of: "private func handleQuitAppleEvent("))
        XCTAssertTrue(app[appleEvent.upperBound...].prefix(200).contains("requestQuit()"))
        XCTAssertTrue(app.contains("turnOnWaitNote: UserDefaultsTurnOnWaitNote()"))
    }
}
