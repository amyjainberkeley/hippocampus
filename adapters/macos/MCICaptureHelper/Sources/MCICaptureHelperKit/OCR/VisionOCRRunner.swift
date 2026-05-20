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
// ┌──────────────────────────────────────────────────────────────────┐
// │ THIS FILE IS A SCAFFOLD (P3.5).                                  │
// │                                                                  │
// │ It is reachable by the production helper binary ONLY through     │
// │ `VisionOCRWorker`, and `VisionOCRWorker` is NOT YET WIRED INTO   │
// │ `SCStreamCaptureSession.swift`. That wiring lands at P3.6 along  │
// │ with the wire bump `0x03 → 0x04` + cascade-twice plumbing. CSO   │
// │ veto-gate on the P3.6 PR. This PR exists in isolation so the     │
// │ §4 invariants are vacuously held (worker not invoked).           │
// └──────────────────────────────────────────────────────────────────┘
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

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognize(
        input: OCREngineInput,
        timeoutMs: Int
    ) async -> OCRResult {
        // UNVERIFIED — needs live macOS; do not claim working.
        let started = DispatchTime.now()
        let timeoutNanos = UInt64(max(1, timeoutMs)) * 1_000_000

        // Race the OCR perform against a wall-clock timeout. We do
        // NOT cancel the underlying VNRequest — Apple Vision does not
        // expose a stable cancellation primitive in current SDKs; the
        // observation result is simply discarded if it arrives after
        // the deadline. The bounded MPSC channel in `VisionOCRWorker`
        // caps the absolute number of in-flight Vision calls so a
        // timed-out call cannot pile up indefinitely.
        //
        // `OCREngineInput` is `@unchecked Sendable` (see the type doc):
        // CVPixelBuffer reference is single-owner here for the
        // duration of the call, then released.
        let languages = recognitionLanguages
        let capturedInput = input

        let resultFromVision: OCRResult? = await withTaskGroup(
            of: OCRResult?.self,
            returning: OCRResult?.self
        ) { group in
            group.addTask {
                await Self.runVisionPerform(
                    input: capturedInput,
                    languages: languages
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return nil  // sentinel: timed out
            }
            // The first completed task wins; cancel the loser.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
        let durationMs = UInt64(elapsedNanos / 1_000_000)

        if let r = resultFromVision {
            return OCRResult(
                recognizedLines: r.recognizedLines,
                durationMs: durationMs,
                timedOut: false
            )
        } else {
            return OCRResult(
                recognizedLines: [],
                durationMs: durationMs,
                timedOut: true
            )
        }
    }

    /// One synchronous Vision call wrapped in an async shell so the
    /// task group can race it against the timeout. Returns `nil` on
    /// any underlying error (mapped to the "engine error" arm of the
    /// `OCREngine` contract: `recognizedLines == []`, `timedOut ==
    /// false`).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    private static func runVisionPerform(
        input: OCREngineInput,
        languages: [String]
    ) async -> OCRResult? {
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
