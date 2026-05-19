// SPDX-License-Identifier: TBD-private
//
// DHash — 64-bit perceptual hash with the dual-threshold drop / store /
// tie-break decision logic from RESEARCH_DIGEST.md Stream A (capture
// hardening).
//
// Per the CRS scan (verified McKeown & Buchanan DFRWS EU 2023, arXiv
// 2212.08035): a single dHash threshold fails on spatial shift =
// scrolling. Tight threshold = false-split (storage bloat); loose
// threshold = false-merge. The dual-threshold approach:
//
//   distance ≤ T_low   → DROP (near-duplicate; dedupe absorbs it)
//   distance ≥ T_high  → STORE (genuinely new content)
//   T_low < d < T_high → TIE-BREAK with cheap downscaled-SSIM
//
// The SSIM tie-break is `Phase-1 cycle 2+` (needs Core Image); this file
// lands the hash + the policy. The cascade callers use `Decision` to
// gate whether to forward the frame.

import Foundation

/// dHash output bits — 64 in the standard 9×8 difference-hash variant.
public struct DHash: Sendable, Equatable, Hashable {
    public let bits: UInt64

    public init(bits: UInt64) {
        self.bits = bits
    }

    /// Hamming distance between two hashes (0…64).
    public func distance(to other: DHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }
}

/// Decision the dHash dual-threshold filter returns.
public enum DHashDecision: Sendable, Equatable {
    /// Near-duplicate — drop. Saves an OCR / encode / store cycle.
    case drop
    /// Genuinely new content — forward to encode / OCR.
    case store
    /// Ambiguous — needs the SSIM tie-break. Phase-1 cycle 2+ wires the
    /// tie-breaker; for now the cascade treats this as `.store` (the
    /// safer side: an extra store is harmless; a wrong drop loses data).
    case tieBreak
}

/// Threshold pair for the dual-threshold filter.
///
/// Calibrate from real scroll / cursor / typing traces during Phase-1
/// integration. The defaults below are the CRS scan's reasonable
/// starting band; the Phase-1 capture-spine PR re-calibrates against
/// the integration corpus.
public struct DHashThresholds: Sendable, Equatable {
    public let low: Int
    public let high: Int

    public static let `default` = DHashThresholds(low: 4, high: 12)

    public init(low: Int, high: Int) {
        precondition(low <= high, "DHashThresholds.low must be ≤ .high")
        precondition(low >= 0 && high <= 64, "thresholds must be in [0, 64]")
        self.low = low
        self.high = high
    }

    /// Classify a Hamming distance against this threshold pair.
    public func decide(distance: Int) -> DHashDecision {
        precondition(distance >= 0 && distance <= 64, "distance out of range")
        if distance <= low {
            return .drop
        }
        if distance >= high {
            return .store
        }
        return .tieBreak
    }
}
