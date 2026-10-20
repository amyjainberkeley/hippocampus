// SPDX-License-Identifier: Apache-2.0
//
// SyntheticCaptureFeed — the capture helper's pipeline in fixture mode.
//
// Development and test only; never bundled. `scripts/e2e-full.sh` drives it.
//
// It does what `MCICaptureHelper --capture` does after ScreenCaptureKit has
// handed it a frame and the pixel-time cascade has said yes, with made-up
// windows instead of a screen:
//
//   1. draws each window of a JSON manifest into a BGRA pixel buffer
//      (CoreText, black on white, a title bar), with no screen and no
//      window server;
//   2. hands it to the production `CascadeTwiceOCREmitter`, with the
//      production reader (the bundled PP-OCR worker named by `--worker`, or
//      Apple Vision as an unbundled helper reads), the production
//      `SuppressionCascade` (its OCR-time secret checks run three times),
//      and the production `KeyframeRetentionCoordinator`, which seals the
//      screenshot under `~/Library/Application Support/MCI/blobs`;
//   3. writes the framed wire bytes on stdout, for `mci-agent --drain-stdin`.
//
// What it does not exercise: ScreenCaptureKit, focus tracking and the
// pixel-time cascade (secure input, password fields, denylists, private
// browser windows). Those read the live screen and need Screen Recording and
// Accessibility granted by a person (`scripts/run-live-capture-overlap.sh`).
//
// The database key comes from the helper's own resolver in development
// file-key mode only. Without `MCI_DEVELOPMENT_FILE_KEY=1` and
// `MCI_DB_KEY_FILE` naming `~/Library/Application Support/MCI/dev.key` it
// refuses to run, so it can never reach a Keychain item.
//
//     SyntheticCaptureFeed --manifest FRAMES.json [--worker PATH]
//                          [--worker-sandbox-rules RULES.sb]
//                          [--report REPORT.json] [--timeout-ms MS]
//
// The worker starts as the helper starts it, inside the product's
// no-network sandbox (OCRWorkerSandbox). `--worker-sandbox-rules` appends a
// test's own rules to that profile: the end-to-end harness closes the real
// ~/Library to the worker too. A sandbox can't be applied inside another, so
// a test adds its rules here rather than wrapping the worker.
//
// Manifest: {"frames": [{"id", "app", "title", "url"?, "lines": [...],
//            "offset_seconds"?: -3600, "width"?: 1100, "height"?: 700}]}
//
// The report is content-free: per frame, its id, what reached the wire (an
// event, or a tombstone and its reason) and whether a screenshot was sealed.
// It never holds a frame's text.

import CoreGraphics
import CoreText
import CoreVideo
import Darwin
import Foundation
import MCICaptureHelperKit

private struct Manifest: Decodable {
    struct Frame: Decodable {
        let id: String
        let app: String
        let title: String
        let url: String?
        let lines: [String]
        let offsetSeconds: Int64?
        let width: Int?
        let height: Int?

        enum CodingKeys: String, CodingKey {
            case id, app, title, url, lines, width, height
            case offsetSeconds = "offset_seconds"
        }
    }

    let frames: [Frame]
}

private enum FeedError: Error, CustomStringConvertible {
    case usage
    case developmentModeRequired
    case manifest(String)
    case render(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: SyntheticCaptureFeed --manifest FRAMES.json [--worker PATH] [--report REPORT.json] [--timeout-ms MS]"
        case .developmentModeRequired:
            return "development file-key mode is required (MCI_DEVELOPMENT_FILE_KEY=1 and MCI_DB_KEY_FILE); the Keychain is never read"
        case .manifest(let detail):
            return "manifest: \(detail)"
        case .render(let detail):
            return "render: \(detail)"
        }
    }
}

/// What reached the wire for one frame. Content-free by construction.
private struct FrameOutcome: Encodable {
    let id: String
    var events = 0
    var tombstones = 0
    var tombstoneReasons: [UInt8] = []
    var screenshotSealed = false
    var disposition = "pending"

    enum CodingKeys: String, CodingKey {
        case id, events, tombstones, disposition
        case tombstoneReasons = "tombstone_reasons"
        case screenshotSealed = "screenshot_sealed"
    }
}

/// Forwards every frame to the real stdout sink and notes its type.
private actor TeeSink: FrameSink {
    private let forward: FileHandleFrameSink
    private var seen: [(type: UInt16, reason: UInt8?, sealed: Bool)] = []

    init(forward: FileHandleFrameSink) {
        self.forward = forward
    }

    func write(_ data: Data) async throws {
        try await forward.write(data)
        guard data.count >= minFrameHeaderBytes else { return }
        let type = UInt16(data[2]) | (UInt16(data[3]) << 8)
        switch type {
        case MessageType.privacyTombstone.rawValue:
            // payload: ts u64, app (u16 length + bytes), reason u8.
            seen.append((type, data.last, false))
        case MessageType.ocrEvent.rawValue, MessageType.contextOcrEvent.rawValue:
            // payload: seq u64, ts u64, bundle[64], three lengths, hash[32].
            let hashStart = minFrameHeaderBytes + 8 + 8 + ocrEventAppBundleIdLen + 2 + 2 + 4
            var sealed = false
            if data.count >= hashStart + ocrEventKeyframeHashLen {
                sealed = data[hashStart ..< hashStart + ocrEventKeyframeHashLen].contains { $0 != 0 }
            }
            seen.append((type, nil, sealed))
        default:
            seen.append((type, nil, false))
        }
    }

    func drain() -> [(type: UInt16, reason: UInt8?, sealed: Bool)] {
        defer { seen.removeAll() }
        return seen
    }
}

private final class DispositionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OCRPostAllowDisposition?

    func set(_ disposition: OCRPostAllowDisposition) {
        lock.withLock { if value == nil { value = disposition } }
    }

    func get() -> OCRPostAllowDisposition? { lock.withLock { value } }
}

@main
private enum SyntheticCaptureFeed {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("SyntheticCaptureFeed: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var manifestPath: String?
        var workerPath: String?
        var workerSandboxRules = ""
        var reportPath: String?
        var timeoutOverride: Int?
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard let value = arguments.first else { throw FeedError.usage }
            arguments.removeFirst()
            switch flag {
            case "--manifest": manifestPath = value
            case "--worker": workerPath = value
            case "--worker-sandbox-rules":
                workerSandboxRules = try String(contentsOf: URL(fileURLWithPath: value), encoding: .utf8)
            case "--report": reportPath = value
            case "--timeout-ms": timeoutOverride = Int(value)
            default: throw FeedError.usage
            }
        }
        guard let manifestPath else { throw FeedError.usage }

        // Development file-key mode only, checked before any key is touched.
        let environment = ProcessInfo.processInfo.environment
        guard environment["MCI_DEVELOPMENT_FILE_KEY"] == "1",
              environment["MCI_DB_KEY_FILE"] != nil
        else {
            throw FeedError.developmentModeRequired
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(
                Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
            )
        } catch {
            throw FeedError.manifest("\(error)")
        }
        guard !manifest.frames.isEmpty else { throw FeedError.manifest("no frames") }

        // The helper's own key path and blob folder (main.swift), resolved the
        // same way: Foundation's Application Support, which follows
        // CFFIXED_USER_HOME.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let mciDirectory = appSupport.appendingPathComponent("MCI")
        let keyBytes = try KeychainDatabaseKeyResolver().resolveBytes(
            environment: environment,
            developmentKeyPath: mciDirectory.appendingPathComponent("dev.key")
        )
        let blobDirectory = mciDirectory.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobDirectory.path)

        // The reader the helper would use: the bundled PP-OCR worker, warm, or
        // Apple Vision when no worker is given (an unbundled helper).
        let engine: OCREngine
        let timeoutMs: Int
        var paddle: PaddleOCRRunner?
        if let workerPath {
            let runner = PaddleOCRRunner(executableURL: URL(fileURLWithPath: workerPath), persistent: true,
                                         sandbox: OCRWorkerSandbox(extraRules: workerSandboxRules))
            runner.prewarm()
            paddle = runner
            engine = runner
            timeoutMs = timeoutOverride ?? PaddleOCRRunner.timeoutMs
        } else {
            engine = VisionOCRRunner()
            timeoutMs = timeoutOverride ?? VisionOCRWorker.defaultTimeoutMs
        }
        let worker = VisionOCRWorker(engine: engine, timeoutMs: timeoutMs)

        // The production cascade, built as main.swift builds it. Only its
        // OCR-time checks run here: the pixel-time arms read the live screen.
        let cascade = SuppressionCascade(
            secureEventInput: CarbonSecureEventInputProbe(),
            axSecureSubrole: AXSubroleProbe(),
            denylist: SensitiveCaptureDenylist(entries: []),
            blackedRegion: PixelGridBlackedRegionProbe(),
            knownSafeAppBundles: Set(manifest.frames.map(\.app)),
            browserAppBundles: BrowserPixelCapturePolicy.browserBundleIds,
            admissionPolicy: .ordinaryApplications,
            browserWindowPrivacy: BrowserWindowPrivacyProbe()
        )
        let tee = TeeSink(forward: FileHandleFrameSink(handle: .standardOutput))
        let emitter = CascadeTwiceOCREmitter(
            worker: worker,
            cascade: cascade,
            sink: tee,
            sequence: FrameSequence(),
            counters: HelperHealthCounters(),
            keyframeRetainer: KeyframeRetentionCoordinator(
                blobDirectory: blobDirectory,
                keyMaterial: Data(keyBytes)
            )
        )
        await worker.start()

        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        var outcomes: [FrameOutcome] = []
        for (index, frame) in manifest.frames.enumerated() {
            let ordinal = UInt64(index + 1)
            let pixels = try render(frame)
            let offsetUs = (frame.offsetSeconds ?? 0) * 1_000_000
            let tsUs = offsetUs < 0 ? nowUs - UInt64(-offsetUs) : nowUs + UInt64(offsetUs)
            let box = DispositionBox()
            await emitter.processAfterAllow(
                captureOrdinal: ordinal,
                tsUs: tsUs,
                context: WorkflowContext(appBundleId: frame.app, windowTitle: frame.title, url: frame.url),
                input: OCREngineInput(
                    pixelBuffer: pixels,
                    roi: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pixelsPerPoint: 2
                ),
                evidenceCandidate: KeyframeEvidenceCandidate(
                    captureOrdinal: ordinal,
                    focusedWindowId: UInt32(1_000 + index),
                    dhash: DHash(bits: ordinal),
                    monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
                ),
                disposition: { box.set($0) }
            )
            // One frame at a time, as a window read waits for the reader.
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000 * 2 + 30)
            while box.get() == nil, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            var outcome = FrameOutcome(id: frame.id)
            for written in await tee.drain() {
                if written.type == MessageType.privacyTombstone.rawValue {
                    outcome.tombstones += 1
                    if let reason = written.reason { outcome.tombstoneReasons.append(reason) }
                } else if written.type == MessageType.ocrEvent.rawValue
                    || written.type == MessageType.contextOcrEvent.rawValue {
                    outcome.events += 1
                    outcome.screenshotSealed = outcome.screenshotSealed || written.sealed
                }
            }
            switch box.get() {
            case .finalized: outcome.disposition = "finalized"
            case .retryableNoContent: outcome.disposition = "no_content"
            case nil: outcome.disposition = "timed_out"
            }
            outcomes.append(outcome)
            FileHandle.standardError.write(Data(
                "SyntheticCaptureFeed: frame \(frame.id): events=\(outcome.events) tombstones=\(outcome.tombstones) disposition=\(outcome.disposition)\n".utf8
            ))
        }
        await emitter.stopAndDrain()
        paddle?.stop()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = try encoder.encode(["frames": outcomes])
        if let reportPath {
            try report.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        } else {
            FileHandle.standardError.write(report)
        }
        try? FileHandle.standardOutput.synchronize()
    }

    /// One made-up window: a grey title bar with its title, then its lines,
    /// drawn at 2x as a Retina window is captured.
    private static func render(_ frame: Manifest.Frame) throws -> CVPixelBuffer {
        let scale: CGFloat = 2
        let widthPoints = CGFloat(frame.width ?? 1100)
        let heightPoints = CGFloat(frame.height ?? 700)
        let width = Int(widthPoints * scale)
        let height = Int(heightPoints * scale)
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &output) == kCVReturnSuccess,
              let buffer = output
        else {
            throw FeedError.render("pixel buffer for \(frame.id)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw FeedError.render("bitmap context for \(frame.id)")
        }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: widthPoints, height: heightPoints))
        // Title bar: 44 points at the top (CoreGraphics' origin is bottom-left).
        context.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: heightPoints - 44, width: widthPoints, height: 44))
        draw(frame.title, in: context, x: 96, baseline: heightPoints - 28, size: 14)
        var baseline = heightPoints - 96
        for line in frame.lines {
            if baseline < 24 { break }
            draw(line, in: context, x: 48, baseline: baseline, size: 19)
            baseline -= 34
        }
        return buffer
    }

    private static func draw(_ text: String, in context: CGContext, x: CGFloat, baseline: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
    }
}
