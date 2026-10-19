// SPDX-License-Identifier: Apache-2.0
//
// What opening Hippocampus shows (spec-shell S7, 07fedaf; Oct 18): setup
// while it is unfinished; otherwise the window for the person's own launch
// and for every reopen; nothing for a login, a quiet relaunch, a link or a
// Preferences request at launch.

import AppKit
import CoreServices
import XCTest
@testable import HippocampusKit

final class AppOpeningTests: XCTestCase {
    private static let reasons: [LaunchReason] = [.preferences, .quiet, .login, .url, .user]

    func testALoginLaunchStaysQuiet() {
        XCTAssertEqual(AppOpening.atLaunch(.login, setupFinished: true, hasSetup: true), .nothing)
        for reason in Self.reasons where reason != .user {
            XCTAssertEqual(AppOpening.atLaunch(reason, setupFinished: true, hasSetup: true), .nothing, "\(reason)")
        }
    }

    func testThePersonsOwnLaunchShowsTheWindow() {
        XCTAssertEqual(AppOpening.atLaunch(.user, setupFinished: true, hasSetup: true), .window)
        XCTAssertEqual(AppOpening.atLaunch(.user, setupFinished: false, hasSetup: false), .window,
                       "a build without setup starts as if setup were done")
    }

    func testUnfinishedSetupOpensSetupAtLaunchAndWhenOpenedAgain() {
        for reason in Self.reasons {
            XCTAssertEqual(AppOpening.atLaunch(reason, setupFinished: false, hasSetup: true), .setup, "\(reason)")
        }
        XCTAssertEqual(AppOpening.atReopen(setupFinished: false, hasSetup: true), .setup)
    }

    /// Opening it again is always the person: the window, whatever
    /// remembering is doing.
    func testEveryReopenAfterSetupShowsTheWindow() {
        XCTAssertEqual(AppOpening.atReopen(setupFinished: true, hasSetup: true), .window)
        XCTAssertEqual(AppOpening.atReopen(setupFinished: false, hasSetup: false), .window,
                       "a build without setup")
    }

    /// End to end from the Apple event macOS sends a login item: read at
    /// launch it is a login, and the launch shows nothing. The same event
    /// without the login marker is the person, and shows the window.
    @MainActor
    func testTheLoginEventStaysQuietAndThePersonsLaunchShowsTheWindow() throws {
        let suite = "ai.hippocampus.tests.opening.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func openApplication(atLogin: Bool) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            if atLogin {
                event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                               forKeyword: AEKeyword(keyAEPropData))
            }
            return event
        }
        let now = Date(timeIntervalSince1970: 1_791_841_025)
        let login = LaunchReason.read(preferencesRequested: false, environment: [:], defaults: defaults, now: now,
                                      currentEvent: openApplication(atLogin: true)).reason
        XCTAssertEqual(AppOpening.atLaunch(login, setupFinished: true, hasSetup: true), .nothing)
        let byHand = LaunchReason.read(preferencesRequested: false, environment: [:], defaults: defaults, now: now,
                                       currentEvent: openApplication(atLogin: false)).reason
        XCTAssertEqual(AppOpening.atLaunch(byHand, setupFinished: true, hasSetup: true), .window)
    }
}

/// Every way to the window but a reopen goes through one place, which
/// brings setup forward until setup is done. A window opened before setup
/// made the memory's key built its reader once, with no key, and the window
/// the person got after setup (setup closing asks for it, and finds that one
/// running) could not read the memory until they closed and reopened it.
final class WindowRequestRoutingTests: XCTestCase {
    func testEveryWindowRequestBringsSetupForwardUntilSetupIsDone() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Hippocampus/HippocampusApp.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(app.range(of: "private func openWindow(tab: String?, focusEventId: UInt64? = nil, openPopup: Bool = false) {"))
        let end = try XCTUnwrap(app.range(of: "\n    }\n", range: start.upperBound..<app.endIndex))
        let route = app[start.upperBound..<end.lowerBound]
        XCTAssertTrue(route.contains("AppOpening.atReopen(setupFinished: OnboardingSentinel.isComplete, hasSetup: supervisor.hasOnboarding)"))
        XCTAssertTrue(route.contains("case .setup: supervisor.showOnboarding()"))
        XCTAssertTrue(route.contains("supervisor.openRecallUI(initialTab: tab, focusEventId: focusEventId, openPopup: openPopup)"))
        // The menu, Ask (both of its ways), Preferences and the link all use it.
        XCTAssertEqual(app.components(separatedBy: "supervisor.openRecallUI(").count - 1, 1, "only the route opens the window")
        XCTAssertTrue(app.contains("openWindow: { [weak self] in self?.openWindow(tab: nil) }"))
        XCTAssertTrue(app.contains("openEvent: { [weak self] eventId in self?.openWindow(tab: \"search\", focusEventId: eventId) }"))
        XCTAssertEqual(app.components(separatedBy: "openWindow: { [weak self] tab in self?.openWindow(tab: tab) }").count - 1, 2,
                       "Ask's and Preferences' Open")
        XCTAssertTrue(app.contains("openWindow(tab: tab, focusEventId: focusEventId, openPopup: openPopup)"))
    }
}
