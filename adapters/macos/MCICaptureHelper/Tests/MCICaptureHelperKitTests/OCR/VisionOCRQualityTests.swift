import CoreGraphics
import CoreML
import CoreText
import CoreVideo
import Foundation
import Vision
import XCTest

@testable import MCICaptureHelperKit

final class VisionOCRQualityTests: XCTestCase {
    // Synthetic source text only. Rendering never reads the screen or opens a window.
    private static let corpus = [
        "let cacheKey = \"hippo_v1\";",
        "if (retryCount <= 2) { return nil; }",
        "result.map { $0.id }.joined(separator: \",\")",
        "GET /v1/events?limit=12&cursor=abc_123",
        "OCR punctuation: [a-z_]+ != nil; count += 1",
        "Hippocampus MCICaptureHelper cacheKey user_id",
        "Build succeeded. 12 tests passed (0 failures).",
        "Review changes before publishing the release."
    ]

    func testSmallCodeDoesNotAcquireLanguageCorrectionSpaces() async throws {
        let input = try Self.render(lines: Self.corpus, fontSize: 12)
        let runner = VisionOCRRunner(regionDidFinish: { _, _ in })
        let result = await runner.recognize(input: input, timeoutMs: 10_000)
        // Drain timed-out work without changing the recognition result or budget.
        let drained = await runner.waitUntilIdle(timeoutMs: 5_000)
        XCTAssertTrue(drained, "The Vision perform must finish before the next fixture")
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(
            result.recognizedLines.contains { $0.text == "result.map { $0.id }.joined(separator: \",\")" },
            "OCR changed the rendered code: \(result.recognizedLines.map(\.text))"
        )
    }

    func testSyntheticRecognitionBenchmark() throws {
        let modes: [(String, VNRequestTextRecognitionLevel, Bool)] = [
            ("accurate-corrected", .accurate, true),
            ("accurate-raw", .accurate, false),
            ("fast-corrected", .fast, true)
        ]
        for size: CGFloat in [12, 16, 24] {
            let input = try Self.render(lines: Self.corpus, fontSize: size)
            for (name, level, correction) in modes {
                let start = ContinuousClock.now
                let observations = try Self.recognize(input, level: level, correction: correction)
                let actual = observations.compactMap { $0.topCandidates(1).first?.string }
                let expected = Self.corpus.joined(separator: "\n")
                let errors = Self.editDistance(expected, actual.joined(separator: "\n"))
                print("OCR-BENCH size=\(size) mode=\(name) errors=\(errors)/\(expected.count) elapsed=\(start.duration(to: .now))")
                for observation in observations {
                    if let candidate = observation.topCandidates(1).first {
                        print("OCR-LINE \(candidate.string) candidate=\(candidate.confidence) observation=\(observation.confidence)")
                    }
                }
                XCTAssertFalse(actual.isEmpty)
            }
        }
    }

    func testSyntheticAccurateComputeDeviceComparison() throws {
        let request = Self.recognitionRequest(level: .accurate, correction: false)
        let stages = try request.supportedComputeStageDevices
        print("OCR-COMPUTE available=\(MLComputeDevice.allComputeDevices.map(Self.deviceKind).sorted())")
        for stage in stages.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            print("OCR-COMPUTE stage=\(stage.rawValue) supported=\(stages[stage, default: []].map(Self.deviceKind).sorted()) assigned=\(request.computeDevice(for: stage).map(Self.deviceKind) ?? "automatic")")
        }
        let devices = try XCTUnwrap(stages[.main])
        XCTAssertFalse(devices.isEmpty)
        let input = try Self.render(lines: Self.corpus, fontSize: 16)
        for sample in 0..<2 {
            for device in devices {
                let baselineStarted = ContinuousClock.now
                let baseline = try Self.recognize(input, level: .accurate, correction: false)
                    .compactMap { $0.topCandidates(1).first }
                let baselineElapsed = baselineStarted.duration(to: .now)
                let candidateStarted = ContinuousClock.now
                let candidate = try Self.recognize(input, level: .accurate, correction: false, device: device)
                    .compactMap { $0.topCandidates(1).first }
                let candidateElapsed = candidateStarted.duration(to: .now)
                let errors = Self.editDistance(Self.corpus.joined(separator: "\n"), candidate.map(\.string).joined(separator: "\n"))
                print("OCR-COMPUTE sample=\(sample) route=\(Self.deviceKind(device)) baseline_elapsed=\(baselineElapsed) candidate_elapsed=\(candidateElapsed) baseline_lines=\(baseline.count) candidate_lines=\(candidate.count) errors=\(errors)/329")
                XCTAssertFalse(baseline.isEmpty)
                XCTAssertEqual(candidate.map(\.string), baseline.map(\.string), "An explicit device must preserve every automatic-mode reading in order")
                for (actual, original) in zip(candidate, baseline) {
                    XCTAssertGreaterThanOrEqual(actual.confidence, original.confidence)
                }
            }
        }
    }

    private static func deviceKind(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .neuralEngine: return "neural_engine"
        @unknown default: return "unknown"
        }
    }

    private static func recognize(
        _ input: OCREngineInput,
        level: VNRequestTextRecognitionLevel = .accurate,
        correction: Bool = true,
        device: MLComputeDevice? = nil
    ) throws -> [VNRecognizedTextObservation] {
        let request = recognitionRequest(level: level, correction: correction)
        request.setComputeDevice(device, for: .main)
        request.regionOfInterest = input.roi
        try VNImageRequestHandler(cvPixelBuffer: input.pixelBuffer, orientation: .up)
            .perform([request])
        return request.results ?? []
    }

    private static func recognitionRequest(
        level: VNRequestTextRecognitionLevel,
        correction: Bool
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = correction
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = true
        return request
    }

    private static func render(lines: [String], fontSize: CGFloat) throws -> OCREngineInput {
        let width = 1920
        let height = 1080
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, fontSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        for (index, text) in lines.enumerated() {
            context.textPosition = CGPoint(x: 40, y: CGFloat(height) - 60 - CGFloat(index) * (fontSize + 16))
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        return OCREngineInput(pixelBuffer: pixels, roi: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func editDistance(_ expected: String, _ actual: String) -> Int {
        let rhs = Array(actual)
        var previous = Array(0...rhs.count)
        for (i, lhs) in expected.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, char) in rhs.enumerated() {
                row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (lhs == char ? 0 : 1))
            }
            previous = row
        }
        return previous[rhs.count]
    }
}
