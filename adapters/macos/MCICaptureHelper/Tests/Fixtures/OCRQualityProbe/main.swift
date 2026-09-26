import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import MCICaptureHelperKit

@main struct OCRQualityProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || arguments.count == 3 else { throw ProbeError.arguments }
        let url = URL(fileURLWithPath: arguments[1])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width <= 3840, image.height <= 3840 else { throw ProbeError.image }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferCGImageCompatibilityKey: true,
                                   kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                  &pixels) == kCVReturnSuccess, let buffer = pixels else { throw ProbeError.image }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),width: image.width,height: image.height,
                                      bitsPerComponent: 8,bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { CVPixelBufferUnlockBaseAddress(buffer, []); throw ProbeError.image }
        context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let engine: any OCREngine
        let budget: Int
        if arguments.count == 3 {
            engine = PaddleOCRRunner(executableURL: URL(fileURLWithPath: arguments[2]))
            budget = PaddleOCRRunner.timeoutMs
        } else {
            engine = VisionOCRRunner()
            budget = VisionOCRWorker.defaultTimeoutMs
        }
        let result = await engine.recognize(input: OCREngineInput(pixelBuffer: buffer,roi: CGRect(x: 0,y: 0,width: 1,height: 1)),timeoutMs: budget)
        _ = await engine.waitUntilAvailable(timeoutMs: 2000)
        let output: [String:Any] = ["seconds": Double(result.durationMs)/1000,"timed_out": result.timedOut,
                                    "lines": result.recognizedLines.map { ["text": $0.text,"confidence": $0.confidence] }]
        let data = try JSONSerialization.data(withJSONObject: output,options:[.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
    enum ProbeError: Error { case arguments, image }
}
