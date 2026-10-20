// SPDX-License-Identifier: Apache-2.0
//
// UserPauseController — the user-initiated pause layer.
//
// Distinct from the automatic TCC pause path in the app:
//   - TCC-revoke pause (PR #80) — the helper self-pauses when
//     required Screen Recording or Accessibility access is revoked
//     mid-run. Handled by TCCHelperStderrTail → notifier + menu-bar
//     red pill. Not user-initiated; recovers automatically when the
//     grant is restored.
//
// This layer is the person's explicit Pause, from the menu, Ask's footer
// or Preferences, through `ProcessSupervisor.setPaused`, which owns the
// app's controller. When set, the supervisor stops the owned helper
// and agent topology completely, then launches a fresh generation on
// resume. A `helper_health
// user_paused=true` breadcrumb is emitted so the health-log ring
// surfaces user-initiated pauses distinctly from the automated ones.
//
// Thread-safety: the pause is guarded by a serial dispatch queue.
// Writes come from the main actor; downstream sinks (logging thread,
// supervisor's main-actor apply) may read. A serial queue is cheaper
// than an actor here because callers are synchronous and need a `Bool`
// back at once.
//
// Breadcrumb emission: on every state flip we call `sink(paused)` on
// the same serial queue as the state transition. This keeps observable
// transitions ordered under concurrent callers. Sinks must remain short
// and must not call back into this controller.

import Foundation
import os

/// Thread-safe user-initiated pause gate. See file header.
///
/// A pause survives a relaunch: the app's controller keeps the time of the
/// pause in its own defaults, so the menu can say "Since {time}." and the
/// next launch goes straight to Paused (spec-shell S5, RULINGS S5 and S10).
public final class UserPauseController: @unchecked Sendable {
    /// The app's pause, kept in its own defaults. Tests make their own
    /// controllers, which keep nothing.
    public static let shared = UserPauseController(defaults: .standard)
    /// When the person paused, as seconds since 1970.
    public static let defaultsKey = "ai.hippocampus.capture.paused"
    /// When a timed pause ends, as seconds since 1970 (SPEC 2.6.2): For 1
    /// Hour, or Until Tomorrow at 6:00 AM. Absent for Until I Start It Again.
    public static let resumeAtKey = "ai.hippocampus.capture.pausedUntil"

    private let queue = DispatchQueue(
        label: "ai.hippocampus.user-pause",
        qos: .userInitiated
    )
    private let defaults: UserDefaults?
    private let clock: @Sendable () -> Date
    private var _pausedSince: Date?
    private var _resumeAt: Date?
    private var _sinks: [(Bool) -> Void] = []

    /// Default sink — writes the breadcrumb to the same subsystem the
    /// helper's `helper_health` log ring uses, so downstream telemetry
    /// filters can pick both up with the same category filter. Marked
    /// nonisolated so it can be attached during singleton init.
    private let logger = Logger(
        subsystem: "ai.hippocampus",
        category: "user-pause"
    )

    /// `defaults` keeps the pause across launches; nil keeps it in memory.
    public init(defaults: UserDefaults? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
        _pausedSince = (defaults?.object(forKey: Self.defaultsKey) as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        // A timed pause outlives a relaunch with its end, as the pause does.
        _resumeAt = _pausedSince == nil ? nil : (defaults?.object(forKey: Self.resumeAtKey) as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
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
        queue.sync { _pausedSince != nil }
    }

    /// When the person paused; nil when not paused.
    public var pausedSince: Date? {
        queue.sync { _pausedSince }
    }

    /// When a timed pause ends; nil when not paused or paused until the
    /// person resumes.
    public var resumeAt: Date? {
        queue.sync { _resumeAt }
    }

    /// Whether a timed pause's end has come: remembering resumes on its own.
    public func isDue(now: Date) -> Bool {
        queue.sync {
            guard _pausedSince != nil, let end = _resumeAt else { return false }
            return now >= end
        }
    }

    /// Pause until `resumeAt` (nil: until the person resumes). A pause
    /// already on keeps its first time and takes the new end.
    @discardableResult
    public func pause(until resumeAt: Date?) -> Bool {
        queue.sync {
            let wasPaused = _pausedSince != nil
            _resumeAt = resumeAt
            if let resumeAt {
                defaults?.set(resumeAt.timeIntervalSince1970, forKey: Self.resumeAtKey)
            } else {
                defaults?.removeObject(forKey: Self.resumeAtKey)
            }
            if !wasPaused { apply(true) }
            return true
        }
    }

    /// Set the pause state to `paused`. No-op if already at that
    /// value — sinks fire only on actual transitions so the health
    /// log stays clean of redundant breadcrumbs, and a repeated pause
    /// keeps its first time.
    ///
    /// Returns the new (post-call) state, matching what a downstream
    /// menu-title flip should render.
    @discardableResult
    public func setPaused(_ paused: Bool) -> Bool {
        queue.sync {
            guard (_pausedSince != nil) != paused else { return paused }
            apply(paused)
            return paused
        }
    }

    /// Toggle and return the new state.
    @discardableResult
    public func togglePaused() -> Bool {
        queue.sync {
            let paused = _pausedSince == nil
            apply(paused)
            return paused
        }
    }

    /// Attach an additional breadcrumb sink. Called during
    /// initialisation (default logger) and from tests. Sinks fire on
    /// state transitions only, on the same serial queue as the write.
    /// They must not block or call back into this controller.
    public func addSink(_ sink: @escaping (Bool) -> Void) {
        queue.sync {
            _sinks.append(sink)
        }
    }

    /// Reset the controller — clears sinks (keeps the default logger),
    /// unpauses and forgets a kept pause. Test-only helper; not used from
    /// the app.
    public func resetForTesting() {
        queue.sync {
            _pausedSince = nil
            _resumeAt = nil
            defaults?.removeObject(forKey: Self.defaultsKey)
            defaults?.removeObject(forKey: Self.resumeAtKey)
            _sinks.removeAll()
        }
        addSink { [logger] paused in
            logger.info("helper_health user_paused=\(paused, privacy: .public)")
        }
    }

    /// On the queue: record the change, keep it, then tell the sinks.
    private func apply(_ paused: Bool) {
        _pausedSince = paused ? clock() : nil
        if let since = _pausedSince {
            defaults?.set(since.timeIntervalSince1970, forKey: Self.defaultsKey)
        } else {
            defaults?.removeObject(forKey: Self.defaultsKey)
            _resumeAt = nil
            defaults?.removeObject(forKey: Self.resumeAtKey)
        }
        for sink in _sinks {
            sink(paused)
        }
    }
}
