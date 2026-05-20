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
// ## STEP-2-FINDING-006 — why a second detection path
//
// The original `thresholdRatio = 0.85` path catches full-display
// black: it fires only when ≥62 of the 72 sampled grid cells register
// black. That works for full-screen `NSWindowSharingType=.none`
// windows and for FairPlay playback that fills the *display*.
// However — Apple's FairPlay protection scopes the OS black-out to
// the video surface itself (the rectangular hardware overlay plane),
// not the whole display. Even when the user toggles TV.app, Safari,
// or QuickTime to full-screen, the menu bar, HUD, cursor, and any
// chrome around the video surface remain visible to capture clients.
// The 9×8 grid samples 72 pixels evenly across the frame; in this
// regime ~40-60% of grid cells land inside the black FairPlay
// rectangle and ~40-60% land in non-black chrome. The 0.85 ratio
// can NEVER be reached on real-world FairPlay rendering — the
// rectangle is the wrong shape, not too small.
//
// (Sources: Daring Fireball "Why Can't We Screenshot DRM-Protected
// Video"; Apple Developer Forums #63725; Screenify Studio
// 2026-04-23. Confirmed locally with `screencapture -x` of a
// FairPlay full-screen playback: Terminal chrome at top, browser/
// desktop edges around the rectangle, solid-black FairPlay
// rectangle in the centre.)
//
// We keep the existing 0.85 ratio check as a regression-safe fast
// path — full-display black still fires there — and add a second
// path that runs only when the fast path comes back negative. The
// second path looks for a single contiguous near-black region whose
// **bounding box** has video-like aspect ratio + non-trivial area
// in the 9×8 grid. Two predicates:
//
//   1. `cellsInBBox ≥ 18` — at least 25% of the 72 grid cells lie
//      inside the bbox of the largest connected black component.
//      A FairPlay rectangle that covers a meaningful portion of
//      the display will trivially clear this.
//   2. `aspect ∈ [1.3, 2.4]` — covers the standard consumer-video
//      aspect ratios: 16:10 (1.60), 16:9 (1.78), 21:9 (2.33). A
//      thin sidebar (aspect ≪ 1) or a menu-bar strip (aspect ≫ 2.4)
//      will not qualify.
//
// Cost is still O(72): flood-fill on a 9×8 grid visits each cell at
// most once and pushes/pops at most 72 indices onto a fixed-capacity
// stack. The combined fast-path-then-flood-fill update remains well
// under the ADR-0013 §2 hot-path budget of 100 µs/frame.
//
// **Privacy direction.** This is a STRICTLY-MORE-REDACTION change.
// The existing positive path is preserved; the new path can only
// add positive verdicts. No frame can move from `.suppress` to
// `.allow` as a result of this code. A false positive merely
// relabels a frame's tombstone from `reason=7` (failsafe-unknown)
// to `reason=2` (os-blacked-region) — same `.suppress`, same lack
// of leak, just a more specific reason byte. The cascade itself is
// untouched (this PR does not modify ordering, the
// `BlackedRegionProbe` protocol, or the §2 slot).
//
// ## What this is NOT
//
// - NOT a full-frame scan. The ADR-0013 §2 contract is "blacked
//   region in the frame's bounds matching a tracked window"; we
//   approximate via "the sampled 9×8 grid is overwhelmingly black
//   OR contains a video-like rectangle of black." This catches
//   full-screen `NSWindowSharingType=.none` windows AND the
//   real-world FairPlay overlay-plane rendering described above.
//   It will MISS a small blacked overlay on an otherwise busy
//   desktop; those still fall to §3 / §4 / §7 (safe direction —
//   the cascade fail-safe handles them).
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

    /// Minimum number of grid cells the largest connected-black
    /// component's *bounding box* must cover for the contiguous-
    /// rectangle path (STEP-2-FINDING-006) to fire. 18 of 72 = 25%
    /// of the grid; below this is too small to be a video overlay
    /// plane in any practical sense.
    public let rectMinCells: Int

    /// Inclusive aspect-ratio window (`bbox_width / bbox_height`)
    /// that the contiguous-rectangle path treats as video-like.
    /// Defaults bracket the standard consumer-video ratios:
    ///   16:10 → 1.60
    ///   16:9  → 1.78
    ///   21:9  → 2.33
    /// Tall sidebars (aspect ≪ 1) and menu-bar strips (aspect ≫ 2.4)
    /// fail this check.
    public let rectAspectMin: Double
    public let rectAspectMax: Double

    private let lock = NSLock()
    private var lastResult: Bool = false

    public init(
        thresholdLuma: UInt8 = 4,
        thresholdRatio: Double = 0.85,
        rectMinCells: Int = 18,
        rectAspectMin: Double = 1.3,
        rectAspectMax: Double = 2.4
    ) {
        precondition(
            thresholdRatio >= 0.0 && thresholdRatio <= 1.0,
            "thresholdRatio must be a fraction in [0, 1], got \(thresholdRatio)"
        )
        precondition(
            rectMinCells >= 0 && rectMinCells <= CapturedSampleExtractor.dhashGridCount,
            "rectMinCells must lie in [0, \(CapturedSampleExtractor.dhashGridCount)], got \(rectMinCells)"
        )
        precondition(
            rectAspectMin > 0 && rectAspectMax >= rectAspectMin,
            "rectAspect window must satisfy 0 < min ≤ max, got [\(rectAspectMin), \(rectAspectMax)]"
        )
        self.thresholdLuma = thresholdLuma
        self.thresholdRatio = thresholdRatio
        self.rectMinCells = rectMinCells
        self.rectAspectMin = rectAspectMin
        self.rectAspectMax = rectAspectMax
    }

    /// Pre-feed the probe from the 9×8 grayscale grid extracted in
    /// the `SCStreamOutput` callback. MUST be called before the
    /// cascade runs on the same frame (the session does this in
    /// `stream(_:didOutputSampleBuffer:of:)`).
    ///
    /// Bounded O(`CapturedSampleExtractor.dhashGridCount`) — two
    /// linear passes (count + flood-fill) over the 72-byte grid.
    /// The flood-fill visits each cell at most once and pushes at
    /// most 72 indices onto a fixed-capacity stack. Combined cost
    /// stays well inside the ADR-0013 §2 100 µs/frame budget.
    public func update(grayscale grid: [UInt8]) {
        precondition(
            grid.count == CapturedSampleExtractor.dhashGridCount,
            "BlackedRegionProbe expects the dHash 9×8 grid (\(CapturedSampleExtractor.dhashGridCount) samples), got \(grid.count)"
        )

        // Fast path: whole-display black (preserves prior behavior).
        // Catches `NSWindowSharingType=.none` covering the full
        // display and FairPlay rendered onto a black background that
        // fills the frame. Regression-safe — no frame that previously
        // returned `true` here can return anything else now.
        let limit = thresholdLuma
        var blackCount = 0
        for v in grid where v <= limit {
            blackCount += 1
        }
        let ratio = Double(blackCount) / Double(grid.count)
        var result = ratio >= thresholdRatio

        // Slow path (STEP-2-FINDING-006): contiguous video-shaped
        // black rectangle inside a frame with non-black chrome.
        // Only runs when the fast path returned negative — so this
        // path can only *add* positive verdicts (strictly-more-
        // redaction direction). On any internal anomaly the
        // detector returns `false`, leaving the fast path's negative
        // verdict in place — fail-safe direction preserved.
        if !result {
            result = detectVideoLikeRectangle(grid: grid)
        }

        lock.lock()
        lastResult = result
        lock.unlock()
    }

    /// Flood-fill the 9×8 grid for connected-black components
    /// (4-connectivity). For the largest component, compute its
    /// bounding box and return `true` iff the bbox covers at least
    /// `rectMinCells` of the grid AND its aspect ratio falls inside
    /// `[rectAspectMin, rectAspectMax]`.
    ///
    /// O(72) worst case: each cell is pushed onto the stack at most
    /// once and popped at most once. Bounded constant work, no heap
    /// allocation beyond fixed-size local buffers.
    private func detectVideoLikeRectangle(grid: [UInt8]) -> Bool {
        let width = CapturedSampleExtractor.dhashGridWidth
        let height = CapturedSampleExtractor.dhashGridHeight
        let count = grid.count
        // Defensive: if the grid somehow shrank past the precondition
        // (it cannot in production; the precondition fires first),
        // fail closed by returning negative — never widen to true.
        guard count == width * height, count > 0 else { return false }

        let limit = thresholdLuma
        var visited = [Bool](repeating: false, count: count)

        var bestSize = 0
        var bestMinX = 0
        var bestMinY = 0
        var bestMaxX = 0
        var bestMaxY = 0

        var stack: [Int] = []
        stack.reserveCapacity(count)

        for startIdx in 0 ..< count {
            if visited[startIdx] { continue }
            if grid[startIdx] > limit { continue }

            stack.removeAll(keepingCapacity: true)
            stack.append(startIdx)
            visited[startIdx] = true

            let sx = startIdx % width
            let sy = startIdx / width
            var minX = sx, maxX = sx, minY = sy, maxY = sy
            var size = 0

            while let idx = stack.popLast() {
                size += 1
                let x = idx % width
                let y = idx / width
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }

                if x > 0 {
                    let n = idx - 1
                    if !visited[n] && grid[n] <= limit {
                        visited[n] = true
                        stack.append(n)
                    }
                }
                if x < width - 1 {
                    let n = idx + 1
                    if !visited[n] && grid[n] <= limit {
                        visited[n] = true
                        stack.append(n)
                    }
                }
                if y > 0 {
                    let n = idx - width
                    if !visited[n] && grid[n] <= limit {
                        visited[n] = true
                        stack.append(n)
                    }
                }
                if y < height - 1 {
                    let n = idx + width
                    if !visited[n] && grid[n] <= limit {
                        visited[n] = true
                        stack.append(n)
                    }
                }
            }

            if size > bestSize {
                bestSize = size
                bestMinX = minX
                bestMinY = minY
                bestMaxX = maxX
                bestMaxY = maxY
            }
        }

        if bestSize == 0 { return false }

        let bboxW = bestMaxX - bestMinX + 1
        let bboxH = bestMaxY - bestMinY + 1
        let cellsInBBox = bboxW * bboxH
        if cellsInBBox < rectMinCells { return false }

        let aspect = Double(bboxW) / Double(bboxH)
        return aspect >= rectAspectMin && aspect <= rectAspectMax
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
