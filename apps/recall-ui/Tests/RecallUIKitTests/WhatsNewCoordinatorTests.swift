// WhatsNewCoordinatorTests.swift — decision + persistence coverage.
//
// The coordinator's UserDefaults writes are tested against an isolated
// suite (per-test UUID) so parallel runs don't collide + so we never
// leak state into `.standard`. Bundle-lookup paths are exercised
// implicitly — the tests focus on the shouldShow / markShown state
// machine, which is where the "show at most once per version"
// invariant lives.

import XCTest
@testable import RecallUIKit

@MainActor
final class WhatsNewCoordinatorTests: XCTestCase {

    // The class is @MainActor, so these would be main-actor isolated, but
    // XCTestCase declares setUp()/tearDown() as nonisolated and an override
    // cannot add isolation. Two fixes look right and are not:
    //
    //   - async setUp()/tearDown() overrides: awaiting super sends a
    //     non-Sendable XCTestCase across an isolation boundary.
    //   - MainActor.assumeIsolated in the sync overrides: the closure is
    //     main-actor isolated and still captures task-isolated self.
    //
    // Opting the two properties out is what actually holds. It is sound
    // here because XCTest serializes setUp, the test body, and tearDown on
    // one instance, so there is no concurrent access to race on. Same
    // pattern as AuditLog.iso8601Formatter.
    private nonisolated(unsafe) var defaults: UserDefaults!
    private nonisolated(unsafe) var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WhatsNewCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - shouldShow decision

    /// A first launch has nothing new to tell: release notes would cover the
    /// person's first window (Oct 18).
    func test_shouldShow_false_on_first_boot() {
        let coord = WhatsNewCoordinator(defaults: defaults)
        XCTAssertFalse(coord.shouldShow(currentVersion: "1.0.0"))
    }

    func test_first_boot_records_the_version_quietly() {
        let coord = WhatsNewCoordinator(defaults: defaults)
        coord.maybeShow(onBootOf: "0.3.0")
        XCTAssertFalse(coord.isVisible)
        XCTAssertEqual(defaults.string(forKey: WhatsNewCoordinator.lastShownKey), "0.3.0")

        // The next launch of the same version stays quiet too.
        let again = WhatsNewCoordinator(defaults: defaults)
        again.maybeShow(onBootOf: "0.3.0")
        XCTAssertFalse(again.isVisible)
    }

    func test_an_update_shows_what_changed_once() {
        let before = WhatsNewCoordinator(defaults: defaults)
        before.maybeShow(onBootOf: "0.2.1")
        XCTAssertFalse(before.isVisible)

        let updated = WhatsNewCoordinator(defaults: defaults)
        updated.maybeShow(onBootOf: "0.3.0")
        XCTAssertTrue(updated.isVisible)
        updated.dismiss()
        XCTAssertFalse(updated.isVisible)
        XCTAssertEqual(defaults.string(forKey: WhatsNewCoordinator.lastShownKey), "0.3.0")

        let next = WhatsNewCoordinator(defaults: defaults)
        next.maybeShow(onBootOf: "0.3.0")
        XCTAssertFalse(next.isVisible, "once per version")
    }

    func test_boot_with_no_version_records_nothing() {
        let coord = WhatsNewCoordinator(defaults: defaults)
        coord.maybeShow(onBootOf: "")
        XCTAssertFalse(coord.isVisible)
        XCTAssertNil(defaults.object(forKey: WhatsNewCoordinator.lastShownKey))
    }

    func test_shouldShow_false_after_markShown_same_version() {
        let coord = WhatsNewCoordinator(defaults: defaults)
        coord.markShown(version: "1.0.0")
        XCTAssertFalse(coord.shouldShow(currentVersion: "1.0.0"))
    }

    func test_shouldShow_true_after_update_to_new_version() {
        let coord = WhatsNewCoordinator(defaults: defaults)
        coord.markShown(version: "1.0.0")
        XCTAssertTrue(coord.shouldShow(currentVersion: "1.0.1"))
    }

    func test_shouldShow_false_on_empty_version_string() {
        // Guard against a missing CFBundleShortVersionString — we do
        // NOT want to show the modal in that degenerate case.
        let coord = WhatsNewCoordinator(defaults: defaults)
        XCTAssertFalse(coord.shouldShow(currentVersion: ""))
    }

    // MARK: - dismiss persistence

    func test_dismiss_records_current_release_version() {
        let coord = WhatsNewCoordinator(defaults: defaults)
        coord.isVisible = true
        coord.currentRelease = .init(
            version: "1.2.3",
            date: "2026-07-13",
            sections: [.init(title: "Features", items: ["hello"])]
        )
        coord.dismiss()
        XCTAssertFalse(coord.isVisible)
        XCTAssertEqual(defaults.string(forKey: WhatsNewCoordinator.lastShownKey), "1.2.3")
    }

    func test_dismiss_without_release_still_marks_key() {
        // Dev-build path — no matching CHANGELOG entry — should still
        // mark *something* so we don't reopen on every boot.
        let coord = WhatsNewCoordinator(defaults: defaults)
        coord.isVisible = true
        coord.isDevBuild = true
        coord.currentRelease = nil
        coord.dismiss()
        XCTAssertFalse(coord.isVisible)
        // Empty string is acceptable when the bundle also has no
        // version — we specifically don't want to crash or leak the
        // modal onto every boot.
        XCTAssertNotNil(defaults.object(forKey: WhatsNewCoordinator.lastShownKey))
    }

    // MARK: - Show-once invariant across two coordinator lifetimes

    func test_show_once_per_version_across_instances() {
        let c1 = WhatsNewCoordinator(defaults: defaults)
        XCTAssertFalse(c1.shouldShow(currentVersion: "1.0.0"), "a first launch is quiet")
        c1.markShown(version: "1.0.0")

        // Fresh instance = fresh app launch. Should still be silent.
        let c2 = WhatsNewCoordinator(defaults: defaults)
        XCTAssertFalse(c2.shouldShow(currentVersion: "1.0.0"))

        // But a new version flips it back on.
        XCTAssertTrue(c2.shouldShow(currentVersion: "1.0.1"))
    }
}
