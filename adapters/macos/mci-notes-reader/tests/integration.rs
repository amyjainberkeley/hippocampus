// Integration tests for the Phase D Notes scaffold.
#![cfg(target_os = "macos")]

use mci_notes_reader::{
    read_events_since, read_notes_since, watch_notes, Note, NoteFolder,
};

#[test]
fn read_notes_since_returns_empty_vec() {
    let out = read_notes_since(0).expect("scaffold never errors");
    assert!(out.is_empty(), "scaffold must return an empty vec");
}

#[test]
fn read_events_since_alias_returns_empty_vec() {
    let out = read_events_since(0).expect("scaffold never errors");
    assert!(out.is_empty());
}

#[test]
fn read_notes_since_does_not_panic_on_future_watermark() {
    let out = read_notes_since(i64::MAX).expect("scaffold never errors");
    assert!(out.is_empty());
}

#[test]
fn watch_notes_returns_a_watcher() {
    let watcher = watch_notes().expect("scaffold never errors");
    watcher.stop();
}

#[test]
fn wire_format_is_constructible() {
    // Locks the shape ADR-0037 §4 documents.
    let note = Note {
        note_id: "x-coredata://abc/ICNote/p1".into(),
        folder: NoteFolder {
            folder_id: "x-coredata://abc/ICFolder/p1".into(),
            folder_name: "Notes".into(),
        },
        title: Some("Test".into()),
        body_plain: Some("Hello".into()),
        modification_unix: 0,
    };
    assert_eq!(note.folder.folder_name, "Notes");
}
