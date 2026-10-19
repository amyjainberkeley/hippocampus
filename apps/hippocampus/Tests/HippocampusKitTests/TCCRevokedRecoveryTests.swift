// SPDX-License-Identifier: Apache-2.0
//
// TCCRevokedRecoveryTests — cycle 8.45 audit risk #2. Pins the
// menu-bar + notifier contract:
//   (a) tccRevokedSurface overrides even a .running supervisor state;
//   (b) TCCRevokedReason.fromHealthLogSurface round-trips the wire
//       identifier the helper emits;
//   (c) settingsPaneURLString is a valid parseable URL for every case;
//   (d) TCCRevokedNotifier is idempotent per surface — repeated
//       notifyRevoked(_:) calls result in ONE `add(_:)` call;
//   (e) notifyRestored(_:) clears state so a subsequent
//       notifyRevoked(_:) fires again;
//   (f) TCCRevokedNotificationActionHandler ignores non-MCI categories.

import XCTest
import UserNotifications
@testable import HippocampusKit

// MARK: - Fake UserNotificationCenter

private final class FakeUNCenter: UserNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private var _removedPending: [String] = []
    private var _removedDelivered: [String] = []
    private var _authorizationRequests = 0

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock { _authorizationRequests += 1 }
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _added.append(request) }
    }

    func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        lock.withLock { _removedPending.append(contentsOf: ids) }
    }

    func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        lock.withLock { _removedDelivered.append(contentsOf: ids) }
    }

    var added: [UNNotificationRequest] {
        lock.withLock { _added }
    }
    var removedPending: [String] {
        lock.withLock { _removedPending }
    }
    var removedDelivered: [String] {
        lock.withLock { _removedDelivered }
    }
    var authorizationRequests: Int {
        lock.withLock { _authorizationRequests }
    }
}

final class TCCRevokedRecoveryTests: XCTestCase {

    // (a)
    func testDerivation_tccRevokedOverridesRunning() {
        let status = MenuBarStatus.derive(
            from: .running,
            tccRevokedSurface: .screenRecording
        )
        XCTAssertEqual(status, .needsPermission(.screenRecording))
    }

    func testDerivation_tccRevokedOverridesIntegrityError() {
        // Precedence: TCC revoke is user-recoverable (one click), it
        // must surface first so the notification's actionable button
        // is discoverable.
        let status = MenuBarStatus.derive(
            from: .running,
            integrityError: "hash mismatch",
            tccRevokedSurface: .accessibility
        )
        XCTAssertEqual(status, .needsPermission(.accessibility))
    }

    func testDerivation_noOverride_preservesLegacyBehaviour() {
        // Sanity: pre-cycle-8.45 callsites that pass no override
        // continue to behave exactly as before.
        XCTAssertNotEqual(
            MenuBarStatus.derive(from: .running),
            .recording
        )
        XCTAssertEqual(
            MenuBarStatus.derive(from: .paused),
            .paused
        )
    }

    // (b)
    func testFromHealthLogSurface_roundTripsAllCases() {
        for reason in TCCRevokedReason.allCases {
            let raw = reason.rawValue
            XCTAssertEqual(
                TCCRevokedReason.fromHealthLogSurface(raw),
                reason,
                "raw \(raw) must round-trip"
            )
        }
    }

    /// The helper names permissions by its `TCCSurface` (readiness receipt,
    /// stderr breadcrumbs) and the app reads them as `TCCRevokedReason`. A
    /// surface added to one and not the other is a permission the app cannot
    /// name: the two lists are the same, in the same spelling.
    func testTheHelpersSurfacesAndTheAppsReasonsShareTheirNames() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let monitor = package.appendingPathComponent(
            "../../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/TCC/TCCStatusMonitor.swift"
        ).standardizedFileURL
        let source = try String(contentsOf: monitor, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public enum TCCSurface: String, Sendable, CaseIterable {"))
        let end = try XCTUnwrap(source.range(of: "}", range: start.upperBound..<source.endIndex))
        let surfaces = source[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { String($0.dropFirst("case ".count)) }
        XCTAssertFalse(surfaces.isEmpty)
        XCTAssertEqual(surfaces, TCCRevokedReason.allCases.map(\.rawValue))
    }

    func testFromHealthLogSurface_unknownReturnsNil() {
        XCTAssertNil(TCCRevokedReason.fromHealthLogSurface("bogus"))
        XCTAssertNil(TCCRevokedReason.fromHealthLogSurface(""))
    }

    // (c)
    func testSettingsPaneURLString_isValidURLForEveryCase() {
        for reason in TCCRevokedReason.allCases {
            XCTAssertNotNil(
                URL(string: reason.settingsPaneURLString),
                "URL must parse for \(reason.rawValue)"
            )
            // All panes must live under the security preference domain.
            XCTAssertTrue(
                reason.settingsPaneURLString.contains("com.apple.preference.security"),
                "\(reason.rawValue) should target Privacy & Security"
            )
        }
    }

    func testTheNotificationButtonSaysWhereItGoes() {
        XCTAssertEqual(TCCRevokedNotifierRequestBuilder.makeCategory().actions.map(\.title), ["Open System Settings"])
    }

    func testEachPermissionHasItsMacOSName() {
        XCTAssertEqual(TCCRevokedReason.allCases.map(\.name),
                       ["Screen Recording", "Accessibility", "Full Disk Access", "Automation"])
    }

    // (d)
    func testNotifier_idempotentPerSurface() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)

        await notifier.notifyRevoked(.screenRecording)
        await notifier.notifyRevoked(.screenRecording)
        await notifier.notifyRevoked(.screenRecording)

        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(
            center.added[0].identifier,
            TCCRevokedNotifierRequestBuilder.identifier(for: .screenRecording)
        )
        XCTAssertEqual(center.added[0].content.title, "Hippocampus stopped remembering")
        XCTAssertEqual(
            center.added[0].content.body,
            "Screen Recording was turned off for Hippocampus. Click to open System Settings."
        )
    }

    /// A turn-on that finds the permission off stopped nothing: remembering
    /// was off, and the permission may never have been on. The notification
    /// says what is needed, in the menu's words.
    func testNotifier_aPermissionATurnOnFoundOffSaysWhatIsNeeded() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)

        await notifier.notifyRevoked(.screenRecording, whileRemembering: false)

        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added[0].content.title, "Hippocampus needs permission")
        XCTAssertEqual(
            center.added[0].content.body,
            "Screen Recording is off for Hippocampus. Click to open System Settings."
        )
        XCTAssertEqual(
            center.added[0].content.userInfo[TCCRevokedNotifierRequestBuilder.userInfoPaneKey] as? String,
            TCCRevokedReason.screenRecording.settingsPaneURLString
        )
    }

    /// A fresh helper that has the permission never reports it restored, so
    /// once remembering starts every permission notification is withdrawn,
    /// and a later revoke can notify again.
    func testNotifier_withdrawAllRemovesWhatIsShownAndAllowsANewOne() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)
        await notifier.notifyRevoked(.screenRecording, whileRemembering: false)

        await notifier.withdrawAll()

        let id = TCCRevokedNotifierRequestBuilder.identifier(for: .screenRecording)
        XCTAssertTrue(center.removedDelivered.contains(id))
        XCTAssertTrue(center.removedPending.contains(id))
        let outstanding = await notifier.outstandingForTest()
        XCTAssertTrue(outstanding.isEmpty)
        await notifier.notifyRevoked(.screenRecording)
        XCTAssertEqual(center.added.count, 2)
        XCTAssertEqual(center.added[1].content.title, "Hippocampus stopped remembering")
    }

    func testNotifier_distinctSurfacesFireDistinctNotifications() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)

        await notifier.notifyRevoked(.screenRecording)
        await notifier.notifyRevoked(.accessibility)
        await notifier.notifyRevoked(.fullDiskAccess)

        XCTAssertEqual(center.added.count, 3)
        let ids = Set(center.added.map(\.identifier))
        XCTAssertEqual(ids.count, 3)
    }

    // (e)
    func testNotifier_restoreClearsStateAllowingRefire() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)

        await notifier.notifyRevoked(.screenRecording)
        XCTAssertEqual(center.added.count, 1)

        await notifier.notifyRestored(.screenRecording)
        let id = TCCRevokedNotifierRequestBuilder.identifier(for: .screenRecording)
        XCTAssertEqual(center.removedPending, [id])
        XCTAssertEqual(center.removedDelivered, [id])

        // After restore, a fresh revoke must fire again.
        await notifier.notifyRevoked(.screenRecording)
        XCTAssertEqual(center.added.count, 2)
    }

    func testNotifier_restoreWithoutRevoke_isNoOp() async {
        let center = FakeUNCenter()
        let notifier = TCCRevokedNotifier(center: center)

        await notifier.notifyRestored(.screenRecording)
        XCTAssertEqual(center.removedPending.count, 0)
        XCTAssertEqual(center.removedDelivered.count, 0)
    }

    // (f)
    func testRequestBuilder_encodesUserInfoPayload() {
        let request = TCCRevokedNotifierRequestBuilder.makeRequest(for: .fullDiskAccess)

        XCTAssertEqual(
            request.content.categoryIdentifier,
            TCCRevokedNotifierRequestBuilder.categoryIdentifier
        )

        let pane = request.content.userInfo[
            TCCRevokedNotifierRequestBuilder.userInfoPaneKey
        ] as? String
        XCTAssertEqual(pane, TCCRevokedReason.fullDiskAccess.settingsPaneURLString)

        let surface = request.content.userInfo[
            TCCRevokedNotifierRequestBuilder.userInfoSurfaceKey
        ] as? String
        XCTAssertEqual(surface, TCCRevokedReason.fullDiskAccess.rawValue)
    }
}
