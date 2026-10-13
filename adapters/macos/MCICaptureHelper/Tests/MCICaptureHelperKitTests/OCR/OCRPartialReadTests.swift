import CoreGraphics
import CoreVideo
import XCTest

@testable import MCICaptureHelperKit

/// Reads of part of a window: the focused window read only where it changed,
/// or a whole-screen window with another window in front of it. Such a read
/// may not have seen a box's neighbours, so it must never move content to
/// chrome by judging a box against them: when unsure, it is content. All
/// text is made up.
final class OCRPartialReadTests: XCTestCase {
    // MARK: - Which reads are partial

    func testAFocusedReadOfOnlyTheChangedAreaIsPartial() {
        let context = WorkflowContext(appBundleId: "com.example.notes", windowTitle: "Weekly review")
        let buffer = OCRReadingPrivacyTests.makePixelBuffer(width: 2880, height: 1800)
        func geometry(_ dirty: [DirtyRect]) -> OCRWindowGeometry {
            let roi = OCRROIComputer.normalizedBoundingROI(widthPx: 2880, heightPx: 1800, dirtyRects: dirty)
            return OCRWindowGeometry.focused(context: context,
                                             input: OCREngineInput(pixelBuffer: buffer, roi: roi, pixelsPerPoint: 2))
        }
        let whole = geometry([DirtyRect(x: 0, y: 0, width: 2880, height: 1800)])
        XCTAssertFalse(whole.partial)
        XCTAssertEqual(whole.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(whole.pixelsPerPoint, 2)
        XCTAssertEqual(whole.title, "Weekly review")
        XCTAssertEqual(whole.bundleId, "com.example.notes")
        // Typing: the line, the tab's mark and the status bar change, so the
        // changed area spans nearly the whole window.
        XCTAssertFalse(geometry([DirtyRect(x: 900, y: 700, width: 1200, height: 40),
                                 DirtyRect(x: 400, y: 60, width: 300, height: 40),
                                 DirtyRect(x: 200, y: 1760, width: 2500, height: 30)]).partial)
        // One paragraph changed in the middle of the window.
        let paragraph = geometry([DirtyRect(x: 700, y: 600, width: 1500, height: 300)])
        XCTAssertTrue(paragraph.partial)
        XCTAssertEqual(paragraph.rect, CGRect(x: 0, y: 0, width: 1, height: 1), "still the whole window's place")
        // The lower half, and a column down the middle: each leaves out more
        // than a quarter of the window's height or width.
        XCTAssertTrue(geometry([DirtyRect(x: 0, y: 900, width: 2880, height: 900)]).partial)
        XCTAssertTrue(geometry([DirtyRect(x: 720, y: 0, width: 1440, height: 1800)]).partial)
        // Three quarters of each side is enough.
        XCTAssertFalse(geometry([DirtyRect(x: 360, y: 225, width: 2160, height: 1350)]).partial)
    }

    func testAWholeScreenWindowReadInPartIsPartial() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func window(_ id: CGWindowID, _ bundle: String, _ rect: CGRect) -> VisibleWindow {
            VisibleWindow(windowId: id, bundleId: bundle, title: "Window \(id)", bounds: rect, layer: 0)
        }
        let front = window(1, "com.example.notes", CGRect(x: 0, y: 0, width: 800, height: 600))
        let behind = window(2, "com.example.mail", CGRect(x: 400, y: 300, width: 800, height: 500))
        let clear = window(3, "com.example.chat", CGRect(x: 1000, y: 0, width: 400, height: 280))
        let offDisplay = window(4, "com.example.files", CGRect(x: 1200, y: 400, width: 600, height: 400))
        // Under the corner of `behind` (50 of 280 points wide) and the edge of
        // `offDisplay` (20 of 120 points tall).
        let corner = window(5, "com.example.music", CGRect(x: 1150, y: 780, width: 280, height: 120))
        let windows = [front, behind, clear, offDisplay, corner]
        func placed(_ window: VisibleWindow) -> (geometry: OCRWindowGeometry?, ownsSeparators: Bool) {
            BackgroundCapturePolicy.geometry(of: window, displayBounds: display, pixelsPerPoint: 2,
                                             windows: windows, excludedBundleIds: [])
        }
        let first = placed(front)
        XCTAssertEqual(first.geometry?.partial, false)
        XCTAssertTrue(first.ownsSeparators)
        XCTAssertEqual(first.geometry?.rect, OCRWindowGeometry.normalizedRect(of: front.bounds, in: display))
        XCTAssertEqual(first.geometry?.title, "Window 1")
        // Half of it under the front window.
        let second = placed(behind)
        XCTAssertEqual(second.geometry?.partial, true)
        XCTAssertFalse(second.ownsSeparators)
        XCTAssertEqual(placed(clear).geometry?.partial, false)
        // 240 of its 600 points off the display.
        let off = placed(offDisplay)
        XCTAssertEqual(off.geometry?.partial, true)
        XCTAssertTrue(off.ownsSeparators, "nothing in front of it")
        // A window in front over one small corner: covered, so no separators,
        // but read nearly whole.
        let small = placed(corner)
        XCTAssertFalse(small.ownsSeparators)
        XCTAssertEqual(small.geometry?.partial, false)
        // Not listed: when unsure, partial and without separators.
        let unknown = BackgroundCapturePolicy.geometry(of: clear, displayBounds: display, pixelsPerPoint: 2,
                                                       windows: [front], excludedBundleIds: [])
        XCTAssertEqual(unknown.geometry?.partial, true)
        XCTAssertFalse(unknown.ownsSeparators)
    }

    // MARK: - What a partial read moves

    /// Parts of a window, normalized with a bottom-left origin.
    static let areas: [CGRect] = {
        var out: [CGRect] = []
        for x in [0.0, 0.25, 0.5] {
            for y in [0.0, 0.3, 0.6] {
                for (w, h) in [(0.5, 0.4), (0.75, 0.7)] {
                    out.append(CGRect(x: x, y: y, width: min(w, 1 - x), height: min(h, 1 - y)))
                }
            }
        }
        return out
    }()

    /// What a read of only `area` sees: the lines inside it, and the pane
    /// separators clipped to it.
    static func changedArea(_ fixture: OCRReadingOrderTests.Fixture, _ area: CGRect) -> ([OCRLine], [CGRect]) {
        let lines = fixture.ocrLines.filter { area.contains($0.boundingBox) }
        let separators = fixture.separatorRects.compactMap { separator -> CGRect? in
            if separator.width == 0 {
                guard area.minX < separator.minX, separator.minX < area.maxX else { return nil }
                let y0 = max(separator.minY, area.minY), y1 = min(separator.maxY, area.maxY)
                return y1 > y0 ? CGRect(x: separator.minX, y: y0, width: 0, height: y1 - y0) : nil
            }
            guard area.minY < separator.minY, separator.minY < area.maxY else { return nil }
            let x0 = max(separator.minX, area.minX), x1 = min(separator.maxX, area.maxX)
            return x1 > x0 ? CGRect(x: x0, y: separator.minY, width: x1 - x0, height: 0) : nil
        }
        return (lines, separators)
    }

    /// What a window with another window over `area` shows: the lines whose
    /// centre is not under it, and no separators.
    static func covered(_ fixture: OCRReadingOrderTests.Fixture, _ area: CGRect) -> ([OCRLine], [CGRect]) {
        (fixture.ocrLines.filter { !area.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }, [])
    }

    static func key(_ box: OCRReadingOrder.Box) -> String {
        "\(box.text)@\(Int(box.x0.rounded())),\(Int(box.y0.rounded()))"
    }

    static func partial(_ geometry: OCRWindowGeometry?) -> OCRWindowGeometry? {
        geometry.map {
            OCRWindowGeometry(rect: $0.rect, pixelsPerPoint: $0.pixelsPerPoint, title: $0.title,
                              bundleId: $0.bundleId, partial: true)
        }
    }

    func testAPartialReadNeverMovesContentToChrome() throws {
        let edgeRules: Set<String> = ["bar", "status", "placeholder", "date"]
        var reads = 0
        for name in try OCRReadingOrderTests.names(".reading.json") where name.hasPrefix("window_") {
            let fixture = try OCRReadingOrderTests.fixture(name)
            let whole = OCRReadingOrder.read(fixture.ocrLines, pixelSize: fixture.pixelSize,
                                             separators: fixture.separatorRects, window: fixture.geometry)
            let content = Set(whole.blocks.filter { $0.role == .content }.flatMap(\.boxes).map(Self.key))
            for area in Self.areas {
                for (lines, separators) in [Self.changedArea(fixture, area), Self.covered(fixture, area)]
                where !lines.isEmpty {
                    reads += 1
                    let reading = OCRReadingOrder.read(lines, pixelSize: fixture.pixelSize, separators: separators,
                                                       window: Self.partial(fixture.geometry))
                    for block in reading.blocks where block.role == .chrome {
                        XCTAssertTrue(edgeRules.contains(block.rule), "\(name) \(area): \(block.rule)")
                        for box in block.boxes {
                            XCTAssertFalse(content.contains(Self.key(box)),
                                           "\(name) \(area): content moved to chrome by \(block.rule)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(reads, 400)
    }

    func testTheRulesThatNeedNeighboursWouldMisreadThesePartialReads() throws {
        // The order form beside its summary, with a window over its middle: the
        // form's widest line is hidden, so it looks like a sidebar.
        let order = try OCRReadingOrderTests.fixture("window_order_summary")
        let (formLines, formSeparators) = Self.covered(order, CGRect(x: 0.11, y: 0.14, width: 0.66, height: 0.6))
        let asWhole = OCRReadingOrder.read(formLines, pixelSize: order.pixelSize, separators: formSeparators,
                                           window: order.geometry)
        XCTAssertTrue(asWhole.blocks.contains { $0.rule == "navigation" && $0.text.contains("Shipping address") })
        let asPartial = OCRReadingOrder.read(formLines, pixelSize: order.pixelSize, separators: formSeparators,
                                             window: Self.partial(order.geometry))
        XCTAssertTrue(asPartial.classified)
        XCTAssertTrue(asPartial.blocks.contains { $0.role == .content && $0.text.contains("Shipping address") })
        XCTAssertTrue(asPartial.blocks.contains { $0.role == .content && $0.text.contains("41 Harbor Street") })
        // A table's first column read without the columns beside it: its week
        // numbers look like an editor's line numbers.
        let report = try OCRReadingOrderTests.fixture("window_fullscreen_doc")
        let (tableLines, tableSeparators) = Self.changedArea(report, CGRect(x: 0.2, y: 0.39, width: 0.14, height: 0.37))
        let tableAsWhole = OCRReadingOrder.read(tableLines, pixelSize: report.pixelSize, separators: tableSeparators,
                                                window: report.geometry)
        XCTAssertTrue(tableAsWhole.blocks.contains { $0.rule == "gutter" })
        let tableAsPartial = OCRReadingOrder.read(tableLines, pixelSize: report.pixelSize,
                                                  separators: tableSeparators, window: Self.partial(report.geometry))
        XCTAssertTrue(tableAsPartial.classified)
        XCTAssertFalse(tableAsPartial.blocks.contains { $0.role == .chrome })
        XCTAssertTrue(tableAsPartial.stored.hasSuffix(OCRReadingOrder.chromeSeparator))
    }

    func testAPartialReadStillMovesTheBarsAtTheWindowsTop() throws {
        // The mail window's top half: its toolbar rows are judged by
        // themselves, so they still move (with the icons beside them, which a
        // partial read leaves in place).
        let mail = try OCRReadingOrderTests.fixture("window_mail")
        let whole = OCRReadingOrder.read(mail.ocrLines, pixelSize: mail.pixelSize, separators: mail.separatorRects,
                                         window: mail.geometry)
        XCTAssertTrue(whole.blocks.contains { $0.rule == "bar" && $0.text.contains("Search mail") })
        let (lines, separators) = Self.changedArea(mail, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let top = OCRReadingOrder.read(lines, pixelSize: mail.pixelSize, separators: separators,
                                       window: Self.partial(mail.geometry))
        XCTAssertTrue(top.classified)
        XCTAssertTrue(top.blocks.contains { $0.rule == "bar" && $0.text.contains("Search mail") })
        XCTAssertFalse(top.blocks.contains { $0.role == .content && $0.text.contains("Search mail") })
    }
}
