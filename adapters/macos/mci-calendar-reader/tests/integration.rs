// Integration tests for the Phase D Calendar scaffold.
//
// The wire-up PR replaces these with fixture-driven EventKit tests. Today
// the surface is verified to be:
//   - present (compiles, exports the promised names),
//   - safe (returns empty vec, never panics), and
//   - shape-stable (struct fields match the wire format documented in
//     ADR-0037 §4).

#![cfg(target_os = "macos")]

use mci_calendar_reader::{
    read_events_since, watch_calendar, CalendarEvent, EventSource, ParticipantHandle,
};

#[test]
fn read_events_since_returns_empty_vec() {
    // Watermark deliberately in the past.
    let out = read_events_since(0).expect("scaffold never errors");
    assert!(out.is_empty(), "scaffold must return an empty vec");
}

#[test]
fn read_events_since_does_not_panic_on_future_watermark() {
    let out = read_events_since(i64::MAX).expect("scaffold never errors");
    assert!(out.is_empty());
}

#[test]
fn watch_calendar_returns_a_watcher() {
    let watcher = watch_calendar().expect("scaffold never errors");
    watcher.stop();
}

#[test]
fn wire_format_is_constructible() {
    // If this ever fails to compile, the wire-up PR must revisit its
    // dependents. Locks the shape ADR-0037 §4 documents.
    let ev = CalendarEvent {
        event_id: "test".into(),
        calendar_id: "cal".into(),
        title: Some("t".into()),
        notes: None,
        location: None,
        start_unix: 0,
        end_unix: 0,
        participants: vec![ParticipantHandle {
            handle: "a@b.com".into(),
            display_name: None,
        }],
        source: EventSource::EventKit,
    };
    assert_eq!(ev.event_id, "test");
}
