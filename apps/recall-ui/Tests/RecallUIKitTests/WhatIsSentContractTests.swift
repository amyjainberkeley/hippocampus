import Foundation
import XCTest
@testable import RecallUIKit

/// Holds `WhatIsSent`, the one Swift statement of what a connected AI is
/// given, to the Rust that gives it (contract what-is-sent.md section 4,
/// RULINGS I12). Each expected line is built from the Swift value, so changing
/// one side alone fails. Until the agent names its numbers as constants
/// (section 4.1), the literals they replace are checked instead.
final class WhatIsSentContractTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // RecallUIKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // recall-ui
        .deletingLastPathComponent() // apps
        .deletingLastPathComponent() // repository

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheNumbersOnThePageAreTheNumbersTheAgentSends() throws {
        let query = try source("apps/agent/src/understanding/query.rs")
        let lines = Set(query.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        if query.contains("pub const RECENT_WORK_LINES") {
            let expected = [
                "pub const RECENT_WORK_LINES: usize = \(WhatIsSent.recentWorkLines);",
                "pub const RECENT_WORK_WINDOW_US: u64 = \(WhatIsSent.recentWorkHours) * 3_600_000_000;",
                "pub const ABOUT_YOU_LINES: usize = \(WhatIsSent.aboutYouLines);",
                "pub const ABOUT_YOU_MIN_CONFIDENCE: f64 = \(WhatIsSent.aboutYouMinConfidence);",
                "pub const ABOUT_YOU_CANDIDATES: usize = \(WhatIsSent.aboutYouCandidates);",
                "pub const ABOUT_YOU_FOCUS_MATCHES: usize = \(WhatIsSent.aboutYouFocusMatches);",
                "pub const TITLE_CHARS: usize = \(WhatIsSent.titleChars);",
                "pub const DETAIL_CHARS: usize = \(WhatIsSent.detailChars);",
                "pub const STATEMENT_CHARS: usize = \(WhatIsSent.statementChars);",
                "pub const NOT_SEEN_LATELY_DAYS: u64 = \(WhatIsSent.notSeenLatelyDays);",
            ]
            for line in expected {
                XCTAssertTrue(lines.contains(line), "query.rs has no line: \(line)")
            }
        } else {
            // What the agent sends today (what-is-sent.md section 1).
            let expected = [
                "let half_day = \(WhatIsSent.recentWorkHours) * 3_600_000_000u64;",
                ".take(\(WhatIsSent.recentWorkLines))",
                ".and_then(|f| store.search_propositions(f, \(WhatIsSent.aboutYouFocusMatches)).ok())",
                "let recent = store.propositions_with_status(PropositionStatus::Active, "
                    + "\(WhatIsSent.aboutYouCandidates)).unwrap_or_default();",
                "if out.len() == \(WhatIsSent.aboutYouLines) {",
                "&& p.confidence >= \(WhatIsSent.aboutYouMinConfidence)",
            ]
            for line in expected {
                XCTAssertTrue(lines.contains(line), "query.rs has no line: \(line)")
            }
            for fragment in [
                "clip(&p.text, \(WhatIsSent.statementChars))",
                "clip(note.title.trim(), \(WhatIsSent.titleChars))",
                "clip(detail.trim(), \(WhatIsSent.detailChars))",
            ] {
                XCTAssertTrue(query.contains(fragment), "query.rs does not cut with \(fragment)")
            }
        }
    }

    func testOnlyTheKindsThePageCallsSharedAreSentUnasked() throws {
        let query = try source("apps/agent/src/understanding/query.rs")
        let header = "const SHARED_UNASKED: [PropositionKind; \(WhatIsSent.sharedKinds.count)] = ["
        guard let start = query.range(of: header),
              let end = query.range(of: "];", range: start.upperBound..<query.endIndex)
        else { return XCTFail("query.rs has no \(header)") }
        let kinds = query[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(kinds, WhatIsSent.sharedKinds.map { "PropositionKind::\($0.prefix(1).uppercased())\($0.dropFirst())," })
    }

    func testEveryKindTheAgentKnowsIsSharedLookedUpOrNeverShown() throws {
        let store = try source("core/brain/src/understanding.rs")
        guard let start = store.range(of: "pub enum PropositionKind {"),
              let end = store.range(of: "}", range: start.upperBound..<store.endIndex)
        else { return XCTFail("understanding.rs has no PropositionKind") }
        let variants = store[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix(",") && !$0.hasPrefix("//") && !$0.hasPrefix("#") }
            .map { $0.dropLast().lowercased() }
        let page = WhatIsSent.sharedKinds + WhatIsSent.lookUpOnlyKinds + WhatIsSent.neverShownKinds
        XCTAssertEqual(Set(variants), Set(page))
        XCTAssertEqual(page.count, Set(page).count, "a kind is listed twice")
    }

    func testTheContextNamesTheToolsThePageNames() throws {
        let packet = try source("apps/agent/src/context_packet.rs")
        let line = "\"\\nMore, on request: \(WhatIsSent.lookUpTools.joined(separator: ", ")).\\n\""
        XCTAssertTrue(packet.contains(line), "context_packet.rs has no \(line)")
    }

    func testTheWindowIgnoresTheSystemAppsTheAgentIgnores() throws {
        // The catalog lives in mci-brain, which the agent re-exports.
        let apps = try source("core/brain/src/apps.rs")
        guard let start = apps.range(of: "const NOISE: &[&str] = &["),
              let end = apps.range(of: "];", range: start.upperBound..<apps.endIndex)
        else { return XCTFail("apps.rs has no NOISE list") }
        let ids = apps[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\",")) }
        XCTAssertEqual(ids, WhatIsSent.ignoredApps)
        // The agent compares lower-cased ids.
        XCTAssertTrue(apps.contains("let lowered = bundle_id.to_ascii_lowercase();"))
        XCTAssertTrue(WhatIsSent.isIgnoredApp("com.apple.Dock"))
        XCTAssertTrue(WhatIsSent.isIgnoredApp("ai.hippocampus"))
        XCTAssertFalse(WhatIsSent.isIgnoredApp("ai.hippocampus.recall"))
        XCTAssertFalse(WhatIsSent.isIgnoredApp("com.apple.Notes"))
        XCTAssertFalse(WhatIsSent.isIgnoredApp(nil))
    }

    func testThePagesCaptionsSayTheAgentsNumbers() {
        XCTAssertEqual(UserFacingCopy.You.sharedCaption,
                       "Up to six go to your AI at the start of each session, the ones Hippocampus is surest of.")
        XCTAssertEqual(UserFacingCopy.You.recentWorkCaption,
                       "Your AI gets your last four sessions from the past 12 hours.")
        XCTAssertEqual(UserFacingCopy.You.recentWorkEmpty, "No sessions in the past 12 hours.")
        XCTAssertEqual(WhatIsSent.spelled(6), "six")
        XCTAssertEqual(WhatIsSent.spelled(12), "12")
    }
}
