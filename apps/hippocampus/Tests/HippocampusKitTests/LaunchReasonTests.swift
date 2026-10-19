// SPDX-License-Identifier: Apache-2.0
import CoreServices
import Foundation
import XCTest
@testable import HippocampusKit

/// Only a launch by the person opens the window (spec-shell S7).
final class LaunchReasonTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let login = LaunchReason.Event(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        propData: OSType(keyAELaunchedAsLogInItem)
    )
    private let open = LaunchReason.Event(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication)
    )
    private let link = LaunchReason.Event(eventClass: 0x4755_524C, eventID: 0x4755_524C)

    func testTheTableIsReadInOrder() {
        // 1. Preferences was asked for, whatever else is true.
        XCTAssertEqual(reason(preferences: true, quiet: true, event: login), .preferences)
        // 2. A quiet launch, from the environment or a fresh note.
        XCTAssertEqual(reason(quiet: true, event: login), .quiet)
        XCTAssertEqual(reason(quietOnceAt: now.addingTimeInterval(-30), event: link), .quiet)
        // 3. Opened as a login item.
        XCTAssertEqual(reason(event: login), .login)
        // 4. Opened by a link.
        XCTAssertEqual(reason(event: link), .url)
        // 5. Anything else is the person.
        XCTAssertEqual(reason(event: open), .user)
        XCTAssertEqual(reason(event: nil), .user)
        XCTAssertEqual(reason(event: LaunchReason.Event(eventClass: AEEventClass(kCoreEventClass), eventID: 0x6F64_6F63)), .user)
    }

    func testTheQuietNoteIsHonouredForTwoMinutesOnly() {
        XCTAssertEqual(reason(quietOnceAt: now.addingTimeInterval(-119), event: nil), .quiet)
        XCTAssertEqual(
            reason(quietOnceAt: now.addingTimeInterval(-121), event: nil), .user,
            "an update that never relaunched must not make the person's next launch quiet"
        )
        XCTAssertEqual(reason(quietOnceAt: now.addingTimeInterval(60), event: nil), .user)
    }

    func testTheNoteIsTakenOnceAndReadingRemovesIt() throws {
        let suite = "ai.hippocampus.tests.launch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(QuietLaunchNote.take(from: defaults))
        QuietLaunchNote.record(now, in: defaults)
        XCTAssertEqual(QuietLaunchNote.take(from: defaults), now)
        XCTAssertNil(QuietLaunchNote.take(from: defaults), "read, then removed")
        XCTAssertNil(defaults.object(forKey: "ai.hippocampus.launch.quietOnce"))
    }

    @MainActor
    func testReadTakesTheNoteAndHonoursTheQuietEnvironment() throws {
        let suite = "ai.hippocampus.tests.launch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        QuietLaunchNote.record(now, in: defaults)
        XCTAssertEqual(LaunchReason.read(preferencesRequested: false, environment: [:], defaults: defaults, now: now).reason, .quiet)
        XCTAssertEqual(LaunchReason.read(preferencesRequested: false, environment: [:], defaults: defaults, now: now).reason, .user)
        XCTAssertEqual(
            LaunchReason.read(
                preferencesRequested: false, environment: ["HIPPOCAMPUS_QUIET_LAUNCH": "1"], defaults: defaults, now: now
            ).reason,
            .quiet
        )
        XCTAssertEqual(LaunchReason.read(preferencesRequested: true, environment: [:], defaults: defaults, now: now).reason, .preferences)
    }

    func testTheLogLineNamesTheEventWithoutContent() {
        XCTAssertEqual(login.logDescription, "aevt/oapp prdt=lgit")
        XCTAssertEqual(open.logDescription, "aevt/oapp")
        XCTAssertEqual(link.logDescription, "GURL/GURL")
    }

    @MainActor
    func testRestartRelaunchesQuietly() {
        let arguments = DelayedApplicationRestartLauncher.restartArguments(bundlePath: "/Applications/Hippocampus.app")
        XCTAssertEqual(arguments, [
            "-c",
            "sleep 1; exec /usr/bin/open --env HIPPOCAMPUS_QUIET_LAUNCH=1 \"$1\"",
            "hippocampus-restart",
            "/Applications/Hippocampus.app",
        ])
    }

    func testAnUpdateLeavesTheQuietNoteBeforeItRelaunches() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/HippocampusKit/Updater.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("func updaterWillRelaunchApplication(_ updater: SPUUpdater) {\n        QuietLaunchNote.record()"))
        XCTAssertTrue(source.contains("updaterDelegate: relaunchDelegate,"))
    }

    /// The event macOS sends a login item, built as Apple builds it: open
    /// application, with `keyAELaunchedAsLogInItem` under `keyAEPropData`.
    /// Read through `read`, as at launch, it never opens the window (07fedaf).
    @MainActor
    func testALoginLaunchNeverOpensTheWindow() throws {
        let suite = "ai.hippocampus.tests.launch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let loginEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        loginEvent.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                            forKeyword: AEKeyword(keyAEPropData))
        let atLogin = LaunchReason.read(preferencesRequested: false, environment: [:], defaults: defaults,
                                        now: now, currentEvent: loginEvent)
        XCTAssertEqual(atLogin.reason, .login)
        XCTAssertEqual(atLogin.event?.logDescription, "aevt/oapp prdt=lgit")
        XCTAssertFalse(atLogin.reason.opensWindow)

        // The same event without the login marker is the person opening it.
        let byHand = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        let opened = LaunchReason.read(preferencesRequested: false, environment: [:], defaults: defaults,
                                       now: now, currentEvent: byHand)
        XCTAssertEqual(opened.reason, .user)
        XCTAssertTrue(opened.reason.opensWindow)
    }

    /// A link that launches Hippocampus (`open hippocampus://ask?q=…`)
    /// reaches `application(_:open:)` before `applicationDidFinishLaunching`,
    /// and by then no Apple event is current: it read as the person's own
    /// launch, so the window opened over what the link asked for.
    @MainActor
    func testALinkThatLaunchedTheAppIsALinkLaunch() throws {
        let suite = "ai.hippocampus.tests.launch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let launched = LaunchReason.read(
            preferencesRequested: false, linkOpened: true, environment: [:], defaults: defaults, now: now, currentEvent: nil
        )
        XCTAssertEqual(launched.reason, .url)
        XCTAssertFalse(launched.reason.opensWindow)
        XCTAssertEqual(reason(link: true, event: nil), .url)
        XCTAssertEqual(reason(link: true, event: open), .url)
        XCTAssertEqual(reason(preferences: true, link: true, event: nil), .preferences, "Preferences still comes first")
    }

    /// The app records the link as it arrives, before it reads the reason,
    /// and Ask keeps a link that comes before it is set up.
    func testTheAppRecordsALinkBeforeItReadsTheReasonAndAskKeepsIt() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Hippocampus")
        let app = try String(contentsOf: sources.appendingPathComponent("HippocampusApp.swift"), encoding: .utf8)
        let open = try XCTUnwrap(app.range(of: "func application(_ application: NSApplication, open urls: [URL]) {"))
        let openBody = app[open.upperBound...].prefix(400)
        XCTAssertTrue(openBody.contains("if !launchReasonRead { linkOpenedAtLaunch = true }"))
        XCTAssertTrue(app.contains("LaunchReason.read(preferencesRequested: initialPreferencesRequest != nil, linkOpened: linkOpenedAtLaunch)"))
        XCTAssertTrue(app.contains("launchReasonRead = true"))

        let bar = try String(contentsOf: sources.appendingPathComponent("CommandBar.swift"), encoding: .utf8)
        XCTAssertTrue(bar.contains("guard let model else {\n            heldShow = (question, opening)\n            return\n        }"))
        let configure = try XCTUnwrap(bar.range(of: "func configure("))
        let configureBody = bar[configure.upperBound...].prefix(1200)
        XCTAssertTrue(configureBody.contains("if let held = heldShow {"))
        XCTAssertTrue(configureBody.contains("show(asking: held.question, from: held.opening)"))
    }

    func testOnlyThePersonsOwnLaunchOpensTheWindow() {
        let all: [LaunchReason] = [.preferences, .quiet, .login, .url, .user]
        XCTAssertEqual(all.filter(\.opensWindow), [.user])
    }

    private func reason(
        preferences: Bool = false, quiet: Bool = false, quietOnceAt: Date? = nil, link: Bool = false,
        event: LaunchReason.Event?
    ) -> LaunchReason {
        LaunchReason.decide(
            preferencesRequested: preferences, quietEnvironment: quiet, quietOnceAt: quietOnceAt, now: now,
            linkOpened: link, event: event
        )
    }
}
