import Foundation
import XCTest
@testable import RecallUIKit

/// The window's sidebar: the hi mark drawn from the app's own geometry, and the
/// footer that says whether Hippocampus is remembering (RULINGS W10, B3).
final class WindowShellTests: XCTestCase {
    private func appGeometrySource() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repo.appendingPathComponent("apps/hippocampus/Sources/HippocampusKit/Brand/HiMarkGeometry.swift"),
            encoding: .utf8
        )
    }

    func testTheMarkIsACopyOfTheAppsGeometry() throws {
        let app = try appGeometrySource()
        XCTAssertTrue(app.contains("public static let hSVGPath = \"\(WindowHiMark.hSVGPath)\""))
        XCTAssertTrue(app.contains("public static let iStemSVGPath = \"\(WindowHiMark.iStemSVGPath)\""))
        XCTAssertTrue(app.contains("dotCenter = CGPoint(x: \(WindowHiMark.dotCenter.x), y: \(WindowHiMark.dotCenter.y))"))
        XCTAssertTrue(app.contains("dotRadius: CGFloat = \(WindowHiMark.dotRadius)"))
        let box = WindowHiMark.inkBounds
        XCTAssertTrue(app.contains("inkBounds = CGRect(x: 0, y: \(box.minY), width: \(box.width), height: \(box.height))"))
        XCTAssertTrue(app.contains(String(format: "lettersRGB: UInt32 = 0x%06X", WindowHiMark.lettersRGB)))
        XCTAssertTrue(app.contains(String(format: "dotRGB: UInt32 = 0x%06X", WindowHiMark.dotRGB)))
    }

    func testTheMarksPathsParse() {
        XCTAssertNotNil(WindowHiMark.path(svg: WindowHiMark.hSVGPath))
        XCTAssertNotNil(WindowHiMark.path(svg: WindowHiMark.iStemSVGPath))
        XCTAssertNil(WindowHiMark.path(svg: "M0 0 A1 1 0 0 1 2 2"), "arcs are not part of the mark")
    }

    private func receipt(updated: Date, blocked: String? = nil, skipped: String? = nil) -> CaptureHealthReceipt {
        CaptureHealthReceipt(schemaVersion: 1, updatedAt: updated, lastStoredFrameAt: updated,
                             storedFrameCount: 10, storedScreenshotCount: 2,
                             suppressionReason: skipped, blockedReason: blocked)
    }

    func testTheFooterSaysWhetherHippocampusIsRemembering() {
        let now = Date(timeIntervalSince1970: 1_791_841_025)
        XCTAssertEqual(SidebarStatus(receipt: nil, now: now).text, "Not remembering right now.")
        XCTAssertFalse(SidebarStatus(receipt: nil, now: now).remembering)

        let fresh = SidebarStatus(receipt: receipt(updated: now.addingTimeInterval(-20)), now: now)
        XCTAssertEqual(fresh.text, "Remembering")
        XCTAssertTrue(fresh.remembering)

        let skipping = SidebarStatus(receipt: receipt(updated: now, skipped: "secure_input"), now: now)
        XCTAssertEqual(skipping.text, "Remembering", "a skipped window leaves the rest of the screen read")

        for status in [SidebarStatus(receipt: receipt(updated: now.addingTimeInterval(-600)), now: now),
                       SidebarStatus(receipt: receipt(updated: now, blocked: "screen_recording_denied"), now: now)] {
            XCTAssertEqual(status.text, "Not remembering")
            XCTAssertFalse(status.remembering)
        }
    }
}
