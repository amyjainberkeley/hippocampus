// SPDX-License-Identifier: TBD-private
//
// OCRResult / OCRLine — Sendable value types the OCR worker delivers
// back to its caller. Mirrors the shape Apple Vision's
// `VNRecognizedTextObservation` exposes (top-candidate text per line,
// normalized bounding box, confidence) but is value-typed so it can
// cross actor boundaries cleanly.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These types carry OCR'd text,
// which is USER CONTENT per ADR-0016 §4 invariant 1. They do NOT cross
// the IPC seam in this PR (P3.5 is helper-internal only); the wire
// surfacing lands at P3.6 alongside the `0x03 → 0x04` bump + the
// cascade-twice plumbing. CSO veto-gate on any change that lets these
// values reach the wire without re-running cascade §6 (OCR-time secret
// /PII regex) over the OCR'd text.

import CoreGraphics
import Foundation

/// One recognized line of text from Apple Vision OCR.
///
/// The bounding box is in normalized image coordinates (origin
/// lower-left per Vision's convention, units in [0, 1]). The
/// confidence is Vision's per-observation confidence in [0, 1].
public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let boundingBox: CGRect
    public let confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Result of one OCR job. `timedOut == true` ⇒ `recognizedLines` is
/// always empty (the worker drops the request before any partial
/// observation is materialized). An error from the underlying engine
/// resolves to `recognizedLines == []` with `timedOut == false` — the
/// caller cannot distinguish "no text" from "engine error" by design,
/// because either way nothing usable can flow downstream.
public struct OCRResult: Sendable, Equatable {
    public let recognizedLines: [OCRLine]
    public let durationMs: UInt64
    public let timedOut: Bool

    public init(
        recognizedLines: [OCRLine],
        durationMs: UInt64,
        timedOut: Bool
    ) {
        self.recognizedLines = recognizedLines
        self.durationMs = durationMs
        self.timedOut = timedOut
    }

    /// Convenience: empty result used on engine error / no input.
    public static let empty = OCRResult(
        recognizedLines: [],
        durationMs: 0,
        timedOut: false
    )
}
