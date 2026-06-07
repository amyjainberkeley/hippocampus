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
    /// `is_from_me=1` or the join is empty. This is the **incoming**
    /// "who": it is keyed on the message row's own `handle_id`, which
    /// Apple sets to `0` on every row the user SENT (the local user is
    /// never a row in `handle`). For the **outgoing** "who" see
    /// [`Self::recipient_handles`].
    pub sender_handle: Option<String>,
    /// `1` when the message has attachments. The body of an
    /// attachment-only message is `None`; this field lets the
    /// cascade-equivalent route to a "drop with `reason=plugin_no_body`"
    /// surface vs. running the SMS-OTP regex on `Some("")`.
    pub has_attachments: bool,
    /// The remote participant set of the **chat this message belongs
    /// to**, resolved via `chat_message_join ⨝ chat_handle_join ⨝
    /// handle`. This is the **outgoing** "who": for a row the user sent
    /// (`is_from_me = 1`, `handle_rowid = 0`) the recipient is NOT on the
    /// message row — it lives on the conversation, so we source it from
    /// the chat's remote participants. A 1:1 DM yields exactly one entry;
    /// a group chat yields N (every remote member). Empty when the
    /// message maps to no chat or the chat has no resolvable remote
    /// handle. Deduped and sorted (byte-lexicographic ascending) by the
    /// reader so the persisted who-label is stable across reads — SQLite's
    /// `group_concat` order is otherwise unspecified (see
    /// [`parse_recipient_handles`]).
    ///
    /// Populated for **every** row (incoming rows also belong to a chat),
    /// but the brain-ingest pump only consults it for the outgoing
    /// direction — an incoming row's "who" is its [`Self::sender_handle`],
    /// kept byte-identical to the pre-recipient-resolution behavior.
    pub recipient_handles: Vec<String>,
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
/// recover the **sender's** phone/email address (the incoming "who") in
/// one round-trip. The **recipient** set — the outgoing "who" — is NOT on
/// the message row (Apple sets `handle_id = 0` on everything the user
/// sent); it lives on the conversation, so the correlated subquery walks
/// `chat_message_join ⨝ chat_handle_join ⨝ handle` to recover the chat's
/// remote participants. [`MessageRow::recipient_handles`] carries that
/// set; see [`row_to_message`] for how the `char(31)`-joined aggregate is
/// split back out.
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
             COALESCE(m.cache_has_attachments, 0),
             (SELECT group_concat(rh.id, char(31))
                FROM chat_message_join cmj
                JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
                JOIN handle rh ON rh.ROWID = chj.handle_id
               WHERE cmj.message_id = m.ROWID)
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

    // 3) messages. Projects the SAME column shape as `list_recent_messages`
    // (the shared `row_to_message` reads column 9 = the recipient-handle
    // aggregate), so the correlated `chat_message_join ⨝ chat_handle_join ⨝
    // handle` subquery is repeated here verbatim.
    let mut m_stmt = conn.prepare(
        "SELECT m.ROWID,
                COALESCE(m.guid, ''),
                COALESCE(m.date, 0),
                COALESCE(m.is_from_me, 0),
                COALESCE(m.service, ''),
                m.text,
                COALESCE(m.handle_id, 0),
                h.id,
                COALESCE(m.cache_has_attachments, 0),
                (SELECT group_concat(rh.id, char(31))
                   FROM chat_message_join cmj2
                   JOIN chat_handle_join chj ON chj.chat_id = cmj2.chat_id
                   JOIN handle rh ON rh.ROWID = chj.handle_id
                  WHERE cmj2.message_id = m.ROWID)
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
///
/// Column 9 is the `char(31)`-joined recipient-handle aggregate produced by
/// the correlated subquery in [`list_recent_messages`] / [`read_thread`].
/// `group_concat` returns `NULL` (→ `None`) when the message maps to no
/// chat-participant row; [`parse_recipient_handles`] splits + dedups the
/// non-null case.
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
    let recipient_raw: Option<String> = row.get(9)?;
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
        recipient_handles: parse_recipient_handles(recipient_raw.as_deref()),
    })
}

/// Split the `char(31)`-joined recipient aggregate from the SQL layer into a
/// deduped, **sorted** `Vec<String>`. `char(31)` (ASCII unit separator) never
/// appears in a phone number or email address, so it is an unambiguous
/// delimiter for `group_concat`. Empty / whitespace-only fragments are
/// dropped and duplicates collapsed (a message that maps to more than one
/// chat — or a handle that exists once per service — can repeat an address).
///
/// The output is sorted (byte-lexicographic ascending) **here in Rust**, not
/// in SQL: `group_concat` leaves element order unspecified absent a per-
/// aggregate `ORDER BY` (and the ordered form needs SQLite ≥ 3.44), so
/// sorting at the boundary makes the persisted who-label (`to a, b, c`)
/// stable across reads of identical data regardless of the query plan or the
/// bundled SQLite version. The set membership is what the cascade gates and
/// per-handle extraction consume; both are order-independent, so the sort is
/// purely for a deterministic display string.
fn parse_recipient_handles(raw: Option<&str>) -> Vec<String> {
    let Some(raw) = raw else {
        return Vec::new();
    };
    let mut out: Vec<String> = Vec::new();
    for part in raw.split('\u{1f}') {
        let p = part.trim();
        if !p.is_empty() && !out.iter().any(|e| e == p) {
            out.push(p.to_owned());
        }
    }
    out.sort();
    out
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
                (3, '+15559999999', 'SMS', 'US'),
                (4, '+15558887777', 'iMessage', 'US');

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
                       921693100000000000, 0, 0, 1, 1, 1, 0),
                -- Outgoing (is_from_me=1, handle_id=0) into the group chat 11.
                -- The recipient is NOT on this row; it is chat 11's remote
                -- participant set {bob@example.com, +15558887777}.
                (104, 'M-EEEE', 'See you all there (synthetic).',         0, 'iMessage',
                       921693200000000000, 1, 1, 1, 1, 0, 0);

            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                (10, 1),
                (11, 2),
                (11, 4);

            INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES
                (10, 100, 921692800000000000),
                (10, 101, 921692900000000000),
                (10, 102, 921693000000000000),
                (11, 103, 921693100000000000),
                (11, 104, 921693200000000000);
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
        assert_eq!(all.len(), 5);
        // Ordered ascending by `date`.
        assert!(all[0].date_unix <= all[1].date_unix);
        assert!(all[1].date_unix <= all[2].date_unix);
        assert!(all[3].date_unix <= all[4].date_unix);

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

        // Last row is the outgoing group message.
        assert_eq!(all[4].rowid, 104);
        assert!(all[4].is_from_me);
        // The user has no row in `handle`, so the message row's own sender
        // join is empty — the recipient must come from the chat instead.
        assert!(all[4].sender_handle.is_none());
        assert_eq!(all[4].handle_rowid, 0);
    }

    #[test]
    fn list_recent_messages_respects_watermark() {
        let (_guard, loc) = fixture_location();

        // unix_seconds = 921_692_900 + APPLE_EPOCH_OFFSET_SECS
        // = 921_692_900 + 978_307_200 = 1_900_000_100. The first row's
        // unix_seconds is 1_900_000_000; the second is 1_900_000_100.
        let recent = list_recent_messages(&loc, 1_900_000_100).unwrap();
        assert_eq!(recent.len(), 4);
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
        assert_eq!(t.participants.len(), 2);
        let p_ids: Vec<&str> = t.participants.iter().map(|p| p.id.as_str()).collect();
        assert!(p_ids.contains(&"bob@example.com"));
        assert!(p_ids.contains(&"+15558887777"));
        // chat 11 now holds the attachment-only incoming row AND the
        // outgoing group reply.
        assert_eq!(t.messages.len(), 2);
        assert_eq!(t.messages[0].rowid, 103);
        assert!(t.messages[0].has_attachments);
        assert_eq!(t.messages[1].rowid, 104);
        assert!(t.messages[1].is_from_me);
    }

    #[test]
    fn list_recent_messages_resolves_dm_recipient_for_outgoing() {
        // Row 101 is the user's outgoing reply in the 1:1 DM (chat 10).
        // `handle_id = 0` (no sender row), so the recipient is sourced from
        // the chat's single remote participant.
        let (_guard, loc) = fixture_location();
        let all = list_recent_messages(&loc, 0).unwrap();
        let outgoing = all.iter().find(|m| m.rowid == 101).expect("row 101");
        assert!(outgoing.is_from_me);
        assert!(outgoing.sender_handle.is_none(), "no sender on a sent row");
        assert_eq!(
            outgoing.recipient_handles,
            vec!["+15551234567".to_owned()],
            "DM: exactly the one remote participant of the chat"
        );
    }

    #[test]
    fn list_recent_messages_resolves_group_recipients_for_outgoing() {
        // Row 104 is the user's outgoing message into the GROUP chat 11,
        // whose remote participants are {bob@example.com, +15558887777}.
        let (_guard, loc) = fixture_location();
        let all = list_recent_messages(&loc, 0).unwrap();
        let outgoing = all.iter().find(|m| m.rowid == 104).expect("row 104");
        assert!(outgoing.is_from_me);
        let mut got = outgoing.recipient_handles.clone();
        got.sort();
        assert_eq!(
            got,
            vec!["+15558887777".to_owned(), "bob@example.com".to_owned()],
            "group: the full remote participant set, deduped"
        );
    }

    #[test]
    fn list_recent_messages_incoming_recipient_set_excludes_no_one() {
        // The recipient aggregate is populated for incoming rows too (they
        // also belong to a chat); the pump simply ignores it for the
        // incoming direction. Row 100 is incoming in the DM (chat 10).
        let (_guard, loc) = fixture_location();
        let all = list_recent_messages(&loc, 0).unwrap();
        let incoming = all.iter().find(|m| m.rowid == 100).expect("row 100");
        assert!(!incoming.is_from_me);
        // Incoming "who" stays on `sender_handle` (unchanged); the chat's
        // remote set is also resolvable but is not the incoming who.
        assert_eq!(incoming.sender_handle.as_deref(), Some("+15551234567"));
        assert_eq!(incoming.recipient_handles, vec!["+15551234567".to_owned()]);
    }

    #[test]
    fn parse_recipient_handles_dedups_trims_drops_empties_and_sorts() {
        // `None` (group_concat returned NULL — no chat-participant row).
        assert!(parse_recipient_handles(None).is_empty());

        // Drives every branch at once: a leading/trailing-whitespace
        // fragment (trimmed), a duplicate (a message that maps to two chats —
        // or a handle that exists once per service — can repeat an address;
        // collapsed), and empty fragments from a doubled / trailing
        // separator (dropped). Output is sorted byte-lexicographic ascending,
        // so '+' (0x2B) precedes 'b' (0x62) deterministically.
        let raw = "  bob@example.com \u{1f}+15558887777\u{1f}bob@example.com\u{1f}\u{1f}";
        assert_eq!(
            parse_recipient_handles(Some(raw)),
            vec!["+15558887777".to_owned(), "bob@example.com".to_owned()],
        );

        // A single handle round-trips unchanged.
        assert_eq!(
            parse_recipient_handles(Some("+15551234567")),
            vec!["+15551234567".to_owned()]
        );

        // Separator-only / all-empty input collapses to nothing.
        assert!(parse_recipient_handles(Some("\u{1f}\u{1f}")).is_empty());
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
