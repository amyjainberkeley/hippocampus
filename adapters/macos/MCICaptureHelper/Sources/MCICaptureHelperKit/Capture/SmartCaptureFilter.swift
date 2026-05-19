// SPDX-License-Identifier: TBD-private
//
// SmartCaptureFilter — the four-stage filter chain that gates whether a
// candidate frame becomes a state-transition event.
//
// Per DESIGN.md §5.2 + RESEARCH_DIGEST Stream A:
//
//   idle-gate  → frame-status  → dirty-rect  → dHash dual-threshold
//
// Each stage is cheap; a frame must pass all four to be considered new
// content worth running through the suppression cascade and the encode
// pipeline. The chain is `Sendable` and exercises every stage on the
// caller's frame-delivery thread (the SCStream callback thread in
// production; an XCTest thread in tests).

import Foundation

/// Inputs to the filter — what the SCStream callback delivers.
public struct CandidateFrame: Sendable, Equatable {
    /// True iff `last-input-idle` (DESIGN.md §5.2) says the user has been
    /// inactive past the helper's idle threshold. The idle gate is the
    /// authoritative idle signal; `SCFrameStatus.idle` alone is NOT
    /// trustworthy (RESEARCH_DIGEST Stream A correction).
    public let userIdle: Bool

    /// The OS-reported frame status.
    public let frameStatusComplete: Bool

    /// Pixels that changed since the prior delivered frame.
    public let dirtyRects: [DirtyRect]

    /// Perceptual hash of the current frame, computed by the caller.
    public let dhash: DHash

    /// Perceptual hash of the prior delivered frame, or `nil` for the
    /// very first frame.
    public let priorDhash: DHash?

    public init(
        userIdle: Bool,
        frameStatusComplete: Bool,
        dirtyRects: [DirtyRect],
        dhash: DHash,
        priorDhash: DHash?
    ) {
        self.userIdle = userIdle
        self.frameStatusComplete = frameStatusComplete
        self.dirtyRects = dirtyRects
        self.dhash = dhash
        self.priorDhash = priorDhash
    }
}

/// A rectangle of changed pixels (mirrors `core::ipc::DirtyRect`).
public struct DirtyRect: Sendable, Equatable {
    public let x: UInt32
    public let y: UInt32
    public let width: UInt32
    public let height: UInt32

    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// What the filter decided about a candidate frame.
public enum FilterDecision: Sendable, Equatable {
    /// User is idle (no input activity for past N seconds); skip the
    /// whole pipeline.
    case dropIdle
    /// OS frame status reported not-complete (suspended / stopped / pure
    /// idle); skip.
    case dropStatus
    /// No dirty rects — nothing changed.
    case dropNoDirtyRects
    /// dHash dual-threshold says drop (near-duplicate).
    case dropNearDuplicate
    /// dHash dual-threshold says tie-break; for now forward to encode
    /// (the safer side; SSIM tie-breaker lands Phase-1 cycle 2+).
    case forwardTieBreak
    /// All four stages passed — genuine new content.
    case forward
}

/// The four-stage filter chain.
public struct SmartCaptureFilter: Sendable {
    private let thresholds: DHashThresholds

    public init(thresholds: DHashThresholds = .default) {
        self.thresholds = thresholds
    }

    /// Apply the filter to a candidate frame.
    public func decide(frame: CandidateFrame) -> FilterDecision {
        // Stage 1 — idle gate.
        if frame.userIdle {
            return .dropIdle
        }
        // Stage 2 — frame status.
        if !frame.frameStatusComplete {
            return .dropStatus
        }
        // Stage 3 — dirty rects.
        if frame.dirtyRects.isEmpty {
            return .dropNoDirtyRects
        }
        // Stage 4 — dHash dual-threshold. The very first frame
        // (`priorDhash == nil`) always forwards; we have no prior to
        // compare against.
        guard let prior = frame.priorDhash else {
            return .forward
        }
        let distance = frame.dhash.distance(to: prior)
        switch thresholds.decide(distance: distance) {
        case .drop: return .dropNearDuplicate
        case .tieBreak: return .forwardTieBreak
        case .store: return .forward
        }
    }
}
