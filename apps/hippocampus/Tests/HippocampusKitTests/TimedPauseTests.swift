// SPDX-License-Identifier: Apache-2.0
//
// Pause for an hour, or until 6:00 AM tomorrow (SPEC 2.6.2): the end is kept
// with the pause, so it survives a relaunch, and remembering resumes on time.
// The menu says "Until 3:41 PM." and offers Start Remembering, the words
// that end any pause.

import XCTest
@testable import HippocampusKit

@MainActor
final class TimedPauseTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "ai.hippocampus.tests.timed-pause.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    /// 2:41 PM on Monday, Oct 12, 2026, in Los Angeles.
    private let start = TimedPauseTests.monday
    nonisolated static let monday = Date(timeIntervalSince1970: 1_791_841_260)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    func testATimedPauseAndItsEndSurviveARelaunch() async {
        await withDefaults { defaults in
            let end = start.addingTimeInterval(3_600)
            let first = UserPauseController(defaults: defaults, clock: { TimedPauseTests.monday })
            first.pause(until: end)
            XCTAssertTrue(first.isPaused)
            XCTAssertEqual(first.resumeAt, end)

            let relaunched = UserPauseController(defaults: defaults)
            XCTAssertTrue(relaunched.isPaused)
            XCTAssertEqual(relaunched.pausedSince, start)
            XCTAssertEqual(relaunched.resumeAt, end)
            XCTAssertFalse(relaunched.isDue(now: end.addingTimeInterval(-1)))
            XCTAssertTrue(relaunched.isDue(now: end))

            relaunched.setPaused(false)
            let after = UserPauseController(defaults: defaults)
            XCTAssertNil(after.resumeAt, "resuming forgets the end")
            XCTAssertFalse(after.isPaused)
        }
    }

    func testUntilIResumeHasNoEndAndReplacesATimedOne() async {
        let pauses = UserPauseController(clock: { TimedPauseTests.monday })
        pauses.pause(until: start.addingTimeInterval(3_600))
        pauses.pause(until: nil)
        XCTAssertTrue(pauses.isPaused)
        XCTAssertNil(pauses.resumeAt)
        XCTAssertEqual(pauses.pausedSince, start, "a pause already on keeps its first time")
        XCTAssertFalse(pauses.isDue(now: start.addingTimeInterval(86_400)))
    }

    func testPauseLengthsEndWhenTheySay() {
        XCTAssertEqual(PauseLength.allCases.map(\.title), ["For 1 Hour", "Until Tomorrow", "Until I Start It Again"])
        XCTAssertEqual(PauseLength.hour.end(from: start, calendar: calendar), start.addingTimeInterval(3_600))
        XCTAssertNil(PauseLength.untilResume.end(from: start, calendar: calendar))
        let tomorrow = PauseLength.tomorrow.end(from: start, calendar: calendar)
        XCTAssertEqual(tomorrow.map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0) },
                       DateComponents(month: 10, day: 13, hour: 6, minute: 0))
    }

    func testTheMenuSaysWhenATimedPauseEndsAndOffersStartRemembering() {
        let paused = StatusRow(StatusFacts(status: .paused, pausedSince: start), now: start, calendar: calendar)
        let timed = paused.pausedUntil(start.addingTimeInterval(3_600), now: start, calendar: calendar)
        XCTAssertEqual(timed.detail?.replacingOccurrences(of: "\u{202F}", with: " "), "Until 3:41 PM.")
        // One name for turning remembering back on, setup's own: Resume is
        // Working On's, and reopens a project.
        XCTAssertEqual(timed.actionTitle, "Start Remembering")
        XCTAssertEqual(timed.action, .resume)
        let tomorrow = paused.pausedUntil(PauseLength.tomorrow.end(from: start, calendar: calendar), now: start,
                                          calendar: calendar)
        XCTAssertEqual(tomorrow.detail?.replacingOccurrences(of: "\u{202F}", with: " "), "Until tomorrow at 6:00 AM.")
        XCTAssertEqual(paused.pausedUntil(nil, now: start), paused, "Until I Start It Again says since when")
        XCTAssertEqual(paused.actionTitle, "Start Remembering")
        let items = StatusMenuModel.items(row: timed, setupComplete: true, askLabel: "⇧⇧", aiToolsConnected: false)
        XCTAssertTrue(items.contains { $0.role == .action(.resume) && $0.title == "Start Remembering" })
    }

    func testPauseOffersHowLong() {
        let remembering = StatusRow(StatusFacts(status: .recording, lastSavedAt: start), now: start, calendar: calendar)
        let items = StatusMenuModel.items(row: remembering, setupComplete: true, askLabel: "⇧⇧",
                                          aiToolsConnected: false)
        let pause = items.first { $0.role == .action(.pause) }
        XCTAssertEqual(pause?.title, "Pause")
        XCTAssertEqual(pause?.submenu.map(\.title), ["For 1 Hour", "Until Tomorrow", "Until I Start It Again"])
        XCTAssertEqual(pause?.submenu.map(\.role), PauseLength.allCases.map { .pauseFor($0) })
        XCTAssertEqual(StatusRow.forgetting, StatusRow(title: "Forgetting\u{2026}", detail: nil, action: nil))
    }

    // MARK: The supervisor

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func supervisor(pauses: UserPauseController, clock: Clock,
                            sleep: @escaping @MainActor @Sendable (TimeInterval) async throws -> Void)
        -> ProcessSupervisor {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        return ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: FakeSupervisorTopology(), keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: pauses, clock: { clock.now },
            timedResumeSleep: sleep
        )
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testRememberingResumesOnTimeAfterATimedPause() async throws {
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock) { seconds in
            clock.now = clock.now.addingTimeInterval(seconds)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await supervisor.startAndWaitForReadiness()
        supervisor.pause(until: start.addingTimeInterval(3_600))
        XCTAssertEqual(supervisor.pausedUntil, start.addingTimeInterval(3_600))
        await eventually { supervisor.state == .running && !pauses.isPaused }
        XCTAssertFalse(pauses.isPaused, "the hour passed: remembering resumed by itself")
        XCTAssertNil(supervisor.pausedUntil)
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    func testAResumeBeforeTheEndCancelsIt() async throws {
        let clock = Clock(start)
        let pauses = UserPauseController(clock: { clock.now })
        let supervisor = supervisor(pauses: pauses, clock: clock) { _ in
            try await Task.sleep(for: .seconds(30))
        }
        try await supervisor.startAndWaitForReadiness()
        supervisor.pause(until: start.addingTimeInterval(3_600))
        await eventually { supervisor.state == .paused }
        supervisor.setPaused(false)
        await eventually { supervisor.state == .running }
        supervisor.pause(until: nil)
        await eventually { supervisor.state == .paused }
        XCTAssertNil(supervisor.pausedUntil)
        XCTAssertTrue(pauses.isPaused)
        try await supervisor.shutdownAndWait()
    }

    func testAPauseWhoseEndCameWhileQuitIsOverAtLaunch() async throws {
        try await withDefaults { defaults in
            UserPauseController(defaults: defaults, clock: { TimedPauseTests.monday })
                .pause(until: self.start.addingTimeInterval(60))
            let later = Clock(start.addingTimeInterval(3_600))
            let pauses = UserPauseController(defaults: defaults, clock: { later.now })
            let supervisor = supervisor(pauses: pauses, clock: later) { _ in }
            XCTAssertFalse(pauses.isPaused, "the end came while Hippocampus was quit")
            try await supervisor.startAndWaitForReadiness()
            XCTAssertEqual(supervisor.state, .running)
            try await supervisor.shutdownAndWait()
        }
    }
}
