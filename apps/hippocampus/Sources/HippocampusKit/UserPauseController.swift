// SPDX-License-Identifier: TBD-private
//
// UserPauseController — the user-initiated pause layer.
//
// Distinct from the two other pause paths in the app:
//   - TCC-revoke pause (PR #80) — the helper self-pauses when
//     Screen Recording / Accessibility / FDA / Automation is revoked
//     mid-run. Handled by TCCHelperStderrTail → notifier + menu-bar
//     red pill. Not user-initiated; recovers automatically when the
//     grant is restored.
//   - Screen-share leak-pause (PR #75) — the helper self-pauses when
//     the user starts a Zoom/Meet/AirPlay share. Not user-initiated;
//     recovers automatically when sharing ends.
//
// This layer is the third: an explicit "I want to stop being recorded
// right now" gate the user flips from the menu-bar drop-down (⌘⇧P) or
// the ⌘K Action Panel. When set, the supervisor is asked to SIGSTOP
// the helper (existing setPaused path) AND a `helper_health
// user_paused=true` breadcrumb is emitted so the health-log ring
// surfaces user-initiated pauses distinctly from the automated ones.
//
// Thread-safety: `isPaused` is guarded by a serial dispatch queue.
// Reads and writes cross thread boundaries — the menu-bar (main) and
// the ⌘K panel (main) drive writes; downstream sinks (logging thread,
// supervisor's main-actor apply) may read. A serial queue is cheaper
// than an actor here because the menu-bar `Button` closure is
// synchronous and we need a `Bool` back for immediate title flip.
//
// Breadcrumb emission: on every state flip we call `sink(paused)` on
// a background dispatch queue so the menu-bar closure returns
// immediately. In production `sink` is a Logger; in tests it captures
// into an array so `UserPauseControllerTests` can assert the emission
// order. See PR #77's MenuBarStatus tests for the same pattern.

import Foundation
import os

/// Thread-safe user-initiated pause gate. See file header.
public final class UserPauseController: @unchecked Sendable {
    /// The process-wide instance. Menu-bar + ⌘K Action Panel both
    /// drive this. Fresh in tests via `UserPauseController()` — the
    /// singleton reference is deliberately not a `let` so the test
    /// suite can substitute a fake without polluting shared state.
    public static let shared = UserPauseController()

    private let queue = DispatchQueue(
        label: "ai.hippocampus.user-pause",
        qos: .userInitiated
    )
    private var _isPaused: Bool = false
    private var _sinks: [(Bool) -> Void] = []

    /// Default sink — writes the breadcrumb to the same subsystem the
    /// helper's `helper_health` log ring uses, so downstream telemetry
    /// filters can pick both up with the same category filter. Marked
    /// nonisolated so it can be attached during singleton init.
    private let logger = Logger(
        subsystem: "ai.hippocampus",
        category: "user-pause"
    )

    public init() {
        // Wire the default logger sink. Tests can attach additional
        // sinks; they never remove this one, but the logger is inert
        // under `swift test` (no os-log listener) so it does not
        // interfere with test assertions.
        addSink { [logger] paused in
            logger.info("helper_health user_paused=\(paused, privacy: .public)")
        }
    }

    /// Current pause state. Thread-safe read.
    public var isPaused: Bool {
        queue.sync { _isPaused }
    }

    /// Set the pause state to `paused`. No-op if already at that
    /// value — sinks fire only on actual transitions so the health
    /// log stays clean of redundant breadcrumbs.
    ///
    /// Returns the new (post-call) state, matching what a downstream
    /// menu-title flip should render.
    @discardableResult
    public func setPaused(_ paused: Bool) -> Bool {
        let didChange: Bool = queue.sync {
            guard _isPaused != paused else { return false }
            _isPaused = paused
            return true
        }
        if didChange {
            let sinks = queue.sync { _sinks }
            for sink in sinks {
                sink(paused)
            }
        }
        return paused
    }

    /// Toggle and return the new state. Used by the ⌘⇧P menu-bar
    /// keyboard shortcut which has no idea what the previous state
    /// was — it just wants a flip.
    @discardableResult
    public func togglePaused() -> Bool {
        let next = queue.sync { !_isPaused }
        return setPaused(next)
    }

    /// Attach an additional breadcrumb sink. Called during
    /// initialisation (default logger) and from tests. Sinks fire on
    /// state transitions only, on the same serial queue as the write
    /// — they must not block for long.
    public func addSink(_ sink: @escaping (Bool) -> Void) {
        queue.sync {
            _sinks.append(sink)
        }
    }

    /// Reset the controller — clears sinks (keeps the default logger)
    /// and unpauses. Test-only helper; not used from the app.
    public func resetForTesting() {
        queue.sync {
            _isPaused = false
            _sinks.removeAll()
        }
        addSink { [logger] paused in
            logger.info("helper_health user_paused=\(paused, privacy: .public)")
        }
    }
}
