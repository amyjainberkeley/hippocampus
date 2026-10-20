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
        var isQuiet: Bool { real.isQuiet }
        var isConnectingAITools: Bool { false }
        func pauseRemembering() async throws { try await real.pauseRemembering() }
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
                            topology: FakeSupervisorTopology = FakeSupervisorTopology()) -> ProcessSupervisor {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        return ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: captureEnabled),
            topology: topology, keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: pauses, clock: { clock.now },
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
}
