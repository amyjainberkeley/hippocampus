import XCTest
@testable import RecallUIKit

/// Whether Hippocampus is remembering, as the window shows it (SPEC 2.6):
/// the banner in every state of the table in 2.6.3, the dot, the hi mark,
/// and the status menu, from the app's own words over the pipe.
final class StatusBannerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")
    /// Monday, October 12, 2026, 2:41 PM in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_791_841_260)

    private func status(_ state: WindowChannelStatus.State, title: String, action: String? = nil,
                        permission: String? = nil, since: Date? = nil, until: Date? = nil) -> WindowStatus {
        WindowStatus(WindowChannelStatus(state: state, title: title, action: action, permission: permission,
                                         pausedSince: since, pausedUntil: until))
    }

    private func banner(_ status: WindowStatus) -> WindowStatus.Banner? {
        status.banner(now: now, calendar: calendar, locale: locale)
    }

    func testRememberingAndItsKindsShowNoBannerAndTheBlueDot() {
        for (state, title) in [(WindowChannelStatus.State.remembering, "Remembering"), (.starting, "Starting\u{2026}"),
                               (.nothingSaved, "Nothing saved yet"), (.skipping, "Skipping this window")] {
            let shown = status(state, title: title, action: "pause")
            XCTAssertNil(banner(shown), title)
            XCTAssertEqual(shown.dot, .on, title)
            XCTAssertTrue(shown.remembering, "a skipped window still counts as remembering (RULINGS B1)")
            XCTAssertEqual(shown.title, title, "the footer says the menu bar's own words")
        }
    }

    func testPausedSaysSinceWhenAndOffersStartRemembering() {
        let paused = status(.paused, title: "Paused", action: "resume", since: now.addingTimeInterval(-60))
        XCTAssertEqual(banner(paused), WindowStatus.Banner(
            text: "Paused since 2:40\u{202F}PM. Nothing new is saved until you start it again.", action: .resume,
            isProblem: false))
        XCTAssertEqual(paused.dot, .off)
        XCTAssertFalse(paused.remembering, "the hi mark loses its dot")
        // Setup's own words end a pause; Resume is Working On's, and reopens
        // a project.
        XCTAssertEqual(WindowStatus.Action.resume.title, "Start Remembering")
    }

    func testATimedPauseSaysUntilWhenAndOffersStartRemembering() {
        let timed = status(.paused, title: "Paused", action: "resume", since: now,
                           until: now.addingTimeInterval(59 * 60))
        XCTAssertEqual(timed.action, .resumeNow)
        XCTAssertEqual(banner(timed)?.text, "Paused until 3:40\u{202F}PM. Nothing new is saved until then.")
        XCTAssertEqual(banner(timed)?.action, .resumeNow)
        XCTAssertEqual(WindowStatus.Action.resumeNow.title, "Start Remembering", "one name for every pause")
        let tomorrow = status(.paused, title: "Paused", action: "resume", since: now,
                              until: WindowStatusMenu.PauseChoice.tomorrow.until(now: now, calendar: calendar))
        XCTAssertEqual(banner(tomorrow)?.text,
                       "Paused until tomorrow at 6:00\u{202F}AM. Nothing new is saved until then.")
    }

    func testEveryOtherStateOfTheTable() {
        let rows: [(WindowStatus, String, WindowStatus.Action, Bool)] = [
            (status(.off, title: "Off", action: "turnOn"),
             "Remembering is off. What\u{2019}s already saved is still here.", .turnOn, false),
            (status(.needsPermission, title: "Needs permission", action: "openSystemSettings",
                    permission: "screenRecording"),
             "Screen Recording is off for Hippocampus, so nothing new is saved.",
             .openSystemSettings(.screenRecording), true),
            (status(.needsPermission, title: "Needs permission", action: "openSystemSettings",
                    permission: "accessibility"),
             "Accessibility is off for Hippocampus, so nothing new is saved.",
             .openSystemSettings(.accessibility), true),
            (status(.notSaving, title: "Not saving", action: "tryAgain"),
             "Hippocampus can\u{2019}t confirm anything new was saved.", .tryAgain, true),
            (status(.couldNotStop, title: "Couldn\u{2019}t stop", action: "quit"),
             "Hippocampus may still be reading the screen.", .quit, true),
            (status(.couldNotTurnOn, title: "Couldn\u{2019}t turn on", action: "tryAgain"),
             "It didn\u{2019}t start, so remembering is still off.", .tryAgain, true),
            (status(.notSetUp, title: "Not set up yet", action: "finishSetup"),
             "Setup isn\u{2019}t finished, so nothing is read yet.", .finishSetup, false),
            (WindowStatus(byHand: nil, appRunning: false),
             "Hippocampus isn\u{2019}t running, so nothing new is saved.", .openHippocampus, false),
        ]
        for (shown, text, action, problem) in rows {
            XCTAssertEqual(banner(shown), WindowStatus.Banner(text: text, action: action, isProblem: problem),
                           shown.title)
            XCTAssertEqual(shown.dot, problem ? .problem : .off, shown.title)
            XCTAssertFalse(text.lowercased().contains("yellow"))
        }
    }

    func testForgettingShowsNoBannerAndSaysSoInTheFooter() {
        let remembering = status(.remembering, title: "Remembering", action: "pause")
        let forgetting = remembering.forgetting(.forgetting)
        XCTAssertEqual(forgetting.title, "Forgetting\u{2026}")
        XCTAssertNil(banner(forgetting))
        XCTAssertEqual(forgetting.dot, .off)
        XCTAssertNil(forgetting.action)
        XCTAssertEqual(remembering.forgetting(.finishing).title, "Finishing a forget\u{2026}")
        XCTAssertEqual(remembering.forgetting(nil), remembering)
    }

    // MARK: The status menu (SPEC 2.6.2)

    func testTheMenuWhileRemembering() {
        let remembering = WindowStatus(WindowChannelStatus(state: .remembering, title: "Remembering",
                                                           detail: "Last saved 12s ago", action: "pause"))
        XCTAssertEqual(WindowStatusMenu.items(remembering), [
            .title("Remembering", .on), .line("Last saved 12s ago"), .separator, .pause, .separator,
            .forget(.tenMinutes), .forget(.hour), .forget(.today), .separator, .privacy, .preferences,
        ])
        XCTAssertEqual(WindowStatusMenu.PauseChoice.allCases.map(\.title),
                       ["For 1 Hour", "Until Tomorrow", "Until I Start It Again"])
        XCTAssertEqual(WindowStatusMenu.title(.tenMinutes), "Forget the Last 10 Minutes\u{2026}")
        XCTAssertEqual(WindowStatusMenu.title(.hour), "Forget the Last Hour\u{2026}")
        XCTAssertEqual(WindowStatusMenu.title(.today), "Forget Today\u{2026}")
    }

    func testTheMenuWhilePausedAndInLowPowerMode() {
        var pushed = WindowChannelStatus(state: .paused, title: "Paused", detail: "Since 2:40 PM.",
                                         action: "resume", pausedSince: now)
        pushed.lowPower = true
        let items = WindowStatusMenu.items(WindowStatus(pushed))
        XCTAssertEqual(Array(items.prefix(5)), [
            .title("Paused", .off), .line("Since 2:40 PM."),
            .line("Low Power Mode is on, so only the window you\u{2019}re using is read."), .separator,
            .action(.resume),
        ])
    }

    /// A window opened by hand has no controls: the status lines and Open
    /// Hippocampus (SPEC 2.6.4).
    func testAWindowOpenedByHandHasNoControls() {
        let byHand = WindowStatus(byHand: nil, appRunning: true)
        XCTAssertFalse(byHand.hasControls)
        XCTAssertEqual(WindowStatusMenu.items(byHand), [.title("Not remembering", .off), .separator,
                                                        .action(.openHippocampus)])
        XCTAssertNil(byHand.banner(), "it can't tell why, so it says nothing more")
        let notRunning = WindowStatus(byHand: nil, appRunning: false)
        XCTAssertEqual(WindowStatusMenu.items(notRunning).last, .action(.openHippocampus))
    }

    /// While the window reads Demo Memory, remembering is paused, and the
    /// Demo tag says so: no banner on every page, the footer says Demo
    /// Memory, and its one action goes back to the person's own memory
    /// (SPEC-DELTA 6). A forget under way still says so.
    func testDemoMemoryShowsNoBannerAndOffersToLeave() {
        let paused = status(.paused, title: "Paused", action: "resume", since: now.addingTimeInterval(-60))
        let demo = paused.inDemoMemory
        XCTAssertEqual(demo.kind, .demoMemory)
        XCTAssertNil(banner(demo))
        XCTAssertEqual(demo.dot, .off, "nothing new is remembered while it is in use")
        XCTAssertEqual(demo.title, "Demo Memory")
        XCTAssertEqual(demo.action, .leaveDemoMemory)
        XCTAssertEqual(demo.action?.title, "Leave Demo Memory")
        XCTAssertTrue(demo.hasControls)
        XCTAssertEqual(WindowStatusMenu.items(demo).prefix(4),
                       [.title("Demo Memory", .off), .line("Your own memory is paused until you leave."), .separator,
                        .action(.leaveDemoMemory)])
        let forgetting = WindowStatus(kind: .forgetting, title: NavigationCopy.forgetting)
        XCTAssertEqual(forgetting.inDemoMemory, forgetting)
        for word in [NavigationCopy.demoMemory, NavigationCopy.demoMemoryDetail, NavigationCopy.leaveDemoMemory] {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
        }
    }

    func testPauseChoicesEndWhenTheySay() {
        XCTAssertEqual(WindowStatusMenu.PauseChoice.hour.until(now: now, calendar: calendar),
                       now.addingTimeInterval(3_600))
        XCTAssertNil(WindowStatusMenu.PauseChoice.untilResume.until(now: now, calendar: calendar))
        let tomorrow = WindowStatusMenu.PauseChoice.tomorrow.until(now: now, calendar: calendar)
        XCTAssertEqual(tomorrow.map { calendar.dateComponents([.day, .hour, .minute], from: $0) },
                       DateComponents(day: 13, hour: 6, minute: 0))
    }

    func testAMalformedStatusIsIgnored() {
        XCTAssertNil(WindowChannelStatus(json: ["op": "status", "state": "weird", "title": "Remembering"]))
        XCTAssertNil(WindowChannelStatus(json: ["op": "status", "state": "paused"]))
        XCTAssertNil(WindowChannelStatus(json: ["op": "pause", "state": "paused", "title": "Paused"]))
        XCTAssertNil(WindowChannelStatus(json: ["op": "status", "state": "paused",
                                                "title": String(repeating: "x", count: 81)]))
        let ok = WindowChannelStatus(json: ["op": "status", "state": "paused", "title": "Paused",
                                            "pausedUntil": "2026-10-12T15:40:00-07:00"])
        XCTAssertEqual(ok?.pausedUntil, Date(timeIntervalSince1970: 1_791_844_800))
    }

    func testEveryWordPassesTheCopyRules() {
        let words = [
            NavigationCopy.bannerPaused(since: "2:40 PM"), NavigationCopy.bannerPausedUntil("3:40 PM"),
            NavigationCopy.bannerPausedNoTime, NavigationCopy.resume, NavigationCopy.pauseUntilResume,
            NavigationCopy.bannerOff, NavigationCopy.bannerPermission("Screen Recording"),
            NavigationCopy.bannerNotSaving, NavigationCopy.bannerCouldNotStop, NavigationCopy.bannerCouldNotTurnOn,
            NavigationCopy.bannerNotSetUp, NavigationCopy.bannerNotRunning, NavigationCopy.lowPower,
            NavigationCopy.forgetting, NavigationCopy.finishingForget, NavigationCopy.workingOnFootnote,
            NavigationCopy.sidebarIsNew, NavigationCopy.forgetRecentTitle, NavigationCopy.forgetRecentBody,
            NavigationCopy.firstForget, NavigationCopy.forgotten, NavigationCopy.couldNotForget,
            NavigationCopy.openHippocampusToForget, NavigationCopy.typeForget, NavigationCopy.forgotMoments(1),
            NavigationCopy.forgotMoments(4), NavigationCopy.itemTooltip(name: "trailhead-shop", when: "today at 2:20 PM"),
            NavigationCopy.workingOnPlaceholder, NavigationCopy.hiMarkLabel("Remembering"),
        ]
        for word in words {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
            XCTAssertFalse(CopyStyleValidator.hasEmDashPileup(word), word)
            XCTAssertFalse(word.lowercased().contains("captured"), word)
        }
        XCTAssertEqual(NavigationCopy.forgotMoments(1), "Forgot 1 moment.")
        XCTAssertEqual(NavigationCopy.forgotMoments(4), "Forgot 4 moments.")
        XCTAssertEqual(NavigationCopy.rowTooltip("History", key: "2"), "History  \u{2318}2")
        XCTAssertEqual(NavigationCopy.rowTooltip("Privacy", key: nil), "Privacy")
    }

    /// The confirmations before a larger forget, word for word (SPEC 9,
    /// rows 107 to 113).
    func testTheForgetConfirmationsSayWhatGoes() {
        XCTAssertEqual(NavigationCopy.forgetSpanTitle("2:12 to 2:36 PM"), "Forget 2:12 to 2:36 PM?")
        XCTAssertEqual(NavigationCopy.forgetSpanBody("2:12 to 2:36 PM", moments: 41),
                       "Everything saved from 2:12 to 2:36 PM is deleted from this Mac for good: 41 moments and their screenshots.")
        XCTAssertEqual(NavigationCopy.forgetPageTitle("Rounding half to even"), "Forget \u{201C}Rounding half to even\u{201D}?")
        XCTAssertEqual(NavigationCopy.forgetPageBody(moments: 6, days: 3),
                       "6 moments from 3 days are deleted from this Mac for good, with their screenshots.")
        XCTAssertEqual(NavigationCopy.forgetPageBody(moments: 1, days: 1),
                       "1 moment from 1 day is deleted from this Mac for good, with their screenshots.")
        XCTAssertEqual(NavigationCopy.forgetSearchTitle("per seat vs tiered pricing"),
                       "Forget the search \u{201C}per seat vs tiered pricing\u{201D}?")
        XCTAssertEqual(NavigationCopy.forgetSelectionTitle(36), "Forget 36 moments?")
        XCTAssertEqual(NavigationCopy.forgetSinceBody("midnight", moments: 1_284),
                       "Everything saved since midnight is deleted from this Mac for good: 1,284 moments and their screenshots.")
        for word in [NavigationCopy.forgetSearchBody, NavigationCopy.forgetSelectionBody, NavigationCopy.forgetTodayTitle,
                     NavigationCopy.forgetLastDayTitle, NavigationCopy.forgetSpanBody("2 PM to 3 PM", moments: 212)] {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
        }
    }

    /// The old advice can't work (a window the app opened closes with it)
    /// and appears nowhere (SPEC 3.11).
    func testQuitHippocampusLeaveThisWindowOpenIsGone() {
        XCTAssertFalse(UserFacingCopy.deleteBlockedBanner.contains("leave this window open"))
        XCTAssertFalse(UserFacingCopy.deleteBlockedBanner.lowercased().contains("quit"))
        XCTAssertTrue(UserFacingCopy.deleteBlockedBanner.hasPrefix(NavigationCopy.couldNotForget))
    }
}
