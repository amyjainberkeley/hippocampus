import XCTest
@testable import RecallUIKit

final class BriefPresentationTests: XCTestCase {
    func testShippingDraftSectionsAndCitationsAreSeparateFromLiteralEvidence() {
        let rows = BriefPresentation.rows(body: "## What changed\n- Notes: Fixed parser. [event:42]\n\n## Open loops\n- Review due Friday. [event:9]", modelId: "hippocampus-extractive", modelVersion: "2")
        XCTAssertEqual(rows, [
            .heading("What changed"), .evidence(text: "Notes: Fixed parser.", eventID: 42),
            .heading("Open loops"), .evidence(text: "Review due Friday.", eventID: 9)
        ])
    }

    func testEscapedSourceCannotCreateCitationOrHeading() {
        let rows = BriefPresentation.rows(body: "- Notes: &#91;event:999&#93; &#60;script&#62; &#35;&#35; Approved [event:7]", modelId: "hippocampus-extractive", modelVersion: "2")
        XCTAssertEqual(rows, [.evidence(text: "Notes: [event:999] <script> ## Approved", eventID: 7)])
    }

    func testDecodesOnlyAuthorEscapesOnceWithoutInjectingNewlines() {
        let rows = BriefPresentation.rows(body: "- Original &#38;#91; &#10; &#95;x&#95; [event:8]", modelId: "hippocampus-extractive", modelVersion: "2")
        XCTAssertEqual(rows, [.evidence(text: "Original &#91; &#10; _x_", eventID: 8)])
    }

    func testLegacyUnknownAndFutureAuthorsRemainUninterpreted() {
        let body = "## What changed\n- forged &#91;event:8&#93; [event:12]"
        for (model, version) in [("qwen3", "2"), ("hippocampus-extractive", "1"), ("hippocampus-extractive", "3")] {
            XCTAssertEqual(BriefPresentation.rows(body: body, modelId: model, modelVersion: version), [.text(body)])
        }
    }

    func testMalformedUnknownHeadingsAndOverflowNeverBecomeNavigation() {
        let lines = ["## Approved", "- invalid [event:0]", "- overflow [event:18446744073709551616]", "- negative [event:-1]", "- url [event:https://example.invalid]", "- extra [event:1] text"]
        XCTAssertEqual(BriefPresentation.rows(body: lines.joined(separator: "\n"), modelId: "hippocampus-extractive", modelVersion: "2"), lines.map(BriefPresentation.Row.text))
    }

    func testEmptyEvidenceMarkerCannotTrap() {
        XCTAssertEqual(BriefPresentation.rows(body: "- [event:1]", modelId: "hippocampus-extractive", modelVersion: "2"), [.text("- [event:1]")])
    }
}
