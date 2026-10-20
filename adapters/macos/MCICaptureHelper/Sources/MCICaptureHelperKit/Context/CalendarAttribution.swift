// SPDX-License-Identifier: Apache-2.0
//
// CalendarAttribution — the capture helper's calendar source for
// `WorkflowContext.currentCalendarEvent`. It reads nothing.
//
// Phase 6 PR 5 (SH Fork D1) had the helper read the event under way every
// 30 seconds into `WorkflowContext.currentCalendarEvent`, and make an
// `EKEventStore` at every launch, which can start the calendar's services
// even when nothing is asked. Nothing reads that field or sends it anywhere,
// so the helper no longer reads the calendar at all, whether or not the
// person turned it on, and never makes a store.
//
// The calendar the person sees (SPEC-DELTA 5: Today's bars, meetings named
// after their events) is the window's own: it reads EventKit itself, only
// while the person has the calendar on (`ai.hippocampus.calendar.show`).
//
// The type stays so the helper's wiring (`main.swift`) and the context tick
// keep their shape: `start()` does nothing, and `eventNow(at:)` is `nil`.

import Foundation

/// Protocol surface for the context tick: the calendar event whose time
/// window covers `now`, or `nil`. Tests inject a deterministic stub.
public protocol CalendarEventSource: Sendable {
    /// Currently-active event at `now`. `nil` is the graceful absence.
    func eventNow(at now: Date) -> CalendarEventRef?
}

/// The capture helper's calendar source: never reads the calendar, never
/// makes an `EKEventStore`, never asks macOS anything.
public final class CalendarAttribution: CalendarEventSource, @unchecked Sendable {
    public init() {}

    /// Nothing to start: the helper doesn't read the calendar.
    public func start() {}

    /// Always `nil`: no moment carries a calendar event.
    public func eventNow(at _: Date) -> CalendarEventRef? {
        nil
    }
}
