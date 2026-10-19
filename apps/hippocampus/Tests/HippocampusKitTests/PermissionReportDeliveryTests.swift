// SPDX-License-Identifier: Apache-2.0
//
// The helper's permission lines reach the status at once. The stderr tail
// handles one event at a time and waited on each: the sink awaited the
// notifier, which awaited macOS's "allow notifications" prompt for the app's
// first permission notification. Until the person answered it, a later
// `tcc_restored` line never reached the supervisor, and the menu kept "Needs
// permission" (h!) while the helper read again.

import UserNotifications
import XCTest
@testable import HippocampusKit

/// A notification center whose authorization request waits until `answer`,
/// as macOS's prompt does until the person answers it.
final class PromptingNotificationCenter: UserNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var answered: Bool?
    private var _added: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        await withCheckedContinuation { continuation in
            let answer: Bool? = lock.withLock {
                if answered == nil { waiters.append(continuation) }
                return answered
            }
            if let answer { continuation.resume(returning: answer) }
        }
    }

    func answer(_ granted: Bool) {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            answered = granted
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(returning: granted) }
    }

    func add(_ request: UNNotificationRequest) async throws { lock.withLock { _added.append(request) } }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) {}
    func removeDeliveredNotifications(withIdentifiers ids: [String]) {}
    var added: [UNNotificationRequest] { lock.withLock { _added } }
}

@MainActor
final class PermissionReportDeliveryTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tcc-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func make() -> (ProcessSupervisor, FakeSupervisorTopology) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: topology, keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }
        )
        return (supervisor, topology)
    }

    private func write(_ line: String, to log: URL) throws {
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try handle.close()
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

    /// Accessibility goes off while remembering runs, the app's first
    /// permission notification waits on macOS's prompt, and the person
    /// allows Accessibility again before answering it: the helper's
    /// `tcc_restored` line reaches the status at once, and remembering is
    /// started again. The notification for a permission already back is
    /// never shown.
    func test_a_restore_reaches_the_status_while_the_notification_prompt_waits() async throws {
        let (supervisor, topology) = make()
        try await supervisor.startAndWaitForReadiness()
        let log = scratch.appendingPathComponent("helper.stderr.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let center = PromptingNotificationCenter()
        let tail = TCCHelperStderrTail(
            sink: TCCNotifierAndSupervisorSink(notifier: TCCRevokedNotifier(center: center), supervisor: supervisor),
            logPath: log
        )
        tail.start()
        defer { tail.stop() }

        try write("mci-capture-helper: helper_health tcc_revoked=accessibility", to: log)
        await eventually { supervisor.tccRevokedSurface == .accessibility }
        XCTAssertEqual(supervisor.menuBarStatus.markState, .needsYou)

        try write("mci-capture-helper: helper_health tcc_restored=accessibility", to: log)
        await eventually({ supervisor.tccRevokedSurface == nil }, within: 2.5)
        await eventually { supervisor.state == .running }
        XCTAssertGreaterThan(topology.launchPlans.count, 1, "remembering started again")

        center.answer(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(center.added.isEmpty, "no notification for a permission already back")
        try await supervisor.shutdownAndWait()
    }

    /// A second permission going off while the first notification waits on
    /// the prompt reaches the status at once too.
    func test_a_second_permission_report_is_not_held_behind_the_prompt() async throws {
        let (supervisor, _) = make()
        let center = PromptingNotificationCenter()
        let sink = TCCNotifierAndSupervisorSink(notifier: TCCRevokedNotifier(center: center), supervisor: supervisor)

        let delivery = Task { @MainActor in
            await sink.handleRevoked(.accessibility)
            await sink.handleRevoked(.screenRecording)
        }

        await eventually({ supervisor.tccRevokedSurface == .screenRecording }, within: 2)
        center.answer(true)
        await delivery.value
        await eventually { center.added.count == 2 }
    }
}
