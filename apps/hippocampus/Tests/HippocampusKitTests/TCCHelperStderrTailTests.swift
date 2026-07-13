// SPDX-License-Identifier: TBD-private
//
// TCCHelperStderrTailTests — cycle 8.47 PR #80 follow-up.
//
// Covers three things:
//
//   (1) `TCCHelperStderrParser.parseLine` recognises the exact wire
//       format the helper emits via `TCCHelperHealth.line(...)`:
//         `mci-capture-helper: helper_health tcc_revoked=<surface>`
//         `mci-capture-helper: helper_health tcc_restored=<surface>`
//       …across all four surfaces, ignores unknown lines, and tolerates
//       leading log-line decoration.
//
//   (2) The full pipe (breadcrumb chunk → parser → sink) routes a
//       `tcc_revoked=screen_recording` breadcrumb to
//       `TCCRevokedNotifier.notifyRevoked(.screenRecording)` AND
//       mirrors the surface onto `ProcessSupervisor.tccRevokedSurface`,
//       so `MenuBarStatus.derive(from:, tccRevokedSurface:)` returns
//       the correct `.error("Screen Recording revoked")` state.
//
//   (3) The matching `tcc_restored=<surface>` clears the pipeline —
//       both the notifier's outstanding set AND the supervisor's
//       tccRevokedSurface — so the menu-bar red pill drops back to
//       whatever the underlying supervisor state says.

import XCTest
import UserNotifications
@testable import HippocampusKit

// MARK: - Fakes

@MainActor
private final class RecordingSink: TCCRevokedEventSink {
    var revoked: [TCCRevokedReason] = []
    var restored: [TCCRevokedReason] = []

    func handleRevoked(_ reason: TCCRevokedReason) async {
        revoked.append(reason)
    }

    func handleRestored(_ reason: TCCRevokedReason) async {
        restored.append(reason)
    }
}

/// Reused from `TCCRevokedRecoveryTests` — kept private per-file rather
/// than cross-file-shared because the `@testable` module gives every
/// XCTest file access to the same internals; a private duplicate here
/// avoids leaking a test-only public symbol into HippocampusKit.
private final class FakeUNCenter: UserNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private var _removedPending: [String] = []
    private var _removedDelivered: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws {
        lock.lock(); _added.append(request); lock.unlock()
    }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        lock.lock(); _removedPending.append(contentsOf: ids); lock.unlock()
    }
    func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        lock.lock(); _removedDelivered.append(contentsOf: ids); lock.unlock()
    }
    var added: [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }; return _added
    }
    var removedPending: [String] {
        lock.lock(); defer { lock.unlock() }; return _removedPending
    }
}

// MARK: - Parser tests

final class TCCHelperStderrParserTests: XCTestCase {

    // (1) The exact line format the helper emits (verified by
    // `TCCHelperHealthTests.testHealthLineForRevoked_hasFrozenFormat`
    // on the helper side).

    func testParse_revokedScreenRecording() {
        let line = "mci-capture-helper: helper_health tcc_revoked=screenRecording\n"
        XCTAssertEqual(
            TCCHelperStderrParser.parseLine(line),
            .revoked(.screenRecording)
        )
    }

    func testParse_restoredAccessibility() {
        let line = "mci-capture-helper: helper_health tcc_restored=accessibility"
        XCTAssertEqual(
            TCCHelperStderrParser.parseLine(line),
            .restored(.accessibility)
        )
    }

    func testParse_allFourSurfaces_revoked() {
        for reason in TCCRevokedReason.allCases {
            let line = "mci-capture-helper: helper_health tcc_revoked=\(reason.rawValue)"
            XCTAssertEqual(
                TCCHelperStderrParser.parseLine(line),
                .revoked(reason),
                "surface \(reason.rawValue) must parse"
            )
        }
    }

    func testParse_allFourSurfaces_restored() {
        for reason in TCCRevokedReason.allCases {
            let line = "mci-capture-helper: helper_health tcc_restored=\(reason.rawValue)"
            XCTAssertEqual(
                TCCHelperStderrParser.parseLine(line),
                .restored(reason)
            )
        }
    }

    func testParse_ignoresUnknownSurface() {
        XCTAssertNil(TCCHelperStderrParser.parseLine(
            "mci-capture-helper: helper_health tcc_revoked=bluetooth"
        ))
    }

    func testParse_ignoresUnknownKey() {
        // The helper reserves `tcc_revoked` / `tcc_restored` — any
        // other `helper_health <foo>=<bar>` is ignored so an unrelated
        // future breadcrumb category cannot spuriously fire the
        // notifier.
        XCTAssertNil(TCCHelperStderrParser.parseLine(
            "mci-capture-helper: helper_health frame_delivered=42"
        ))
    }

    func testParse_ignoresNonHelperLine() {
        XCTAssertNil(TCCHelperStderrParser.parseLine(
            "[2026-07-13T10:00:00Z] mci-agent: Rust panic somewhere"
        ))
        XCTAssertNil(TCCHelperStderrParser.parseLine(""))
        XCTAssertNil(TCCHelperStderrParser.parseLine("   "))
    }

    func testParse_toleratesLeadingDecoration() {
        // Some log wrappers prepend timestamps / PID tags. The parser
        // scans for the `helper_health ` marker anywhere in the line.
        let line = "[2026-07-13T10:00:00Z pid=1234] mci-capture-helper: helper_health tcc_revoked=fullDiskAccess"
        XCTAssertEqual(
            TCCHelperStderrParser.parseLine(line),
            .revoked(.fullDiskAccess)
        )
    }

    func testParseChunk_multiline() {
        let chunk = """
        random helper log line
        mci-capture-helper: helper_health tcc_revoked=screenRecording
        another unrelated line
        mci-capture-helper: helper_health tcc_restored=screenRecording
        """
        XCTAssertEqual(
            TCCHelperStderrParser.parseChunk(chunk),
            [.revoked(.screenRecording), .restored(.screenRecording)]
        )
    }
}

// MARK: - Integration tests

final class TCCHelperStderrTailIntegrationTests: XCTestCase {

    /// (2) End-to-end: a `helper_health tcc_revoked=screenRecording`
    /// breadcrumb routes to the sink, which drives the notifier +
    /// mirrors the supervisor's `tccRevokedSurface`, which flips
    /// `MenuBarStatus.derive` to `.error("Screen Recording revoked")`.
    @MainActor
    func testEndToEnd_revokedBreadcrumb_firesNotifierAndFlipsMenuBar() async {
        let sink = RecordingSink()
        let tail = TCCHelperStderrTail(
            sink: sink,
            logPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("stderr-\(UUID().uuidString).log")
        )

        // Simulate the helper's stderr chunk arriving via the file
        // watch. `injectForTest` bypasses the file layer so we don't
        // race on FS events during CI.
        await tail.injectForTest(
            "mci-capture-helper: helper_health tcc_revoked=screenRecording\n"
        )

        XCTAssertEqual(sink.revoked, [.screenRecording])
        XCTAssertEqual(sink.restored, [])
    }

    /// The full production sink drives BOTH the notifier and the
    /// supervisor mirror in one call.
    @MainActor
    func testProductionSink_revokedDrivesNotifierAndSupervisor() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)
        let supervisor = ProcessSupervisor(
            locator: FakeBinaryLocator(),
            keyStore: FakeKeyStore()
        )
        let sink = TCCNotifierAndSupervisorSink(
            notifier: notifier,
            supervisor: supervisor
        )

        await sink.handleRevoked(.screenRecording)

        // Notifier fired.
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(
            center.added[0].identifier,
            TCCRevokedNotifierRequestBuilder.identifier(for: .screenRecording)
        )

        // Supervisor mirror set.
        XCTAssertEqual(supervisor.tccRevokedSurface, .screenRecording)

        // MenuBarStatus.derive picks up the mirror and forces .error
        // — even when the supervisor state itself is .running.
        let status = MenuBarStatus.derive(
            from: .running,
            tccRevokedSurface: supervisor.tccRevokedSurface
        )
        guard case .error(let reason) = status else {
            return XCTFail("expected .error, got \(status)")
        }
        XCTAssertEqual(reason, "Screen Recording revoked")
    }

    /// (3) The matching `tcc_restored=<surface>` clears both the
    /// notifier's outstanding set AND the supervisor's mirror.
    @MainActor
    func testProductionSink_restoredClearsMenuBar() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)
        let supervisor = ProcessSupervisor(
            locator: FakeBinaryLocator(),
            keyStore: FakeKeyStore()
        )
        let sink = TCCNotifierAndSupervisorSink(
            notifier: notifier,
            supervisor: supervisor
        )

        await sink.handleRevoked(.accessibility)
        XCTAssertEqual(supervisor.tccRevokedSurface, .accessibility)

        await sink.handleRestored(.accessibility)
        XCTAssertNil(supervisor.tccRevokedSurface)
        XCTAssertFalse(
            center.removedPending.isEmpty,
            "restore must clear pending notification"
        )

        // With the mirror cleared, MenuBarStatus falls back to the
        // underlying supervisor state — .running → .recording.
        XCTAssertEqual(
            MenuBarStatus.derive(
                from: .running,
                tccRevokedSurface: supervisor.tccRevokedSurface
            ),
            .recording
        )
    }

    /// A restored breadcrumb for a DIFFERENT surface than the one
    /// currently tracked does NOT clear the menu-bar mirror — this
    /// prevents a stray `tcc_restored=accessibility` from flipping off
    /// the red pill while `screenRecording` is still revoked.
    @MainActor
    func testProductionSink_restoreOfDifferentSurface_doesNotClearMirror() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)
        let supervisor = ProcessSupervisor(
            locator: FakeBinaryLocator(),
            keyStore: FakeKeyStore()
        )
        let sink = TCCNotifierAndSupervisorSink(
            notifier: notifier,
            supervisor: supervisor
        )

        await sink.handleRevoked(.screenRecording)
        XCTAssertEqual(supervisor.tccRevokedSurface, .screenRecording)

        await sink.handleRestored(.accessibility)
        XCTAssertEqual(
            supervisor.tccRevokedSurface,
            .screenRecording,
            "restore of a non-tracked surface must not clear the tracked one"
        )
    }

    /// Full pipeline via the tail's inject hook: parser → sink →
    /// notifier + supervisor.
    @MainActor
    func testTail_endToEndViaProductionSink() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)
        let supervisor = ProcessSupervisor(
            locator: FakeBinaryLocator(),
            keyStore: FakeKeyStore()
        )
        let sink = TCCNotifierAndSupervisorSink(
            notifier: notifier,
            supervisor: supervisor
        )
        let tail = TCCHelperStderrTail(
            sink: sink,
            logPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("stderr-\(UUID().uuidString).log")
        )

        await tail.injectForTest(
            "mci-capture-helper: helper_health tcc_revoked=fullDiskAccess\n"
        )
        XCTAssertEqual(supervisor.tccRevokedSurface, .fullDiskAccess)
        XCTAssertEqual(center.added.count, 1)
    }
}

// Test doubles for ProcessSupervisor construction are shared with
// `ProcessSupervisorTests.swift` (same test target): `FakeBinaryLocator`
// + `FakeKeyStore`. Reused rather than duplicated.
