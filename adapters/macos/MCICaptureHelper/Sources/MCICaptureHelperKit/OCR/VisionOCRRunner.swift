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
///   - `usesLanguageCorrection = true`
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
    ) { input, languages in
        Self.runVisionPerform(input: input, languages: languages)
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
            synchronousPerform: synchronousPerform
        )
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

    /// One synchronous Vision call executed by the serial lane. Any
    /// underlying error is mapped to the "engine error" arm of the
    /// `OCREngine` contract: `recognizedLines == []`, `timedOut ==
    /// false`).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    private static func runVisionPerform(
        input: OCREngineInput,
        languages: [String]
    ) -> OCRResult {
        // UNVERIFIED — needs live macOS; do not claim working.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = true
        request.regionOfInterest = input.roi

        let handler = VNImageRequestHandler(
            cvPixelBuffer: input.pixelBuffer,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            // Map any Vision error to the "engine error" arm —
            // recognizedLines == [], timedOut == false.
            return OCRResult(
                recognizedLines: [],
                durationMs: 0,
                timedOut: false
            )
        }

        let observations = request.results ?? []
        var lines: [OCRLine] = []
        lines.reserveCapacity(observations.count)
        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            lines.append(OCRLine(
                text: top.string,
                boundingBox: obs.boundingBox,
                confidence: obs.confidence
            ))
        }
        return OCRResult(
            recognizedLines: lines,
            durationMs: 0,  // overridden by caller using the outer wall-clock
            timedOut: false
        )
    }
}

/// A single-operation boundary around cancellation-insensitive Vision work.
///
/// A timed-out operation remains the lane's sole occupant until it really
/// returns. Later calls fail fast instead of enqueueing another pixel buffer
/// or consuming another thread. The late result is discarded by
/// `VisionOCRAttempt`, which resumes its continuation exactly once.
private final class VisionOCRExecutionLane: @unchecked Sendable {
    typealias SynchronousPerform = @Sendable (OCREngineInput, [String]) -> OCRResult

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
        return await withCheckedContinuation { continuation in
            let attempt = VisionOCRAttempt(continuation: continuation)

            queue.async { [self, attempt, input, languages] in
                guard attempt.beginSynchronousWork() else {
                    releaseClaim()
                    return
                }

                let rawResult = synchronousPerform(input, languages)
                let result = Self.result(rawResult, started: started)
                attempt.resolve(with: result)
                releaseClaim()
            }

            deadlineQueue.asyncAfter(
                deadline: .now() + .milliseconds(boundedTimeoutMs)
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
