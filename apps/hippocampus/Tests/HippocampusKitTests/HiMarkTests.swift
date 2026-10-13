// SPDX-License-Identifier: TBD-private
//
// The hi mark's geometry: what the parsed paths cover, where the parts sit,
// and which parts each picture draws.

import CoreGraphics
import XCTest
@testable import HippocampusKit

final class HiMarkTests: XCTestCase {

    private func assertRect(_ rect: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(rect.maxX, expected.maxX, accuracy: accuracy, "maxX", file: file, line: line)
        XCTAssertEqual(rect.maxY, expected.maxY, accuracy: accuracy, "maxY", file: file, line: line)
    }

    func testEveryPathStringParses() {
        for data in [HiMark.hSVGPath, HiMark.iStemSVGPath, HiMark.bangStemSVGPath, HiMark.lettersSVGPath, HiMark.tileSVGPath] {
            XCTAssertNotNil(HiMark.path(svg: data), data)
        }
    }

    func testTheLettersRunFromTheStemToTheIAndFromTheAscenderToTheBaseline() {
        assertRect(HiMark.letters().boundingBoxOfPath, CGRect(x: 0, y: 0, width: 91, height: 100))
        assertRect(HiMark.hOnly().boundingBoxOfPath, CGRect(x: 0, y: 0, width: 62, height: 100))
        assertRect(HiMark.iStem().boundingBoxOfPath, CGRect(x: 75.5, y: 29.2, width: 15.5, height: 70.8))
    }

    func testTheLettersCoverTheStemsAndLeaveTheCounterEmpty() {
        let letters = HiMark.letters()
        // The arch overlaps the stem here; the non-zero rule keeps it filled.
        XCTAssertTrue(letters.contains(CGPoint(x: 14, y: 45), using: .winding))
        XCTAssertFalse(letters.contains(CGPoint(x: 14, y: 45), using: .evenOdd))
        // Inside the h's counter, and inside the i.
        XCTAssertFalse(letters.contains(CGPoint(x: 30, y: 60), using: .winding))
        XCTAssertTrue(letters.contains(CGPoint(x: 83, y: 60), using: .winding))
        // Between the h and the i.
        XCTAssertFalse(letters.contains(CGPoint(x: 68, y: 80), using: .winding))
    }

    func testTheParserTakesOnlyAbsoluteMoveLineCurveAndClose() {
        XCTAssertNotNil(HiMark.path(svg: "M0 0L10 0V10H0Q-2 5 0 0C1 1 2 2 3 3Z"))
        for rejected in [
            "m0 0l1 1z",            // relative commands
            "M0 0A5 5 0 0 1 10 10", // arcs
            "L1 1",                 // no move first
            "M0 0L1",               // too few numbers
            "M0 0L1 1 2 2",         // implicit repeats
            "M0 0L1e2 1",           // exponents
        ] {
            XCTAssertNil(HiMark.path(svg: rejected), rejected)
        }
    }

    func testTheDotIsCenteredOnTheIAndClearOfIt() {
        let stem = HiMark.iStem().boundingBoxOfPath
        XCTAssertEqual(HiMark.dotCenter.x, stem.midX, accuracy: 0.001)
        XCTAssertEqual(2 * HiMark.dotRadius / HiMark.stemWidth, 1.3, accuracy: 0.001)
        let dot = HiMark.dot().boundingBoxOfPath
        XCTAssertLessThan(dot.maxY, stem.minY)
        XCTAssertTrue(HiMark.dot().contains(HiMark.dotCenter))
    }

    func testTheHollowDotHasAHoleAndRestsWhereTheSolidDotDoes() {
        let ring = HiMark.ring()
        XCTAssertFalse(ring.contains(HiMark.ringCenter, using: .winding))
        let band = (HiMark.ringOuterRadius + HiMark.ringInnerRadius) / 2
        XCTAssertTrue(ring.contains(CGPoint(x: HiMark.ringCenter.x + band, y: HiMark.ringCenter.y), using: .winding))
        XCTAssertEqual(ring.boundingBoxOfPath.maxY, HiMark.dot().boundingBoxOfPath.maxY, accuracy: 0.01)
        XCTAssertEqual(ring.boundingBoxOfPath.midX, HiMark.dotCenter.x, accuracy: 0.01)
    }

    func testTheBangIsTheIMirroredAboutTheMiddle() {
        let stem = HiMark.iStem().boundingBoxOfPath
        let bang = HiMark.bangStem().boundingBoxOfPath
        XCTAssertEqual(bang.minX, stem.minX, accuracy: 0.001)
        XCTAssertEqual(bang.maxX, stem.maxX, accuracy: 0.001)
        XCTAssertEqual(bang.minY, 100 - stem.maxY, accuracy: 0.001)
        XCTAssertEqual(bang.maxY, 100 - stem.minY, accuracy: 0.001)
        XCTAssertEqual(HiMark.bangDotCenter.y, 100 - HiMark.dotCenter.y, accuracy: 0.001)
        XCTAssertEqual(HiMark.bangDotCenter.x, HiMark.dotCenter.x, accuracy: 0.001)
    }

    func testEachPictureDrawsItsOwnParts() {
        XCTAssertEqual(HiMark.parts(for: .remembering), [.h, .iStem, .dot])
        XCTAssertEqual(HiMark.parts(for: .skipping), [.h, .iStem, .ring])
        XCTAssertEqual(HiMark.parts(for: .off), [.h, .iStem])
        XCTAssertEqual(HiMark.parts(for: .needsYou), [.h, .bangStem, .bangDot])
        XCTAssertEqual(HiMark.letterStrength(for: .off), 0.55, accuracy: 0.001)
        for state in [HiMark.State.remembering, .skipping, .needsYou] {
            XCTAssertEqual(HiMark.letterStrength(for: state), 1)
        }
    }

    func testTheInkBoundsHoldTheLettersAndTheDot() {
        let ink = HiMark.letters().boundingBoxOfPath.union(HiMark.dot().boundingBoxOfPath)
        assertRect(ink, HiMark.inkBounds)
    }

    func testTheTileIsTheSquircleScaledToItsSide() {
        assertRect(HiMark.tile(side: 824).boundingBoxOfPath, CGRect(x: 0, y: 0, width: 824, height: 824), accuracy: 0.1)
        let small = HiMark.tile(side: 100)
        XCTAssertTrue(small.contains(CGPoint(x: 50, y: 50)))
        XCTAssertTrue(small.contains(CGPoint(x: 50, y: 0.5)))
        XCTAssertFalse(small.contains(CGPoint(x: 1, y: 1)), "the corners are rounded")
    }

    func testTheColorsAreTheLabColors() {
        XCTAssertEqual(HiMark.tileTopRGB, 0xFFFFFF)
        XCTAssertEqual(HiMark.tileBottomRGB, 0xE9EEF6)
        XCTAssertEqual(HiMark.lettersRGB, 0x0F1B3D)
        XCTAssertEqual(HiMark.dotRGB, 0x2F6BFF)
        let navy = HiMark.components(HiMark.lettersRGB)
        XCTAssertEqual(navy.red, 15 / 255, accuracy: 0.0001)
        XCTAssertEqual(navy.green, 27 / 255, accuracy: 0.0001)
        XCTAssertEqual(navy.blue, 61 / 255, accuracy: 0.0001)
    }
}
