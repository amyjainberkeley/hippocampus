// Integration tests for the Phase D Reminders scaffold.
#![cfg(target_os = "macos")]

use mci_reminders_reader::{
    read_events_since, read_reminders_since, watch_reminders, Reminder, ReminderList,
};

#[test]
fn read_reminders_since_returns_empty_vec() {
    let out = read_reminders_since(0).expect("scaffold never errors");
    assert!(out.is_empty(), "scaffold must return an empty vec");
}

#[test]
fn read_events_since_alias_returns_empty_vec() {
    let out = read_events_since(0).expect("scaffold never errors");
    assert!(out.is_empty());
}

#[test]
fn read_reminders_since_does_not_panic_on_future_watermark() {
    let out = read_reminders_since(i64::MAX).expect("scaffold never errors");
    assert!(out.is_empty());
}

#[test]
fn watch_reminders_returns_a_watcher() {
    let watcher = watch_reminders().expect("scaffold never errors");
    watcher.stop();
}

#[test]
fn wire_format_is_constructible() {
    let r = Reminder {
        reminder_id: "abc".into(),
        list: ReminderList {
            list_id: "list-1".into(),
            list_name: "Reminders".into(),
        },
        title: Some("Buy milk".into()),
        notes: None,
        due_unix: Some(1_800_000_000),
        completion_unix: None,
        is_completed: false,
    };
    assert!(!r.is_completed);
}
