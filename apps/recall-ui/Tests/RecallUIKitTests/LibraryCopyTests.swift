import Foundation
import XCTest
@testable import RecallUIKit

/// Every word of History and its lenses (SPEC 3.4, SPEC-DELTA 1) follows the
/// window's style: no internal or banned word, quiet punctuation, curly
/// apostrophes, short sentences, Title Case on buttons.
final class LibraryCopyTests: XCTestCase {
    private typealias History = LibraryCopy.History

    static var all: [(String, String)] {
        var strings: [(String, String)] = [
            ("History.emptyTodayTitle", History.emptyTodayTitle), ("History.emptyTodayBody", History.emptyTodayBody),
            ("History.emptyPastDay", History.emptyPastDay), ("History.today", History.today),
            ("History.previousDay", History.previousDay), ("History.nextDay", History.nextDay),
            ("History.wholeDay", History.wholeDay), ("History.partOf", History.partOf("trailhead-shop")),
            ("History.open", History.open), ("History.copyText", History.copyText),
            ("History.openLink", History.openLink), ("History.openScreenshot", History.openScreenshot),
            ("History.openLinkHelp", History.openLinkHelp), ("History.openScreenshotHelp", History.openScreenshotHelp),
            ("History.copyForYourAI", History.copyForYourAI), ("History.showRelated", History.showRelated),
            ("History.forgetThisMoment", History.forgetThisMoment),
            ("History.forgetThisMomentMenu", History.forgetThisMomentMenu),
            ("History.forgetMoments", History.forgetMoments(4)), ("History.forgetMomentsMenu", History.forgetMomentsMenu(4)),
            ("History.forgetHelp", History.forgetHelp(1)),
            ("History.forgetHour", History.forgetHour(History.hourRange("2 PM", "3 PM"))),
            ("History.selected", History.selected(3)), ("History.selectedOne", History.selected(1)),
            ("History.forgetHint", History.forgetHint),
            ("olderDeleted", LibraryCopy.olderDeleted(days: 90)), ("olderDeletedOne", LibraryCopy.olderDeleted(days: 1)),
            ("change", LibraryCopy.change), ("showEarlier", LibraryCopy.showEarlier),
            ("today", LibraryCopy.today), ("yesterday", LibraryCopy.yesterday),
            ("previous7Days", LibraryCopy.previous7Days), ("previous30Days", LibraryCopy.previous30Days),
            ("Conversations.filterLabel", LibraryCopy.Conversations.filterLabel),
        ]
        for lens in LibraryLens.allCases {
            strings.append(("lead.\(lens)", LibraryCopy.lead(lens)))
            strings.append(("emptyTitle.\(lens)", LibraryCopy.empty(lens).title))
            strings.append(("emptyBody.\(lens)", LibraryCopy.empty(lens).body))
        }
        for filter in ConversationFilter.allCases {
            strings.append(("chip.\(filter)", filter.title))
            strings.append(("emptyConversations.\(filter)", LibraryCopy.emptyConversations(filter)))
        }
        return strings
    }

    private static let banned = [
        "brain", "capture", "captured", "captures", "event", "events", "episode", "evidence", "handoff", "packet",
        "mcp", "client", "hook", "provider", "insights", "simply", "just", "seamlessly", "powerful", "smart",
        "magic", "unlock", "supercharge", "journey", "leverage", "track", "monitor", "record", "recording",
        "observe", "frame", "keyframe", "ocr", "daemon", "helper", "agent", "pipeline", "dashboard", "timeline",
        "productive", "distracted", "stuck",
    ]

    func testNoStringUsesAnInternalOrBannedWord() {
        for (name, text) in Self.all {
            XCTAssertFalse(CopyStyleValidator.containsRawErrorCode(text), "\(name): \(text)")
            XCTAssertNil(CopyStyleValidator.containsJargon(text), "\(name): \(text)")
            let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted))
            for word in Self.banned {
                XCTAssertFalse(words.contains(word), "\(name) says \u{201C}\(word)\u{201D}: \(text)")
            }
        }
    }

    func testPunctuationIsQuietAndApostrophesCurly() {
        for (name, text) in Self.all {
            for mark in ["\u{2014}", ";", "%", "!", "'", "\"", " / ", "..."] {
                XCTAssertFalse(text.contains(mark), "\(name) has \u{201C}\(mark)\u{201D}: \(text)")
            }
        }
    }

    func testSentencesAreTwelveWordsOrFewer() {
        for (name, text) in Self.all {
            for sentence in text.components(separatedBy: ". ") {
                XCTAssertLessThanOrEqual(sentence.split(separator: " ").count, 12, "\(name): \(sentence)")
            }
        }
    }

    func testActionsAreTitleCase() {
        let actions = [History.open, History.copyText, History.openLink, History.openScreenshot,
                       History.copyForYourAI, History.showRelated, History.forgetThisMomentMenu,
                       History.forgetMomentsMenu(2), History.wholeDay, History.previousDay, History.nextDay,
                       LibraryCopy.showEarlier, LibraryCopy.previous7Days, LibraryCopy.previous30Days]
        let small: Set<String> = ["for", "to", "in", "of", "the", "a", "and"]
        for action in actions {
            for word in action.split(separator: " ").dropFirst() where !small.contains(String(word)) {
                XCTAssertTrue(word.first.map { $0.isUppercase || $0.isNumber } ?? true, "\(action): \(word)")
            }
        }
    }
}
