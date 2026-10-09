import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import MCICaptureHelperKit

/// Runs only with MCI_LIVE_OCR_WORKER and MCI_LIVE_OCR_IMAGE set: the real
/// bundled worker, through the production persistent runner, on a real image.
final class PaddleOCRLiveWorkerProbe: XCTestCase {
    func testRealWorkerThroughPersistentRunner() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let worker = env["MCI_LIVE_OCR_WORKER"], let imagePath = env["MCI_LIVE_OCR_IMAGE"] else {
            throw XCTSkip("set MCI_LIVE_OCR_WORKER and MCI_LIVE_OCR_IMAGE")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var created: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let runner = PaddleOCRRunner(executableURL: URL(fileURLWithPath: worker), persistent: true)
        runner.prewarm()
        for attempt in 1...3 {
            let start = ContinuousClock.now
            let result = await runner.recognize(
                input: OCREngineInput(pixelBuffer: buffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1)),
                timeoutMs: 30_000)
            print("PROBE attempt \(attempt) timedOut=\(result.timedOut) lines=\(result.recognizedLines.count) elapsed=\(start.duration(to: .now))")
            print("PROBE text:", result.recognizedLines.map(\.text).joined(separator: " | "))
        }
        runner.stop()
    }
}
