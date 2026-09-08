import Foundation
import XCTest
@testable import RecallUIKit

final class HandoffPreviewTests: XCTestCase {
    func testHeadingsParagraphsAndMetadataKeepReadableSpacing() {
        let blocks = HandoffPreview.blocks("# Daily handoff\n\nTime: 10&#58;30\nSource: app&#95;name\n\n## Source excerpts\n\n> Saved body")
        XCTAssertEqual(blocks.map { String($0.text.characters) }, [
            "Daily handoff", "Time: 10:30\nSource: app_name", "Source excerpts", "Saved body",
        ])
        XCTAssertEqual(blocks.map(\.isHeading), [true, false, true, false])
    }

    func testEscapedCapturedMarkupRemainsLiteralAfterOneParse() {
        let hostile = "![remote](https://example.invalid/tracker) __private_name__ <script>alert(1)</script>"
        let hit = Hit(eventId: 42, tsUs: 1_788_739_200_000_000, appBundleId: "com.apple.Safari",
            windowTitle: "Review: local_notes", url: nil, ocrTextSnippet: hostile,
            source: "timeline", score: nil, sourceKind: "screen_ocr")
        let packet = VisualMemoryExport.markdown(title: "Source excerpts", hits: [hit])
        let blocks = HandoffPreview.blocks(packet)
        let displayed = blocks.map { String($0.text.characters) }.joined(separator: "\n\n")
        XCTAssertTrue(displayed.contains("Review: local_notes"))
        XCTAssertTrue(displayed.contains(hostile))
        XCTAssertFalse(displayed.contains("&#58;"))
        XCTAssertFalse(displayed.contains("&#95;"))
        for block in blocks {
            for run in block.text.runs {
                XCTAssertNil(run.link)
                XCTAssertNil(run.imageURL)
                XCTAssertFalse(run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
            }
        }
        XCTAssertTrue(packet.contains("&#58;"), "Display parsing must not modify the export packet.")
    }

    func testEvenExplicitLinksAndImagesHaveNoActiveAttributes() {
        let blocks = HandoffPreview.blocks("[Event 42](hippocampus://recall?tab=search&focus=42) [web](https://example.invalid) ![image](https://example.invalid/image.png)")
        XCTAssertEqual(blocks.map { String($0.text.characters) }.joined(), "Event 42 web image")
        for block in blocks {
            for run in block.text.runs {
                XCTAssertNil(run.link)
                XCTAssertNil(run.imageURL)
            }
        }
    }
}
