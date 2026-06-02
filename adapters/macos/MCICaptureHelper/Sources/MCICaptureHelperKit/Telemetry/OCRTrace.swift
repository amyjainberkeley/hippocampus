// SPDX-License-Identifier: TBD-private
//
// OCRTrace — `MCI_OCR_TRACE=1` env-gated stderr trace for the
// cascade + post-allow OCR emit path.
//
// PR #226 §5.1 (2): "MCI_OCR_TRACE=1 debug-build stderr gate — when
// the env var is set, `OCRPostAllowEmitter.processAfterAllow` and
// `SuppressionCascade.decide` each emit ONE stderr line per call with
// bundle_id + AX outcome enum + cascade decision + OCR result length
// (no content)."
//
// PROTECTED-SET per AGENT_PROTOCOL §5. Content-free by construction:
// the only string surface is the bundle id (already cascade-attributed,
// already on the wire via `PrivacyTombstone.appBundle`), a decision
// enum, an optional AX backstop outcome, and an INTEGER ocr length.
// NEVER recognized text, NEVER window title or URL.
//
// Gated by env var read at process start — zero steady-state cost when
// off (one ProcessInfo lookup at first call, cached in a static let).
// Mirrors the existing `--probe-debug` discipline in main.swift.

import Foundation

/// `MCI_OCR_TRACE` env-var gate. True iff the env var is set to "1"
/// at process start. The eager initializer is intentional — we want
/// the check to be a single static-let-load on the hot path, not a
/// ProcessInfo call per cascade decision.
public enum OCRTrace {
    /// True iff `MCI_OCR_TRACE=1` is set in the process environment.
    /// One-time read at first access; subsequent reads are O(1) load.
    public static let isEnabled: Bool = {
        return ProcessInfo.processInfo.environment["MCI_OCR_TRACE"] == "1"
    }()

    /// Emit ONE trace line to stderr. No-op when `isEnabled` is false.
    /// The autoclosure is intentional — when off, we don't even pay
    /// for the line-construction cost. Format is fixed:
    ///
    ///     mci-helper: trace(<source>) <key>=<value> <key>=<value> ...
    ///
    /// where `<source>` distinguishes the call site (e.g.
    /// `cascade-decide`, `ocr-post-allow`). The key=value tail is
    /// caller-supplied; do NOT pass OCR text content or any user-
    /// visible string beyond the bundle id.
    public static func emit(_ source: String, _ keysAndValues: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "mci-helper: trace(\(source)) \(keysAndValues())\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
}
