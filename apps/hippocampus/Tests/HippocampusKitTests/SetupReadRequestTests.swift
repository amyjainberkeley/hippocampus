// SPDX-License-Identifier: Apache-2.0
//
// Setup's request for one fresh read of the window in front: the name both
// sides use, when the app honours it, and how the executable wires it. The
// app target cannot be imported, so the wiring is read from its source, as
// AskPanelWiringTests does.

import XCTest
@testable import HippocampusKit

final class SetupReadRequestTests: XCTestCase {
    private var package: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testSetupAndTheAppUseOneName() throws {
        XCTAssertEqual(SetupReadRequest.notificationName.rawValue, "ai.hippocampus.setup.readFrontWindow")
        let setup = try String(
            contentsOf: package.deletingLastPathComponent()
                .appendingPathComponent("onboarding/Sources/OnboardingKit/TryItPresentation.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(setup.contains("Notification.Name(\"\(SetupReadRequest.notificationName.rawValue)\")"))
    }

    func testOnlyAfterConsentAndWhileSetupIsOpen() {
        XCTAssertTrue(SetupReadRequest.honours(consentGiven: true, setupOpen: true))
        XCTAssertFalse(SetupReadRequest.honours(consentGiven: false, setupOpen: true), "nothing is read before consent")
        XCTAssertFalse(SetupReadRequest.honours(consentGiven: true, setupOpen: false), "no one else may ask")
        XCTAssertFalse(SetupReadRequest.honours(consentGiven: false, setupOpen: false))
    }

    func testTheAppAsksTheSupervisorWhichKeepsEveryRule() throws {
        let app = try String(contentsOf: package.appendingPathComponent("Sources/Hippocampus/HippocampusApp.swift"),
                             encoding: .utf8)
        let install = try XCTUnwrap(app.range(of: "installSetupReadReceiver()\n"))
        let launched = try XCTUnwrap(app.range(of: "installPreferencesReceiver()\n"))
        XCTAssertLessThan(launched.lowerBound, install.lowerBound, "installed at launch, beside the Preferences receiver")
        XCTAssertTrue(app.contains("name: SetupReadRequest.notificationName, object: nil"))
        let receive = try XCTUnwrap(app.range(of: "@objc private func receiveSetupReadRequest(_ notification: Notification) {"))
        let body = String(app[receive.lowerBound...].prefix(400))
        XCTAssertTrue(body.contains("consentGiven: OnboardingSentinel.isComplete, setupOpen: supervisor.onboardingIsRunning"))
        XCTAssertTrue(body.contains("supervisor.requestFreshRead()"))
        // The supervisor's own guard: running, capturing, not paused or
        // stopping, every permission on.
        let supervisor = try String(
            contentsOf: package.appendingPathComponent("Sources/HippocampusKit/ProcessSupervisor.swift"), encoding: .utf8)
        XCTAssertTrue(supervisor.contains(
            "guard state == .running, captureEnabled, !requestedPauseState, !captureStopLatched,"))
    }
}
