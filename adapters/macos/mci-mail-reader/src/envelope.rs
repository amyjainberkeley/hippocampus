//! Read-only `Envelope Index` `SQLite` reader (WAL-aware).
//!
//! Per Mail-spike memo §4 + §4.6:
//!
//! - Open with `?mode=ro` (NOT `immutable=1`) so we tail Mail.app's WAL
//!   writes without taking the writer lock.
//! - `messages` is the hub; `subjects`, `addresses`, `recipients`,
//!   `mailboxes` are the auxiliary FK targets.
//! - `message_global_data.message_id_header` is the RFC 5322 `Message-ID:`
//!   — the cross-device dedup key (Mail-spike §11 Q7).
//!
//! V2-P8a exposes a single query: list metadata for messages whose
//! `date_received` is at or after a watermark. The richer surface
//! (`get_recipients`, `get_conversation`, …) lands in V2-P8b alongside
//! the cascade-equivalent; that surface is not needed for the read-only
//! API contract this PR ships.

use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, OptionalExtension, Row};

use crate::discover::{envelope_index_path, MailDataRoot};
use crate::error::MailReaderError;

/// One row from `Envelope Index.messages`, plus the on-disk path of the
/// emlx file that backs it.
#[derive(Debug, Clone)]
pub struct EmlxMetadata {
    /// `messages.ROWID`. Stable for the lifetime of a row in Mail.app's
    /// store; suitable as a watermark for incremental polling.
    pub rowid: i64,
    /// `messages.message_id` — Mail-internal per-mailbox message id, also
    /// the basename (`<N>.emlx`) of the file on disk.
    pub message_id: i64,
    /// `messages.date_received` — Unix seconds. The right watermark column
    /// for "give me everything since timestamp T" (Mail-spike §4.1).
    pub date_received: i64,
    /// `messages.date_sent` — Unix seconds.
    pub date_sent: i64,
    /// `messages.mailbox` → `mailboxes.ROWID`. Lookup join not done here
    /// (cheap, but Trail-of-FKs is V2-P8b territory).
    pub mailbox_rowid: i64,
    /// `mailboxes.url` for the message's mailbox, e.g.
    /// `imap://<acct>/INBOX` or `local://<acct>/Sent%20Messages`. Resolved
    /// via a small join so callers can route messages back to their
    /// account/mailbox on disk without a second query.
    pub mailbox_url: Option<String>,
    /// `messages.size` (bytes; null in some Mail versions).
    pub size: Option<i64>,
    /// `messages.flags` — bitfield mirrored from the emlx plist trailer.
    pub flags: i64,
    /// Best-effort path to the backing `.emlx` file on disk. `None` when
    /// `mailbox_url` was not resolvable or the URL did not parse.
    pub emlx_path: Option<PathBuf>,
}

/// Open the Envelope Index read-only with WAL-aware flags.
///
/// We open with `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_URI`. We deliberately
/// do NOT pass `immutable=1` — Mail.app writes the file live and
/// `immutable=1` would lie to `SQLite` about that. WAL admits one writer
/// + many readers, so this is safe.
fn open_read_only(envelope_index: &Path) -> Result<Connection, MailReaderError> {
    // rusqlite's `open_with_flags(path, flags)` constructs a URI-less open;
    // we use `open_with_flags_and_vfs` shape via the URI form so we can
    // assert `mode=ro` explicitly. The simpler path is just to use
    // OpenFlags::SQLITE_OPEN_READ_ONLY which is equivalent.
    let conn = Connection::open_with_flags(
        envelope_index,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(map_sqlite_io_err(envelope_index))?;

    // Modest busy timeout — see Mail-spike §4.6: SQLITE_BUSY can occur
    // during Mail.app's exit-time WAL checkpoint window. A 250 ms timeout
    // is more than enough to ride out that handshake without making
    // mail-reader feel hung.
    conn.busy_timeout(Duration::from_millis(250))?;

    Ok(conn)
}

fn map_sqlite_io_err(path: &Path) -> impl FnOnce(rusqlite::Error) -> MailReaderError + '_ {
    move |err| {
        // rusqlite hides the underlying errno; the only path where SQLite
        // can't open a file we know exists is permission denied — which on
        // ~/Library/Mail/V<N>/ means Full Disk Access.
        if let rusqlite::Error::SqliteFailure(ffi, _) = &err {
            // SQLITE_CANTOPEN = 14, SQLITE_PERM = 3. Treat both as access-denied
            // signals at the public boundary; the test surface for true
            // missing-file is `DataRootMissing`, surfaced upstream by the
            // discovery layer before we ever try to open the DB.
            if ffi.code == rusqlite::ErrorCode::CannotOpen
                || ffi.code == rusqlite::ErrorCode::PermissionDenied
            {
                return MailReaderError::AccessDenied {
                    path: path.to_path_buf(),
                };
            }
        }
        MailReaderError::Sqlite(err)
    }
}

/// Return all `messages` rows with `date_received >= since_unix`,
/// ordered by `date_received` ascending so callers can use the last row's
/// `date_received` as the next watermark.
pub fn list_recent_messages(
    root: &MailDataRoot,
    since_unix: i64,
) -> Result<Vec<EmlxMetadata>, MailReaderError> {
    let envelope_index = envelope_index_path(root);
    let conn = open_read_only(&envelope_index)?;

    // The join is small: messages ⨝ mailboxes on messages.mailbox.
    // `messages.mailbox` is the FK; `mailboxes.ROWID` is the PK.
    let mut stmt = conn.prepare(
        "SELECT
             m.ROWID,
             m.message_id,
             COALESCE(m.date_received, 0),
             COALESCE(m.date_sent, 0),
             m.mailbox,
             mb.url,
             m.size,
             COALESCE(m.flags, 0)
         FROM messages m
         LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
         WHERE COALESCE(m.date_received, 0) >= ?1
         ORDER BY m.date_received ASC, m.ROWID ASC",
    )?;

    let rows = stmt.query_map([since_unix], |row| row_to_metadata(row, &root.path))?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

fn row_to_metadata(row: &Row<'_>, vn_root: &Path) -> rusqlite::Result<EmlxMetadata> {
    let rowid: i64 = row.get(0)?;
    let message_id: i64 = row.get(1)?;
    let date_received: i64 = row.get(2)?;
    let date_sent: i64 = row.get(3)?;
    let mailbox_rowid: i64 = row.get(4)?;
    let mailbox_url: Option<String> = row.get(5)?;
    let size: Option<i64> = row.get(6)?;
    let flags: i64 = row.get(7)?;
    let emlx_path = mailbox_url
        .as_deref()
        .and_then(|url| resolve_emlx_path(vn_root, url, message_id));
    Ok(EmlxMetadata {
        rowid,
        message_id,
        date_received,
        date_sent,
        mailbox_rowid,
        mailbox_url,
        size,
        flags,
        emlx_path,
    })
}

/// Best-effort resolver for the on-disk `.emlx` path from a `mailboxes.url`
/// and the `messages.message_id`.
///
/// Mail.app fans out messages into buckets of ~1000 (Mail-spike §2): the
/// first 1000 land in `Data/Messages/`, the next thousand under
/// `Data/1/Messages/`, the next under `Data/2/Messages/`, and so on. The
/// bucket for message `N` is `(N - 1) / 1000`; bucket 0 is the bare
/// `Data/Messages/` form. We return all plausible candidates flattened to
/// the first one — `read_message` is path-agnostic, so a caller that
/// wants strict resolution can `fs::metadata` each candidate.
///
/// We do NOT walk the FS here. Without an exact `<MBOX-UUID>` (one level
/// below `INBOX.mbox/`) we cannot synthesize the full path. The Envelope
/// Index does not carry `MBOX-UUID` directly; it's derived from the
/// per-mailbox `Info.plist` at scan time. V2-P8a returns `mailbox_url`
/// raw and lets `read_message` take the absolute path the caller already
/// has from `FSEvents`. V2-P8b can promote this to a strict resolver once
/// the `<MBOX-UUID>` cache lands. For now: return `None` — the explicit
/// `read_message(path)` API is the supported entry point.
fn resolve_emlx_path(_vn_root: &Path, _mailbox_url: &str, _message_id: i64) -> Option<PathBuf> {
    None
}

/// Look up the `properties.version` + `properties.minor_version` so callers
/// (telemetry, the CLI) can record what Envelope Index schema they read
/// against. Useful for future schema-drift detection without leaking
/// content. Returns `(version, minor_version)`.
pub fn schema_version(root: &MailDataRoot) -> Result<(Option<i64>, Option<i64>), MailReaderError> {
    let envelope_index = envelope_index_path(root);
    let conn = open_read_only(&envelope_index)?;
    let version: Option<i64> = conn
        .query_row(
            "SELECT value FROM properties WHERE key = 'version'",
            [],
            |r| r.get::<_, i64>(0),
        )
        .optional()?;
    let minor: Option<i64> = conn
        .query_row(
            "SELECT value FROM properties WHERE key = 'minor_version'",
            [],
            |r| r.get::<_, i64>(0),
        )
        .optional()?;
    Ok((version, minor))
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs;
    use tempfile::tempdir;

    fn build_envelope_index_fixture(root: &Path) -> PathBuf {
        let maildata = root.join("MailData");
        fs::create_dir_all(&maildata).unwrap();
        let db_path = maildata.join("Envelope Index");
        let conn = Connection::open(&db_path).expect("open ro+rw");
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
                (1, 'imap://AAAAAAAA-BBBB-CCCC-DDDD-000000000001/INBOX'),
                (2, 'imap://AAAAAAAA-BBBB-CCCC-DDDD-000000000001/Sent%20Messages');

            INSERT INTO messages
                (ROWID, message_id, date_received, date_sent, mailbox, size, flags)
            VALUES
                (1, 100, 1000, 999,  1, 512, 1),
                (2, 101, 1500, 1499, 1, 600, 0),
                (3, 102, 2000, 1999, 2, 700, 1);
            ",
        )
        .unwrap();
        // We let Connection drop here so the file is fully flushed before
        // the read-only re-open below.
        db_path
    }

    #[test]
    fn schema_version_round_trips() {
        let tmp = tempdir().unwrap();
        let vn = tmp.path().join("V10");
        fs::create_dir_all(&vn).unwrap();
        build_envelope_index_fixture(&vn);
        let root = MailDataRoot {
            path: vn.clone(),
            version: 10,
        };
        let (ver, minor) = schema_version(&root).unwrap();
        assert_eq!(ver, Some(4));
        assert_eq!(minor, Some(84003));
    }

    #[test]
    fn list_recent_messages_filters_by_watermark_and_joins_mailboxes() {
        let tmp = tempdir().unwrap();
        let vn = tmp.path().join("V10");
        fs::create_dir_all(&vn).unwrap();
        build_envelope_index_fixture(&vn);
        let root = MailDataRoot {
            path: vn,
            version: 10,
        };

        // Watermark below everything: 3 rows, ordered ascending.
        let all = list_recent_messages(&root, 0).unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].date_received, 1000);
        assert_eq!(all[2].date_received, 2000);
        assert_eq!(
            all[0].mailbox_url.as_deref(),
            Some("imap://AAAAAAAA-BBBB-CCCC-DDDD-000000000001/INBOX")
        );
        assert_eq!(
            all[2].mailbox_url.as_deref(),
            Some("imap://AAAAAAAA-BBBB-CCCC-DDDD-000000000001/Sent%20Messages")
        );

        // Watermark above the first row: 2 rows.
        let recent = list_recent_messages(&root, 1500).unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].rowid, 2);
        assert_eq!(recent[1].rowid, 3);

        // Watermark above everything: empty.
        let none = list_recent_messages(&root, 9_999_999).unwrap();
        assert!(none.is_empty());
    }
}
