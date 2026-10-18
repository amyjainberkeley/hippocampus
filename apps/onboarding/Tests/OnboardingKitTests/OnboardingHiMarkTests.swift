import XCTest
@testable import OnboardingKit

/// The mark setup draws is the app's: its geometry and its Lab colours are a
/// copy of HiMarkGeometry.swift, held here to that file.
final class OnboardingHiMarkTests: XCTestCase {
    private func appGeometrySource() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("apps/hippocampus/Sources/HippocampusKit/Brand/HiMarkGeometry.swift"),
            encoding: .utf8
        )
    }

    func testTheMarkIsACopyOfTheAppsGeometry() throws {
        let app = try appGeometrySource()
        XCTAssertTrue(app.contains("public static let hSVGPath = \"\(OnboardingHiMark.hSVGPath)\""))
        XCTAssertTrue(app.contains("public static let iStemSVGPath = \"\(OnboardingHiMark.iStemSVGPath)\""))
        let dot = OnboardingHiMark.dotCenter
        XCTAssertTrue(app.contains("dotCenter = CGPoint(x: \(dot.x), y: \(dot.y))"))
        XCTAssertTrue(app.contains("dotRadius: CGFloat = \(OnboardingHiMark.dotRadius)"))
        let box = OnboardingHiMark.inkBounds
        XCTAssertTrue(app.contains("inkBounds = CGRect(x: 0, y: \(box.minY), width: \(box.width), height: \(box.height))"))
    }

    func testTheTileAndItsLabColoursAreTheAppIcons() throws {
        let app = try appGeometrySource()
        XCTAssertTrue(app.contains("public static let tileSVGPath = \"\(OnboardingHiMark.tileSVGPath)\""))
        let tile = OnboardingHiMark.iconTileRect
        XCTAssertTrue(app.contains("iconTileRect = CGRect(x: \(Int(tile.minX)), y: \(Int(tile.minY)), width: \(Int(tile.width)), height: \(Int(tile.height)))"))
        let origin = OnboardingHiMark.iconMarkOrigin
        XCTAssertTrue(app.contains("iconMarkOrigin = CGPoint(x: \(origin.x), y: \(origin.y))"))
        XCTAssertTrue(app.contains("iconMarkScale: CGFloat = \(OnboardingHiMark.iconMarkScale)"))
        for (name, value) in [("tileTopRGB", OnboardingHiMark.tileTopRGB), ("tileBottomRGB", OnboardingHiMark.tileBottomRGB),
                              ("lettersRGB", OnboardingHiMark.lettersRGB), ("dotRGB", OnboardingHiMark.dotRGB)] {
            XCTAssertTrue(app.contains(String(format: "\(name): UInt32 = 0x%06X", value)), name)
        }
        // The colours Amy chose for the Lab mark.
        XCTAssertEqual(OnboardingHiMark.tileTopRGB, 0xFFFFFF)
        XCTAssertEqual(OnboardingHiMark.tileBottomRGB, 0xE9EEF6)
        XCTAssertEqual(OnboardingHiMark.lettersRGB, 0x0F1B3D)
        XCTAssertEqual(OnboardingHiMark.dotRGB, 0x2F6BFF)
        // Setup's palette names the same navy and blue.
        XCTAssertEqual(OnboardingPalette.ink, OnboardingHiMark.lettersRGB)
        XCTAssertEqual(OnboardingPalette.accent, OnboardingHiMark.dotRGB)
    }

    func testThePathsParseAndTheMarkSitsInsideTheTile() {
        XCTAssertNotNil(OnboardingHiMark.path(svg: OnboardingHiMark.hSVGPath))
        XCTAssertNotNil(OnboardingHiMark.path(svg: OnboardingHiMark.iStemSVGPath))
        XCTAssertNotNil(OnboardingHiMark.path(svg: OnboardingHiMark.tileSVGPath))
        XCTAssertNil(OnboardingHiMark.path(svg: "M0 0 A1 1 0 0 1 2 2"), "arcs are not part of the mark")
        let place = OnboardingHiMark.markInTile
        let letters = OnboardingHiMark.letters().boundingBoxOfPath
        let minX = place.origin.x + letters.minX * place.scale
        let maxX = place.origin.x + letters.maxX * place.scale
        let maxY = place.origin.y + letters.maxY * place.scale
        XCTAssertGreaterThan(minX, 0)
        XCTAssertLessThan(maxX, 1)
        XCTAssertLessThan(maxY, 1)
        // About 56% of the tile wide, as the icon is.
        XCTAssertEqual(maxX - minX, 0.56, accuracy: 0.02)
    }
}
