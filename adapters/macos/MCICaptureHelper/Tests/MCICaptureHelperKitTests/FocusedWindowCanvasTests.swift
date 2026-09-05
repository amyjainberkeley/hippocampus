import CoreGraphics
import ScreenCaptureKit
import XCTest

@testable import MCICaptureHelperKit

/// Configuration values only: no shareable-content enumeration or live stream.
final class FocusedWindowCanvasTests: XCTestCase {
    private func configuration(
        width: CGFloat,
        height: CGFloat,
        scale: Float = 1
    ) throws -> SCStreamConfiguration {
        try SCStreamConfigFactory.makeFocusedWindowConfiguration(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            pointPixelScale: scale
        )
    }

    private func assertCanvas(
        _ configuration: SCStreamConfiguration,
        width: Int,
        height: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(configuration.width, width, file: file, line: line)
        XCTAssertEqual(configuration.height, height, file: file, line: line)
        XCTAssertTrue(configuration.scalesToFit, file: file, line: line)
        XCTAssertTrue(configuration.preservesAspectRatio, file: file, line: line)
        XCTAssertGreaterThan(configuration.width, 0, file: file, line: line)
        XCTAssertGreaterThan(configuration.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(max(configuration.width, configuration.height), 1920,
                                 file: file, line: line)
    }

    func testOrdinaryWindowMatchesItsPixelExtentInsteadOfDefaultCanvas() throws {
        assertCanvas(try configuration(width: 960, height: 640), width: 960, height: 640)
    }

    func testRetinaWindowUsesPointPixelScale() throws {
        assertCanvas(try configuration(width: 800, height: 600, scale: 2), width: 1600, height: 1200)
    }

    func testOversizedRetinaWindowIsCappedWithItsAspectRatio() throws {
        assertCanvas(try configuration(width: 1280, height: 800, scale: 2), width: 1920, height: 1200)
    }

    func testWideWindowIsNotForcedIntoSixteenByNine() throws {
        assertCanvas(try configuration(width: 3840, height: 960, scale: 2), width: 1920, height: 480)
    }

    func testTallWindowUsesHeightAsTheLongEdge() throws {
        assertCanvas(try configuration(width: 720, height: 2880, scale: 2), width: 480, height: 1920)
    }

    func testSquareWindowBoundsBothAllocationDimensions() throws {
        assertCanvas(try configuration(width: 5000, height: 5000, scale: 2), width: 1920, height: 1920)
    }

    func testSmallWindowIsNotUpscaledAtBindTime() throws {
        assertCanvas(try configuration(width: 320, height: 200), width: 320, height: 200)
    }

    func testFractionalPointGeometryRoundsOnlyAtThePixelBoundary() throws {
        assertCanvas(try configuration(width: 801.25, height: 600.75, scale: 1.25),
                     width: 1002, height: 751)
    }

    func testExtremeFiniteGeometryDoesNotOverflowBeforeBounding() throws {
        let largest = CGFloat.greatestFiniteMagnitude
        assertCanvas(try configuration(width: largest, height: largest / 2,
                                       scale: Float.greatestFiniteMagnitude),
                     width: 1920, height: 960)
    }

    func testInvalidDimensionsAreRejectedInsteadOfProducingAFallbackCanvas() {
        let invalid: [CGFloat] = [0, -1, .nan, .infinity, -.infinity, .leastNonzeroMagnitude]
        for value in invalid {
            XCTAssertThrowsError(try configuration(width: value, height: 600), "width=\(value)")
            XCTAssertThrowsError(try configuration(width: 800, height: value), "height=\(value)")
        }
    }

    func testInvalidScaleIsRejected() {
        let invalid: [Float] = [0, -1, .nan, .infinity, -.infinity, .leastNonzeroMagnitude]
        for scale in invalid {
            XCTAssertThrowsError(try configuration(width: 800, height: 600, scale: scale),
                                 "scale=\(scale)")
        }
    }

    func testUnrepresentableAspectRatioIsRejectedInsteadOfStretchedOrCropped() {
        XCTAssertThrowsError(try configuration(width: 1_000_000, height: 1))
        XCTAssertThrowsError(try configuration(width: 1, height: 1_000_000))
        XCTAssertThrowsError(try configuration(width: .greatestFiniteMagnitude, height: 1))
    }

    func testInvalidContentOriginIsRejected() {
        for origin in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
            XCTAssertThrowsError(try SCStreamConfigFactory.makeFocusedWindowConfiguration(
                contentRect: CGRect(origin: origin, size: CGSize(width: 800, height: 600)),
                pointPixelScale: 1
            ))
        }
        XCTAssertThrowsError(try SCStreamConfigFactory.makeFocusedWindowConfiguration(
            contentRect: .null, pointPixelScale: 1
        ))
        XCTAssertThrowsError(try SCStreamConfigFactory.makeFocusedWindowConfiguration(
            contentRect: .infinite, pointPixelScale: 1
        ))
    }

    func testNegativeDisplayOriginDoesNotCropOrTranslateTheWindow() throws {
        let config = try SCStreamConfigFactory.makeFocusedWindowConfiguration(
            contentRect: CGRect(x: -2400, y: -600, width: 800, height: 600),
            pointPixelScale: 2
        )
        assertCanvas(config, width: 1600, height: 1200)
        XCTAssertEqual(config.sourceRect, .zero)
        XCTAssertEqual(config.destinationRect, .zero)
    }

    func testWindowSizingPreservesCapturePolicyAndWholeWindowSampling() throws {
        let policy = StreamPolicy(showsCursor: false, queueDepth: 2, minimumFrameIntervalMs: 750)
        let base = SCStreamConfigFactory.makeConfiguration(policy: policy)
        let config = try SCStreamConfigFactory.makeFocusedWindowConfiguration(
            policy: policy,
            contentRect: CGRect(x: 50, y: 30, width: 800, height: 600),
            pointPixelScale: 2
        )
        assertCanvas(config, width: 1600, height: 1200)
        XCTAssertEqual(config.showsCursor, base.showsCursor)
        XCTAssertEqual(config.queueDepth, base.queueDepth)
        XCTAssertEqual(config.minimumFrameInterval, base.minimumFrameInterval)
        XCTAssertEqual(config.sourceRect, base.sourceRect)
        XCTAssertEqual(config.destinationRect, base.destinationRect)
        XCTAssertEqual(config.capturesAudio, base.capturesAudio)
        XCTAssertEqual(config.pixelFormat, base.pixelFormat)
    }

    func testLegacyConfigurationKeepsItsExistingDefaults() {
        let config = SCStreamConfigFactory.makeConfiguration()
        XCTAssertEqual(config.width, 1920)
        XCTAssertEqual(config.height, 1080)
        XCTAssertFalse(config.scalesToFit)
        XCTAssertFalse(config.showsCursor)
    }
}
