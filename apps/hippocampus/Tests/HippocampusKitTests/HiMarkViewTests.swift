// SPDX-License-Identifier: TBD-private
//
// HiMarkView draws the four pictures off screen: blue only in the brand
// mark's solid dot, a hole in the hollow dot, dim letters when off, and
// h! when something needs the person. Ask's search row uses the brand mark.

import SwiftUI
import XCTest
@testable import HippocampusKit

final class HiMarkViewTests: XCTestCase {

    private struct Pixel {
        let red, green, blue, alpha: UInt8
        var isBlue: Bool { alpha > 200 && blue > 200 && red < 100 }
        var isBlack: Bool { alpha > 200 && red < 40 && green < 40 && blue < 40 }
        var isClear: Bool { alpha < 30 }
    }

    /// Renders at one pixel per mark unit: (x, y) in the mark's own units,
    /// shifted down by the 2.12 the dot rises above the ascender.
    @MainActor
    private func render(_ style: HiMarkView.Style, _ state: HiMark.State) throws -> (CGFloat, CGFloat) -> Pixel {
        let box = HiMark.inkBounds
        let renderer = ImageRenderer(content: HiMarkView(style: style, state: state)
            .frame(width: box.width, height: box.height)
            .foregroundStyle(Color.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(context.data)
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return { x, y in
            let column = Int(x - box.minX), row = Int(y - box.minY)
            let i = (row * width + column) * 4
            return Pixel(red: bytes[i], green: bytes[i + 1], blue: bytes[i + 2], alpha: bytes[i + 3])
        }
    }

    @MainActor
    private func blueCount(_ style: HiMarkView.Style, _ state: HiMark.State) throws -> Int {
        let pixel = try render(style, state)
        var count = 0
        for y in stride(from: HiMark.inkBounds.minY + 0.5, to: HiMark.inkBounds.maxY, by: 1) {
            for x in stride(from: HiMark.inkBounds.minX + 0.5, to: HiMark.inkBounds.maxX, by: 1) where pixel(x, y).isBlue {
                count += 1
            }
        }
        return count
    }

    @MainActor
    func testTheBrandMarkIsBlueOnlyInItsSolidDot() throws {
        let brand = try render(.brand, .remembering)
        XCTAssertTrue(brand(HiMark.dotCenter.x, HiMark.dotCenter.y).isBlue)
        XCTAssertTrue(brand(7, 60).isBlack, "letters take the foreground style")
        XCTAssertGreaterThan(try blueCount(.brand, .remembering), 200)
        for state in [HiMark.State.skipping, .off, .needsYou] {
            XCTAssertEqual(try blueCount(.brand, state), 0, "\(state)")
        }
    }

    @MainActor
    func testTheMonoMarkIsOneColor() throws {
        let mono = try render(.mono, .remembering)
        XCTAssertTrue(mono(HiMark.dotCenter.x, HiMark.dotCenter.y).isBlack)
        for state in HiMark.State.allCases {
            XCTAssertEqual(try blueCount(.mono, state), 0, "\(state)")
        }
    }

    @MainActor
    func testTheHollowDotHasAHole() throws {
        let hollow = try render(.brand, .skipping)
        XCTAssertTrue(hollow(HiMark.ringCenter.x, HiMark.ringCenter.y).isClear)
        let band = (HiMark.ringOuterRadius + HiMark.ringInnerRadius) / 2
        XCTAssertTrue(hollow(HiMark.ringCenter.x + band, HiMark.ringCenter.y).isBlack)
    }

    @MainActor
    func testTheOffMarkDimsItsLettersAndDropsTheDot() throws {
        let off = try render(.brand, .off)
        XCTAssertTrue(off(HiMark.dotCenter.x, HiMark.dotCenter.y).isClear)
        XCTAssertEqual(Double(off(7, 60).alpha), 0.55 * 255, accuracy: 6)
    }

    @MainActor
    func testHBangDrawsAStemThroughTheDotAndADotOnTheBaseline() throws {
        let bang = try render(.brand, .needsYou)
        XCTAssertTrue(bang(HiMark.dotCenter.x, HiMark.dotCenter.y).isBlack)
        XCTAssertTrue(bang(HiMark.bangDotCenter.x, HiMark.bangDotCenter.y).isBlack)
        XCTAssertTrue(bang(HiMark.bangDotCenter.x, 76).isClear, "a gap between the stem and its dot")
    }

    func testAskShowsTheBrandMarkInItsSearchRowAndNoCurl() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/Hippocampus/CommandBar.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("HiMarkView(style: .brand"))
        for retired in ["CurlGlyph", "CurlShape", "CurlDot"] {
            XCTAssertFalse(source.contains(retired), retired)
        }
    }
}
