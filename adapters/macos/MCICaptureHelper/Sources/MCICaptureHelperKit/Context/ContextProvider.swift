// SPDX-License-Identifier: TBD-private
//
// ContextProvider — protocol that surfaces the ADR-0013 cascade's
// `WorkflowContext` inputs (frontmost app bundle id, focused window
// title, active browser tab URL, page text).
//
// PROTECTED-SET per AGENT_PROTOCOL §5. Citing ADR-0015 §2: every
// `WorkflowContext` field is user content. Production impls of this
// protocol read from OS APIs (NSWorkspace, AX, AppleScript) on
// background pollers and stash results in the in-process
// `WorkflowContextSnapshot` actor; the SCStream callback reads the
// snapshot synchronously via the actor's `nonisolated currentSync()`
// hot-path accessor. No raw context field crosses IPC ahead of a
// cascade decision (ADR-0015 §4 invariant `cascade-before-storage`).
//
// Phase-2 PR sequence (ADR-0015 §6):
//   - P2.1 (this file + `NSWorkspaceContextProvider`) — `appBundleId`
//     only, 1 Hz poll, not yet wired into the SCStream callback.
//   - P2.2 — `AXWindowTitleProvider` lands `windowTitle`.
//   - P2.3 / P2.4 — per-browser `URLProvider`s land `url`.
//   - P2.5 — CSO-gated wiring into `SCStreamCaptureSession.swift`.
//   - P2.6 — live-Mac audit doc.
//
// The trait itself is OS-API-free. Stub impls in tests cover the
// cascade decision matrix headlessly — the same pattern PRs #36/#37/
// #38 used for `SecureEventInputProbe`/`AXSecureSubroleProbe`/
// `BlackedRegionProbe` (`Suppression/SuppressionInputs.swift:18-122`).

import Foundation

/// Snapshot of the current workflow context — the inputs the
/// ADR-0013 cascade consumes per frame.
///
/// Production impls return the freshest values their background
/// pollers have observed; per-field `nil` when a sub-provider declined,
/// failed, or lacks permission. MUST be non-blocking on the hot path
/// — the SCStream callback at `SCStreamCaptureSession.swift:274–279`
/// / `:382–389` cannot await an actor.
///
/// See ADR-0015 §2 (trait shape) and §3 (bounded-staleness contract,
/// ≤ 1 s lag).
public protocol ContextProvider: Sendable {
    /// Latest workflow-context snapshot. Returns synchronously; reads
    /// the cached value the background poller most recently stored.
    /// First call before any poll has completed returns the all-nil
    /// initial value, which the cascade treats as "unknown app"
    /// (fail-closed under §7 catchall).
    func snapshot() -> WorkflowContext
}
