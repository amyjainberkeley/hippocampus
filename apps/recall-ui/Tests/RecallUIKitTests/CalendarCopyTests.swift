import Foundation
import XCTest
@testable import RecallUIKit

/// The window's calendar words (SPEC-DELTA 5) keep the launch copy bar.
final class CalendarCopyTests: XCTestCase {
    func testTheWordsKeepTheLaunchCopyBar() {
        XCTAssertFalse(CalendarCopy.all.isEmpty)
        for text in CalendarCopy.all {
            XCTAssertNil(CopyStyleValidator.containsJargon(text), text)
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(text), text)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(text), text)
            XCTAssertFalse(CopyStyleValidator.hasEmDashPileup(text), text)
            XCTAssertFalse(CopyStyleValidator.containsRawErrorCode(text), text)
            XCTAssertFalse(text.lowercased().contains("eventkit"), text)
        }
    }

    func testTheNoteAfterShowCalendarSaysWhatHappened() {
        XCTAssertNil(CalendarCopy.note(after: .allowed), "the bars appearing say it")
        XCTAssertEqual(CalendarCopy.note(after: .denied), "macOS isn’t letting Hippocampus read your calendar.")
        XCTAssertEqual(CalendarCopy.note(after: .notAsked), CalendarCopy.couldNotAsk)
        XCTAssertEqual(CalendarCopy.openSystemSettings, "Open System Settings…")
    }
}
