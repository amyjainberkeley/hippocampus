import Foundation
import XCTest
@testable import RecallUIKit

final class ScreenshotInspectorTests: XCTestCase {
    private let hit = Hit(eventId: 42, tsUs: 1_788_566_400_000_000,
                          appBundleId: "com.example.Fixture", windowTitle: "Fixture screenshot",
                          url: "https://example.invalid/source", ocrTextSnippet: "Saved preview only.",
                          source: "timeline", score: nil, sourceKind: "screen_ocr")

    func testContextKeepsCitationAndProvenanceAndIncludesTextBeyondExportSnippetLimit() throws {
        let body = String(repeating: "stored line\n", count: 1000) + "final stored line"
        let text = try EventText(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId, text: body, isTruncated: false)
        let context = ScreenshotInspectorContext.markdown(hit: hit, text: text)
        XCTAssertTrue(context.hasPrefix(VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit])))
        XCTAssertTrue(context.contains("[Event 42](hippocampus://recall?tab=search&focus=42)"))
        XCTAssertTrue(context.contains("observations, not verified facts"))
        XCTAssertTrue(context.contains("Review before sharing"))
        XCTAssertTrue(context.contains("Fixture screenshot"))
        XCTAssertTrue(context.contains(body), "the inspector must not reapply the shared excerpt export cap")
        XCTAssertTrue(context.contains("## Complete stored text"))
    }

    func testUnavailableOrMismatchedTextCannotExportAnotherSelection() throws {
        let preview = VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit])
        XCTAssertEqual(ScreenshotInspectorContext.markdown(hit: hit, text: nil), preview)
        let stale = try EventText(eventId: 99, tsUs: hit.tsUs, appBundleId: hit.appBundleId, text: "old selection text", isTruncated: false)
        XCTAssertEqual(ScreenshotInspectorContext.markdown(hit: hit, text: stale), preview)
        XCTAssertFalse(ScreenshotInspectorContext.markdown(hit: hit, text: stale).contains("old selection text"))
    }

    func testReusedIdWithDifferentIdentityCannotExportUnderOldCitation() throws {
        let preview = VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit])
        for (timestamp, app) in [(hit.tsUs + 1, hit.appBundleId), (hit.tsUs, nil)] {
            let replacement = try EventText(eventId: hit.id, tsUs: timestamp, appBundleId: app,
                                             text: "replacement private body", isTruncated: false)
            XCTAssertEqual(ScreenshotInspectorContext.markdown(hit: hit, text: replacement), preview)
        }
    }

    func testDetailReloadIsKeyedBySnapshotNotJustReusedId() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/DetailPaneView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains(".task(id: hit)"))
        XCTAssertTrue(source.contains("textModel.load(hit: hit, reader: reader)"))
        XCTAssertFalse(source.contains("textModel.text(for: hit.id)"))
    }

    func testCapIsVisibleAndEmptyStoredTextIsNotReplacedWithPreview() throws {
        let body = String(repeating: "\u{e9}", count: EventText.maxUTF8Bytes / 2)
        let text = try EventText(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId, text: body, isTruncated: true)
        let context = ScreenshotInspectorContext.markdown(hit: hit, text: text)
        XCTAssertTrue(context.contains(body))
        XCTAssertTrue(context.contains("## Stored text (truncated)"))
        XCTAssertTrue(context.contains("128 KiB"))
        XCTAssertFalse(context.contains("## Complete stored text"))
        let empty = try EventText(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId, text: "", isTruncated: false)
        let emptyContext = ScreenshotInspectorContext.markdown(hit: hit, text: empty)
        XCTAssertTrue(emptyContext.contains("## Complete stored text"))
        XCTAssertTrue(emptyContext.hasSuffix("```text\n\n```\n"))
    }

    func testCapturedMarkdownAndFenceRunsRemainInsideOneLiteralBlock() throws {
        let body = "```\n![image](https://example.invalid)\n<script>data</script>\r\n````\n# captured heading"
        let text = try EventText(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId, text: body, isTruncated: false)
        let context = ScreenshotInspectorContext.markdown(hit: hit, text: text)
        XCTAssertTrue(context.hasSuffix("`````text\n" + body + "\n`````\n"))
        XCTAssertEqual(context.components(separatedBy: "hippocampus://").count - 1, 1)
    }

    func testWorstCaseFenceGrowthIsStillBoundedWithoutLosingStoredBytes() throws {
        let body = String(repeating: "`", count: EventText.maxUTF8Bytes)
        let text = try EventText(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId, text: body, isTruncated: true)
        let context = ScreenshotInspectorContext.markdown(hit: hit, text: text)
        let fence = String(repeating: "`", count: EventText.maxUTF8Bytes + 1)
        XCTAssertTrue(context.hasSuffix(fence + "text\n" + body + "\n" + fence + "\n"))
        XCTAssertLessThan(context.utf8.count, EventText.maxUTF8Bytes * 3 + 65_536)
    }

    // The inspector lives in the executable target. These narrow composition
    // contracts complement the real renderer and existing EventText model tests.
    func testInspectorUsesSelectedTextModelForDisplayAndContext() throws {
        let source = try inspectorSource()
        XCTAssertTrue(source.contains("@StateObject private var textModel = EventTextViewModel()"))
        XCTAssertTrue(source.contains("await textModel.load(hit: current, reader: reader)"))
        XCTAssertTrue(source.contains("textModel.copyText(for: hit)"))
        XCTAssertTrue(source.contains("textModel.text(for: hit)"))
        XCTAssertTrue(source.contains("ScreenshotInspectorContext.markdown"))
        XCTAssertTrue(source.contains("Truncated at the 128 KiB text limit."))
        XCTAssertFalse(source.contains("No text was stored with this screenshot."),
                       "a missing preview cannot establish that no full text was stored")
    }

    func testNavigationRefreshAndDismissalClearHitAndFullText() throws {
        let source = try inspectorSource()
        let clear = try section(source, from: "private func clearLoadedEvent()", to: "private func copyContext()")
        XCTAssertTrue(clear.contains("loadGeneration = UUID()"))
        XCTAssertTrue(clear.contains("hit = nil"))
        XCTAssertTrue(clear.contains("textModel.clear()"))
        XCTAssertTrue(source.contains("clearLoadedEvent(); index -= 1"))
        XCTAssertTrue(source.contains("clearLoadedEvent(); index += 1"))
        XCTAssertTrue(source.contains(".onDisappear(perform: clearLoadedEvent)"))
        let refresh = try section(source, from: ".onReceive(", to: ".onDisappear(")
        XCTAssertLessThan(try XCTUnwrap(refresh.range(of: "clearLoadedEvent()")?.lowerBound),
                          try XCTUnwrap(refresh.range(of: "refreshID += 1")?.lowerBound))
        let task = try section(source, from: ".task(id:", to: ".onReceive(")
        XCTAssertTrue(task.contains("clearLoadedEvent()"))
        XCTAssertTrue(task.contains("eventID == self.eventID"))
        XCTAssertTrue(task.contains("loadGeneration == request"))
        XCTAssertTrue(task.contains("current.id == eventID"))
    }

    func testCopyAndExportRecheckCurrentSelectionIncludingAfterSaveDialog() throws {
        let source = try inspectorSource()
        let selected = try section(source, from: "private var selectedHit:", to: "var body:")
        XCTAssertTrue(selected.contains("hit.id == eventID"))
        let copy = try section(source, from: "private func copyContext()", to: "private func exportContext()")
        XCTAssertTrue(copy.contains("guard let hit = selectedHit"))
        let export = try section(source, from: "private func exportContext()", to: "private func copy(")
        XCTAssertTrue(export.contains("let generation = loadGeneration"))
        let dialog = try XCTUnwrap(export.range(of: "panel.runModal()"))
        let checked = try XCTUnwrap(export.range(of: "loadGeneration == generation"))
        let written = try XCTUnwrap(export.range(of: "try text.write"))
        XCTAssertLessThan(dialog.upperBound, checked.lowerBound)
        XCTAssertLessThan(checked.upperBound, written.lowerBound)
        XCTAssertTrue(export.contains("current.id == hit.id"))
    }

    private func inspectorSource() throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/ScreenshotViewer.swift"),
                          encoding: .utf8)
    }

    private func section(_ source: String, from start: String, to end: String) throws -> String {
        let range = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: range.upperBound..<source.endIndex))
        return String(source[range.lowerBound..<endRange.lowerBound])
    }
}
