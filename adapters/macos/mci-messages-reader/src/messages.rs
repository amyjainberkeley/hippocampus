//! Read-only `chat.db` reader (WAL-aware).
//!
//! `chat.db` schema (knowable from Apple's public Messages.app stack and
//! community reverse-engineering; the schema has been stable since macOS
//! 10.12 with additive columns only):
//!
//! - **`message`** — one row per message. `ROWID`, `guid`, `text` (nullable
//!   on attachment-only messages), `service` (`iMessage` | `SMS` | `RCS`),
//!   `handle_id` (sender — FK into `handle.ROWID`; 0 when `is_from_me=1`),
//!   `date` (Apple-absolute nanoseconds — see [`APPLE_EPOCH_OFFSET_SECS`]),
//!   `is_from_me`, `is_sent`, `is_delivered`, `is_read`, `cache_has_attachments`,
//!   `item_type` (0=text, 1=group rename, 2=member add, …).
//! - **`handle`** — one row per remote participant address. `ROWID`, `id`
//!   (phone or email), `service`, `country`.
//! - **`chat`** — one row per conversation. `ROWID`, `guid`, `style`
//!   (43=DM, 45=group), `service_name` (`iMessage`/`SMS`), `display_name`,
//!   `chat_identifier`.
//! - **`chat_handle_join`** — many-to-many `chat ⨯ handle`.
//! - **`chat_message_join`** — many-to-many `chat ⨯ message`, with
//!   `message_date` (Apple-absolute ns) duplicated for fast time-range
//!   queries on a chat.
//!
//! V2-P7 exposes the minimum surface needed by the V2-P10 brain-ingest
//! plumbing:
//!
//! - [`list_recent_messages`] returns rows since a unix-seconds watermark.
//! - [`read_thread`] returns participants + ordered messages for one chat.
//!
//! Both functions open `chat.db` with `SQLITE_OPEN_READ_ONLY` only —
//! Messages.app is a live writer; `immutable=1` would lie to `SQLite` about
//! that. WAL admits one writer + many readers, so read-only is safe.

use std::path::Path;
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, Row};

use crate::discover::ChatDbLocation;
use crate::error::MessagesReaderError;

/// Apple-absolute time epoch is 2001-01-01T00:00:00 UTC.
/// Add this to a Mac-absolute-time (seconds since 2001) value to get the
/// equivalent unix-seconds value. Apple stores `message.date` and
/// `chat_message_join.message_date` in *nanoseconds* since this epoch
/// (`date / 1_000_000_000 + APPLE_EPOCH_OFFSET_SECS` → unix seconds).
///
/// (`978_307_200` = number of seconds between 1970-01-01 and
/// 2001-01-01 UTC.)
pub const APPLE_EPOCH_OFFSET_SECS: i64 = 978_307_200;

/// One row from `chat.db`'s `message` table, projected to the fields V2-P10
/// brain-ingest needs.
///
/// `body` is `None` for messages with no rendered text (attachment-only,
/// reactions, system messages). The cascade-equivalent in
/// `core/brain/src/redaction/messages_plugin.rs` treats `None` as an
/// auto-drop (no body to redact, nothing to ingest).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageRow {
    /// `message.ROWID`. Stable per-message id; suitable as a watermark
    /// surface for incremental polling alongside `date`.
    pub rowid: i64,
    /// `message.guid`. Cross-device stable per-message id; the natural
    /// dedup key when V2-P11 sync arrives.
    pub guid: String,
    /// Unix-seconds form of `message.date` (already converted from Apple
    /// absolute nanoseconds). The right column for "give me everything
    /// since timestamp T".
    pub date_unix: i64,
    /// `1` when the user sent it; `0` when received.
    pub is_from_me: bool,
    /// `message.service` — `"iMessage"`, `"SMS"`, or `"RCS"` on macOS 26+.
    pub service: ChatService,
    /// `message.text`. `None` for attachment-only / system messages.
    pub body: Option<String>,
    /// `message.handle_id` → `handle.ROWID`. `0` when `is_from_me=1`
    /// (the user has no row in `handle`).
    pub handle_rowid: i64,
    /// `handle.id` for the sender (phone or email). `None` when
    /// `is_from_me=1` or the join is empty.
    pub sender_handle: Option<String>,
    /// `1` when the message has attachments. The body of an
    /// attachment-only message is `None`; this field lets the
    /// cascade-equivalent route to a "drop with `reason=plugin_no_body`"
    /// surface vs. running the SMS-OTP regex on `Some("")`.
    pub has_attachments: bool,
}

/// `message.service` enum, normalized to a closed set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatService {
    /// iMessage — end-to-end-encrypted Apple service.
    IMessage,
    /// SMS / MMS — carrier text relayed via Continuity from iPhone.
    Sms,
    /// RCS — Rich Communication Services. macOS 26+ on supported carriers.
    Rcs,
    /// Anything Apple ever adds to the `service` column we don't know about
    /// yet. The cascade-equivalent treats `Other` the same as `Sms` for
    /// redaction purposes (defense-in-depth: every non-iMessage path runs
    /// through the full SMS-OTP regex set).
    Other,
}

impl ChatService {
    /// Parse the `service` column. Case-insensitive.
    ///
    /// Named `from_str_ci` (not `from_str`) so it doesn't shadow the
    /// `std::str::FromStr::from_str` blanket which would require an
    /// `Err` associated type we deliberately do not have (an unknown
    /// service maps to [`Self::Other`], not an error).
    #[must_use]
    pub fn from_str_ci(raw: &str) -> Self {
        match raw.to_ascii_lowercase().as_str() {
            "imessage" => Self::IMessage,
            "sms" | "mms" => Self::Sms,
            "rcs" => Self::Rcs,
            _ => Self::Other,
        }
    }

    /// Back to the canonical display string. Useful for tests + the CLI.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::IMessage => "iMessage",
            Self::Sms => "SMS",
            Self::Rcs => "RCS",
            Self::Other => "other",
        }
    }
}

/// One participant in a thread. `id` is the phone number or email address
/// (Apple's `handle.id` column).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParticipantHandle {
    /// `handle.ROWID`.
    pub rowid: i64,
    /// `handle.id` — phone (E.164-like) or email.
    pub id: String,
    /// `handle.service` — `"iMessage"` / `"SMS"` / `"RCS"`.
    pub service: ChatService,
}

/// One conversation, with its participants and ordered messages.
#[derive(Debug, Clone)]
pub struct Thread {
    /// `chat.ROWID`.
    pub chat_rowid: i64,
    /// `chat.guid`. Cross-device stable per-thread id.
    pub guid: String,
    /// `chat.style` — `43` for DM, `45` for group chat. Carried verbatim
    /// so the V2-P10 brain ingest can attribute episode shape.
    pub style: i64,
    /// `chat.display_name` if set (group chats), else `None`.
    pub display_name: Option<String>,
    /// Remote participants (the user is implicit; their messages have
    /// `is_from_me=1`).
    pub participants: Vec<ParticipantHandle>,
    /// Messages in this thread, ordered ascending by `date`.
    pub messages: Vec<MessageRow>,
}

/// Open `chat.db` read-only with WAL-aware flags.
///
/// `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_NO_MUTEX`. Deliberately NO
/// `immutable=1` — Messages.app writes the file live and `immutable=1`
/// would lie to `SQLite` about that. WAL admits one writer + many readers,
/// so this is safe.
fn open_read_only(chat_db: &Path) -> Result<Connection, MessagesReaderError> {
    let conn = Connection::open_with_flags(
        chat_db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(map_sqlite_io_err(chat_db))?;

    // Modest busy timeout — Messages.app can hold the WAL writer lock
    // briefly during an iMessage exchange. 250 ms is more than enough.
    conn.busy_timeout(Duration::from_millis(250))?;

    Ok(conn)
}

fn map_sqlite_io_err(
    path: &Path,
) -> impl FnOnce(rusqlite::Error) -> MessagesReaderError + '_ {
    move |err| {
        if let rusqlite::Error::SqliteFailure(ffi, _) = &err {
            if ffi.code == rusqlite::ErrorCode::CannotOpen
                || ffi.code == rusqlite::ErrorCode::PermissionDenied
            {
                return MessagesReaderError::AccessDenied {
                    path: path.to_path_buf(),
                };
            }
        }
        MessagesReaderError::Sqlite(err)
    }
}

/// Return all `message` rows whose `date_unix >= since_unix`, ordered by
/// `date` ascending so callers can use the last row's `date_unix` as the
/// next watermark.
///
/// The query joins `handle` left-anchored on `message.handle_id` to
/// recover the sender's phone/email address in one round-trip. Joining
/// `chat` for the originating thread is left to [`read_thread`].
///
/// Apple stores `message.date` in nanoseconds since 2001-01-01 UTC; the
/// `WHERE` predicate converts the input watermark *back* to that frame so
/// the comparison can ride on top of any index that Messages.app keeps on
/// `date`.
pub fn list_recent_messages(
    loc: &ChatDbLocation,
    since_unix: i64,
) -> Result<Vec<MessageRow>, MessagesReaderError> {
    let conn = open_read_only(&loc.path)?;

    let since_apple_ns = unix_seconds_to_apple_ns(since_unix);

    let mut stmt = conn.prepare(
        "SELECT
             m.ROWID,
             COALESCE(m.guid, ''),
             COALESCE(m.date, 0),
             COALESCE(m.is_from_me, 0),
             COALESCE(m.service, ''),
             m.text,
             COALESCE(m.handle_id, 0),
             h.id,
             COALESCE(m.cache_has_attachments, 0)
         FROM message m
         LEFT JOIN handle h ON h.ROWID = m.handle_id
         WHERE COALESCE(m.date, 0) >= ?1
         ORDER BY m.date ASC, m.ROWID ASC",
    )?;

    let rows = stmt.query_map([since_apple_ns], row_to_message)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// Return one [`Thread`] for the given `chat.ROWID`.
///
/// The participant list is the result of
/// `chat_handle_join ⨝ handle WHERE chat_handle_join.chat_id = ?`. The
/// message list is the result of `chat_message_join ⨝ message ⨝ handle
/// WHERE chat_message_join.chat_id = ?` ordered by `message.date`.
pub fn read_thread(
    loc: &ChatDbLocation,
    chat_rowid: i64,
) -> Result<Option<Thread>, MessagesReaderError> {
    let conn = open_read_only(&loc.path)?;

    // 1) chat metadata. Returns None when the rowid does not exist.
    let chat = conn
        .query_row(
            "SELECT COALESCE(c.guid, ''),
                    COALESCE(c.style, 0),
                    c.display_name
               FROM chat c
              WHERE c.ROWID = ?1",
            [chat_rowid],
            |r| {
                let guid: String = r.get(0)?;
                let style: i64 = r.get(1)?;
                let display_name: Option<String> = r.get(2)?;
                Ok((guid, style, display_name))
            },
        )
        .optional_row()?;

    let Some((guid, style, display_name)) = chat else {
        return Ok(None);
    };

    // 2) participants.
    let mut p_stmt = conn.prepare(
        "SELECT h.ROWID,
                COALESCE(h.id, ''),
                COALESCE(h.service, '')
           FROM chat_handle_join chj
           JOIN handle h ON h.ROWID = chj.handle_id
          WHERE chj.chat_id = ?1
          ORDER BY h.ROWID ASC",
    )?;
    let participants: Vec<ParticipantHandle> = p_stmt
        .query_map([chat_rowid], |r| {
            let rowid: i64 = r.get(0)?;
            let id: String = r.get(1)?;
            let service_raw: String = r.get(2)?;
            Ok(ParticipantHandle {
                rowid,
                id,
                service: ChatService::from_str_ci(&service_raw),
            })
        })?
        .collect::<rusqlite::Result<_>>()?;

    // 3) messages.
    let mut m_stmt = conn.prepare(
        "SELECT m.ROWID,
                COALESCE(m.guid, ''),
                COALESCE(m.date, 0),
                COALESCE(m.is_from_me, 0),
                COALESCE(m.service, ''),
                m.text,
                COALESCE(m.handle_id, 0),
                h.id,
                COALESCE(m.cache_has_attachments, 0)
           FROM chat_message_join cmj
           JOIN message m ON m.ROWID = cmj.message_id
           LEFT JOIN handle h ON h.ROWID = m.handle_id
          WHERE cmj.chat_id = ?1
          ORDER BY m.date ASC, m.ROWID ASC",
    )?;
    let messages: Vec<MessageRow> = m_stmt
        .query_map([chat_rowid], row_to_message)?
        .collect::<rusqlite::Result<_>>()?;

    Ok(Some(Thread {
        chat_rowid,
        guid,
        style,
        display_name,
        participants,
        messages,
    }))
}

/// Project one `message` row → [`MessageRow`].
fn row_to_message(row: &Row<'_>) -> rusqlite::Result<MessageRow> {
    let rowid: i64 = row.get(0)?;
    let guid: String = row.get(1)?;
    let date_ns: i64 = row.get(2)?;
    let is_from_me_i: i64 = row.get(3)?;
    let service_raw: String = row.get(4)?;
    let body: Option<String> = row.get(5)?;
    let handle_rowid: i64 = row.get(6)?;
    let sender_handle: Option<String> = row.get(7)?;
    let has_attachments_i: i64 = row.get(8)?;
    Ok(MessageRow {
        rowid,
        guid,
        date_unix: apple_ns_to_unix_seconds(date_ns),
        is_from_me: is_from_me_i != 0,
        service: ChatService::from_str_ci(&service_raw),
        body,
        handle_rowid,
        sender_handle,
        has_attachments: has_attachments_i != 0,
    })
}

/// Convert an Apple-absolute nanoseconds value to unix seconds.
///
/// The transformation tolerates the historical case where Messages.app
/// stored seconds (not nanoseconds) — older macOS releases (pre-Sierra)
/// used seconds and the `date` column was migrated by Messages.app on
/// first launch. Any value below ~10^12 is treated as already-seconds.
#[must_use]
pub fn apple_ns_to_unix_seconds(date_ns: i64) -> i64 {
    if date_ns < 1_000_000_000_000 {
        // Old shape (seconds since 2001) — leave as-is, just shift epoch.
        date_ns + APPLE_EPOCH_OFFSET_SECS
    } else {
        date_ns / 1_000_000_000 + APPLE_EPOCH_OFFSET_SECS
    }
}

/// Inverse: convert a unix-seconds watermark to the Apple-absolute
/// nanoseconds form Messages.app stores in `message.date`.
#[must_use]
pub fn unix_seconds_to_apple_ns(unix_seconds: i64) -> i64 {
    let apple_seconds = unix_seconds.saturating_sub(APPLE_EPOCH_OFFSET_SECS);
    apple_seconds.saturating_mul(1_000_000_000)
}

// Tiny `OptionalExtension::optional` shim for `query_row` — we already
// pull in `rusqlite::OptionalExtension`, but the trait method moves the
// `Result` so we wrap it in a small helper trait to keep the call-site
// expression compact.
trait OptionalRow<T> {
    fn optional_row(self) -> Result<Option<T>, MessagesReaderError>;
}

impl<T> OptionalRow<T> for rusqlite::Result<T> {
    fn optional_row(self) -> Result<Option<T>, MessagesReaderError> {
        match self {
            Ok(t) => Ok(Some(t)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use rusqlite::Connection;
    use tempfile::tempdir;

    fn build_chat_db_fixture(path: &Path) {
        let conn = Connection::open(path).expect("open chat.db fixture");
        conn.execute_batch(
            "
            -- minimal subset of the real chat.db schema needed by V2-P7.
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
                chat_id INTEGER,
                handle_id INTEGER,
                PRIMARY KEY (chat_id, handle_id)
            );
            CREATE TABLE chat_message_join (
                chat_id INTEGER,
                message_id INTEGER,
                message_date INTEGER,
                PRIMARY KEY (chat_id, message_id)
            );

            INSERT INTO handle (ROWID, id, service, country) VALUES
                (1, '+15551234567', 'iMessage', 'US'),
                (2, 'bob@example.com', 'iMessage', 'US'),
                (3, '+15559999999', 'SMS', 'US');

            INSERT INTO chat (ROWID, guid, style, service_name, display_name, chat_identifier)
            VALUES
                (10, 'iMessage;-;+15551234567', 43, 'iMessage', NULL, '+15551234567'),
                (11, 'iMessage;-;chat999',      45, 'iMessage', 'Project crew', 'chat999');

            -- Apple-absolute nanoseconds. The unix timestamp 1_900_000_000
            -- corresponds to apple_seconds 921_692_800 (1_900_000_000 -
            -- 978_307_200) → 921_692_800_000_000_000 ns.
            INSERT INTO message
                (ROWID, guid, text, handle_id, service, date, is_from_me,
                 is_sent, is_delivered, is_read, cache_has_attachments, item_type)
            VALUES
                (100, 'M-AAAA', 'Hello from Alice (synthetic).',          1, 'iMessage',
                       921692800000000000, 0, 0, 1, 1, 0, 0),
                (101, 'M-BBBB', 'Reply from me (synthetic).',             0, 'iMessage',
                       921692900000000000, 1, 1, 1, 1, 0, 0),
                (102, 'M-CCCC', '482917 is your verification code.',      3, 'SMS',
                       921693000000000000, 0, 0, 1, 1, 0, 0),
                (103, 'M-DDDD', NULL,                                     2, 'iMessage',
                       921693100000000000, 0, 0, 1, 1, 1, 0);

            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                (10, 1),
                (11, 2);

            INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES
                (10, 100, 921692800000000000),
                (10, 101, 921692900000000000),
                (10, 102, 921693000000000000),
                (11, 103, 921693100000000000);
            ",
        )
        .unwrap();
        drop(conn);
    }

    fn fixture_location() -> (tempfile::TempDir, ChatDbLocation) {
        let tmp = tempdir().unwrap();
        let root = tmp.path().join("Library").join("Messages");
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("chat.db");
        build_chat_db_fixture(&path);
        let loc = ChatDbLocation { path, root };
        (tmp, loc)
    }

    #[test]
    fn apple_ns_round_trip_for_modern_value() {
        let unix = 1_900_000_000_i64;
        let apple = unix_seconds_to_apple_ns(unix);
        assert_eq!(apple, 921_692_800_000_000_000);
        assert_eq!(apple_ns_to_unix_seconds(apple), unix);
    }

    #[test]
    fn apple_ns_handles_old_seconds_shape() {
        // Pre-Sierra rows had seconds, not nanoseconds. The accessor
        // tolerates that without re-quoting Messages.app's migrator.
        let unix = apple_ns_to_unix_seconds(100);
        assert_eq!(unix, 100 + APPLE_EPOCH_OFFSET_SECS);
    }

    #[test]
    fn list_recent_messages_returns_rows_in_date_order() {
        let (_guard, loc) = fixture_location();
        let all = list_recent_messages(&loc, 0).unwrap();
        assert_eq!(all.len(), 4);
        // Ordered ascending by `date`.
        assert!(all[0].date_unix <= all[1].date_unix);
        assert!(all[1].date_unix <= all[2].date_unix);

        // First row is the Alice → me iMessage.
        assert_eq!(all[0].rowid, 100);
        assert_eq!(all[0].guid, "M-AAAA");
        assert_eq!(all[0].body.as_deref(), Some("Hello from Alice (synthetic)."));
        assert!(!all[0].is_from_me);
        assert_eq!(all[0].service, ChatService::IMessage);
        assert_eq!(all[0].sender_handle.as_deref(), Some("+15551234567"));

        // SMS row carries the OTP shape — V2-P10 redaction will catch it.
        assert_eq!(all[2].service, ChatService::Sms);
        assert_eq!(all[2].body.as_deref(), Some("482917 is your verification code."));

        // Attachment-only row has body=None.
        assert_eq!(all[3].rowid, 103);
        assert!(all[3].body.is_none());
        assert!(all[3].has_attachments);
    }

    #[test]
    fn list_recent_messages_respects_watermark() {
        let (_guard, loc) = fixture_location();

        // unix_seconds = 921_692_900 + APPLE_EPOCH_OFFSET_SECS
        // = 921_692_900 + 978_307_200 = 1_900_000_100. The first row's
        // unix_seconds is 1_900_000_000; the second is 1_900_000_100.
        let recent = list_recent_messages(&loc, 1_900_000_100).unwrap();
        assert_eq!(recent.len(), 3);
        assert_eq!(recent[0].rowid, 101);
    }

    #[test]
    fn read_thread_returns_participants_and_messages() {
        let (_guard, loc) = fixture_location();
        let t = read_thread(&loc, 10).unwrap().expect("chat 10 exists");
        assert_eq!(t.chat_rowid, 10);
        assert_eq!(t.style, 43);
        assert_eq!(t.guid, "iMessage;-;+15551234567");
        assert_eq!(t.participants.len(), 1);
        assert_eq!(t.participants[0].id, "+15551234567");
        assert_eq!(t.participants[0].service, ChatService::IMessage);

        // chat 10 has 3 messages (the 4th is in chat 11).
        assert_eq!(t.messages.len(), 3);
        assert_eq!(t.messages[0].rowid, 100);
        assert_eq!(t.messages[2].rowid, 102);
    }

    #[test]
    fn read_thread_returns_none_for_unknown_chat() {
        let (_guard, loc) = fixture_location();
        assert!(read_thread(&loc, 9999).unwrap().is_none());
    }

    #[test]
    fn read_thread_handles_group_chat() {
        let (_guard, loc) = fixture_location();
        let t = read_thread(&loc, 11).unwrap().expect("chat 11 exists");
        assert_eq!(t.style, 45);
        assert_eq!(t.display_name.as_deref(), Some("Project crew"));
        assert_eq!(t.participants.len(), 1);
        assert_eq!(t.messages.len(), 1);
        assert_eq!(t.messages[0].rowid, 103);
        assert!(t.messages[0].has_attachments);
    }

    #[test]
    fn chat_service_round_trips() {
        assert_eq!(ChatService::from_str_ci("iMessage"), ChatService::IMessage);
        assert_eq!(ChatService::from_str_ci("IMESSAGE"), ChatService::IMessage);
        assert_eq!(ChatService::from_str_ci("SMS"), ChatService::Sms);
        assert_eq!(ChatService::from_str_ci("MMS"), ChatService::Sms);
        assert_eq!(ChatService::from_str_ci("RCS"), ChatService::Rcs);
        assert_eq!(ChatService::from_str_ci("future-protocol"), ChatService::Other);
        assert_eq!(ChatService::IMessage.as_str(), "iMessage");
        assert_eq!(ChatService::Sms.as_str(), "SMS");
    }
}
