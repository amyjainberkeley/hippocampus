// SPDX-License-Identifier: Apache-2.0
//
// Opening the window while its process runs. The window's process ends with
// its last window, and between the close and its exit it no longer hears the
// app; a minimized window stayed in the Dock. The app took any running
// process as one that would show the window: it posted the command and
// activated it, and nothing appeared. Now the window answers when it shows
// itself, and with no answer the app waits for that process to end and opens
// a fresh window on the place asked for.
//
// Nothing here messages a real Recall window: the stand-in windows are shell
// scripts, and the channel is a fake or the real one on names made up for the
// test.

import XCTest
@testable import HippocampusKit

/// Records the commands sent to a running window and answers as told.
@MainActor
final class FakeRecallWindowChannel: RecallWindowCommanding {
    var answers = true
    private(set) var tabs: [String?] = []

    func command(_ command: [String: Any], processID: pid_t, timeout: Duration) async -> Bool {
        tabs.append(command["tab"] as? String)
        return answers
    }
}

@MainActor
final class WindowProcessTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("window-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A supervisor whose window is a stand-in that writes the place it
    /// opened on and then stays up for `lingers` seconds, as the window's
    /// process does between its last window closing and its exit.
    private func make(
        lingers seconds: Double, channel: any RecallWindowCommanding
    ) throws -> (ProcessSupervisor, URL) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let windows = scratch.appendingPathComponent("windows")
        let script = scratch.appendingPathComponent("recall-ui")
        try "#!/bin/sh\nprintf '%s\\n' \"$MCI_INITIAL_TAB\" >> '\(windows.path)'\nexec /bin/sleep \(seconds)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        locator.recallURL = script
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: FakeSupervisorTopology(), keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, memoryOnDisk: { true }, recallWindowChannel: channel
        )
        return (supervisor, windows)
    }

    private func opened(_ windows: URL, count: Int, within seconds: TimeInterval) async -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var lines: [String] = []
        repeat {
            lines = ((try? String(contentsOf: windows, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if lines.count >= count { return lines }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        return lines
    }

    /// Closed with ⌘W, the window's process is quitting; Hippocampus is
    /// opened again at once. The command finds no window to answer, so the
    /// app waits for that process to end and opens a fresh window.
    func test_a_reopen_while_the_windows_process_is_quitting_opens_a_fresh_window() async throws {
        let channel = FakeRecallWindowChannel()
        channel.answers = false
        let (supervisor, windows) = try make(lingers: 1.5, channel: channel)
        try await supervisor.startAndWaitForReadiness()
        supervisor.reopenWindow()
        let first = await opened(windows, count: 1, within: 5)
        XCTAssertEqual(first, ["overview"])

        supervisor.reopenWindow()

        let places = await opened(windows, count: 2, within: 8)
        XCTAssertEqual(places, ["overview", "overview"], "the reopen went to a process that was quitting")
        XCTAssertEqual(channel.tabs, ["overview"], "it asked the running one first")
        await supervisor.stopWindowsForQuit(timeout: 1)
        try await supervisor.shutdownAndWait()
    }

    /// A window that answers shows itself (minimized ones come back out of
    /// the Dock): the app opens nothing beside it.
    func test_a_window_that_answers_shows_itself_and_nothing_else_opens() async throws {
        let channel = FakeRecallWindowChannel()
        let (supervisor, windows) = try make(lingers: 5, channel: channel)
        try await supervisor.startAndWaitForReadiness()
        supervisor.reopenWindow()
        _ = await opened(windows, count: 1, within: 5)

        supervisor.openRecallUI(initialTab: "search")
        supervisor.openRecallUI()

        let places = await opened(windows, count: 2, within: 1)
        XCTAssertEqual(places, ["overview"], "a second window process beside the first")
        XCTAssertEqual(channel.tabs, ["search", nil])
        await supervisor.stopWindowsForQuit(timeout: 1)
        try await supervisor.shutdownAndWait()
    }

    /// One that neither answers nor ends (stuck) is never doubled: a second
    /// window process would be a second reader of the memory.
    func test_a_window_that_neither_answers_nor_ends_is_not_doubled() async throws {
        let channel = FakeRecallWindowChannel()
        channel.answers = false
        let (supervisor, windows) = try make(lingers: 30, channel: channel)
        try await supervisor.startAndWaitForReadiness()
        supervisor.reopenWindow()
        _ = await opened(windows, count: 1, within: 5)

        supervisor.reopenWindow()

        let places = await opened(windows, count: 2, within: 5)
        XCTAssertEqual(places, ["overview"])
        await supervisor.stopWindowsForQuit(timeout: 1)
        try await supervisor.shutdownAndWait()
    }

    /// Quit retires the windows: a request still waiting opens nothing after.
    func test_nothing_opens_once_quit_has_closed_the_windows() async throws {
        let channel = FakeRecallWindowChannel()
        channel.answers = false
        let (supervisor, windows) = try make(lingers: 1, channel: channel)
        try await supervisor.startAndWaitForReadiness()
        supervisor.reopenWindow()
        _ = await opened(windows, count: 1, within: 5)
        supervisor.reopenWindow()

        await supervisor.stopWindowsForQuit(timeout: 1)

        let places = await opened(windows, count: 2, within: 2.5)
        XCTAssertEqual(places, ["overview"])
        try await supervisor.shutdownAndWait()
    }

    /// The real channel, on names made up for this test: the command goes
    /// out at once with an id, and the answer that repeats it, from the
    /// window's process, is heard.
    func test_the_distributed_channel_hears_the_answer_to_its_command() async throws {
        let commandName = Notification.Name("dev.hippocampus.tests.recall.command.\(UUID().uuidString)")
        let answerName = Notification.Name("dev.hippocampus.tests.recall.answer.\(UUID().uuidString)")
        let channel = DistributedRecallWindowChannel(commandName: commandName, acknowledgementName: answerName)
        let center = DistributedNotificationCenter.default()
        let window: pid_t = 4242
        let observer = center.addObserver(forName: commandName, object: nil, queue: .main) { note in
            guard let id = note.userInfo?["request_id"] as? String else { return }
            center.postNotificationName(answerName, object: String(window), userInfo: ["request_id": id], deliverImmediately: true)
        }
        defer { center.removeObserver(observer) }

        let answered = await channel.command(["tab": "overview"], processID: window, timeout: .seconds(2))
        XCTAssertTrue(answered)

        let fromAnother = await channel.command(["tab": "overview"], processID: window + 1, timeout: .milliseconds(300))
        XCTAssertFalse(fromAnother, "only that process's answer counts")
    }

    /// The app speaks the window's own words (RecallUIKit's names).
    func test_the_app_and_the_window_use_the_same_names() throws {
        let tab = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("../recall-ui/Sources/RecallUIKit/Tab.swift").standardizedFileURL,
            encoding: .utf8
        )
        let channel = DistributedRecallWindowChannel()
        XCTAssertTrue(tab.contains("\"\(channel.commandName.rawValue)\""))
        XCTAssertTrue(tab.contains("\"\(channel.acknowledgementName.rawValue)\""))
        XCTAssertTrue(tab.contains("public static let requestIDKey = \"\(DistributedRecallWindowChannel.requestIDKey)\""))
    }
}
