import Foundation
import XCTest
@testable import RecallUIKit

/// Every string Overview and You show follows the window's writing rules
/// (BRIEF, spec-copy S1 and S2, RULINGS V): no internal or banned words, no
/// percentages, quiet punctuation, curly apostrophes, short sentences.
final class OverviewCopyTests: XCTestCase {
    private typealias Overview = UserFacingCopy.Overview
    private typealias You = UserFacingCopy.You

    /// Sentences longer than twelve words that RULINGS I7 and the insights
    /// product critique give word for word.
    private static let givenWordForWord = Set(
        [You.sharedCaption, You.footer] + ModelUnavailableReasonCases.all.map { You.modelLine($0) }
    )

    private static var all: [(name: String, text: String)] {
        var strings: [(String, String)] = [
            ("loading", Overview.loading), ("dayUnavailable", Overview.dayUnavailable),
            ("tryAgain", Overview.tryAgain), ("previousDay", Overview.previousDay), ("nextDay", Overview.nextDay),
            ("today", Overview.today), ("todayEmpty", Overview.todayEmpty), ("pastDayEmpty", Overview.pastDayEmpty),
            ("nothingSaved", Overview.nothingSaved), ("connectLine", Overview.connectLine),
            ("aiKnowsNothingYet", Overview.aiKnowsNothingYet), ("showAll", Overview.showAll),
            ("showLess", Overview.showLess),
            ("sessionHelp", Overview.sessionHelp(title: "Pricing page copy", time: "9:05 – 9:34 AM")),
            ("mostly", Overview.mostly("Writing", some: "Design")), ("appTime", Overview.appTime("Notes", "19m")),
            ("timeAndLength", Overview.timeAndLength("9:05 – 9:34 AM", "29m")),
            ("noticedTitle", Overview.noticedTitle), ("lookedUp", Overview.lookedUp), ("copied", Overview.copied),
            ("couldNotCopy", Overview.couldNotCopy), ("hide", Overview.hide), ("summaryTitle", Overview.summaryTitle),
            ("activeHelp", Overview.activeHelp),
            ("stripLabel", Overview.stripLabel), ("legendHint", Overview.legendHint),
            ("recentWorkTitle", You.recentWorkTitle), ("recentWorkCaption", You.recentWorkCaption),
            ("recentWorkEmpty", You.recentWorkEmpty), ("sharedTitle", You.sharedTitle),
            ("sharedCaption", You.sharedCaption), ("exactWords", You.exactWords),
            ("keptBackTitle", You.keptBackTitle), ("notSeenLatelyTitle", You.notSeenLatelyTitle),
            ("footer", You.footer), ("right", You.right), ("rightHelp", You.rightHelp), ("forget", You.forget),
            ("forgetHelp", You.forgetHelp), ("forgotten", You.forgotten), ("undo", You.undo), ("why", You.why),
            ("reasoningCaption", You.reasoningCaption), ("nothingLearnedTitle", You.nothingLearnedTitle),
            ("nothingLearnedBody", You.nothingLearnedBody), ("unavailableTitle", You.unavailableTitle),
            ("yourDataTitle", You.yourDataTitle), ("rememberedRow", You.rememberedRow),
            ("rememberedCaption", You.rememberedCaption), ("namesRow", You.namesRow), ("aiToolsRow", You.aiToolsRow),
            ("sessionRow", You.sessionRow(date: "Oct 12", time: "2:02 – 2:31 PM")),
        ]
        for basis in [ModelItem.Basis.confirmed, .seenOnDays, .seenOnce] {
            strings.append(("basis.\(basis.rawValue)", You.basis(basis, daysSeen: 3)))
        }
        for reason in ModelUnavailableReasonCases.all {
            strings.append(("Overview.modelLine.\(reason)", Overview.modelLine(reason)))
            strings.append(("You.modelLine.\(reason)", You.modelLine(reason)))
        }
        return strings
    }

    private static let banned = [
        "brain", "capture", "captured", "captures", "event", "events", "episode", "stretch", "evidence",
        "handoff", "packet", "mcp", "register", "client", "hook", "provider", "proposition", "insights",
        "simply", "just", "seamlessly", "powerful", "smart", "magic", "unlock", "supercharge", "journey",
        "leverage", "track", "monitor", "record", "recording", "observe", "frame", "keyframe", "ocr", "daemon",
        "helper", "agent", "pipeline", "dashboard", "timeline", "brief", "productive", "distracted", "stuck",
    ]

    func testNoStringUsesAnInternalOrBannedWord() {
        for (name, text) in Self.all {
            XCTAssertFalse(CopyStyleValidator.containsRawErrorCode(text), "\(name): \(text)")
            XCTAssertNil(CopyStyleValidator.containsJargon(text), "\(name): \(text)")
            let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted))
            for word in Self.banned {
                XCTAssertFalse(words.contains(word), "\(name) says “\(word)”: \(text)")
            }
        }
    }

    func testPunctuationIsQuietAndApostrophesCurly() {
        for (name, text) in Self.all {
            for mark in ["\u{2014}", ";", "%", "!", "'", "\"", " / ", "..."] {
                XCTAssertFalse(text.contains(mark), "\(name) has “\(mark)”: \(text)")
            }
        }
    }

    func testSentencesAreTwelveWordsOrFewerUnlessGivenWordForWord() {
        for (name, text) in Self.all where !Self.givenWordForWord.contains(text) {
            for sentence in text.components(separatedBy: ". ") {
                let count = sentence.split(whereSeparator: { $0 == " " }).count
                XCTAssertLessThanOrEqual(count, 12, "\(name): \(sentence)")
            }
        }
    }

    func testBasisWordsSayWhereAThingCameFrom() {
        XCTAssertEqual(You.basis(.confirmed, daysSeen: 3), "You confirmed this")
        XCTAssertEqual(You.basis(.seenOnDays, daysSeen: 3), "Seen on 3 days")
        XCTAssertEqual(You.basis(.seenOnDays, daysSeen: 1), "Seen once")
        XCTAssertEqual(You.basis(.seenOnce, daysSeen: 1), "Seen once")
        XCTAssertEqual(You.basis(.seenOnce, daysSeen: 0), "Seen once")
    }

    func testTheModelOffLinesKeepWhatStillWorks() {
        XCTAssertEqual(You.modelLine(.appleIntelligenceOff),
                       "Hippocampus learns about you with Apple Intelligence, which is off on this Mac. "
                           + "Your day and search still work.")
        for reason in ModelUnavailableReasonCases.all {
            XCTAssertTrue(You.modelLine(reason).hasSuffix("Your day and search still work."))
            XCTAssertTrue(Overview.modelLine(reason).contains("Apple Intelligence"))
        }
    }

    func testTheEmptyDaysSayWhatRulingsW7Says() {
        XCTAssertEqual(Overview.todayEmpty, "Your day fills in as you work. It stays on this Mac.")
        XCTAssertEqual(Overview.pastDayEmpty, "Nothing saved on this day.")
    }
}

private enum ModelUnavailableReasonCases {
    static let all: [ModelUnavailableReason] = [.appleIntelligenceOff, .deviceNotEligible, .modelNotReady, .notAvailable]
}
