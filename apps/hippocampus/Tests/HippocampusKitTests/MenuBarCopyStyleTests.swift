// SPDX-License-Identifier: Apache-2.0
//
// MenuBarCopyStyleTests.swift — the launch copy guard for the "left-hand
// side" the person sees first: the menu-bar status panel and its menu. Every
// word macOS draws from `MenuBarStatus`, `StatusMenuModel` and the permission
// notifications is held to the same professional, trustworthy tone the window
// (RecallUIKit `CopyStyleTests`) and onboarding (`OnboardingCopyTests`) are.
//
// This module does not depend on RecallUIKit, so the banned lists are inlined
// here; `scripts/check-launch-copy.sh` carries the canonical set across all
// apps. See `reports/launch-kit/copy.md`.

import XCTest
@testable import HippocampusKit

final class MenuBarCopyStyleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_929_400)

    /// Marketing / machine-written words, matched whole-word.
    private static let marketingWords: Set<String> = [
        "seamless", "seamlessly", "effortless", "effortlessly", "unlock",
        "supercharge", "magic", "magical", "delve", "powerful", "smart",
        "simply", "leverage", "utilize", "robust", "elevate", "empower",
        "unleash", "harness", "frictionless", "revolutionary", "hiccup",
        "oops", "whoops", "gotcha",
    ]
    private static let marketingPhrases = ["ai-powered", "ai powered", "cutting-edge", "state-of-the-art"]
    /// Engineer jargon that must never reach a status string.
    private static let jargon = [
        "scstream", "sqlcipher", "sentinel", "denylist", "mci-agent", "errno", "\u{201C}mci\u{201D}",
    ]

    /// Every word the menu-bar panel and its menu can draw, as data.
    private var menuStrings: [(name: String, text: String)] {
        var out: [(String, String)] = []
        let statuses: [MenuBarStatus] = [
            .idle, .starting, .recording, .unchanged, .noMemory, .paused,
            .skipping(reason: "private_browsing"), .skipping(reason: "secure-event-input"),
            .skipping(reason: "denylist-source"), .skipping(reason: "os-blacked-region"),
            .skipping(reason: "ocr-time-secret"), .skipping(reason: "failsafe-unknown"),
            .skipping(reason: "browser_window_unknown"), .skipping(reason: "app_identity_unknown"),
            .needsPermission(.screenRecording), .needsPermission(.accessibility),
            .needsPermission(.fullDiskAccess), .needsPermission(.automation),
            .blocked(reason: "storage_error"), .blocked(reason: "helper_disconnected"),
            .blocked(reason: "capture_failed"), .blocked(reason: "capture_disabled"),
            .blocked(reason: "a-future-code"), .stale(reason: "x"), .error(reason: "x"),
            .stopFailed(reason: "x"), .turnOnFailed(reason: "x"),
        ]
        for status in statuses {
            out.append(("displayText(\(status))", status.displayText))
            if let detail = status.detailText { out.append(("detailText(\(status))", detail)) }
            if let action = status.action?.title { out.append(("action(\(status))", action)) }
            let row = StatusRow(StatusFacts(status: status), now: now)
            out.append(("footer(\(status))", AskPanelStatus(status, row: row, setup: .complete).text))
        }
        // The menu items, across setup and connected states.
        for setup in [AskPanelStatus.Setup.complete, .notFinished, .inProgress] {
            for connected in [true, false] {
                let row = StatusRow(StatusFacts(status: .recording, setup: setup), now: now)
                for item in StatusMenuModel.items(row: row, setupComplete: setup == .complete,
                                                  askLabel: "\u{21E7}\u{21E7}", aiToolsConnected: connected)
                where !item.title.isEmpty {
                    out.append(("item(\(item.role))", item.title))
                }
            }
        }
        // The permission notifications.
        for reason in TCCRevokedReason.allCases {
            out.append(("tcc.name", reason.name))
            out.append(("tcc.notificationTitle", reason.notificationTitle))
            out.append(("tcc.notificationBody", reason.notificationBody))
        }
        return out
    }

    func testMenuCopyHasNoMarketingSpeak() {
        for (name, text) in menuStrings {
            let lower = text.lowercased()
            for phrase in Self.marketingPhrases where lower.contains(phrase) {
                XCTFail("\(name) uses marketing phrase \u{201C}\(phrase)\u{201D}: \(text)")
            }
            let words = Set(lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            for word in Self.marketingWords where words.contains(word) {
                XCTFail("\(name) uses marketing word \u{201C}\(word)\u{201D}: \(text)")
            }
        }
    }

    func testMenuCopyHasNoJargonExclamationsOrEmDashPileups() {
        for (name, text) in menuStrings {
            let lower = text.lowercased()
            for term in Self.jargon where lower.contains(term) {
                XCTFail("\(name) leaks jargon \u{201C}\(term)\u{201D}: \(text)")
            }
            XCTAssertFalse(text.contains("!"), "\(name) shouts: \(text)")
            XCTAssertLessThan(text.filter { $0 == "\u{2014}" }.count, 2, "\(name) stacks em-dashes: \(text)")
        }
    }

    /// The guard actually sees the strings it is meant to (a tripwire: if the
    /// model ever stops producing words, this catches it).
    func testTheGuardCoversTheWholeMenu() {
        let titles = Set(menuStrings.map(\.text))
        XCTAssertTrue(titles.contains("Remembering"))
        XCTAssertTrue(titles.contains("Open Hippocampus"))
        XCTAssertTrue(titles.contains("Quit Hippocampus"))
        XCTAssertTrue(titles.contains("This is a private window."))
        XCTAssertTrue(titles.contains("Couldn’t turn on"))
        XCTAssertTrue(titles.contains("It didn’t start, so remembering is still off."))
        XCTAssertGreaterThan(menuStrings.count, 30)
    }
}
