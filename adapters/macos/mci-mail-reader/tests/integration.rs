//! Integration tests for the V2-P8a Mail.app read path.
//!
//! Every fixture is synthesized in-process — no real user mail content
//! reaches this directory. See `tests/fixtures/README.md`.

#![cfg(target_os = "macos")]

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use mci_mail_reader::{
    discover::{find_mail_data_root, list_accounts},
    envelope::{list_recent_messages, schema_version},
    parse::address_domain,
    read_message, watch::watch_path, EmlxMetadata,
};
use rusqlite::Connection;
use tempfile::tempdir;

fn synth_emlx(body: &[u8], trailer: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(11 + body.len() + trailer.len());
    let s = format!("{}", body.len());
    let mut prefix = [b' '; 10];
    prefix[..s.len()].copy_from_slice(s.as_bytes());
    out.extend_from_slice(&prefix);
    out.push(b'\n');
    out.extend_from_slice(body);
    out.extend_from_slice(trailer);
    out
}

fn write_emlx(dir: &Path, n: i64, body: &[u8], trailer: &[u8]) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    let path = dir.join(format!("{n}.emlx"));
    fs::write(&path, synth_emlx(body, trailer)).unwrap();
    path
}

fn build_envelope_index(maildata: &Path) {
    fs::create_dir_all(maildata).unwrap();
    let db_path = maildata.join("Envelope Index");
    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch(
        "
        CREATE TABLE properties (key TEXT UNIQUE, value INTEGER);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT UNIQUE);
        CREATE TABLE messages (
            ROWID INTEGER PRIMARY KEY,
            message_id INTEGER,
            date_received INTEGER,
            date_sent INTEGER,
            mailbox INTEGER,
            size INTEGER,
            flags INTEGER
        );
        INSERT INTO properties (key, value) VALUES ('version', 4);
        INSERT INTO properties (key, value) VALUES ('minor_version', 84003);
        INSERT INTO mailboxes (ROWID, url) VALUES
            (1, 'imap://AAAA-acct/INBOX'),
            (2, 'imap://AAAA-acct/Sent%20Messages');
        INSERT INTO messages (ROWID, message_id, date_received, date_sent, mailbox, size, flags)
        VALUES
            (1, 1, 1000, 999, 1, 256, 1),
            (2, 2, 2000, 1999, 1, 256, 0),
            (3, 3, 3000, 2999, 2, 256, 1);
        ",
    )
    .unwrap();
    drop(conn);
}

fn synthetic_body(n: u32) -> Vec<u8> {
    let s = format!(
        "From: \"Alice {n}\" <alice{n}@example.com>\r\n\
         Reply-To: replies{n}@example.com\r\n\
         To: \"Bob {n}\" <bob{n}@example.com>\r\n\
         Subject: synthesized fixture {n}\r\n\
         Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
         Message-ID: <fixture-{n}@example.invalid>\r\n\
         Mime-Version: 1.0\r\n\
         Content-Type: text/plain; charset=us-ascii\r\n\
         \r\nhello body {n}.\r\n"
    );
    s.into_bytes()
}

fn synthetic_trailer(flags: u32) -> Vec<u8> {
    let s = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <plist version=\"1.0\"><dict>\
         <key>flags</key><integer>{flags}</integer>\
         <key>conversation-id</key><integer>0</integer>\
         </dict></plist>\n"
    );
    s.into_bytes()
}

#[test]
fn discover_round_trips_against_synthesized_tree() {
    let tmp = tempdir().unwrap();
    let mail = tmp.path().join("Library").join("Mail");
    fs::create_dir_all(mail.join("V9")).unwrap();
    fs::create_dir_all(mail.join("V10")).unwrap();
    let acct = mail.join("V10").join("11111111-2222-3333-4444-555555555555");
    fs::create_dir_all(&acct).unwrap();
    fs::create_dir_all(mail.join("V10").join("MailData")).unwrap();

    let root = find_mail_data_root(tmp.path()).unwrap();
    assert_eq!(root.version, 10);
    let accounts = list_accounts(&root).unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].uuid, "11111111-2222-3333-4444-555555555555");
}

#[test]
fn envelope_index_lists_messages_with_watermark() {
    let tmp = tempdir().unwrap();
    let vn = tmp.path().join("V10");
    fs::create_dir_all(&vn).unwrap();
    build_envelope_index(&vn.join("MailData"));

    let root = mci_mail_reader::discover::MailDataRoot {
        path: vn,
        version: 10,
    };
    let (ver, minor) = schema_version(&root).unwrap();
    assert_eq!(ver, Some(4));
    assert_eq!(minor, Some(84003));

    let all = list_recent_messages(&root, 0).unwrap();
    assert_eq!(all.len(), 3);
    let recent: Vec<&EmlxMetadata> = all.iter().filter(|m| m.date_received >= 2000).collect();
    assert_eq!(recent.len(), 2);
}

#[test]
fn read_message_round_trip_extracts_headers_and_body() {
    let tmp = tempdir().unwrap();
    let path = write_emlx(tmp.path(), 1, &synthetic_body(1), &synthetic_trailer(1));
    let m = read_message(&path).unwrap();

    assert_eq!(m.from.len(), 1);
    assert_eq!(m.from[0].address, "alice1@example.com");
    assert_eq!(address_domain(&m.from[0]).as_deref(), Some("example.com"));

    assert_eq!(m.reply_to.len(), 1);
    assert_eq!(m.reply_to[0].address, "replies1@example.com");

    assert_eq!(m.to.len(), 1);
    assert_eq!(m.to[0].address, "bob1@example.com");

    assert_eq!(m.subject.as_deref(), Some("synthesized fixture 1"));
    assert_eq!(m.message_id.as_deref(), Some("fixture-1@example.invalid"));
    assert!(m.body_text.as_deref().unwrap().contains("hello body 1."));
    assert!(!m.plist_trailer.is_empty());
}

#[test]
fn read_message_surfaces_invalid_framing() {
    let tmp = tempdir().unwrap();
    let path = tmp.path().join("bad.emlx");
    fs::write(&path, b"not-an-emlx-file").unwrap();
    let err = read_message(&path).unwrap_err();
    assert!(matches!(
        err,
        mci_mail_reader::MailReaderError::InvalidEmlx { .. }
    ));
}

#[tokio::test(flavor = "current_thread")]
async fn watch_inbox_fires_on_new_emlx() {
    let tmp = tempdir().unwrap();
    let inbox = tmp
        .path()
        .join("INBOX.mbox")
        .join("UUID")
        .join("Data")
        .join("Messages");
    fs::create_dir_all(&inbox).unwrap();

    let mut w = watch_path(tmp.path(), 16).unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    write_emlx(&inbox, 7, &synthetic_body(7), &synthetic_trailer(0));

    let mut got = None;
    for _ in 0..50 {
        if let Ok(ev) = tokio::time::timeout(Duration::from_millis(100), w.next()).await {
            got = ev;
            if got.is_some() {
                break;
            }
        }
    }
    let ev = got.expect("watcher should fire for new emlx");
    assert!(ev.path.ends_with("7.emlx"));

    let m = read_message(&ev.path).unwrap();
    assert_eq!(m.subject.as_deref(), Some("synthesized fixture 7"));
}
