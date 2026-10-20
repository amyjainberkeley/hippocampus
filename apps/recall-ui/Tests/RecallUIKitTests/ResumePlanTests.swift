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

    func testResumesWordsAreCalm() {
        for word in [WorkCopy.resume, WorkCopy.resumeTitle, WorkCopy.resumeNothing, WorkCopy.cancel] {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
        }
    }
}
