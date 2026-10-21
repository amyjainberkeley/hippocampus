import XCTest
@testable import RecallUIKit

/// What the Resume sheet lists (SPEC-DELTA 3), as the agent's `resume-plan`
/// writes it. Until plans are read, there is nothing to open again.
final class ResumePlanTests: XCTestCase {
    func testThePlanReadsAsTheAgentWritesIt() throws {
        let json = #"""
            {"items": [
              {"kind": "page", "title": "Rounding half to even", "app": "com.google.Chrome",
               "url": "https://devnotes.example/rounding", "checked": true},
              {"kind": "folder", "title": "trailhead-shop", "app": "com.microsoft.VSCode", "path": "~/dev/trailhead-shop"},
              {"kind": "document", "title": "Launch checklist", "app": "com.apple.Notes", "checked": false,
               "note": "Notes opens the app; Hippocampus can’t open a single note"}
            ]}
            """#
        let plan = try JSONDecoder().decode(ResumePlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.items.map(\.kind), ["page", "folder", "document"])
        XCTAssertTrue(plan.items[1].checked, "ticked unless the plan says otherwise")
        XCTAssertEqual(plan.openable.map(\.title), ["Rounding half to even", "trailhead-shop"],
                       "a row that can't be reopened says why instead")
        XCTAssertEqual(Set(plan.items.map(\.id)).count, 3)
    }

    func testTheAgentsEmptyPlanAndTheStandInHaveNothingToOpen() async throws {
        XCTAssertEqual(try JSONDecoder().decode(ResumePlan.self, from: Data(#"{"items": []}"#.utf8)), .empty)
        let plan = try await NoResumePlans().plan(item: "w_9c41e2")
        XCTAssertEqual(plan, .empty)
        XCTAssertTrue(plan.openable.isEmpty)
    }

    func testAFolderOpensInItsEditorAndATerminalAsTwoRows() throws {
        let json = #"""
            {"item": {"name": "trailhead-shop", "kind": "code"},
             "session": {"start_us": 1791838800000000, "end_us": 1791840900000000},
             "items": [
              {"kind": "folder", "title": "trailhead-shop", "app": "com.microsoft.VSCode", "path": "~/dev/trailhead-shop"},
              {"kind": "folder", "title": "trailhead-shop", "app": "com.apple.Terminal", "path": "~/dev/trailhead-shop"}
            ]}
            """#
        let plan = try JSONDecoder().decode(ResumePlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.item, .init(name: "trailhead-shop", kind: "code"))
        XCTAssertEqual(plan.session, .init(startUs: 1_791_838_800_000_000, endUs: 1_791_840_900_000_000))
        XCTAssertEqual(Set(plan.items.map(\.id)).count, 2, "the same folder in two apps is two rows")
        XCTAssertEqual(plan.openable.count, 2)
    }

    func testReasonsSayWhetherARowCanOpen() {
        let page = ResumePlan.Target(kind: "page", title: "Rounding half to even", app: "com.google.Chrome",
                                     url: "https://devnotes.example/rounding")
        XCTAssertTrue(page.canOpen)
        XCTAssertTrue(page.isTab)
        for reason in ["missing", "no_address"] {
            let blocked = ResumePlan.Target(kind: "page", title: "A page", app: "com.apple.Safari", reason: reason)
            XCTAssertFalse(blocked.canOpen, reason)
        }
        for reason in ["single_note", "app_only", "no_folder"] {
            let appOnly = ResumePlan.Target(kind: "document", title: "Launch checklist", app: "com.apple.Notes",
                                            reason: reason)
            XCTAssertTrue(appOnly.canOpen, "\(reason): its app still opens")
            XCTAssertFalse(appOnly.isTab)
        }
        XCTAssertFalse(ResumePlan.Target(kind: "app", title: "Nothing to open").canOpen)
        XCTAssertFalse(ResumePlan.Target(kind: "page", title: "Noted", app: "com.google.Chrome",
                                         url: "https://devnotes.example/", note: "Can\u{2019}t open").canOpen)
    }

    func testResumesWordsAreCalm() {
        // The sheet names the project it reopens (launch playbook,
        // decision 12).
        XCTAssertEqual(WorkCopy.resumeTitle("Q4 investor update"), "Reopen Q4 investor update")
        XCTAssertEqual(WorkCopy.resumeTitle(nil), "Reopen what was open")
        XCTAssertEqual(WorkCopy.resumeTitle(""), "Reopen what was open")
        for word in [WorkCopy.resume, WorkCopy.resumeTitle("trailhead-shop"), WorkCopy.resumeTitle(nil),
                     WorkCopy.resumeNothing, WorkCopy.cancel] {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
        }
    }
}
