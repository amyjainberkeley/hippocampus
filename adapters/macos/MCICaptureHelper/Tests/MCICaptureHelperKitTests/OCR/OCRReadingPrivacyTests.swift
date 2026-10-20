import CoreVideo
import Foundation
import XCTest

@testable import MCICaptureHelperKit

/// The helper's three privacy scans with roles on (RULINGS T6): the raw join,
/// the page in reading order without roles, and the exact emitted text. The
/// raw join misses every secret below, so each case shows a scan that only
/// reading order or roles make necessary. All text is made up.
final class OCRReadingPrivacyTests: XCTestCase {
    static let window = OCRWindowGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), pixelsPerPoint: 2,
                                          title: "Weekly review", bundleId: "com.example.notes")
    static let pixelSize = CGSize(width: 2880, height: 1800)

    /// Normalized [x, y, w, h] boxes (bottom-left), as `tools/ocr/screens`
    /// wrote them for these scenes.
    static func lines(_ rows: [(String, [Double])]) -> [OCRLine] {
        rows.map { OCRLine(text: $0.0, boundingBox: CGRect(x: $0.1[0], y: $0.1[1], width: $0.1[2], height: $0.1[3]),
                           confidence: 0.95) }
    }

    static let statusBar: [(String, [Double])] = [
        (": hunter2", [0.041667, 0.005556, 0.046875, 0.016667]),
        ("Ln 14, Col 2", [0.3125, 0.005556, 0.0625, 0.016667]),
        ("UTF-8", [0.520833, 0.005556, 0.026042, 0.016667]),
    ]

    /// "password" ends the note; its value opens the status bar. Reading order
    /// puts them side by side across the pane boundary, the stored text keeps
    /// U+001E between them, and the engine read the status bar first.
    static let acrossPaneBoundary = lines(statusBar + [
        ("The review covers the new onboarding flow and its copy.", [0.243056, 0.816667, 0.286458, 0.016667]),
        ("Each screen keeps one idea and one button.", [0.243056, 0.788889, 0.21875, 0.016667]),
        ("Before release we need to reset the password", [0.243056, 0.761111, 0.229167, 0.016667]),
    ])

    /// "password" in the top bar, its value in the status bar: apart on the
    /// screen and in reading order, together once chrome is gathered after
    /// the separator.
    static let onlyInChrome = lines([
        ("The review covers the new onboarding flow and its copy.", [0.243056, 0.816667, 0.286458, 0.016667]),
        ("Each screen keeps one idea and one button.", [0.243056, 0.788889, 0.21875, 0.016667]),
        ("Nothing else changes in this round of the work.", [0.243056, 0.761111, 0.244792, 0.016667]),
    ] + statusBar + [
        ("File", [0.041667, 0.961111, 0.020833, 0.016667]),
        ("Edit", [0.104167, 0.961111, 0.020833, 0.016667]),
        ("password", [0.166667, 0.961111, 0.041667, 0.016667]),
    ])

    /// Two columns the engine read row by row: the label ends the left column
    /// and its value starts the right one.
    static let reorderedByAssembler = lines([
        ("Settings", [0.243056, 0.761111, 0.041667, 0.016667]),
        ("= hunter2 is the value we use for staging", [0.451389, 0.761111, 0.213542, 0.016667]),
        ("Profile", [0.243056, 0.733333, 0.036458, 0.016667]),
        ("Other text here goes on for a while", [0.451389, 0.733333, 0.182292, 0.016667]),
        ("password", [0.243056, 0.705556, 0.041667, 0.016667]),
        ("More text in this column runs long", [0.451389, 0.705556, 0.177083, 0.016667]),
    ])

    static func raw(_ lines: [OCRLine]) -> String { lines.map(\.text).joined(separator: "\n") }

    static func stored(_ lines: [OCRLine]) -> OCRReadingOrder.Reading {
        OCRMemoryText.reading(from: lines, pixelSize: pixelSize, geometry: window)
    }

    func testSecretSplitAcrossPaneBoundaryIsCaughtInReadingOrder() async {
        let lines = Self.acrossPaneBoundary
        XCTAssertFalse(SuppressionCascade.containsSecretOrPII(Self.raw(lines)))
        let reading = Self.stored(lines)
        XCTAssertTrue(reading.classified)
        XCTAssertTrue(reading.stored.contains("password\n\n\u{1E}\n: hunter2"), reading.stored)
        XCTAssertFalse(SuppressionCascade.containsSecretOrPII(reading.stored),
                       "The emitted text alone would pass; the reading-order scan must catch it")
        XCTAssertTrue(SuppressionCascade.containsSecretOrPII(OCRMemoryText.make(from: lines, pixelSize: Self.pixelSize)))
        await Self.assertSuppressed(lines, reason: .ocrTimeSecret)
    }

    func testSecretOnlyInChromeIsCaughtInTheEmittedText() async {
        let lines = Self.onlyInChrome
        XCTAssertFalse(SuppressionCascade.containsSecretOrPII(Self.raw(lines)))
        XCTAssertFalse(SuppressionCascade.containsSecretOrPII(OCRMemoryText.make(from: lines, pixelSize: Self.pixelSize)))
        let reading = Self.stored(lines)
        XCTAssertEqual(reading.blocks.filter { $0.role == .chrome }.map(\.rule), ["bar", "status"])
        XCTAssertTrue(SuppressionCascade.containsSecretOrPII(reading.stored))
        await Self.assertSuppressed(lines, reason: .ocrTimeSecret)
        // Without roles the two halves never meet, and the text is emitted as before.
        let frames = await Self.drive(lines, geometry: nil)
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(frames.first.map(Self.isTombstone) ?? true)
    }

    func testSecretReorderedByTheAssemblerIsCaught() async {
        let lines = Self.reorderedByAssembler
        XCTAssertFalse(SuppressionCascade.containsSecretOrPII(Self.raw(lines)))
        XCTAssertTrue(SuppressionCascade.containsSecretOrPII(Self.stored(lines).stored))
        await Self.assertSuppressed(lines, reason: .ocrTimeSecret)
        let frames = await Self.drive(lines, geometry: nil)
        XCTAssertEqual(frames.map(Self.isTombstone), [true])
        XCTAssertEqual(frames.first?.last, RedactionReason.ocrTimeSecret.rawValue)
    }

    func testRawJoinAtTheCapStillFailsClosedWhenTheStoredTextIsLonger() async {
        // The raw join is exactly 64 KiB, so it passes the byte check; the
        // stored text adds the separator (and a blank line between regions),
        // so the event cannot be encoded. One tombstone, never a cut event.
        let first = String(repeating: "a", count: maxOCRTextBytes / 2 - 1)
        let second = String(repeating: "b", count: maxOCRTextBytes / 2)
        let lines = [
            OCRLine(text: first, boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.02), confidence: 1),
            OCRLine(text: second, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.02), confidence: 1),
        ]
        XCTAssertEqual(Self.raw(lines).utf8.count, maxOCRTextBytes)
        XCTAssertGreaterThan(Self.stored(lines).stored.utf8.count, maxOCRTextBytes)
        await Self.assertSuppressed(lines, reason: .failsafeUnknown)
    }

    func testStoredTextAtTheCapIsEmittedWhole() async throws {
        // Two rows of one block: the stored text is the raw join plus the
        // four bytes of the separator, exactly 64 KiB.
        let first = String(repeating: "a", count: maxOCRTextBytes / 2 - 3)
        let second = String(repeating: "b", count: maxOCRTextBytes / 2 - 2)
        let lines = [
            OCRLine(text: first, boundingBox: CGRect(x: 0.1, y: 0.80, width: 0.8, height: 0.02), confidence: 1),
            OCRLine(text: second, boundingBox: CGRect(x: 0.1, y: 0.775, width: 0.8, height: 0.02), confidence: 1),
        ]
        let stored = Self.stored(lines).stored
        XCTAssertEqual(stored, first + "\n" + second + OCRReadingOrder.chromeSeparator)
        XCTAssertEqual(stored.utf8.count, maxOCRTextBytes)
        let frames = await Self.drive(lines, geometry: Self.window)
        let expected = try encodeOCREvent(seq: 0, event: OCREvent(
            seq: 0, tsUs: 1, appBundleId: "com.example.notes", windowTitle: "Weekly review", url: "", ocrText: stored
        )).get()
        XCTAssertEqual(frames, [expected])
    }

    func testCleanWindowIsEmittedContentFirstWithOneSeparator() async throws {
        let lines = Self.lines([
            ("File", [0.041667, 0.961111, 0.020833, 0.016667]),
            ("Edit", [0.104167, 0.961111, 0.020833, 0.016667]),
            ("View", [0.166667, 0.961111, 0.020833, 0.016667]),
            ("The review covers the new onboarding flow and its copy.", [0.243056, 0.816667, 0.286458, 0.016667]),
            ("Each screen keeps one idea and one button.", [0.243056, 0.788889, 0.21875, 0.016667]),
        ])
        let frames = await Self.drive(lines, geometry: Self.window)
        let text = "The review covers the new onboarding flow and its copy.\nEach screen keeps one idea and one button."
            + OCRReadingOrder.chromeSeparator + "File Edit View"
        let expected = try encodeOCREvent(seq: 0, event: OCREvent(
            seq: 0, tsUs: 1, appBundleId: "com.example.notes", windowTitle: "Weekly review", url: "", ocrText: text
        )).get()
        XCTAssertEqual(frames, [expected])
    }

    /// The shared corpus the Rust reader's guard is checked against
    /// (`core/brain/fixtures/ocr-secret-corpus.json`): the helper's patterns
    /// give every answer it records.
    func testSecretPatternsAnswerTheSharedCorpus() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("core/brain/fixtures/ocr-secret-corpus.json")
        struct Corpus: Decodable {
            let cases: [Case]
            struct Case: Decodable {
                /// The case's text, or `parts` to join: key-shaped cases are
                /// kept in parts so no whole key sits in the repository.
                let text: String?
                let parts: [String]?
                let secret: Bool
                let why: String
            }
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 130)
        for item in corpus.cases {
            let text = try XCTUnwrap(item.text ?? item.parts?.joined(), item.why)
            XCTAssertEqual(SuppressionCascade.containsSecretOrPII(text), item.secret, item.why)
        }
    }

    // MARK: - Driving the emitter

    static func drive(_ lines: [OCRLine], geometry: OCRWindowGeometry?) async -> [Data] {
        let sink = ReadingRecordingSink()
        await CascadeTwiceOCREmitter.handleOCRResult(
            tsUs: 1,
            context: WorkflowContext(appBundleId: "com.example.notes", windowTitle: "Weekly review"),
            result: OCRResult(recognizedLines: lines, durationMs: 1, timedOut: false),
            cascade: allowCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters(),
            pixelBuffer: makePixelBuffer(width: 2880, height: 1800),
            geometry: geometry
        )
        return await sink.frames()
    }

    static func assertSuppressed(_ lines: [OCRLine], reason: RedactionReason,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        let frames = await drive(lines, geometry: window)
        XCTAssertEqual(frames.count, 1, file: file, line: line)
        XCTAssertEqual(frames.first.map(isTombstone), true, file: file, line: line)
        XCTAssertEqual(frames.first?.last, reason.rawValue, file: file, line: line)
    }

    static func isTombstone(_ frame: Data) -> Bool {
        frame.count >= 4 && frame[2] == 0x11 && frame[3] == 0
    }

    static func allowCascade() -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: NoSecureEventInputForReading(),
            axSecureSubrole: NonSecureAXForReading(),
            denylist: EmptyDenylistForReading(),
            blackedRegion: NoBlackRegionForReading(),
            knownSafeAppBundles: ["com.example.notes"]
        )
    }

    static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var output: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil,
                                         &output) == kCVReturnSuccess)
        return output!
    }
}

private actor ReadingRecordingSink: FrameSink {
    private var recorded: [Data] = []
    func write(_ bytes: Data) throws { recorded.append(bytes) }
    func frames() -> [Data] { recorded }
}

private struct NoSecureEventInputForReading: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct NonSecureAXForReading: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct EmptyDenylistForReading: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlackRegionForReading: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}
