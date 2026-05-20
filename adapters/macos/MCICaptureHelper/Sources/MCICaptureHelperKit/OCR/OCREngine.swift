// SPDX-License-Identifier: TBD-private
//
// OCREngine — the indirection seam between `VisionOCRWorker` (queue +
// drop-oldest + timeout discipline) and the actual OCR runtime.
// Production impl lives in `VisionOCRRunner.swift` and uses Apple
// Vision (`VNRecognizeTextRequest`). Headless tests inject a stub that
// returns canned `OCRResult`s without touching CoreVideo or Vision.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. The seam exists so that the
// worker's queue/drop/timeout invariants (ADR-0016 §1.1) are
// exercisable headlessly — the same headless-testability discipline
// PRs #36/#37/#38 used for `SecureEventInputProbe` /
// `AXSecureSubroleProbe` / `BlackedRegionProbe`.

import CoreGraphics
import CoreVideo
import Foundation

/// One OCR job's inputs, packaged into a single Sendable transferable
/// so the queue / worker can shuttle them across actor isolation
/// without each call site re-declaring the @unchecked Sendable escape
/// hatch. `CVPixelBuffer` is a CoreVideo class type; its lifetime is
/// managed by the SCStream callback that originated it — the worker
/// holds the buffer by strong reference for the duration of the OCR
/// call, then releases.
///
/// `@unchecked Sendable`: CVPixelBuffer is reference-typed but Vision
/// reads it on a hidden GCD queue; the worker guarantees exclusive
/// ownership while the job is in-flight. The wrapper exists to make
/// that contract explicit at the type level.
public struct OCREngineInput: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Region of interest in normalized image coordinates
    /// (origin lower-left, units in [0, 1]) — the dirty-rect bounding
    /// rect per ADR-0016 §1.1. The caller normalizes; the engine
    /// passes it through to `VNRecognizeTextRequest.regionOfInterest`.
    public let roi: CGRect

    public init(pixelBuffer: CVPixelBuffer, roi: CGRect) {
        self.pixelBuffer = pixelBuffer
        self.roi = roi
    }
}

/// The OCR runtime indirection. `VisionOCRWorker` calls into this; the
/// production impl wraps Apple Vision; the test stub returns canned
/// results. `Sendable` is required because the worker dispatches the
/// call from inside its actor and awaits on the result.
public protocol OCREngine: Sendable {
    /// Run OCR on `input.pixelBuffer` constrained to `input.roi`.
    ///
    /// MUST return within `timeoutMs` wall-clock ms; on timeout the
    /// engine returns `OCRResult(recognizedLines: [], durationMs:
    /// ≈timeoutMs, timedOut: true)`. On any other failure
    /// (extraction error, language model missing, etc.) it returns
    /// `OCRResult(recognizedLines: [], durationMs: <observed>,
    /// timedOut: false)` — the caller cannot distinguish "no text"
    /// from "engine error" (intentional: either way nothing usable can
    /// flow downstream).
    ///
    /// MUST NOT throw. The worker treats a thrown error as a programmer
    /// bug, not a runtime failure.
    func recognize(input: OCREngineInput, timeoutMs: Int) async -> OCRResult
}
