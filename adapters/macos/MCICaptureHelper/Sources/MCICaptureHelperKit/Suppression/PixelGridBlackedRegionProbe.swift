// SPDX-License-Identifier: TBD-private
//
// PixelGridBlackedRegionProbe — ADR-0013 §2 production implementation.
//
// LAUNCH-BLOCKER per AGENT_PROTOCOL §4 / R5. PROTECTED-SET per §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ WHAT THIS REPLACES                                                │
// │                                                                  │
// │ The Phase-1 helper shipped with `NoBlackedRegionYet` at          │
// │ `main.swift:155` — a deliberate stub that returned `false` on    │
// │ every frame. FairPlay playback + `NSWindowSharingType=.none`     │
// │ windows correctly fell to the §7 fail-safe catchall, so privacy  │
// │ was preserved, but the wire stream could not distinguish "OS     │
// │ blacked region" from "unknown classification." Step-2 §7 corpus  │
// │ PARTIAL PASS (PR #34, 2026-05-19) recorded this as a known gap;  │
// │ this file closes it.                                             │
// └──────────────────────────────────────────────────────────────────┘
//
// ## Why pixel sampling, not SCStream metadata
//
// ADR-0013 §2 mentions two acceptable approaches: (i) sample a small
// grid of pixels in the captured frame and check for a contiguous
// black region above threshold; (ii) ask SCStream for per-display
// exclusions via `SCContentSharingPicker` / `SCContentFilter` query
// APIs. Approach (ii) would be preferable because it carries zero
// pixel cost — but it is NOT available on macOS 26:
//
//   - `SCStreamFrameInfo` (the per-frame attachment dictionary)
//     exposes `status`, `displayTime`, `scaleFactor`, `contentRect`,
//     `contentScale`, `dirtyRects`, `screenRect`, `boundingRect`,
//     and `presenterOverlayContentRect`. There is no
//     `excludedRegion` / `blacked` / `protected` key.
//   - `SCContentSharingPicker` produces an `SCContentFilter` at
//     stream-construction time — this is the cascade §1 surface
//     (ADR-0013), not a per-frame signal.
//   - Apple's FairPlay / `NSWindowSharingType=.none` blacking is
//     transparent to capture clients: the OS hands the surface black
//     pixels and no metadata.
//
// macOS 26 therefore admits only approach (i). We use it.
//
// ## The probe input — the 9×8 grid we already compute
//
// `SCStreamCaptureSession.grayscale9x8(from:)` already reads a
// deterministic 9×8 = 72-pixel luminance grid out of every borrowed
// `CVPixelBuffer` to feed `SmartCaptureFilter`'s dHash dual-threshold
// (`CapturedSampleExtractor.computeDHash9x8`). The grid is a value
// type, `Sendable`, already in the callback hot path, and already
// allocated regardless of this probe — we reuse it here. The §2
// probe adds NO additional pixel read, NO additional pool retain,
// NO additional OS surface access. The surface-budget impact of
// turning on §2 detection is zero.
//
// ## Cost (the analytical bound)
//
// `update(grayscale:)` iterates the 72-byte grid once: one compare
// + one conditional increment per byte. This is O(constant) — the
// grid size is fixed by `CapturedSampleExtractor.dhashGridCount`.
// On Apple Silicon the call retires in well under one microsecond
// in practice; the ADR-0013 §2 hot-path budget is 100 µs/frame, so
// the headroom is ~100×. `hasBlackedRegion()` is a single locked
// read of a `Bool`. The perf test in
// `PixelGridBlackedRegionProbeTests` asserts the analytical bound +
// a wall-clock ceiling so a future refactor cannot regress to an
// O(frame) scan silently.
//
// ## What this is NOT
//
// - NOT a full-frame scan. The ADR-0013 §2 contract is "blacked
//   region in the frame's bounds matching a tracked window"; we
//   approximate via "the sampled 9×8 grid is overwhelmingly black."
//   This catches full-screen FairPlay playback and full-screen
//   `NSWindowSharingType=.none` windows — the test corpus targets in
//   ADR-0013 §7. It will MISS a small blacked overlay on an
//   otherwise busy desktop; those still fall to §3 / §4 / §7 (safe
//   direction — the cascade fail-safe handles them).
// - NOT a positive classifier. `hasBlackedRegion()` returning
//   `false` does not mean "no blacked region in the frame"; it means
//   "the sampled grid is not overwhelmingly black." The cascade
//   fail-safe handles "unknown" — a `false` from §2 ⇒ fall through
//   to §3 / §4 / §7.
// - NOT a tracked-window-bounds lookup. Ideal §2 detection consults
//   `NSWorkspace` for the geometry of `NSWindowSharingType=.none`
//   windows. That work depends on the Phase-2 context join; we ship
//   the pixel-grid approximation here and can refine it then. The
//   safe direction is preserved meanwhile.
//
// ## Failure-mode discipline
//
// If the probe has never been `update(grayscale:)`'d (no frame seen
// yet — session not yet started, or session paused) it returns
// `false`. The cascade then falls through to §3 / §4 / §7
// (fail-safe direction). The probe is NEVER allowed to default to
// `true`; "unknown" is not a §2 fire — ADR-0013 §3 / §7 lock that.
//
// ## Thread-safety
//
// `update(grayscale:)` is called from the `SCStreamOutput` callback
// on `SCStreamCaptureSession.sampleQueue`. `hasBlackedRegion()` is
// called from the cascade inside `SCStreamPipeline.process(...)` on
// a detached `Task`. An `NSLock` guards the single mutable byte
// (`lastResult`). The probe is `@unchecked Sendable` — the lock IS
// the contract.

import Foundation

/// Production `BlackedRegionProbe`. Stateful: the
/// `SCStreamOutput` callback pre-feeds it the synchronously-extracted
/// 9×8 luminance grid before the cascade runs on the frame; the
/// cascade then reads back the verdict via `hasBlackedRegion()`.
public final class PixelGridBlackedRegionProbe: BlackedRegionProbe, @unchecked Sendable {
    /// A pixel with luma ≤ this byte is treated as "black" for the
    /// purposes of §2. RGB(0,0,0) → 0; near-black UI chrome / dark
    /// antialiasing → 1–3; threshold of 4 keeps near-black pixels in
    /// without admitting "dark gray" UI as black.
    public let thresholdLuma: UInt8

    /// Fraction of the 72-pixel grid that must register "black" for
    /// the frame to be classified as a §2 blacked region.
    ///
    /// Default `0.85` ≈ 62 of 72 sampled pixels. Catches full-screen
    /// FairPlay playback and full-screen `NSWindowSharingType=.none`
    /// windows; misses smaller blacked overlays (which fall safely to
    /// §3 / §4 / §7). False-positive cost is bounded: it only
    /// relabels a tombstone reason from `7` to `2`; no
    /// pixel/text/metadata leaves the helper either way per the
    /// ADR-0013 §2 redaction-before-store guarantee.
    public let thresholdRatio: Double

    private let lock = NSLock()
    private var lastResult: Bool = false

    public init(thresholdLuma: UInt8 = 4, thresholdRatio: Double = 0.85) {
        precondition(
            thresholdRatio >= 0.0 && thresholdRatio <= 1.0,
            "thresholdRatio must be a fraction in [0, 1], got \(thresholdRatio)"
        )
        self.thresholdLuma = thresholdLuma
        self.thresholdRatio = thresholdRatio
    }

    /// Pre-feed the probe from the 9×8 grayscale grid extracted in
    /// the `SCStreamOutput` callback. MUST be called before the
    /// cascade runs on the same frame (the session does this in
    /// `stream(_:didOutputSampleBuffer:of:)`).
    ///
    /// O(`CapturedSampleExtractor.dhashGridCount`) — 72 iterations,
    /// each a single compare + conditional increment. Bounded
    /// constant work; never reads beyond the grid.
    public func update(grayscale grid: [UInt8]) {
        precondition(
            grid.count == CapturedSampleExtractor.dhashGridCount,
            "BlackedRegionProbe expects the dHash 9×8 grid (\(CapturedSampleExtractor.dhashGridCount) samples), got \(grid.count)"
        )
        let limit = thresholdLuma
        var blackCount = 0
        for v in grid where v <= limit {
            blackCount += 1
        }
        let ratio = Double(blackCount) / Double(grid.count)
        let result = ratio >= thresholdRatio
        lock.lock()
        lastResult = result
        lock.unlock()
    }

    /// Force the probe back to its fail-safe initial state
    /// (`hasBlackedRegion() == false`). Called by the session on
    /// start/stop so a stale flag from a prior session cannot bleed
    /// into the next one.
    public func reset() {
        lock.lock()
        lastResult = false
        lock.unlock()
    }

    /// Single locked read of a `Bool`. The cascade calls this once
    /// per state-transition decision. Returns the most-recent
    /// `update(grayscale:)` verdict, or `false` (fail-safe) if no
    /// update has happened yet.
    public func hasBlackedRegion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastResult
    }
}
