// SPDX-License-Identifier: TBD-private
//
// WorkflowContextSnapshot — single mutable cell that owns the latest
// `WorkflowContext` value. Writes go through actor isolation;
// READS go through a non-blocking `OSAllocatedUnfairLock`-protected
// accessor so the SCStream callback (a `@Sendable` closure that runs
// on the stream's `sampleQueue` and CANNOT await an actor) can pull
// the freshest value synchronously.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. ADR-0015 §3 staleness contract:
// the maximum lag between a user app-switch and the cascade observing
// the new `appBundleId` is bounded by the polling period (1 s for the
// `NSWorkspaceContextProvider` shipped in P2.1). The lock protects a
// single stored property; readers never spin (the lock is held only
// long enough to copy four optional strings).
//
// Why this shape:
//   - Actor isolation on `store(_:)` serializes writes from multiple
//     pollers (P2.1 only has one, but P2.2/P2.3/P2.4 add AX,
//     AppleScript Safari, etc. — actor-isolated `store` keeps the
//     future-fan-in safe by construction).
//   - `nonisolated` `currentSync()` over an `OSAllocatedUnfairLock`
//     lets the SCStream `@Sendable` callback read synchronously. A
//     pure actor read would require `await`, which means the
//     callback would have to be async — the prior `Task { await … }`
//     pattern released the only strong reference and caused
//     SCSTREAM-LIVE-001 (PR #29). The lock-protected non-async read
//     avoids repeating that bug class.

import Foundation
import os

/// Owner of the latest `WorkflowContext` value. Writes are
/// serialized by actor isolation; the hot-path read is non-blocking
/// through a `nonisolated` `OSAllocatedUnfairLock`-protected
/// accessor.
///
/// Initial state: `WorkflowContext()` (all fields nil). The cascade
/// treats an all-nil context as "unknown app" → fail-closed under
/// §7 catchall, which is the safe direction during P2.1 (the
/// provider is not wired into the SCStream callback yet; PR P2.5
/// lands the wiring).
public actor WorkflowContextSnapshot {
    /// Lock-guarded storage cell. Marked `nonisolated` (via being a
    /// `let` containing internal mutability) so `currentSync()` can
    /// touch it without `await`. Mutation is still serialized by the
    /// actor on the write path AND by the lock on every access; the
    /// double-barrier is intentional fan-in protection for the
    /// P2.2/P2.3/P2.4 pollers landing later.
    private let cell = OSAllocatedUnfairLock(initialState: WorkflowContext())

    public init() {}

    /// Replace the stored snapshot with `ctx`. Actor-isolated;
    /// `await` from background pollers. The write itself completes
    /// while holding the lock — bounded time, no allocation, no I/O.
    public func store(_ ctx: WorkflowContext) async {
        cell.withLock { state in
            state = ctx
        }
    }

    /// Non-blocking read of the most-recently-stored snapshot. Safe
    /// to call from the SCStream `@Sendable` callback. Holds the
    /// lock only long enough to copy out four optional strings
    /// (≪ 1 µs uncontended).
    public nonisolated func currentSync() -> WorkflowContext {
        cell.withLock { state in
            state
        }
    }
}
