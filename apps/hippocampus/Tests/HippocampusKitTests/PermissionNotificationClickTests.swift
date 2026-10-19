// SPDX-License-Identifier: Apache-2.0
//
// The permission notifications say "Click to open System Settings." and
// carry an "Open System Settings" button, but nothing was installed to hear
// the click: it at most brought the windowless app forward, and the look that
// followed did not try a refused Turn On again, since only the status row's
// own Open System Settings… armed that. A click is that button now.

import UserNotifications
import XCTest
@testable import HippocampusKit

@MainActor
final class PermissionNotificationClickTests: XCTestCase {
    private let category = TCCRevokedNotifierRequestBuilder.categoryIdentifier
    private let button = TCCRevokedNotifierRequestBuilder.openSettingsActionIdentifier

    func test_a_click_on_the_body_or_the_button_is_about_its_permission() {
        func permission(_ category: String, _ action: String, _ surface: String?) -> TCCRevokedReason? {
            TCCRevokedNotificationActionHandler.permission(
                categoryIdentifier: category, actionIdentifier: action, surface: surface
            )
        }
        XCTAssertEqual(permission(category, UNNotificationDefaultActionIdentifier, "screenRecording"), .screenRecording)
        XCTAssertEqual(permission(category, button, "accessibility"), .accessibility)
        XCTAssertNil(permission(category, UNNotificationDismissActionIdentifier, "accessibility"), "a dismissal opens nothing")
        XCTAssertNil(permission("SomethingElse", UNNotificationDefaultActionIdentifier, "accessibility"))
        XCTAssertNil(permission(category, UNNotificationDefaultActionIdentifier, "camera"))
        XCTAssertNil(permission(category, UNNotificationDefaultActionIdentifier, nil))
    }

    func test_every_permission_notification_carries_what_the_click_needs() {
        for reason in TCCRevokedReason.allCases {
            for whileRemembering in [true, false] {
                let content = TCCRevokedNotifierRequestBuilder.makeRequest(
                    for: reason, whileRemembering: whileRemembering
                ).content
                XCTAssertEqual(
                    TCCRevokedNotificationActionHandler.permission(
                        categoryIdentifier: content.categoryIdentifier,
                        actionIdentifier: UNNotificationDefaultActionIdentifier,
                        surface: content.userInfo[TCCRevokedNotifierRequestBuilder.userInfoSurfaceKey] as? String
                    ),
                    reason
                )
            }
        }
    }

    /// Turn On found Screen Recording off: "Needs permission", and the
    /// notification "Hippocampus needs permission". The person clicks it,
    /// allows Screen Recording and comes back: that look tries Turn On again,
    /// as after the row's own Open System Settings….
    func test_a_click_after_a_refused_turn_on_opens_the_pane_and_the_next_look_tries_again() async throws {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let config = FakeRuntimeConfig(captureEnabled: false)
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: config, topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1, captureStatusReader: { (nil, nil) }
        )
        try await supervisor.startAndWaitForReadiness()
        var screenRecordingOff = true
        topology.permissionOffInReceipt = { plan in
            screenRecordingOff && plan.helperArguments.contains("--capture") ? .screenRecording : nil
        }
        supervisor.performAskStatusAction(.turnOn, setupFinished: true) { _ in }
        try await waitUntil { !supervisor.turningOn }
        XCTAssertEqual(supervisor.menuBarStatus, .needsPermission(.screenRecording))

        var opened: [URL] = []
        let handled = TCCRevokedNotificationActionHandler.handle(
            categoryIdentifier: category, actionIdentifier: UNNotificationDefaultActionIdentifier,
            surface: TCCRevokedReason.screenRecording.rawValue,
            supervisor: supervisor, setupFinished: true
        ) { opened.append($0) }
        XCTAssertTrue(handled)
        XCTAssertEqual(opened, [URL(string: TCCRevokedReason.screenRecording.settingsPaneURLString)!])

        screenRecordingOff = false
        supervisor.retryIfPermissionMayBeBack()
        try await waitUntil { supervisor.captureEnabled && !supervisor.turningOn }
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertEqual(config.captureWrites, [true])
        try await supervisor.shutdownAndWait()
    }

    /// The app hears the click: AppDelegate is the notification center's
    /// delegate from before it finishes launching (a click can launch it),
    /// and hands every response to the handler.
    func test_the_app_delegate_hears_notification_clicks() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Hippocampus/HippocampusApp.swift"),
            encoding: .utf8
        )
        let willFinish = try XCTUnwrap(app.range(of: "func applicationWillFinishLaunching("))
        let didFinish = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching("))
        let early = app[willFinish.lowerBound..<didFinish.lowerBound]
        XCTAssertTrue(early.contains("UNUserNotificationCenter.current().delegate = self"))
        XCTAssertTrue(app.contains("extension AppDelegate: UNUserNotificationCenterDelegate"))
        XCTAssertTrue(app.contains("TCCRevokedNotificationActionHandler.handle("))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out")
    }
}
