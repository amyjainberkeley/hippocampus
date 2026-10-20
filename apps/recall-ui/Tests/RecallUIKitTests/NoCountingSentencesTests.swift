import Foundation
import XCTest
@testable import RecallUIKit

/// Today never shows a sentence that counts what the person did: switches,
/// rewordings, keys, clicks or scrolls (RULINGS W4, SPEC 3.1). The agent no
/// longer writes `switched_between` or `reworded_search`; the window drops
/// them, and any sentence that counts, from older answers too.
final class NoCountingSentencesTests: XCTestCase {
    private func block(sentences: [DaySentence]) -> DayBlock {
        DayBlock(id: 1, provisional: false, startUs: 1, endUs: 600_000_000, inProgress: false, touchesPrevious: false,
                 title: "Session", writtenBy: "measured", kind: .writing, kindLabel: "Writing", mixed: false,
                 kinds: [], apps: [], windows: [], sentences: sentences, searches: [], screenshotEventId: nil,
                 openEventId: nil, reopen: nil, noticed: nil)
    }

    func testNoSessionOfTheSamplesSaysAnythingThatCounts() throws {
        let overview = try UnderstandingFixture.overview()
        XCTAssertTrue(overview.blocks.contains { !$0.sentences.isEmpty }, "the old samples still carry both kinds")
        for block in overview.blocks {
            let detail = SessionDetail(block: block, locale: SampleDay.locale, timeZone: SampleDay.timeZone)
            XCTAssertTrue(detail.sentences.isEmpty, "\(block.title): \(detail.sentences)")
        }
    }

    func testEveryCountingSentenceIsDroppedWhateverItsId() {
        let counting = [
            ("switched_between", "You switched between Figma and Notes five times."),
            ("reworded_search", "You reworded a search twice."),
            ("other", "You typed 400 keys in this session."),
            ("other", "You clicked 40 times."),
            ("other", "You scrolled through three pages."),
            ("other", "You switched apps every few minutes."),
        ].map { DaySentence(id: $0.0, text: TemplateText(template: $0.1)) }
        XCTAssertTrue(SessionDetail(block: block(sentences: counting)).sentences.isEmpty)
    }

    func testASentenceThatCountsNothingStays() {
        let plain = DaySentence(id: "other", text: TemplateText(template: "Most of it was in Notes."))
        XCTAssertEqual(SessionDetail(block: block(sentences: [plain])).sentences, ["Most of it was in Notes."])
    }

    func testTodaysOwnWordsCountNothing() {
        let words = [
            UserFacingCopy.Overview.yourDay, UserFacingCopy.Overview.todayNothingYet,
            UserFacingCopy.Overview.lookedUpToday, UserFacingCopy.Overview.alsoFrom("yesterday"),
            UserFacingCopy.Overview.leftOff("Yesterday at 6:12 PM"), UserFacingCopy.Overview.showCalendarLine,
            UserFacingCopy.Overview.connectRecentWork, UserFacingCopy.Overview.firstDayPausedBody,
            UserFacingCopy.Overview.firstDayPermissionBody,
        ]
        for text in words {
            XCTAssertFalse(SessionDetail.counts(text), text)
        }
    }
}
