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

    /// Minimum interval between cascade evaluations, in milliseconds.
    ///
    /// STEP-2-FINDING-004 fix. The four-stage `SmartCaptureFilter`
    /// (idle / status / dirty-rects / dHash dual-threshold) gates the
    /// cascade: a filter `.drop*` decision short-circuits before the
    /// cascade runs. Static-screen secure surfaces — full-screen
    /// FairPlay playback, a focused `NSSecureTextField` with no
    /// surrounding motion, an active `sudo` password prompt — generate
    /// near-zero dHash variation, so the filter eats every frame and
    /// the cascade is starved. No probe runs, no privacy-relevant
    /// tombstone emits at the specific cascade layer that detected the
    /// surface — even though the per-frame fail-safe (§7) still catches
    /// any sample the cascade DOES see.
    ///
    /// `cascadeFloorIntervalMs` is a heartbeat floor on the cascade.
    /// When the elapsed wall-clock since the last cascade evaluation
    /// reaches this interval, `SCStreamPipeline.process(...)` runs the
    /// cascade once on the next inbound frame regardless of the
    /// filter's `.drop*` decision. The encode-frame budget is unchanged
    /// — the encoder is still gated by `minimumFrameIntervalMs` (the OS
    /// frame-delivery cap) and by the cascade itself; this knob only
    /// guarantees the cascade is consulted at least once per
    /// `cascadeFloorIntervalMs`.
    ///
    /// `1000` (1 Hz) is the default: cheap (one cascade call/sec on the
    /// hot path is well inside the budget), preserves all dedup
    /// behavior at higher frequencies, and is high enough that a static
    /// secure surface re-asserts itself on the wire every second so the
    /// cascade layer's verdict is observable in the
    /// `PrivacyTombstone(reason=…)` stream. Set to `0` to disable the
    /// floor (legacy behavior — filter-passed cascade only).
    ///
    /// Privacy invariant: this knob only WIDENS observability. A floor
    /// probe runs the SAME cascade logic on the SAME frame; it can
    /// only ADD `.suppress` decisions, never widen `.allow`. Fail-
    /// closed is preserved (Amendment 1 §3(b)).
    public let cascadeFloorIntervalMs: UInt64

    /// Default Phase-1 policy.
    ///
    /// `cascadeFloorIntervalMs = 1000` — see the field docs above; this
    /// is the STEP-2-FINDING-004 fix.
    public static let `default` = StreamPolicy(
        showsCursor: false,
        queueDepth: 3,
        minimumFrameIntervalMs: 200,
        cascadeFloorIntervalMs: 1000
    )

    public init(
        showsCursor: Bool,
        queueDepth: Int,
        minimumFrameIntervalMs: Int,
        cascadeFloorIntervalMs: UInt64 = 1000
    ) {
        self.showsCursor = showsCursor
        self.queueDepth = queueDepth
        self.minimumFrameIntervalMs = minimumFrameIntervalMs
        self.cascadeFloorIntervalMs = cascadeFloorIntervalMs
    }
}
