// SPDX-License-Identifier: TBD-private
//
// StreamConfig — `SCStreamConfiguration` factory.
//
// The single most load-bearing line in this file is `showsCursor = false`.
// Per RESEARCH_DIGEST.md Stream A (capture hardening): cursor jitter
// composites "changed" frames every input device tick, which the OS
// idle gate does NOT suppress. Leaving the cursor on the capture stream
// is the single highest-leverage footprint regression in the project.
//
// The cursor signal (position, click state) is captured separately by
// the Context Director (Phase 2) via NSWorkspace / AX — decoupled from
// the frame pipeline so it cannot bust the §4 footprint SLO.
//
// This file is OS-API-adjacent but does NOT import ScreenCaptureKit —
// the actual SCStreamConfiguration construction happens in Phase-1
// cycle 2+. We expose the policy values as typed constants so
// (a) the policy is reviewable in one place and (b) the cycle-2
// PR cannot accidentally flip `showsCursor` to true without a CSO note.

import Foundation

/// Capture-stream policy values.
///
/// PROTECTED-SET adjacent — `showsCursor` is part of the §4 footprint
/// invariant per RESEARCH_DIGEST. Flipping `showsCursor` to `true`
/// requires a footprint measurement + a documented justification in
/// the PR body.
public struct StreamPolicy: Sendable, Equatable {
    /// Whether the OS draws the cursor into the captured surface.
    /// **MUST stay false** — cursor jitter busts the §4 SLO.
    public let showsCursor: Bool

    /// Frame queue depth handed to the OS (`queueDepth` on
    /// `SCStreamConfiguration`). Default = 3, the Apple recommendation.
    public let queueDepth: Int

    /// Target minimum interval between frame deliveries, in
    /// milliseconds. 200 ms (5 fps) is the static-content default;
    /// adaptive sampling (Phase-1 cycle 2+) drops this when the OS bit
    /// + dirty-rect signal say content is changing.
    public let minimumFrameIntervalMs: Int

    /// Default Phase-1 policy.
    public static let `default` = StreamPolicy(
        showsCursor: false,
        queueDepth: 3,
        minimumFrameIntervalMs: 200
    )
}
