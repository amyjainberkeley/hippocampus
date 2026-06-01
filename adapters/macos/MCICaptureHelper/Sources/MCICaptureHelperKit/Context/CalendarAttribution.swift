// SPDX-License-Identifier: TBD-private
//
// CalendarAttribution — EventKit-backed "what calendar event is
// happening right now" attribution source for `WorkflowContext`.
//
// Phase 6 PR 5 — SH Fork D1 (EventKit + Contacts +
// MPNowPlayingInfoCenter cascade attribution; ratified at
// AGENT_QUESTIONS.md F-RATIFICATION-2026-05-31).
//
// PROTECTED-SET per AGENT_PROTOCOL §5 (this PR adds the
// `NSCalendarsUsageDescription` TCC surface; driver-CSO sign-off
// authored inline in the PR body, not via the `cso` sub-agent —
// CEO-INFRA-001).
//
// # Scope binding
//
// PER-EVENT attribution enricher, NOT a deep-hook plugin. The
// provider's tight contract:
//   - Reads ONLY events whose `startDate <= now <= endDate` (the
//     `EKEventStore.events(matching:)` predicate is constructed with
//     this tight window — see `CalendarEventReader.eventNow`). Past
//     events outside that window are never observed at this layer.
//     The Phase 7 full deep-hook plugin (PR 21) will broaden the
//     window; this attribution surface stays tight by construction.
//   - Returns subject + start + end only (CalendarEventRef in
//     `Suppression/SuppressionInputs.swift`). NO body, NO attendees,
//     NO location. Phase 7 deep-hook owns the broader read.
//   - Caches aggressively (default 30 s TTL — event durations are
//     minutes-to-hours; a 1 Hz poll burns no EventKit calls in the
//     steady state).
//
// # TCC denial path
//
// `EKEventStore.requestFullAccessToEvents` is called once at
// `start()`. On denial / restricted / not-determined we record the
// denial state, emit ONE `tracing`-style stderr line, and every
// subsequent `eventNow(...)` returns `nil`. Graceful absence; never
// crashes. The state-change warn fires only once per transition.
//
// # Cascade-equivalent binding
//
// `CalendarEventRef.subject` MAY carry user content (calendar invites
// can contain "Your verification code is 123456" in the subject).
// The cascade-equivalent at the brain-ingest layer runs the
// ADR-0030 §3(a) SMS-OTP regex bank on `subject` before persistence.
// See `core/brain/src/redaction/calendar_attribution.rs`.

import Dispatch
import Foundation
import os
#if canImport(EventKit)
import EventKit
#endif

/// Protocol surface — production reads `EKEventStore`; tests inject
/// a deterministic stub. Returns the calendar event whose time window
/// covers `now`, or `nil` if there is none / TCC denied / no access /
/// no calendars subscribed. Cheap on the hot path (internal cache).
public protocol CalendarEventSource: Sendable {
    /// Currently-active event at `now`. `nil` is the graceful
    /// absence — TCC denied, no event, store empty.
    func eventNow(at now: Date) -> CalendarEventRef?
}

/// Authorization state of `EKEventStore` for the helper process.
/// Exposed for observability; the only behaviour difference between
/// denied / restricted / notDetermined is whether the
/// state-change warn has already fired. Production code never
/// distinguishes them — all three return `nil`.
public enum CalendarAuthorizationState: Sendable, Equatable {
    /// Not yet requested OR `requestFullAccessToEvents` returned
    /// `false` with no error. Treated as denied for capture purposes.
    case notDetermined
    /// User explicitly denied OR system policy restricts access.
    case denied
    /// `EKAuthorizationStatus.fullAccess` (macOS 14+).
    case granted
}

/// Production `CalendarEventSource` over `EKEventStore`. Holds a
/// single store instance, a denial-state flag, and a small per-`now`
/// cache (cache invalidates when the current event window
/// progresses past `endDate` + a 30 s default refresh period).
///
/// `start()` triggers the TCC prompt asynchronously; until it
/// resolves, `eventNow(...)` returns `nil` (the safe direction).
/// Once granted, the source reads `events(matching:)` over the
/// `[now, now]` window and returns the first match.
///
/// Lifetime discipline (SCSTREAM-LIVE-001 lesson): construct at
/// process top level in `MCICaptureHelper/main.swift`; never let a
/// detached `Task` be the sole owner.
public final class CalendarAttribution: CalendarEventSource, @unchecked Sendable {
    /// Cache TTL — how long a non-nil current-event observation is
    /// trusted before we re-read EventKit. Default 30 s. Event
    /// durations are minutes-to-hours so 30 s gives us a tight
    /// upper bound on staleness without burning per-tick reads.
    private let cacheTtl: TimeInterval

    /// Lock-guarded mutable state.
    private let stateLock = NSLock()
    private var authState: CalendarAuthorizationState
    /// Last successful read. `nil` when we have not observed an
    /// event yet OR the cached event is no longer current.
    private var cachedEvent: CalendarEventRef?
    /// Wall clock of the last EventKit read. The cache is trusted
    /// for `cacheTtl` seconds after this timestamp.
    private var cachedAt: Date?
    /// Set once per state-transition so we do not flood stderr.
    private var loggedDenialOnce: Bool = false

    #if canImport(EventKit)
    private let store: EKEventStore
    #endif

    /// Initial state — `notDetermined`, no cached event.
    public init(cacheTtl: TimeInterval = 30.0) {
        self.cacheTtl = cacheTtl
        self.authState = .notDetermined
        self.cachedEvent = nil
        self.cachedAt = nil
        #if canImport(EventKit)
        self.store = EKEventStore()
        #endif
    }

    /// Kick off the TCC prompt + permission settle. Idempotent —
    /// second call is a no-op. Until access resolves, `eventNow`
    /// returns `nil`.
    public func start() {
        #if canImport(EventKit)
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard let self else { return }
            self.recordAuth(granted: granted)
        }
        #endif
    }

    /// Record the outcome of the auth callback. Idempotent; the
    /// state-change warn fires only once per transition.
    private func recordAuth(granted: Bool) {
        stateLock.lock()
        let prior = authState
        authState = granted ? .granted : .denied
        let shouldLog = !loggedDenialOnce && !granted && prior != authState
        if shouldLog {
            loggedDenialOnce = true
        }
        stateLock.unlock()
        if shouldLog {
            FileHandle.standardError.write(
                ("mci-capture-helper: NSCalendarsUsageDescription "
                 + "denied — current-calendar-event attribution "
                 + "disabled. Re-grant in System Settings → Privacy "
                 + "& Security → Calendars.\n").data(using: .utf8) ?? Data()
            )
        }
    }

    public func eventNow(at now: Date) -> CalendarEventRef? {
        // Snapshot all state under the lock; do the (potentially
        // expensive) EventKit read OUTSIDE the lock. EventKit's
        // `events(matching:)` is internally serialized but we never
        // want the cascade hot path to block on it.
        stateLock.lock()
        let auth = authState
        let cached = cachedEvent
        let cachedAtCopy = cachedAt
        let ttl = cacheTtl
        stateLock.unlock()

        guard auth == .granted else { return nil }

        // Cache-hit fast path: cached event still covers `now` AND
        // the read was within `cacheTtl`.
        if let evt = cached, let at = cachedAtCopy {
            let stillCurrent = Int64(now.timeIntervalSince1970) >= evt.startUnixSeconds
                && Int64(now.timeIntervalSince1970) <= evt.endUnixSeconds
            let withinTtl = now.timeIntervalSince(at) < ttl
            if stillCurrent && withinTtl {
                return evt
            }
        }

        // Cache-miss: re-read from EventKit over the [now, now]
        // window. The predicate's start/end MUST be tight — we
        // explicitly do NOT read past events here.
        let observed = readEventAt(now: now)

        stateLock.lock()
        cachedEvent = observed
        cachedAt = now
        stateLock.unlock()

        return observed
    }

    /// Read EventKit for the calendar event whose window covers
    /// `now`. Returns the first match (deterministic ordering across
    /// overlapping events is out of scope for this PR — Phase 7
    /// deep-hook owns multi-event semantics).
    private func readEventAt(now: Date) -> CalendarEventRef? {
        #if canImport(EventKit)
        // Tight window: exact `[now, now]`. EventKit
        // `predicateForEvents(withStart:end:calendars:)` is
        // documented to return events whose [startDate, endDate]
        // overlaps the predicate window, which is exactly the
        // "happening right now" semantics SH Fork D1 ratified.
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now,
            calendars: nil  // search all subscribed calendars
        )
        let matches = store.events(matching: predicate)
        // EKEvent.startDate / endDate are typed `Date!` (implicit
        // optional). Belt-and-suspenders guard so a malformed event
        // (start or end nil) is never observed as "current."
        guard let event = matches.first(where: { e in
            guard let start = e.startDate, let end = e.endDate else {
                return false
            }
            return start <= now && now <= end
        }),
            let start = event.startDate,
            let end = event.endDate
        else {
            return nil
        }
        // EKEvent.title is typed `String!`; treat nil as empty so
        // the cascade-equivalent regex bank still runs on a
        // zero-length input (cheap no-op).
        let subject = event.title ?? ""
        return CalendarEventRef(
            subject: subject,
            startUnixSeconds: Int64(start.timeIntervalSince1970),
            endUnixSeconds: Int64(end.timeIntervalSince1970)
        )
        #else
        return nil
        #endif
    }
}
