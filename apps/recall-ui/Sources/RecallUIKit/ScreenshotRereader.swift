import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import MCICaptureHelperKit

public enum ScreenshotRereadOutcome: Equatable, Sendable {
    case text(String, omittedLines: Int)
    case unavailable
    case unreadable
    case blocked
    case timedOut
}

public protocol ScreenshotRereading: Sendable {
    func read(url: URL) async -> ScreenshotRereadOutcome
}

/// Re-reads only a user-selected, authenticated saved image, fully offline.
/// No plaintext files, model downloads, history writes or background repair.
/// The OCR worker is the capture kit's own child, so the read registers the
/// worker's stop with `children` while it runs: quitting the window stops it.
public struct LocalScreenshotRereader: ScreenshotRereading {
    private let provider: any ThumbnailDataProviding
    private let executableURL: URL?
    private let children: ChildProcesses

    public init(provider: any ThumbnailDataProviding = ThumbnailDataProvider.shared,
                executableURL: URL? = PaddleOCRRunner.bundledExecutableURL,
                children: ChildProcesses = .shared) {
        self.provider = provider
        self.executableURL = executableURL
        self.children = children
    }

    public func read(url: URL) async -> ScreenshotRereadOutcome {
        guard !Task.isCancelled, let executableURL,
              let data = await provider.rereadScreenshotData(for: url), !Task.isCancelled else { return .unavailable }
        let decoder = Task.detached(priority: .userInitiated) { Self.input(data) }
        let input = await withTaskCancellationHandler { await decoder.value } onCancel: { decoder.cancel() }
        guard !Task.isCancelled, let input else { return .unavailable }
        let engine = PaddleOCRRunner(executableURL: executableURL)
        let registration = children.register(stop: { engine.stop() })
        defer {
            children.unregister(registration)
            engine.stop()
        }
        let result = await withTaskCancellationHandler {
            await engine.recognize(input: input, timeoutMs: PaddleOCRRunner.timeoutMs)
        } onCancel: { engine.stop() }
        guard !Task.isCancelled else { return .unavailable }
        switch OCRReviewedTranscript.review(result) {
        case let .text(text, omittedLines): return .text(text, omittedLines: omittedLines)
        case .unreadable: return .unreadable
        case .blocked: return .blocked
        case .timedOut: return .timedOut
        }
    }

    private static func input(_ data: Data) -> OCREngineInput? {
        guard !Task.isCancelled, data.count <= ThumbnailDataProvider.maximumBlobBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...3840).contains(width), (1...3840).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), !Task.isCancelled else { return nil }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixels) == kCVReturnSuccess, let buffer = pixels,
            CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard !Task.isCancelled else { return nil }
        return OCREngineInput(pixelBuffer: buffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
