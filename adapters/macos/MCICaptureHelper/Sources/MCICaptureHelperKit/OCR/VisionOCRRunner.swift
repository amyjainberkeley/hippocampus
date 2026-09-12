// SPDX-License-Identifier: TBD-private
//
// VisionOCRRunner — production `OCREngine` implementation that runs
// Apple Vision's `VNRecognizeTextRequest` on a borrowed
// `CVPixelBuffer` with a normalized ROI and a wall-clock timeout.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. This file is on-device-only by
// construction:
//   - Apple Vision is local; no network call is made.
//   - The pixel buffer never leaves this process.
//   - The recognized text is the worker's responsibility to feed
//     through the cascade twice (P3.6) before it crosses the IPC seam.
//
// `VisionOCRWorker` is the only production caller. The runner puts the
// synchronous, cancellation-insensitive Vision request on one serial lane;
// a timeout publishes independently and quarantines that lane until the
// underlying request really returns.
//
// Cites ADR-0016 §1.1 (Apple Vision + dirty-rect ROI scoping).

import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Production `OCREngine` over Apple Vision (`VNRecognizeTextRequest`).
///
/// Configuration follows ADR-0016 §1.1:
///   - `recognitionLevel = .accurate`
///   - `usesLanguageCorrection = false` preserves code and identifier spelling
///   - `recognitionLanguages = ["en-US"]` (configurable)
///   - `automaticallyDetectsLanguage = true`
///
/// The ROI is set to the caller-supplied normalized rect (the dirty
/// -rect bounding rect per ADR-0016 §1.1 — never the full frame).
///
/// `// UNVERIFIED — needs live macOS; do not claim working`. Apple
/// Vision's request lifecycle runs on hidden GCD queues; we observe
/// only the result. Real-machine behavior is verified by the P3.11
/// live-Mac audit (HUMAN-ONLY per AGENT_PROTOCOL §9).
public struct VisionOCRRunner: OCREngine {
    /// Languages to hint the recognizer with. Vision still attempts
    /// auto-detection (`automaticallyDetectsLanguage = true`); this
    /// list biases the language model. Default `["en-US"]` per
    /// ADR-0016 §1.1; per-user override is a Phase 4 onboarding-UX
    /// concern, not Phase 3.
    public let recognitionLanguages: [String]

    private let executionLane: VisionOCRExecutionLane

    private static let sharedExecutionLane = VisionOCRExecutionLane(
        label: "com.hippocampus.capture.vision-ocr"
    ) { input, languages, deadline in
        Self.runVisionPerform(input: input, languages: languages, deadline: deadline)
    }

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
        self.executionLane = Self.sharedExecutionLane
    }

    /// Package-only seam for the runnable cancellation fixture. The
    /// production initializer always uses Apple Vision on the shared lane.
    package init(
        recognitionLanguages: [String] = ["en-US"],
        synchronousPerform: @escaping @Sendable (OCREngineInput, [String]) -> OCRResult
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.executionLane = VisionOCRExecutionLane(
            label: "com.hippocampus.capture.vision-ocr.fixture",
            synchronousPerform: { input, languages, _ in synchronousPerform(input, languages) }
        )
    }

    /// Real Vision on an isolated lane with content-free per-pass measurements
    /// for synthetic benchmarks. The production initializer remains unchanged.
    package init(regionDidFinish: @escaping @Sendable (CGRect, UInt64) -> Void) {
        self.recognitionLanguages = ["en-US"]
        self.executionLane = VisionOCRExecutionLane(
            label: "com.hippocampus.capture.vision-ocr.benchmark"
        ) { input, languages, deadline in
            Self.runVisionPerform(input: input, languages: languages, deadline: deadline, regionDidFinish: regionDidFinish)
        }
    }

    /// Exercises the production region loop without changing the lane's real deadline.
    package init(
        regionNow: @escaping @Sendable () -> DispatchTime = { .now() },
        synchronousRegionPerform: @escaping @Sendable (OCREngineInput, [String], CGRect) throws -> [OCRLine]
    ) {
        self.recognitionLanguages = ["en-US"]
        self.executionLane = VisionOCRExecutionLane(
            label: "com.hippocampus.capture.vision-ocr.fixture-regions"
        ) { input, languages, deadline in
            Self.runRegionLoop(
                regions: Self.recognitionRegions(for: input), deadline: deadline, now: regionNow,
                perform: { try synchronousRegionPerform(input, languages, $0) },
                makeLine: { line, _ in line }
            )
        }
    }

    /// Fixture cleanup only; waiting never submits another recognition request.
    package func waitUntilIdle(timeoutMs: Int) async -> Bool {
        await executionLane.waitUntilIdle(timeoutMs: timeoutMs)
    }

    public func waitUntilAvailable(timeoutMs: Int) async -> Bool {
        await executionLane.waitUntilIdle(timeoutMs: timeoutMs)
    }

    public func recognize(
        input: OCREngineInput,
        timeoutMs: Int
    ) async -> OCRResult {
        // UNVERIFIED — needs live macOS; do not claim working.
        return await executionLane.recognize(
            input: input,
            languages: recognitionLanguages,
            timeoutMs: timeoutMs
        )
    }

    /// Bounded synchronous Vision calls executed by the serial lane. Any
    /// underlying error is mapped to the "engine error" arm of the
    /// `OCREngine` contract: `recognizedLines == []`, `timedOut ==
    /// false`).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    private static func runVisionPerform(
        input: OCREngineInput,
        languages: [String],
        deadline: DispatchTime,
        regionDidFinish: (@Sendable (CGRect, UInt64) -> Void)? = nil
    ) -> OCRResult {
        // UNVERIFIED — needs live macOS; do not claim working.
        let regions = recognitionRegions(for: input)
        guard !regions.isEmpty else {
            return OCRResult(recognizedLines: [], durationMs: 0, timedOut: false)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction inserts prose-style spaces into code and identifiers.
        // Preserve recognition output; the original screenshot remains the evidence.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(
            cvPixelBuffer: input.pixelBuffer,
            orientation: .up,
            options: [:]
        )
        return runRegionLoop(
            regions: regions, deadline: deadline, regionDidFinish: regionDidFinish,
            perform: { region in
                request.regionOfInterest = region
                try handler.perform([request])
                return request.results ?? []
            },
            makeLine: { observation, region in
                guard let top = observation.topCandidates(1).first else { return nil }
                // Vision reports ROI-relative boxes. Keep image coordinates
                // without removing text needed by the post-OCR privacy check.
                let box = observation.boundingBox
                let imageBox = CGRect(
                    x: region.minX + box.minX * region.width,
                    y: region.minY + box.minY * region.height,
                    width: box.width * region.width,
                    height: box.height * region.height
                ).intersection(region)
                return OCRLine(
                    text: top.string,
                    boundingBox: imageBox.isNull ? CGRect(origin: region.origin, size: .zero) : imageBox,
                    confidence: top.confidence
                )
            }
        )
    }

    private static func runRegionLoop<Observation>(
        regions: [CGRect],
        deadline: DispatchTime,
        now: () -> DispatchTime = { .now() },
        regionDidFinish: (@Sendable (CGRect, UInt64) -> Void)? = nil,
        perform: (CGRect) throws -> [Observation],
        makeLine: (Observation, CGRect) -> OCRLine?
    ) -> OCRResult {
        guard !regions.isEmpty else {
            return OCRResult(recognizedLines: [], durationMs: 0, timedOut: false)
        }
        var accumulated = OCRLineAccumulator()
        var longestPerformNs: UInt64 = 0
        for (index, region) in regions.enumerated() {
            // A timeout quarantines the current perform, but must not start
            // more Vision requests or publish partially accumulated text.
            let started = now()
            guard started < deadline else {
                return OCRResult(recognizedLines: [], durationMs: 0, timedOut: true)
            }
            // Once there is text to preserve, reserve twice the slowest perform
            // cost before optional supplements. An empty scan can keep trying
            // within the deadline, even if cold model startup was expensive.
            if index > 0 && !accumulated.lines.isEmpty
                && (deadline.uptimeNanoseconds - started.uptimeNanoseconds) / 2 <= longestPerformNs {
                break
            }
            let observations: [Observation]
            do {
                observations = try perform(region)
            } catch {
                return OCRResult(recognizedLines: [], durationMs: 0, timedOut: false)
            }
            let performNs = now().uptimeNanoseconds - started.uptimeNanoseconds
            longestPerformNs = max(longestPerformNs, performNs)
            regionDidFinish?(region, performNs)
            for observation in observations {
                if let line = makeLine(observation, region) { accumulated.append(line) }
            }
        }
        guard now() < deadline else {
            return OCRResult(recognizedLines: [], durationMs: 0, timedOut: true)
        }
        // Every completed pass must remain contiguous and in Vision's order.
        // Even a repeated label can begin a supplemental multiline secret.
        return OCRResult(
            recognizedLines: accumulated.lines,
            durationMs: 0,  // overridden by caller using the outer wall-clock
            timedOut: false
        )
    }

    /// Short 12-pixel labels disappear on a 1920-pixel canvas even with
    /// minimumTextHeight == 0. Subregions recover them without resampling.
    /// Keep the original pass for long lines; add at most four overlapping
    /// subregions, all strictly within the already admitted ROI and buffer.
    internal static func recognitionRegions(for input: OCREngineInput) -> [CGRect] {
        let roi = input.roi
        guard roi.origin.x.isFinite, roi.origin.y.isFinite,
              roi.size.width.isFinite, roi.size.height.isFinite,
              roi.size.width > 0, roi.size.height > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(roi)
        else { return [] }

        let columns = roi.width * CGFloat(CVPixelBufferGetWidth(input.pixelBuffer)) > 960 ? 2 : 1
        let rows = roi.height * CGFloat(CVPixelBufferGetHeight(input.pixelBuffer)) > 960 ? 2 : 1
        guard columns > 1 || rows > 1 else { return [roi] }

        var regions = [roi]
        for row in 0..<rows {
            for column in 0..<columns {
                regions.append(CGRect(
                    x: roi.minX + CGFloat(column) * roi.width * 0.45,
                    y: roi.minY + CGFloat(row) * roi.height * 0.45,
                    width: roi.width * (columns == 1 ? 1 : 0.55),
                    height: roi.height * (rows == 1 ? 1 : 0.55)
                ).intersection(roi))
            }
        }
        return regions
    }
}

/// Append complete passes in order, including repeated lines. Deduplication
/// can destroy a multiline secret found only by a supplemental pass.
internal struct OCRLineAccumulator {
    private(set) var lines: [OCRLine] = []

    mutating func append(_ line: OCRLine) {
        lines.append(line)
    }
}

/// A single-operation boundary around cancellation-insensitive Vision work.
///
/// A timed-out operation remains the lane's sole occupant until it really
/// returns. Later calls fail fast instead of enqueueing another pixel buffer
/// or consuming another thread. The late result is discarded by
/// `VisionOCRAttempt`, which resumes its continuation exactly once.
final class VisionOCRExecutionLane: @unchecked Sendable {
    typealias SynchronousPerform = @Sendable (OCREngineInput, [String], DispatchTime) -> OCRResult

    private let queue: DispatchQueue
    private let deadlineQueue: DispatchQueue
    private let stateLock = NSLock()
    private let synchronousPerform: SynchronousPerform
    private var occupied = false

    init(label: String, synchronousPerform: @escaping SynchronousPerform) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.deadlineQueue = DispatchQueue(label: "\(label).deadline", qos: .userInitiated)
        self.synchronousPerform = synchronousPerform
    }

    func recognize(
        input: OCREngineInput,
        languages: [String],
        timeoutMs: Int
    ) async -> OCRResult {
        let started = DispatchTime.now()
        guard claim() else {
            return Self.timeoutResult(started: started)
        }

        let boundedTimeoutMs = max(1, timeoutMs)
        let deadline = started + .milliseconds(boundedTimeoutMs)
        return await withCheckedContinuation { continuation in
            let attempt = VisionOCRAttempt(continuation: continuation)

            queue.async { [self, attempt, input, languages] in
                guard attempt.beginSynchronousWork() else {
                    releaseClaim()
                    return
                }

                let rawResult = synchronousPerform(input, languages, deadline)
                let result = Self.result(rawResult, started: started)
                attempt.resolve(with: result)
                releaseClaim()
            }

            deadlineQueue.asyncAfter(
                deadline: deadline
            ) {
                attempt.resolve(with: Self.timeoutResult(started: started))
            }
        }
    }

    private func claim() -> Bool {
        stateLock.withLock {
            guard !occupied else { return false }
            occupied = true
            return true
        }
    }

    func waitUntilIdle(timeoutMs: Int) async -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(max(0, timeoutMs))
        while stateLock.withLock({ occupied }) {
            let now = DispatchTime.now()
            guard now < deadline, !Task.isCancelled else { return false }
            do {
                try await Task.sleep(nanoseconds: min(5_000_000, deadline.uptimeNanoseconds - now.uptimeNanoseconds))
            } catch {
                return false
            }
        }
        return true
    }

    private func releaseClaim() {
        stateLock.withLock {
            precondition(occupied, "Vision OCR lane released without an active operation")
            occupied = false
        }
    }

    private static func result(_ rawResult: OCRResult, started: DispatchTime) -> OCRResult {
        OCRResult(
            recognizedLines: rawResult.recognizedLines,
            durationMs: elapsedMilliseconds(since: started),
            timedOut: rawResult.timedOut
        )
    }

    private static func timeoutResult(started: DispatchTime) -> OCRResult {
        OCRResult(
            recognizedLines: [],
            durationMs: elapsedMilliseconds(since: started),
            timedOut: true
        )
    }

    private static func elapsedMilliseconds(since started: DispatchTime) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return (now &- started.uptimeNanoseconds) / 1_000_000
    }
}

/// Races one serial operation against its deadline without structured
/// concurrency waiting for the cancellation-insensitive loser.
private final class VisionOCRAttempt: @unchecked Sendable {
    private enum State {
        case waiting
        case running
        case resolved
    }

    private let lock = NSLock()
    private var state: State = .waiting
    private var continuation: CheckedContinuation<OCRResult, Never>?

    init(continuation: CheckedContinuation<OCRResult, Never>) {
        self.continuation = continuation
    }

    func beginSynchronousWork() -> Bool {
        lock.withLock {
            guard state == .waiting else { return false }
            state = .running
            return true
        }
    }

    func resolve(with result: OCRResult) {
        let continuationToResume: CheckedContinuation<OCRResult, Never>? = lock.withLock {
            guard state != .resolved else { return nil }
            state = .resolved
            defer { continuation = nil }
            return continuation
        }
        continuationToResume?.resume(returning: result)
    }
}
