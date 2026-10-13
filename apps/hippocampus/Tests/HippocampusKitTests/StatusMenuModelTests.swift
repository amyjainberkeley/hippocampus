// SPDX-License-Identifier: TBD-private
//
// Every word of the menu-bar menu, in order, for every row of the menu table
// (spec-shell S2 with product critique 3, 4, 9, 10 and 17, RULINGS S3 and
// S5). The menu, Ask's footer and Preferences all show `StatusRow`.

import XCTest
@testable import HippocampusKit

final class StatusMenuModelTests: XCTestCase {
    /// 3:10 PM on Oct 13, 2026, in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_791_929_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private let tail = ["-", "Ask", "Open Hippocampus", "-", "Connect AI Tools…", "Preferences…", "-", "Quit Hippocampus"]

    private func titles(
        _ status: MenuBarStatus, setup: AskPanelStatus.Setup = .complete,
        lastSaved: Date? = nil, paused: Date? = nil, stopped: Date? = nil,
        askLabel: String? = "⇧⇧", connected: Bool = false
    ) -> [String] {
        items(status, setup: setup, lastSaved: lastSaved, paused: paused, stopped: stopped,
              askLabel: askLabel, connected: connected)
            .map { $0.role == .separator ? "-" : $0.title.replacingOccurrences(of: "\u{202F}", with: " ") }
    }

    private func items(
        _ status: MenuBarStatus, setup: AskPanelStatus.Setup = .complete,
        lastSaved: Date? = nil, paused: Date? = nil, stopped: Date? = nil,
        askLabel: String? = "⇧⇧", connected: Bool = false
    ) -> [StatusMenuModel.Item] {
        let row = StatusRow(StatusFacts(
            status: status, setup: setup, lastSavedAt: lastSaved, pausedSince: paused, stoppedSharingAt: stopped
        ), now: now, calendar: calendar)
        return StatusMenuModel.items(row: row, setupComplete: setup == .complete,
                                     askLabel: askLabel, aiToolsConnected: connected)
    }

    private var sixMinutesAgo: Date { now.addingTimeInterval(-6 * 60) }
    private var yesterday: Date { now.addingTimeInterval(-26 * 3600) }

    func testRememberingSaysWhenItLastSaved() {
        XCTAssertEqual(titles(.recording, lastSaved: now.addingTimeInterval(-8)),
                       ["Remembering", "Last saved 8s ago", "Pause"] + tail)
        XCTAssertEqual(titles(.unchanged, lastSaved: now.addingTimeInterval(-3 * 3600 - 60)),
                       ["Remembering", "Last saved 3h ago", "Pause"] + tail)
        // A save in the same second, or a clock a little ahead, is a second ago.
        XCTAssertEqual(titles(.recording, lastSaved: now.addingTimeInterval(2))[1], "Last saved 1s ago")
        XCTAssertEqual(titles(.recording), ["Remembering", "Pause"] + tail, "nothing unknown is claimed")
    }

    func testStartingAndNothingSavedYetOfferPause() {
        XCTAssertEqual(titles(.starting), ["Starting…", "Pause"] + tail)
        XCTAssertEqual(titles(.noMemory), ["Nothing saved yet", "Pause"] + tail)
    }

    func testSkippingSaysWhy() {
        XCTAssertEqual(titles(.skipping(reason: "private_browsing")),
                       ["Skipping this window", "This is a private window.", "Pause"] + tail)
        XCTAssertEqual(titles(.skipping(reason: "secure-event-input")),
                       ["Skipping this window", "A password field is active.", "Pause"] + tail)
        XCTAssertEqual(titles(.skipping(reason: "denylist-source")),
                       ["Skipping this window", "This window is never read.", "Pause"] + tail)
    }

    func testPausedSaysSinceWhenOnTheSameDayAndAnotherDay() {
        XCTAssertEqual(titles(.paused, paused: sixMinutesAgo), ["Paused", "Since 3:04 PM.", "Resume"] + tail)
        XCTAssertEqual(titles(.paused, paused: yesterday), ["Paused", "Since Oct 12.", "Resume"] + tail)
        XCTAssertEqual(titles(.paused), ["Paused", "Resume"] + tail)
    }

    func testOffAfterStopSharingSaysWhenTheSameDayAndAnotherDay() {
        XCTAssertEqual(titles(.idle, stopped: sixMinutesAgo), ["Off", "You stopped it at 3:04 PM.", "Turn On"] + tail)
        XCTAssertEqual(titles(.idle, stopped: yesterday), ["Off", "You stopped it on Oct 12.", "Turn On"] + tail)
        // Off from Preferences says no more than that (RULINGS S5).
        XCTAssertEqual(titles(.idle), ["Off", "Turn On"] + tail)
        // "sharing" would say the screen went somewhere (product critique 9).
        XCTAssertFalse(titles(.idle, stopped: sixMinutesAgo).joined().contains("sharing"))
    }

    func testNeedsPermissionNamesThePermission() {
        XCTAssertEqual(titles(.needsPermission(.screenRecording)),
                       ["Needs permission", "Screen Recording is off for Hippocampus.", "Open System Settings…"] + tail)
        XCTAssertEqual(titles(.needsPermission(.accessibility))[1], "Accessibility is off for Hippocampus.")
        XCTAssertEqual(titles(.needsPermission(.fullDiskAccess))[1], "Full Disk Access is off for Hippocampus.")
        XCTAssertEqual(titles(.needsPermission(.automation))[1], "Automation is off for Hippocampus.")
    }

    func testNotSavingSaysWhyAndOffersTryAgain() {
        XCTAssertEqual(titles(.blocked(reason: "storage_error")),
                       ["Not saving", "It can’t save. Check free disk space.", "Try Again"] + tail)
        XCTAssertEqual(titles(.blocked(reason: "helper_disconnected"))[1], "It lost its view of the screen.")
        XCTAssertEqual(titles(.blocked(reason: "capture_failed"))[1], "It couldn’t read the screen.")
        XCTAssertEqual(titles(.blocked(reason: "capture_disabled"))[1], "It didn’t start properly.")
        XCTAssertEqual(titles(.blocked(reason: "something-new"))[1], "It stopped and can’t say why.")
        XCTAssertEqual(titles(.stale(reason: "x")),
                       ["Not saving", "It can’t confirm anything was saved.", "Try Again"] + tail)
        XCTAssertEqual(titles(.error(reason: "helper exited (9)")),
                       ["Not saving", "It stopped and couldn’t start again.", "Try Again"] + tail)
    }

    /// The fix is Quit, right under the reason (product critique 3, RULINGS S3).
    func testAFailedStopSaysItMayStillBeReadingAndOffersQuit() {
        XCTAssertEqual(titles(.stopFailed(reason: "x")),
                       ["Couldn’t stop", "Hippocampus may still be reading the screen.", "Quit Hippocampus"] + tail)
        XCTAssertEqual(items(.stopFailed(reason: "x"))[2].role, .action(.quit))
        XCTAssertEqual(MenuBarStatus.stopFailed(reason: "x").action, .quit,
                       "Ask's footer and Preferences offer Quit Hippocampus")
    }

    /// Before setup, nothing turns remembering on and Ask is off in the menu
    /// (product critique 4); the key keeps working.
    func testBeforeSetupTheMenuOffersOnlyToFinishSetup() {
        XCTAssertEqual(titles(.idle, setup: .notFinished), ["Not set up yet", "Finish Setup…"] + tail)
        XCTAssertEqual(titles(.idle, setup: .inProgress), ["Not set up yet"] + tail,
                       "onboarding is on screen; a second copy would only compete with it")
        for setup in [AskPanelStatus.Setup.notFinished, .inProgress] {
            let ask = items(.idle, setup: setup).first { $0.role == .ask }
            XCTAssertEqual(ask?.isEnabled, false)
            let others = items(.idle, setup: setup).filter { $0.role != .ask && $0.role != .status && $0.role != .separator }
            XCTAssertTrue(others.allSatisfy(\.isEnabled), "only Ask is off")
        }
        XCTAssertEqual(items(.idle).first { $0.role == .ask }?.isEnabled, true)
    }

    func testTheFirstTwoLinesAreTextAndEveryOtherItemActs() {
        let all = items(.paused, paused: sixMinutesAgo)
        XCTAssertEqual(all[0].role, .status)
        XCTAssertFalse(all[0].isEnabled)
        XCTAssertEqual(all[1].role, .detail)
        XCTAssertFalse(all[1].isEnabled)
        XCTAssertEqual(all[2].role, .action(.resume))
        XCTAssertTrue(all[2].isEnabled)
    }

    func testOnceAToolIsConnectedTheItemOpensAITools() {
        XCTAssertEqual(items(.recording, connected: true).first { $0.role == .aiTools }?.title, "AI Tools…")
        XCTAssertEqual(items(.recording, connected: false).first { $0.role == .aiTools }?.title, "Connect AI Tools…")
    }

    /// A chosen key is a badge; ⌃⇧Space is a real key equivalent (spec-shell S3).
    func testAskShowsTheKeyThatOpensIt() {
        let solo = items(.recording, askLabel: "⇧⇧").first { $0.role == .ask }
        XCTAssertEqual(solo?.title, "Ask")
        XCTAssertEqual(solo?.badge, "⇧⇧")
        XCTAssertNil(solo?.key)
        let fallback = items(.recording, askLabel: AskShortcut.fallbackLabel).first { $0.role == .ask }
        XCTAssertNil(fallback?.badge)
        XCTAssertEqual(fallback?.key, StatusMenuModel.KeyEquivalent(key: " ", shift: true, control: true))
        let none = items(.recording, askLabel: nil).first { $0.role == .ask }
        XCTAssertNil(none?.badge)
        XCTAssertNil(none?.key)
    }

    func testPreferencesAndQuitKeepTheirKeys() {
        let all = items(.recording)
        XCTAssertEqual(all.first { $0.role == .preferences }?.key, StatusMenuModel.KeyEquivalent(key: ",", command: true))
        XCTAssertEqual(all.first { $0.role == .quit }?.key, StatusMenuModel.KeyEquivalent(key: "q", command: true))
    }

    /// The menu, Ask's footer and Preferences show one row (product critique
    /// 11): the footer differs only in reading "On this Mac" while
    /// remembering and leaving Pause to the menu.
    func testTheFooterIsTheMenusRow() {
        let statuses: [MenuBarStatus] = [
            .idle, .starting, .recording, .unchanged, .noMemory, .paused, .skipping(reason: "private_browsing"),
            .needsPermission(.screenRecording), .blocked(reason: "storage_error"), .stale(reason: "x"),
            .error(reason: "x"), .stopFailed(reason: "x"),
        ]
        for status in statuses {
            let row = StatusRow(StatusFacts(status: status), now: now, calendar: calendar)
            XCTAssertEqual(row.title, status.displayText, "\(status)")
            XCTAssertEqual(row.action, status.action, "\(status)")
            let footer = AskPanelStatus(status, row: row, setup: .complete)
            XCTAssertEqual(footer.text, status.isRemembering ? "On this Mac" : row.title, "\(status)")
            XCTAssertEqual(footer.action, row.action == .pause ? nil : row.action, "\(status)")
        }
    }

    func testTheStatusItemIsNamedByTheMenusFirstLine() {
        let row = StatusRow(StatusFacts(status: .paused), now: now, calendar: calendar)
        XCTAssertEqual(StatusMenuModel.accessibilityLabel(row), "Hippocampus, Paused")
    }
}
