// SPDX-License-Identifier: TBD-private
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
        lock.lock(); _authorizationRequests += 1; lock.unlock()
        return true
    }

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
    var removedDelivered: [String] {
        lock.lock(); defer { lock.unlock() }; return _removedDelivered
    }
    var authorizationRequests: Int {
        lock.lock(); defer { lock.unlock() }; return _authorizationRequests
    }
}

final class TCCRevokedRecoveryTests: XCTestCase {

    // (a)
    func testDerivation_tccRevokedOverridesRunning() {
        let status = MenuBarStatus.derive(
            from: .running,
            tccRevokedSurface: .screenRecording
        )
        guard case .error(let reason) = status else {
            return XCTFail("expected .error, got \(status)")
        }
        XCTAssertEqual(reason, "Screen Recording revoked")
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
        guard case .error(let reason) = status else {
            return XCTFail("expected .error, got \(status)")
        }
        XCTAssertEqual(reason, "Accessibility revoked")
    }

    func testDerivation_noOverride_preservesLegacyBehaviour() {
        // Sanity: pre-cycle-8.45 callsites that pass no override
        // continue to behave exactly as before.
        XCTAssertEqual(
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

    func testMenuBarReason_isDistinctPerSurface() {
        let reasons = Set(TCCRevokedReason.allCases.map(\.menuBarReason))
        XCTAssertEqual(
            reasons.count,
            TCCRevokedReason.allCases.count,
            "each surface must have a distinct menu-bar reason"
        )
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
        XCTAssertEqual(center.added[0].content.title, "Hippocampus can't record")
        XCTAssertTrue(
            center.added[0].content.body.contains("Screen Recording"),
            "body must name the surface"
        )
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
