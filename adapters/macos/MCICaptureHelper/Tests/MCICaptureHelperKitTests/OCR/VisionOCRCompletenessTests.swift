import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import Vision
import XCTest

@testable import MCICaptureHelperKit

final class VisionOCRCompletenessTests: XCTestCase {
    private static let labels = [
        "Search settings", "Pending changes", "cache_key_123", "GET /v1/events"
    ]

    func testSmallLabelsAreNotOmitted() async throws {
        for height in [1080, 1920] {
            let input = try Self.render(height: height, entries: Self.smallLabels(height: height))
            let measurements = RegionMeasurements()
            let runner = VisionOCRRunner(regionDidFinish: measurements.record)
            let result = await runner.recognize(input: input, timeoutMs: VisionOCRWorker.defaultTimeoutMs)
            let actual = result.recognizedLines.map(\.text)
            print("OCR-COMPLETENESS height=\(height) exact=\(Self.labels.filter { actual.contains($0) }.count)/4 ms=\(result.durationMs) \(measurements.summary(planned: VisionOCRRunner.recognitionRegions(for: input).count))")
            XCTAssertFalse(result.timedOut)
            for label in Self.labels {
                XCTAssertTrue(actual.contains(label), "Missing literal label: \(label); got \(actual)")
            }
        }
    }

    func testRepeatedLabelsAndOverlapKeepImagePositionsAndOriginalOrder() async throws {
        let entries = [
            Text("Search settings", x: 40, y: 920, size: 12),
            Text("Search settings", x: 1400, y: 120, size: 12),
            Text("boundary_key_456", x: 880, y: 540, size: 16),
            Text("Review changes before publishing the release.", x: 40, y: 1020, size: 24)
        ]
        let input = try Self.render(entries: entries)
        let original = try Self.singlePass(input)
        let result = await VisionOCRRunner().recognize(input: input, timeoutMs: VisionOCRWorker.defaultTimeoutMs)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(Array(result.recognizedLines.prefix(original.count).map(\.text)), original,
                       "Keep original text contiguous for multiline privacy patterns")
        for entry in entries {
            let matches = result.recognizedLines.filter {
                $0.text == entry.text && abs($0.boundingBox.minX - entry.x / 1920) < 0.02
                    && abs($0.boundingBox.minY - entry.y / 1080) < 0.02
            }
            XCTAssertGreaterThanOrEqual(matches.count, 1, "Expected the label at its image position: \(entry.text); got \(result.recognizedLines)")
        }
        XCTAssertGreaterThanOrEqual(result.recognizedLines.filter { $0.text == "Search settings" }.count, 2)
    }

    func testPartialROIExcludesOutsideTextAndKeepsImageCoordinates() async throws {
        let roi = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let input = try Self.render(entries: [
            Text("inside_left_123", x: 250, y: 850, size: 16),
            Text("inside_right_456", x: 1400, y: 400, size: 16),
            Text("OUTSIDE_TOP", x: 40, y: 1030, size: 24),
            Text("OUTSIDE_BOTTOM", x: 40, y: 40, size: 24)
        ], roi: roi)
        let result = await VisionOCRRunner().recognize(input: input, timeoutMs: VisionOCRWorker.defaultTimeoutMs)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.recognizedLines.contains { $0.text == "inside_left_123" })
        XCTAssertTrue(result.recognizedLines.contains { $0.text == "inside_right_456" })
        for line in result.recognizedLines {
            XCTAssertFalse(line.text.contains("OUTSIDE"))
            XCTAssertTrue(roi.contains(line.boundingBox), "Result must stay in original image coordinates: \(line)")
        }
    }

    func testBlankImageDoesNotInventText() async throws {
        let input = try Self.render(entries: [])
        let result = await VisionOCRRunner().recognize(input: input, timeoutMs: VisionOCRWorker.defaultTimeoutMs)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.recognizedLines.isEmpty)
    }

    func testRecognitionWorkIsBoundedToAdmittedROI() throws {
        let image = try Self.render(entries: [])
        for roi in [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            CGRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25)
        ] {
            let regions = VisionOCRRunner.recognitionRegions(for: OCREngineInput(pixelBuffer: image.pixelBuffer, roi: roi))
            XCTAssertEqual(regions.first, roi, "Keep the original pass for long lines crossing subregion boundaries")
            XCTAssertLessThanOrEqual(regions.count, 5)
            for region in regions {
                XCTAssertTrue(roi.contains(region), "Never expand the admitted input")
                XCTAssertFalse(region.isEmpty)
            }
            if roi.width == 0.25 { XCTAssertEqual(regions.count, 1) }
        }
    }

    func testInvalidROIProducesNoText() async throws {
        let image = try Self.render(entries: Self.smallLabels(height: 1080))
        for roi in [CGRect.zero, .null, .infinite, CGRect(x: -0.1, y: 0, width: 1, height: 1)] {
            let input = OCREngineInput(pixelBuffer: image.pixelBuffer, roi: roi)
            XCTAssertTrue(VisionOCRRunner.recognitionRegions(for: input).isEmpty)
            let runner = VisionOCRRunner(regionDidFinish: { _, _ in })
            let result = await runner.recognize(input: input, timeoutMs: VisionOCRWorker.defaultTimeoutMs)
            XCTAssertFalse(result.timedOut)
            XCTAssertTrue(result.recognizedLines.isEmpty)
        }
    }

    func testRealVisionSupplementalMultilineSecretSuppressesEmissionAndRetention() async throws {
        let input = try Self.render(entries: [
            Text("password", x: 40, y: 1000, size: 24),
            Text(": demo", x: 40, y: 960, size: 10),
            Text("Review notes", x: 1200, y: 500, size: 24)
        ])
        let supplemental = OCREngineInput(pixelBuffer: input.pixelBuffer, roi: CGRect(x: 0, y: 0.45, width: 0.55, height: 0.55))
        let rawPass = try Self.singlePass(supplemental)
        XCTAssertEqual(rawPass, ["password", ": demo"], "Confirm the reviewer's actual Vision fixture")
        let measurements = RegionMeasurements()
        let runner = VisionOCRRunner(regionDidFinish: measurements.record)
        let result = await runner.recognize(input: input, timeoutMs: 10_000)
        print("OCR-PRIVACY-REPRO ms=\(result.durationMs) lines=\(result.recognizedLines.map(\.text))")
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.recognizedLines.map(\.text).joined(separator: "\n").contains("password\n: demo"))
        await PostPrivacyEvidenceTests.assertSecretSuppressed(result: result)
    }

    func testSupplementalOverrunDiscardsBaselineAndQuarantinesUntilReturn() async throws {
        let input = try Self.render(entries: Self.smallLabels(height: 1080, size: 16))
        XCTAssertEqual(try Self.singlePass(input).count, 4, "The original scan has usable text")
        let blocked = BlockingSupplementalPass()
        let runner = VisionOCRRunner(regionDidFinish: blocked.record)
        defer { blocked.release.signal() }

        // Real Vision performs both scans; the fixture holds the serial lane
        // after the first supplement, modeling cancellation-insensitive work.
        let result = await runner.recognize(input: input, timeoutMs: 500)
        XCTAssertEqual(blocked.count, 2)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.recognizedLines.isEmpty, "A supplemental timeout cannot publish the otherwise usable baseline")
        let quarantined = await runner.recognize(input: input, timeoutMs: 100)
        XCTAssertTrue(quarantined.timedOut)
        XCTAssertTrue(quarantined.recognizedLines.isEmpty)
        XCTAssertEqual(blocked.count, 2, "Quarantine must not start another request")

        blocked.release.signal()
        let invalid = OCREngineInput(pixelBuffer: input.pixelBuffer, roi: .zero)
        let recoveryDeadline = ContinuousClock.now + .seconds(1)
        var recovered = false
        while ContinuousClock.now < recoveryDeadline {
            let probe = await runner.recognize(input: invalid, timeoutMs: 100)
            if !probe.timedOut {
                recovered = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(blocked.count, 2, "Do not start remaining supplements after the deadline")
    }

    func testDenseScanKeepsOriginalTextWithinProductionBudget() async throws {
        let entries = (0..<40).flatMap { row in
            [40, 1000].map { x in
                Text("let cache_key_\(row) = result.map { $0.id };", x: CGFloat(x), y: 1020 - CGFloat(row) * 24, size: 16)
            }
        }
        let input = try Self.render(entries: entries)
        let warmupStarted = DispatchTime.now().uptimeNanoseconds
        _ = try Self.singlePass(input)
        print("OCR-DENSE-WARMUP ms=\((DispatchTime.now().uptimeNanoseconds - warmupStarted) / 1_000_000)")
        for sample in 0..<3 {
            let started = DispatchTime.now().uptimeNanoseconds
            let baseline = try Self.singlePass(input)
            let baselineMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let measurements = RegionMeasurements()
            let result = await VisionOCRRunner(regionDidFinish: measurements.record).recognize(input: input, timeoutMs: VisionOCRWorker.defaultTimeoutMs)
            print("OCR-DENSE-BENCH sample=\(sample) baseline_lines=\(baseline.count) candidate_lines=\(result.recognizedLines.count) baseline_ms=\(baselineMs) candidate_ms=\(result.durationMs) timed_out=\(result.timedOut) \(measurements.summary(planned: VisionOCRRunner.recognitionRegions(for: input).count))")
            XCTAssertFalse(result.timedOut)
            guard !result.timedOut else { continue }
            XCTAssertEqual(Array(result.recognizedLines.prefix(baseline.count).map(\.text)), baseline,
                           "Preserve original literal candidates and their order")
        }
    }

    func testSyntheticCompletenessBenchmark() async throws {
        // Alternate a frozen single-pass baseline and the production runner on
        // identical pixels. Timings are observations, not CI performance gates.
        for (height, size) in [(1080, 12), (1920, 12), (1080, 16)] {
            let input = try Self.render(height: height, entries: Self.smallLabels(height: height, size: CGFloat(size)))
            for sample in 0..<5 {
                let started = DispatchTime.now().uptimeNanoseconds
                let baseline = try Self.singlePass(input)
                let baselineMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                let measurements = RegionMeasurements()
                let result = await VisionOCRRunner(regionDidFinish: measurements.record).recognize(input: input, timeoutMs: VisionOCRWorker.defaultTimeoutMs)
                let actual = result.recognizedLines.map(\.text)
                let baselineExact = Self.labels.filter { baseline.contains($0) }.count
                let actualExact = Self.labels.filter { actual.contains($0) }.count
                print("OCR-COMPLETENESS-BENCH height=\(height) size=\(size) sample=\(sample) baseline_exact=\(baselineExact)/4 candidate_exact=\(actualExact)/4 baseline_ms=\(baselineMs) candidate_ms=\(result.durationMs) \(measurements.summary(planned: VisionOCRRunner.recognitionRegions(for: input).count))")
                XCTAssertFalse(result.timedOut)
                XCTAssertEqual(actualExact, 4)
            }
        }
    }

    private static func singlePass(_ input: OCREngineInput) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = true
        request.regionOfInterest = input.roi
        try VNImageRequestHandler(cvPixelBuffer: input.pixelBuffer, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    func testEveryRepeatedReadingIsRetainedInOrder() {
        var accumulated = OCRLineAccumulator()
        for index in 0..<1000 {
            accumulated.append(OCRLine(
                text: "Repeated label", boundingBox: CGRect(x: 0, y: Double(index) / 1000, width: 0.2, height: 0.0005), confidence: 1
            ))
        }
        XCTAssertEqual(accumulated.lines.count, 1000)
        XCTAssertEqual(Set(accumulated.lines.map { $0.boundingBox.minY }).count, 1000)
        XCTAssertEqual(accumulated.lines.map { $0.boundingBox.minY }, (0..<1000).map { Double($0) / 1000 })
    }

    func testDifferingReadingsRemainAvailableToPrivacyCheck() {
        var accumulated = OCRLineAccumulator()
        let box = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)
        accumulated.append(OCRLine(text: "passw0rd=synthetic", boundingBox: box, confidence: 1))
        accumulated.append(OCRLine(text: "password=synthetic", boundingBox: box, confidence: 1))
        accumulated.append(OCRLine(text: "password=synthetic", boundingBox: box, confidence: 1))
        XCTAssertEqual(accumulated.lines.map(\.text), ["passw0rd=synthetic", "password=synthetic", "password=synthetic"])
    }

    private final class RegionMeasurements: @unchecked Sendable {
        private let lock = NSLock()
        private var durations: [UInt64] = []

        func record(_ region: CGRect, _ durationNs: UInt64) {
            lock.withLock { durations.append(durationNs / 1_000_000) }
        }

        func summary(planned: Int) -> String {
            lock.withLock { "passes=\(durations.count)/\(planned) supplemental_skipped=\(planned - durations.count) perform_ms=\(durations)" }
        }
    }

    private final class BlockingSupplementalPass: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = 0
        let release = DispatchSemaphore(value: 0)

        var count: Int { lock.withLock { completed } }

        func record(_ region: CGRect, _ durationNs: UInt64) {
            let ordinal = lock.withLock {
                completed += 1
                return completed
            }
            if ordinal == 2 { release.wait() }
        }
    }

    private struct Text {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat

        init(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat) {
            self.text = text
            self.x = x
            self.y = y
            self.size = size
        }
    }

    private static func smallLabels(height: Int, size: CGFloat = 12) -> [Text] {
        labels.enumerated().map {
            Text($0.element, x: 40, y: CGFloat(height) - 60 - CGFloat($0.offset) * 40, size: size)
        }
    }

    // Synthetic pixels only; no screen, window, file, or memory-store input.
    private static func render(
        height: Int = 1080,
        entries: [Text],
        roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) throws -> OCREngineInput {
        let width = 1920
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
        for entry in entries {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, entry.size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            context.textPosition = CGPoint(x: entry.x, y: entry.y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: entry.text, attributes: attributes)), context)
        }
        return OCREngineInput(pixelBuffer: pixels, roi: roi)
    }
}
