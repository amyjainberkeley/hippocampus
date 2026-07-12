//! Integration tests for the V2-P7 Messages.app read path.
//!
//! Every fixture is synthesized in-process — no real user `chat.db` bytes
//! reach this directory. See `tests/fixtures/README.md`.

#![cfg(target_os = "macos")]

use std::fs;
use std::path::Path;
use std::time::Duration;

use mci_messages_reader::{
    discover::find_chat_db, list_recent_messages, read_thread, watch::watch_path, ChatDbLocation,
    ChatService,
};
use rusqlite::Connection;
use tempfile::tempdir;

fn build_chat_db(db_path: &Path) {
    let conn = Connection::open(db_path).unwrap();
    conn.execute_batch(
        "
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT,
            service TEXT,
            country TEXT
        );
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            style INTEGER,
            service_name TEXT,
            display_name TEXT,
            chat_identifier TEXT
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            text TEXT,
            handle_id INTEGER,
            service TEXT,
            date INTEGER,
            is_from_me INTEGER,
            is_sent INTEGER,
            is_delivered INTEGER,
            is_read INTEGER,
            cache_has_attachments INTEGER,
            item_type INTEGER
        );
        CREATE TABLE chat_handle_join (
            chat_id INTEGER, handle_id INTEGER,
            PRIMARY KEY (chat_id, handle_id)
        );
        CREATE TABLE chat_message_join (
            chat_id INTEGER, message_id INTEGER, message_date INTEGER,
            PRIMARY KEY (chat_id, message_id)
        );

        INSERT INTO handle (ROWID, id, service, country) VALUES
            (1, '+15551234567',   'iMessage', 'US'),
            (2, 'bob@example.com','iMessage', 'US');

        INSERT INTO chat (ROWID, guid, style, service_name, display_name, chat_identifier)
        VALUES (1, 'iMessage;-;+15551234567', 43, 'iMessage', NULL, '+15551234567');

        INSERT INTO message
            (ROWID, guid, text, handle_id, service, date, is_from_me,
             is_sent, is_delivered, is_read, cache_has_attachments, item_type)
        VALUES
            (1, 'M-001', 'Hello from Alice (synthetic).', 1, 'iMessage',
                 921692800000000000, 0, 0, 1, 1, 0, 0),
            (2, 'M-002', 'Reply from me (synthetic).',    0, 'iMessage',
                 921692900000000000, 1, 1, 1, 1, 0, 0);

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);
        INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES
            (1, 1, 921692800000000000),
            (1, 2, 921692900000000000);
        ",
    )
    .unwrap();
    drop(conn);
}

#[test]
fn discover_round_trips_against_synthesized_tree() {
    let tmp = tempdir().unwrap();
    let messages_dir = tmp.path().join("Library").join("Messages");
    fs::create_dir_all(&messages_dir).unwrap();
    let db = messages_dir.join("chat.db");
    fs::write(&db, b"SQLite format 3\0").unwrap();

    let loc = find_chat_db(tmp.path()).unwrap();
    assert_eq!(loc.path, db);
    assert!(loc.root.ends_with("Library/Messages"));
}

#[test]
fn list_recent_messages_returns_synth_rows_ordered() {
    let tmp = tempdir().unwrap();
    let messages_dir = tmp.path().join("Library").join("Messages");
    fs::create_dir_all(&messages_dir).unwrap();
    let db = messages_dir.join("chat.db");
    build_chat_db(&db);
    let loc = ChatDbLocation {
        path: db,
        root: messages_dir,
    };

    let rows = list_recent_messages(&loc, 0).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].rowid, 1);
    assert!(!rows[0].is_from_me);
    assert_eq!(rows[0].service, ChatService::IMessage);
    assert_eq!(
        rows[0].body.as_deref(),
        Some("Hello from Alice (synthetic).")
    );
    assert_eq!(rows[0].sender_handle.as_deref(), Some("+15551234567"));
    assert!(rows[1].is_from_me);
}

#[test]
fn read_thread_returns_synth_thread() {
    let tmp = tempdir().unwrap();
    let messages_dir = tmp.path().join("Library").join("Messages");
    fs::create_dir_all(&messages_dir).unwrap();
    let db = messages_dir.join("chat.db");
    build_chat_db(&db);
    let loc = ChatDbLocation {
        path: db,
        root: messages_dir,
    };

    let t = read_thread(&loc, 1).unwrap().expect("chat 1 exists");
    assert_eq!(t.chat_rowid, 1);
    assert_eq!(t.style, 43);
    assert_eq!(t.participants.len(), 1);
    assert_eq!(t.participants[0].id, "+15551234567");
    assert_eq!(t.messages.len(), 2);
    assert_eq!(t.messages[0].guid, "M-001");
    assert_eq!(t.messages[1].guid, "M-002");
}

#[tokio::test(flavor = "current_thread")]
async fn watch_fires_on_chat_db_write() {
    let tmp = tempdir().unwrap();
    let messages_dir = tmp.path().join("Library").join("Messages");
    fs::create_dir_all(&messages_dir).unwrap();

    let mut w = watch_path(&messages_dir, 16).expect("watch ok");
    tokio::time::sleep(Duration::from_millis(300)).await;

    let db = messages_dir.join("chat.db");
    fs::write(&db, b"SQLite format 3\0").unwrap();

    let mut got = None;
    for _ in 0..50 {
        if let Ok(ev) = tokio::time::timeout(Duration::from_millis(100), w.next()).await {
            got = ev;
            if got.is_some() {
                break;
            }
        }
    }
    let ev = got.expect("watcher should fire for chat.db write");
    assert!(ev.path.ends_with("chat.db"));
}
