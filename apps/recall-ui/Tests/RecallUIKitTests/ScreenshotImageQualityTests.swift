import AppKit
import ImageIO
import MCIKeyframeCodec
import XCTest
@testable import RecallUIKit

final class ScreenshotImageQualityTests: XCTestCase {
    func testDetailedReadPreservesSavedPixelsWhileThumbnailsStaySmall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 7, count: 32)
        let original = try Self.image(width: 2560, height: 1600)
        let sealed = try KeyframeBlobCodec.seal(plaintext: original, keyMaterial: key)
        let url = root.appendingPathComponent(sealed.lowercaseHexDigest + ".bin")
        try sealed.bytes.write(to: url)
        let provider = ThumbnailDataProvider(blobRoot: root) { key }
        let detail = await provider.screenshotData(for: url)
        XCTAssertEqual(detail, original, "Opening a saved screenshot must not recompress or shrink its text")
        let thumbnail = await provider.thumbnailData(for: url, maxPixelSize: 128)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(thumbnail) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 128)

        var tampered = sealed.bytes
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: url)
        let invalid = await provider.screenshotData(for: url)
        XCTAssertNil(invalid)
    }

    func testDetailedReadRejectsOversizedDecodedImageAndOutsidePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 8, count: 32)
        let sealed = try KeyframeBlobCodec.seal(plaintext: Self.image(width: 4096, height: 4), keyMaterial: key)
        let url = root.appendingPathComponent(sealed.lowercaseHexDigest + ".bin")
        try sealed.bytes.write(to: url)
        let provider = ThumbnailDataProvider(blobRoot: root) { key }
        let oversized = await provider.screenshotData(for: url)
        XCTAssertNil(oversized)
        let outside = root.deletingLastPathComponent().appendingPathComponent(sealed.lowercaseHexDigest + ".bin")
        let rejected = await provider.screenshotData(for: outside)
        XCTAssertNil(rejected)
    }

    private static func image(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
