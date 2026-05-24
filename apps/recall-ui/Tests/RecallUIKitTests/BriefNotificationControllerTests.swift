// BriefNotificationControllerTests.swift — pin the fire-once invariant
// + permission-grant gates for the first-brief notification
// (`docs/design/brief-viewer-spec.md` §"When the user discovers their
// first brief"; spec DoD #4 + #8).

import XCTest
import UserNotifications
@testable import RecallUIKit

@MainActor
final class BriefNotificationControllerTests: XCTestCase {

    // MARK: fakes

    /// Records `add()` calls and lets the test set the authorization
    /// status the controller will observe.
    final class FakeNotificationCenter: NotificationCenterClient, @unchecked Sendable {
        var status: UNAuthorizationStatus = .notDetermined
        var grantOnRequest: Bool = true
        var addCallCount: Int = 0
        var lastAddedIdentifier: String?
        var lastAddedTitle: String?
        var addError: Error?

        func currentAuthorizationStatus() async -> UNAuthorizationStatus { status }

        func requestAuthorization() async throws -> Bool {
            if grantOnRequest {
                status = .authorized
                return true
            }
            status = .denied
            return false
        }

        func add(_ request: UNNotificationRequest) async throws {
            if let e = addError { throw e }
            addCallCount += 1
            lastAddedIdentifier = request.identifier
            lastAddedTitle = request.content.title
        }
    }

    /// In-memory `UserDefaults` stand-in.
    final class FakeDefaults: BriefDefaultsStore, @unchecked Sendable {
        var bools: [String: Bool] = [:]
        func bool(forKey k: String) -> Bool { bools[k] ?? false }
        func set(_ value: Bool, forKey k: String) { bools[k] = value }
    }

    // -------------------------------------------------------------------
    // briefExists = false ⇒ nothing happens
    // -------------------------------------------------------------------

    func testNoBriefYetReturnsNoBriefYetAndDoesNotAskOrFire() async {
        let nc = FakeNotificationCenter()
        nc.status = .notDetermined
        let dfs = FakeDefaults()
        let c = BriefNotificationController(notifications: nc, defaults: dfs)
        let outcome = await c.checkAndMaybeFireFirstBriefNotification(briefExists: false)
        XCTAssertEqual(outcome, .noBriefYet)
        XCTAssertEqual(nc.addCallCount, 0)
        XCTAssertFalse(dfs.bool(forKey: BriefNotificationController.firstFiredKey))
    }

    // -------------------------------------------------------------------
    // First-brief notification fires exactly once
    // -------------------------------------------------------------------

    func testFirstCheckRequestsAuthorizationAndFiresWhenGranted() async {
        let nc = FakeNotificationCenter()
        nc.status = .notDetermined
        nc.grantOnRequest = true
        let dfs = FakeDefaults()
        let c = BriefNotificationController(notifications: nc, defaults: dfs)

        let outcome = await c.checkAndMaybeFireFirstBriefNotification(briefExists: true)
        XCTAssertEqual(outcome, .firedFirstBrief)
        XCTAssertEqual(nc.addCallCount, 1)
        XCTAssertEqual(
            nc.lastAddedIdentifier,
            BriefNotificationController.firstBriefNotificationId
        )
        XCTAssertEqual(nc.lastAddedTitle, "Your first Hippocampus brief is ready")
        XCTAssertTrue(dfs.bool(forKey: BriefNotificationController.firstFiredKey))
    }

    func testFirstCheckWithAlreadyAuthorizedFiresWithoutAsking() async {
        let nc = FakeNotificationCenter()
        nc.status = .authorized
        let dfs = FakeDefaults()
        let c = BriefNotificationController(notifications: nc, defaults: dfs)

        let outcome = await c.checkAndMaybeFireFirstBriefNotification(briefExists: true)
        XCTAssertEqual(outcome, .firedFirstBrief)
        XCTAssertEqual(nc.addCallCount, 1)
    }

    func testFirstCheckWithUserDecliningPermissionReturnsDeclinedAndDoesNotFire() async {
        let nc = FakeNotificationCenter()
        nc.status = .notDetermined
        nc.grantOnRequest = false
        let dfs = FakeDefaults()
        let c = BriefNotificationController(notifications: nc, defaults: dfs)

        let outcome = await c.checkAndMaybeFireFirstBriefNotification(briefExists: true)
        XCTAssertEqual(outcome, .permissionAskedAndDeclined)
        XCTAssertEqual(nc.addCallCount, 0)
        XCTAssertFalse(dfs.bool(forKey: BriefNotificationController.firstFiredKey))
    }

    func testFirstCheckWithSettingsDeniedReturnsDeniedAndDoesNotFire() async {
        let nc = FakeNotificationCenter()
        nc.status = .denied
        let dfs = FakeDefaults()
        let c = BriefNotificationController(notifications: nc, defaults: dfs)

        let outcome = await c.checkAndMaybeFireFirstBriefNotification(briefExists: true)
        XCTAssertEqual(outcome, .permissionDenied)
        XCTAssertEqual(nc.addCallCount, 0)
        XCTAssertFalse(dfs.bool(forKey: BriefNotificationController.firstFiredKey))
    }

    // -------------------------------------------------------------------
    // FIRE-ONCE INVARIANT — second check after first fired is silent
    // -------------------------------------------------------------------

    func testSecondCheckAfterFirstFiredDoesNotRefire() async {
        let nc = FakeNotificationCenter()
        nc.status = .authorized
        let dfs = FakeDefaults()
        let c = BriefNotificationController(notifications: nc, defaults: dfs)

        // First check fires.
        _ = await c.checkAndMaybeFireFirstBriefNotification(briefExists: true)
        XCTAssertEqual(nc.addCallCount, 1)

        // Second check is silent.
        let second = await c.checkAndMaybeFireFirstBriefNotification(briefExists: true)
        XCTAssertEqual(second, .alreadyFired)
        XCTAssertEqual(nc.addCallCount, 1, "fire-once invariant: no second add")
    }

    func testTenChecksAfterFirstFiredOnlyFireOnce() async {
        let nc = FakeNotificationCenter()
        nc.status = .authorized
        let dfs = FakeDefaults()
        let c = BriefNotificationController(notifications: nc, defaults: dfs)

        for _ in 0..<10 {
            _ = await c.checkAndMaybeFireFirstBriefNotification(briefExists: true)
        }
        XCTAssertEqual(nc.addCallCount, 1, "fire-once invariant — N checks still 1 add")
    }

    // -------------------------------------------------------------------
    // notifyEachMorning opt-in path
    // -------------------------------------------------------------------

    func testRepeatedChecksAfterFirstFireAreSilentWithoutOptIn() async {
        let nc = FakeNotificationCenter()
        nc.status = .authorized
        let dfs = FakeDefaults()
        // Pretend the first-brief notification already fired earlier.
        dfs.set(true, forKey: BriefNotificationController.firstFiredKey)
        // notifyEachMorning key is NOT set on dfs — so even with a
        // latestBriefDate the controller takes the "alreadyFired" path
        // and never asks for permission or fires.
        // (Per-morning code path is covered by `FakeDefaults` semantics
        // only insofar as the opt-in is false; the actual per-morning
        // fire path requires UserDefaults's string storage which we
        // deliberately don't exercise here to avoid mutating global
        // state from a unit test.)
        let c = BriefNotificationController(notifications: nc, defaults: dfs)
        let outcome = await c.checkAndMaybeFireFirstBriefNotification(
            briefExists: true,
            latestBriefDate: "2026-05-22"
        )
        XCTAssertEqual(outcome, .alreadyFired)
        XCTAssertEqual(nc.addCallCount, 0)
    }

    // -------------------------------------------------------------------
    // Notification payload carries the deep-link
    // -------------------------------------------------------------------

    func testFirstBriefNotificationPayloadCarriesDeepLink() {
        let req = BriefNotificationController.makeFirstBriefRequest()
        XCTAssertEqual(req.identifier, BriefNotificationController.firstBriefNotificationId)
        XCTAssertEqual(req.content.title, "Your first Hippocampus brief is ready")
        XCTAssertEqual(
            req.content.userInfo["deepLink"] as? String,
            "hippocampus://recall?tab=brief"
        )
    }

    func testPerMorningNotificationPayloadCarriesDeepLinkAndDate() {
        let req = BriefNotificationController.makePerMorningRequest(dateLocal: "2026-05-22")
        XCTAssertEqual(
            req.content.userInfo["deepLink"] as? String,
            "hippocampus://recall?tab=brief"
        )
        XCTAssertEqual(req.content.userInfo["dateLocal"] as? String, "2026-05-22")
    }
}
