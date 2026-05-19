// SPDX-License-Identifier: TBD-private
//
// CapturedSampleExtractor — the PURE, OS-free core of the in-callback
// extraction step (enabler PR-1).
//
// PROTECTED-SET per AGENT_PROTOCOL §5 (capture path / ADR-0013).
// LAUNCH-BLOCKER per AGENT_PROTOCOL §4 / R5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ WHY THIS FILE EXISTS                                              │
// │                                                                  │
// │ The live `SCStreamOutput` callback (`SCStreamCaptureSession`,    │
// │ all `// UNVERIFIED`) does exactly two things with the borrowed   │
// │ `CMSampleBuffer` / `IOSurface`, both SYNCHRONOUSLY inside the    │
// │ callback, and then lets the surface go:                          │
// │                                                                  │
// │   1. read the OS frame-status + dirty-rects + a 9×8 luminance    │
// │      grid out of the borrowed pixel buffer                       │
// │   2. fold that grid into a 64-bit dHash                          │
// │                                                                  │
// │ Step 2 — and the assembly of the `Sendable` value types that     │
// │ then cross into the async `SCStreamPipeline.process(...)` — is   │
// │ pure and lives HERE so it is unit-testable headlessly. The OS    │
// │ pixel-buffer read (step 1) stays in the `// UNVERIFIED` live     │
// │ session; only the already-extracted grid reaches this file.      │
// │                                                                  │
// │ Because every value produced here is a `Sendable` value type     │
// │ fully materialized from the borrowed buffer, NOTHING that        │
// │ crosses into the async pipeline references the IOSurface. PR-1   │
// │ also adds no retain and no encoder, so this path STRUCTURALLY    │
// │ CANNOT store a frame (Amendment 1 §3(c)/(d)).                    │
// └──────────────────────────────────────────────────────────────────┘

import Foundation

/// Pure, OS-free extraction helpers. No `ScreenCaptureKit`, no
/// `CoreVideo`, no `CoreMedia` import — by construction this file
/// touches no OS surface and is fully exercised by
/// `CapturedSampleExtractorTests`.
public enum CapturedSampleExtractor {
    /// The number of grayscale samples a dHash needs: a 9-wide × 8-tall
    /// grid (the standard difference-hash geometry — 8 horizontal
    /// comparisons per row × 8 rows = 64 bits).
    public static let dhashGridWidth = 9
    public static let dhashGridHeight = 8
    public static let dhashGridCount = 72 // 9 × 8

    /// Fold a 9×8 row-major grayscale grid into a 64-bit dHash.
    ///
    /// Bit `row*8 + col` is set iff the left sample is strictly brighter
    /// than its right neighbour (`grid[row*9+col] > grid[row*9+col+1]`).
    /// This is the McKeown & Buchanan difference-hash variant the
    /// `DHash` dual-threshold filter (`DHash.swift`) consumes.
    ///
    /// Pure: deterministic, no OS, no allocation beyond the return
    /// value. The caller (the `// UNVERIFIED` live callback) is
    /// responsible for producing the grid from the borrowed pixel
    /// buffer synchronously and then dropping the surface.
    public static func computeDHash9x8(grayscale grid: [UInt8]) -> DHash {
        precondition(
            grid.count == dhashGridCount,
            "dHash needs a 9×8 grayscale grid (\(dhashGridCount) samples), got \(grid.count)"
        )
        var bits: UInt64 = 0
        var bitIndex: UInt64 = 0
        for row in 0 ..< dhashGridHeight {
            let base = row * dhashGridWidth
            for col in 0 ..< (dhashGridWidth - 1) {
                if grid[base + col] > grid[base + col + 1] {
                    bits |= (UInt64(1) << bitIndex)
                }
                bitIndex += 1
            }
        }
        return DHash(bits: bits)
    }

    /// Assemble the `Sendable` `CandidateFrame` that crosses into the
    /// async pipeline. Thin by design: its job is to make explicit that
    /// every field is a value materialized synchronously in-callback —
    /// nothing here borrows the surface, so the value can safely outlive
    /// the callback.
    public static func makeCandidateFrame(
        userIdle: Bool,
        frameStatusComplete: Bool,
        dirtyRects: [DirtyRect],
        dhash: DHash,
        priorDhash: DHash?
    ) -> CandidateFrame {
        CandidateFrame(
            userIdle: userIdle,
            frameStatusComplete: frameStatusComplete,
            dirtyRects: dirtyRects,
            dhash: dhash,
            priorDhash: priorDhash
        )
    }

    /// Assemble the `Sendable` `WorkflowContext` the cascade inspects.
    /// Same contract as `makeCandidateFrame`: value-only, no surface.
    public static func makeWorkflowContext(
        appBundleId: String?,
        windowTitle: String?,
        url: String?,
        pageText: String?
    ) -> WorkflowContext {
        WorkflowContext(
            appBundleId: appBundleId,
            windowTitle: windowTitle,
            url: url,
            pageText: pageText
        )
    }
}
