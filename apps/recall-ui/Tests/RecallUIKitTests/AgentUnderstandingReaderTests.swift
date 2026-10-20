import XCTest
import os
@testable import RecallUIKit

final class AgentUnderstandingReaderTests: XCTestCase {
    private let recall = URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/recall-ui")
    private let agent = "/Applications/Hippocampus.app/Contents/MacOS/mci-agent"
    private let today = UnderstandingDay(dateLocal: "2026-10-12", tzOffsetSeconds: -25_200)
    private let yesterday = UnderstandingDay(dateLocal: "2026-10-11", tzOffsetSeconds: -25_200)

    private var pacific: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func reader(
        _ runner: RecordingRunner,
        clock: TestClock = TestClock(),
        environment: [String: String] = ["MCI_DB_PATH": "/tmp/fixture/mci.sqlite"],
        deletions: MemoryDeletionSignal = MemoryDeletionSignal(),
        verdicts: VerdictInbox? = nil,
        isExecutable: @escaping @Sendable (URL) -> Bool = { $0.path == "/Applications/Hippocampus.app/Contents/MacOS/mci-agent" }
    ) -> AgentUnderstandingReader {
        AgentUnderstandingReader(environment: environment, recallExecutableURL: recall, isExecutable: isExecutable,
                                 run: runner.run, now: { clock.now }, calendar: pacific,
                                 deletions: deletions, verdicts: verdicts)
    }

    private static func samples(overview isToday: Bool = true) -> RecordingRunner {
        RecordingRunner { command in
            switch command.arguments.first {
            case "overview":
                var text = try UnderstandingFixture.text("overview.sample.json")
                if !isToday { text = text.replacingOccurrences(of: #""is_today": true"#, with: #""is_today": false"#) }
                return text
            default:
                return try UnderstandingFixture.text("model-page.sample.json")
            }
        }
    }

    func testTheOverviewRunsTheBundledAgentWithTheDayAndItsOffset() async throws {
        let runner = Self.samples()
        let overview = try await reader(runner).overview(today)
        XCTAssertEqual(overview.date, "2026-10-12")
        XCTAssertEqual(runner.commands.map(\.executableURL.path), [agent])
        XCTAssertEqual(runner.commands.first?.arguments, [
            "overview", "--json", "--date", "2026-10-12", "--tz-offset-secs", "-25200",
            "--db-path", "/tmp/fixture/mci.sqlite",
        ])
        XCTAssertEqual(runner.timeouts, [20])
    }

    func testTheYouPageRunsTheAgentWithTheCurrentOffset() async throws {
        let runner = Self.samples()
        let page = try await reader(runner, environment: [:]).modelPage()
        XCTAssertEqual(page.shared.count, 4)
        XCTAssertEqual(page.notSent.count, 5)
        XCTAssertEqual(runner.commands.first?.arguments, ["model", "--page", "--json", "--tz-offset-secs", "-25200"])
        XCTAssertEqual(runner.timeouts, [20])
    }

    func testTheOffsetIsTakenAtNoonOfTheSelectedDay() {
        let calendar = pacific
        func day(_ year: Int, _ month: Int, _ date: Int, hour: Int) -> UnderstandingDay {
            let moment = calendar.date(from: DateComponents(year: year, month: month, day: date, hour: hour, minute: 30))!
            return UnderstandingDay(date: moment, calendar: calendar)
        }
        XCTAssertEqual(day(2026, 10, 12, hour: 0), UnderstandingDay(dateLocal: "2026-10-12", tzOffsetSeconds: -25_200))
        // Clocks go back at 2 AM on Nov 1: just after midnight is still summer time, noon is not.
        XCTAssertEqual(day(2026, 11, 1, hour: 0), UnderstandingDay(dateLocal: "2026-11-01", tzOffsetSeconds: -28_800))
        // Clocks go forward at 2 AM on Mar 8: noon is summer time.
        XCTAssertEqual(day(2026, 3, 8, hour: 0), UnderstandingDay(dateLocal: "2026-03-08", tzOffsetSeconds: -25_200))
        XCTAssertEqual(day(2026, 3, 7, hour: 23), UnderstandingDay(dateLocal: "2026-03-07", tzOffsetSeconds: -28_800))
    }

    func testTheDateIsGregorianWhateverCalendarThePersonUses() {
        // 14:37:05 on Oct 12, 2026 in Los Angeles: 2569 in the Buddhist
        // calendar, Reiwa 8 in the Japanese one, 20 Mehr 1405 in the Persian one.
        let moment = Date(timeIntervalSince1970: 1_791_841_025)
        for identifier in [Calendar.Identifier.buddhist, .japanese, .persian] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            XCTAssertEqual(UnderstandingDay(date: moment, calendar: calendar),
                           UnderstandingDay(dateLocal: "2026-10-12", tzOffsetSeconds: -25_200), "\(identifier)")
            XCTAssertEqual(MemoryDay(date: moment, calendar: calendar), MemoryDay(date: moment, calendar: pacific),
                           "\(identifier): the same day, named and bounded the same way")
        }
    }

    func testWithoutTheAgentNothingRunsAndTheReadIsUnavailable() async {
        let runner = Self.samples()
        let reader = reader(runner, isExecutable: { _ in false })
        do {
            _ = try await reader.overview(today)
            XCTFail("no agent, no overview")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .unavailable)
        }
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testTodaysOverviewIsKeptForTwoMinutes() async throws {
        let runner = Self.samples()
        let clock = TestClock()
        let reader = reader(runner, clock: clock)
        _ = try await reader.overview(today)
        clock.advance(by: 119)
        _ = try await reader.overview(today)
        XCTAssertEqual(runner.commands.count, 1)
        clock.advance(by: 2)
        _ = try await reader.overview(today)
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testAnotherDaysOverviewIsKeptLonger() async throws {
        let runner = Self.samples(overview: false)
        let clock = TestClock()
        let reader = reader(runner, clock: clock)
        _ = try await reader.overview(yesterday)
        clock.advance(by: 599)
        _ = try await reader.overview(yesterday)
        XCTAssertEqual(runner.commands.count, 1)
        clock.advance(by: 2)
        _ = try await reader.overview(yesterday)
        XCTAssertEqual(runner.commands.count, 2)
        _ = try await reader.overview(today)
        XCTAssertEqual(runner.commands.count, 3, "each day is its own read")
    }

    func testTheYouPageIsKeptForTwoMinutes() async throws {
        let runner = Self.samples()
        let clock = TestClock()
        let reader = reader(runner, clock: clock)
        _ = try await reader.modelPage()
        clock.advance(by: 119)
        _ = try await reader.modelPage()
        XCTAssertEqual(runner.commands.count, 1)
        clock.advance(by: 2)
        _ = try await reader.modelPage()
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testReadsAtTheSameTimeShareOneChild() async throws {
        let gate = Gate()
        let runner = RecordingRunner { _ in
            gate.wait()
            return try UnderstandingFixture.text("overview.sample.json")
        }
        let reader = reader(runner)
        let day = today
        async let first = reader.overview(day)
        async let second = reader.overview(day)
        await assertEventually { runner.commands.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testFailuresAreUnavailableOrMalformedAndAreNotKept() async throws {
        let failing = RecordingRunner { _ in throw ContextHandoffError.commandFailed }
        let unavailable = reader(failing)
        for _ in 0..<2 {
            do {
                _ = try await unavailable.overview(today)
                XCTFail("a failed command is not an overview")
            } catch {
                XCTAssertEqual(error as? UnderstandingError, .unavailable)
            }
        }
        XCTAssertEqual(failing.commands.count, 2, "a failure is never cached")

        let garbled = RecordingRunner { _ in "Hippocampus is starting" }
        do {
            _ = try await reader(garbled).modelPage()
            XCTFail("text that is not JSON is not a page")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .malformed)
        }

        // An agent without `--page` reads the flags as words and prints its
        // old list with exit 0 (mci_agent.rs:2613).
        let older = RecordingRunner { _ in #"{"propositions":[]}"# }
        do {
            _ = try await reader(older).modelPage()
            XCTFail("an older agent's list is not an empty You page")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .malformed)
        }
    }

    func testACancelledReadIsCancellationNeverUnavailable() async throws {
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let reader = AgentUnderstandingReader(
            environment: [:], recallExecutableURL: recall, isExecutable: { _ in true },
            run: { _, _ in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    stopped.withLock { $0 = true }
                    throw error
                }
                return ""
            },
            deletions: MemoryDeletionSignal(), verdicts: nil)
        let day = today
        let read = Task { try await reader.overview(day) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = Date()
        read.cancel()
        do {
            _ = try await read.value
            XCTFail("a cancelled read returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
        await assertEventually("the read nobody waits for is stopped") { stopped.withLock { $0 } }
    }

    func testOneWaiterCancellingLeavesTheOtherItsRead() async throws {
        let gate = Gate()
        let runner = RecordingRunner { _ in
            gate.wait()
            return try UnderstandingFixture.text("overview.sample.json")
        }
        let reader = reader(runner)
        let day = today
        let leaving = Task { try await reader.overview(day) }
        let staying = Task { try await reader.overview(day) }
        await assertEventually { runner.commands.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        leaving.cancel()
        do {
            _ = try await leaving.value
            XCTFail("the cancelled waiter returned")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        gate.open()
        let overview = try await staying.value
        XCTAssertEqual(overview.blocks.count, 8)
    }

    func testADeleteDropsEveryCachedRead() async throws {
        let runner = Self.samples()
        let deletions = MemoryDeletionSignal()
        let reader = reader(runner, deletions: deletions)
        _ = try await reader.overview(today)
        _ = try await reader.modelPage()
        _ = try await reader.overview(today)
        XCTAssertEqual(runner.commands.count, 2)
        await MainActor.run { deletions.post() }
        _ = try await reader.overview(today)
        _ = try await reader.modelPage()
        XCTAssertEqual(runner.commands.count, 4)
    }

    func testInvalidateDropsEveryCachedRead() async throws {
        let runner = Self.samples()
        let reader = reader(runner)
        _ = try await reader.overview(today)
        await reader.invalidate()
        _ = try await reader.overview(today)
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testPendingVerdictsAreLaidOverEveryReadEvenACachedOne() async throws {
        let folder = try TestFolders.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = VerdictInbox(directory: folder.appendingPathComponent("inbox"), environment: [:])
        let runner = Self.samples()
        let reader = reader(runner, verdicts: inbox)
        let before = try await reader.modelPage()
        XCTAssertTrue(before.shared.contains { $0.id == 41 })
        try inbox.give(.reject, id: 41)
        try inbox.give(.confirm, id: 45)
        let after = try await reader.modelPage()
        XCTAssertEqual(runner.commands.count, 1, "the second read came from the cache")
        XCTAssertFalse(after.shared.contains { $0.id == 41 })
        XCTAssertEqual(after.notSent.first { $0.id == 45 }?.basis, .confirmed)
        let overview = try await reader.overview(today)
        XCTAssertFalse(overview.aiKnows.aboutYou.contains { $0.id == 41 })
    }

    func testTheRealRunnersChildIsStoppedWhenItsReadIsCancelled() async throws {
        let folder = try TestFolders.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A stand-in agent that never answers.
        let agent = folder.appendingPathComponent("mci-agent")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        let children = ChildProcesses()
        let reader = AgentUnderstandingReader(
            environment: [:], recallExecutableURL: folder.appendingPathComponent("recall-ui"),
            run: { try await ContextHandoffExporter.run(command: $0, timeoutSeconds: $1, children: children) },
            deletions: MemoryDeletionSignal(), verdicts: nil)
        let day = today
        let read = Task { try await reader.overview(day) }
        await assertEventually { children.running.count == 1 }
        let pid = try XCTUnwrap(children.running.first)
        read.cancel()
        do {
            _ = try await read.value
            XCTFail("a cancelled read returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await assertEventually { children.running.isEmpty && !isAlive(pid) }
    }
}

/// Holds a fake command until the test lets it finish.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal(); semaphore.signal() }
}
