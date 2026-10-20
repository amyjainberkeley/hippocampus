//! Moment readings: a moment's cleaned text and its caption, kept beside the
//! stored text so they are not made again on every scroll (migration 0015).
//!
//! The re-clean job ([`crate::reclean`]) writes them; the window, the FFI and
//! AI tools read them. The stored text in `events` is never touched: it keeps
//! what was read, byte for byte, and stays what search indexes.
//!
//! A row is made from one event and goes with it: it cascades from the event,
//! and [`delete_for_events`] removes it explicitly in every deletion
//! transaction (forget one, delete a range, retention, wipe). It is written
//! only while the event with its id is still the moment it was made from
//! (the same time, app, title and text): an id freed by a deletion and taken
//! by a new capture never receives what was made from the moment it held.

use std::collections::HashMap;

use rusqlite::{params, OptionalExtension, Transaction};

use crate::reading::Reading;
use crate::{EventId, EventSource, SqlCipherBrainStore, StoreError};

/// The version of the rules a row was made by: the one-frame and many-frame
/// chrome rules and the caption rules. A row with this version is done and is
/// never made again; raise it when those rules change, and the job makes every
/// row again, newest first.
///
/// 2: chrome only at a window's edges and only in older text, learned lines
/// of two words or more at the edges of half an app's frames, captions that
/// make no guess about the person or a window beside the front one.
///
/// 3: wrapped lines also join after a joining word ("ties go down and" /
/// "half go up"), before a name and after a sentence that fills the line
/// (J2 to J4, SPEC 4.3); AI chats read as prose; chats with people join only
/// a line that fills the line; two CJK characters join with no space; Zoom's
/// navigation bar and Gmail's label chips are chrome.
pub const READING_VERSION: u32 = 3;

/// The version the caption rules last changed in. When only the reading's
/// rules change, a row made by this version or a later one keeps the fact
/// that the model was asked, and the model's line while it is still grounded
/// in the moment as it now reads: the model is not asked again about a moment
/// it already answered for.
pub const CAPTION_RULES_SINCE: u32 = 2;

/// `caption_by` for a caption made from the title, without a model.
pub const CAPTION_BY_TITLE: &str = "title";

/// The longest caption the table takes, in characters.
const CAPTION_MAX_CHARS: usize = 200;

/// A moment's cleaned text and caption.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MomentReading {
    /// The event this was made from.
    pub event_id: EventId,
    /// The rules it was made by ([`READING_VERSION`]).
    pub version: u32,
    /// The text with the chrome learned from many frames set apart; `None`
    /// when that moved nothing, so the live reading is the same.
    pub reading: Option<Reading>,
    /// One short plain line, when one could be made.
    pub caption: Option<String>,
    /// Who wrote it: [`CAPTION_BY_TITLE`] or the on-device model's label.
    pub caption_by: Option<String>,
    /// The model was asked about this moment and is not asked again.
    pub model_tried: bool,
    /// When the row was written, microseconds since the epoch.
    pub updated_us: u64,
}

/// A stored moment, as the re-clean job reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredMoment {
    /// Its id.
    pub id: EventId,
    /// When it was captured.
    pub ts_us: u64,
    /// The app's bundle id.
    pub app_bundle_id: Option<String>,
    /// The window title.
    pub window_title: Option<String>,
    /// The page address.
    pub url: Option<String>,
    /// The stored text, header and all.
    pub text: String,
    /// Where it came from.
    pub source: EventSource,
}

/// How far the re-clean job has got.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReadingProgress {
    /// Moments with a row of the current version.
    pub done: u64,
    /// All moments.
    pub total: u64,
    /// Moments whose caption still waits for the model.
    pub awaiting_model: u64,
}

fn backend(context: &str, error: impl std::fmt::Display) -> StoreError {
    StoreError::Backend(format!("{context}: {error}"))
}

fn sql_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn table_exists(conn: &rusqlite::Connection, name: &str) -> Result<bool, StoreError> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        params![name],
        |row| row.get(0),
    )
    .map_err(|e| backend("probe table", e))
}

const READING_COLUMNS: &str =
    "event_id, version, main, rest, caption, caption_by, model_tried, updated_us";

fn row_to_reading(row: &rusqlite::Row<'_>) -> rusqlite::Result<MomentReading> {
    let main: Option<String> = row.get(2)?;
    let rest: Option<String> = row.get(3)?;
    Ok(MomentReading {
        event_id: EventId(u64::try_from(row.get::<_, i64>(0)?).unwrap_or(0)),
        version: u32::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
        reading: main.map(|main| Reading {
            main,
            rest: rest.unwrap_or_default(),
        }),
        caption: row.get(4)?,
        caption_by: row.get(5)?,
        model_tried: row.get::<_, i64>(6)? != 0,
        updated_us: u64::try_from(row.get::<_, i64>(7)?).unwrap_or(0),
    })
}

fn moment_select(has_sources: bool) -> &'static str {
    if has_sources {
        "SELECT e.id, e.ts_us, e.app_bundle_id, e.window_title, e.url, e.text,
                COALESCE(s.source_kind, 'unknown')
         FROM events e LEFT JOIN event_sources s ON s.event_id = e.id"
    } else {
        "SELECT e.id, e.ts_us, e.app_bundle_id, e.window_title, e.url, e.text, 'unknown'
         FROM events e"
    }
}

fn row_to_moment(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredMoment> {
    Ok(StoredMoment {
        id: EventId(u64::try_from(row.get::<_, i64>(0)?).unwrap_or(0)),
        ts_us: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
        app_bundle_id: row.get(2)?,
        window_title: row.get(3)?,
        url: row.get(4)?,
        text: row.get(5)?,
        source: EventSource::from_stored(&row.get::<_, String>(6)?),
    })
}

/// The test that the event with a row's id is still the moment the row was
/// made from: the same time, app, title and stored text. `?1` is the id;
/// `?{n}` to `?{n+3}` the moment's time, app, title and text.
fn same_moment(first: usize) -> String {
    format!(
        "EXISTS (SELECT 1 FROM events WHERE id = ?1 AND ts_us = ?{first}
                  AND app_bundle_id IS ?{} AND window_title IS ?{} AND text = ?{})",
        first + 1,
        first + 2,
        first + 3
    )
}

impl SqlCipherBrainStore {
    /// Write a moment's reading, made from `read`, replacing any row it had.
    /// Returns `false` and writes nothing when the moment is gone (forgotten,
    /// expired), and when its id now holds another moment (a capture that
    /// took the id a deletion freed), so a job that read a moment just before
    /// it was deleted leaves nothing behind, on it or on another.
    ///
    /// # Errors
    /// [`StoreError::InvalidInput`] for a caption over 200 characters or a row
    /// for another moment than `read`; database failures.
    pub fn put_moment_reading(
        &self,
        row: &MomentReading,
        read: &StoredMoment,
    ) -> Result<bool, StoreError> {
        if row.caption.as_ref().is_some_and(|caption| {
            caption.is_empty() || caption.chars().count() > CAPTION_MAX_CHARS
        }) {
            return Err(StoreError::InvalidInput(
                "caption must be 1 to 200 characters".into(),
            ));
        }
        if row.event_id != read.id {
            return Err(StoreError::InvalidInput(
                "a reading is written for the moment it was made from".into(),
            ));
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let written = guard
            .conn()
            .execute(
                &format!(
                    "INSERT OR REPLACE INTO moment_readings
                         (event_id, version, main, rest, caption, caption_by, model_tried, updated_us)
                     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
                     WHERE {}",
                    same_moment(9)
                ),
                params![
                    sql_i64(row.event_id.0),
                    i64::from(row.version),
                    row.reading.as_ref().map(|r| r.main.as_str()),
                    row.reading.as_ref().map(|r| r.rest.as_str()),
                    row.caption,
                    row.caption_by,
                    i64::from(row.model_tried),
                    sql_i64(row.updated_us),
                    sql_i64(read.ts_us),
                    read.app_bundle_id,
                    read.window_title,
                    read.text,
                ],
            )
            .map_err(|e| backend("write moment reading", e))?;
        Ok(written > 0)
    }

    /// One stored moment as the re-clean job reads it, if it is there.
    ///
    /// # Errors
    /// Database failures.
    pub fn stored_moment(&self, id: EventId) -> Result<Option<StoredMoment>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let select = moment_select(table_exists(guard.conn(), "event_sources")?);
        guard
            .conn()
            .query_row(
                &format!("{select} WHERE e.id = ?1"),
                params![sql_i64(id.0)],
                row_to_moment,
            )
            .optional()
            .map_err(|e| backend("read stored moment", e))
    }

    /// A moment's reading, if one was written. `None` too on a store the
    /// agent has not upgraded yet (no table), so a read-only window works.
    ///
    /// # Errors
    /// Database failures.
    pub fn moment_reading(&self, id: EventId) -> Result<Option<MomentReading>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "moment_readings")? {
            return Ok(None);
        }
        guard
            .conn()
            .query_row(
                &format!("SELECT {READING_COLUMNS} FROM moment_readings WHERE event_id = ?1"),
                params![sql_i64(id.0)],
                row_to_reading,
            )
            .optional()
            .map_err(|e| backend("read moment reading", e))
    }

    /// The readings of several moments, by event id. Moments without one
    /// are left out.
    ///
    /// # Errors
    /// Database failures.
    pub fn moment_readings(
        &self,
        ids: &[EventId],
    ) -> Result<HashMap<u64, MomentReading>, StoreError> {
        let mut found = HashMap::new();
        if ids.is_empty() {
            return Ok(found);
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "moment_readings")? {
            return Ok(found);
        }
        for batch in ids.chunks(500) {
            let sql = format!(
                "SELECT {READING_COLUMNS} FROM moment_readings WHERE event_id IN ({})",
                vec!["?"; batch.len()].join(", ")
            );
            let mut statement = guard
                .conn()
                .prepare(&sql)
                .map_err(|e| backend("prepare moment readings", e))?;
            let rows = statement
                .query_map(
                    rusqlite::params_from_iter(batch.iter().map(|id| sql_i64(id.0))),
                    row_to_reading,
                )
                .map_err(|e| backend("query moment readings", e))?;
            for row in rows {
                let row = row.map_err(|e| backend("read moment readings", e))?;
                found.insert(row.event_id.0, row);
            }
        }
        Ok(found)
    }

    /// Up to `limit` moments captured before `before_us` without a reading
    /// of `version` or later, newest first: the re-clean job's next work.
    ///
    /// # Errors
    /// Database failures.
    pub fn moments_to_read(
        &self,
        version: u32,
        limit: usize,
        before_us: u64,
    ) -> Result<Vec<StoredMoment>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let select = moment_select(table_exists(guard.conn(), "event_sources")?);
        let sql = format!(
            "{select}
             WHERE e.ts_us < ?3 AND NOT EXISTS (
                 SELECT 1 FROM moment_readings r WHERE r.event_id = e.id AND r.version >= ?1
             )
             ORDER BY e.ts_us DESC, e.id DESC LIMIT ?2"
        );
        let mut statement = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| backend("prepare moments to read", e))?;
        let rows = statement
            .query_map(
                params![
                    i64::from(version),
                    i64::try_from(limit).unwrap_or(i64::MAX),
                    sql_i64(before_us)
                ],
                row_to_moment,
            )
            .map_err(|e| backend("query moments to read", e))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read moments to read", e))
    }

    /// At most `limit` moments of one app in `[from_us, to_us)`, oldest
    /// first, spread evenly over the span when it holds more: what the
    /// many-frame rule learns from.
    ///
    /// # Errors
    /// Database failures.
    pub fn moments_of_app(
        &self,
        app: &str,
        from_us: u64,
        to_us: u64,
        limit: usize,
    ) -> Result<Vec<StoredMoment>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let ids: Vec<i64> = {
            let mut statement = guard
                .conn()
                .prepare(
                    "SELECT id FROM events
                     WHERE app_bundle_id = ?1 AND ts_us >= ?2 AND ts_us < ?3
                     ORDER BY ts_us, id",
                )
                .map_err(|e| backend("prepare moments of app", e))?;
            let rows = statement
                .query_map(params![app, sql_i64(from_us), sql_i64(to_us)], |row| {
                    row.get::<_, i64>(0)
                })
                .map_err(|e| backend("query moments of app", e))?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| backend("read moments of app", e))?
        };
        // Every n-th, so a day's later hours count as much as its first.
        let picked: Vec<i64> = if ids.len() <= limit {
            ids
        } else {
            (0..limit).map(|n| ids[n * ids.len() / limit]).collect()
        };
        let select = moment_select(table_exists(guard.conn(), "event_sources")?);
        let mut statement = guard
            .conn()
            .prepare(&format!("{select} WHERE e.id = ?1"))
            .map_err(|e| backend("prepare moment of app", e))?;
        let mut out = Vec::with_capacity(picked.len());
        for id in picked {
            if let Some(moment) = statement
                .query_row(params![id], row_to_moment)
                .optional()
                .map_err(|e| backend("read moment of app", e))?
            {
                out.push(moment);
            }
        }
        Ok(out)
    }

    /// Up to `limit` moments whose caption was made from the title and has
    /// not been offered to the model yet, newest first, with their rows.
    ///
    /// # Errors
    /// Database failures.
    pub fn moments_awaiting_model_caption(
        &self,
        limit: usize,
    ) -> Result<Vec<(StoredMoment, MomentReading)>, StoreError> {
        let ids: Vec<EventId> = {
            let guard = self.db.lock().expect("brain store mutex poisoned");
            let mut statement = guard
                .conn()
                .prepare(
                    "SELECT r.event_id FROM moment_readings r JOIN events e ON e.id = r.event_id
                     WHERE r.model_tried = 0 AND (r.caption_by = ?1 OR r.caption IS NULL)
                     ORDER BY e.ts_us DESC, e.id DESC LIMIT ?2",
                )
                .map_err(|e| backend("prepare caption work", e))?;
            let rows = statement
                .query_map(
                    params![CAPTION_BY_TITLE, i64::try_from(limit).unwrap_or(i64::MAX)],
                    |row| row.get::<_, i64>(0),
                )
                .map_err(|e| backend("query caption work", e))?;
            rows.map(|row| row.map(|id| EventId(u64::try_from(id).unwrap_or(0))))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| backend("read caption work", e))?
        };
        let readings = self.moment_readings(&ids)?;
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let select = moment_select(table_exists(guard.conn(), "event_sources")?);
        let mut statement = guard
            .conn()
            .prepare(&format!("{select} WHERE e.id = ?1"))
            .map_err(|e| backend("prepare caption moment", e))?;
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            let moment = statement
                .query_row(params![sql_i64(id.0)], row_to_moment)
                .optional()
                .map_err(|e| backend("read caption moment", e))?;
            if let (Some(moment), Some(reading)) = (moment, readings.get(&id.0)) {
                out.push((moment, reading.clone()));
            }
        }
        Ok(out)
    }

    /// Set the caption of `read` after the model was asked: its line and
    /// label when the line was used, or the caption kept as it was. Marks the
    /// moment asked. Returns `false` when the moment or its row is gone, or
    /// its id now holds another moment.
    ///
    /// # Errors
    /// [`StoreError::InvalidInput`] for a caption over 200 characters; database
    /// failures.
    pub fn set_model_caption(
        &self,
        read: &StoredMoment,
        caption: Option<(&str, &str)>,
        now_us: u64,
    ) -> Result<bool, StoreError> {
        if caption.is_some_and(|(line, by)| {
            line.is_empty() || line.chars().count() > CAPTION_MAX_CHARS || by.is_empty()
        }) {
            return Err(StoreError::InvalidInput(
                "caption must be 1 to 200 characters".into(),
            ));
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let (line, by) = caption.map_or((None, None), |(line, by)| (Some(line), Some(by)));
        let changed = guard
            .conn()
            .execute(
                &format!(
                    "UPDATE moment_readings
                     SET caption = CASE WHEN ?2 IS NULL THEN caption ELSE ?2 END,
                         caption_by = CASE WHEN ?2 IS NULL THEN caption_by ELSE ?3 END,
                         model_tried = 1, updated_us = ?4
                     WHERE event_id = ?1 AND {}",
                    same_moment(5)
                ),
                params![
                    sql_i64(read.id.0),
                    line,
                    by,
                    sql_i64(now_us),
                    sql_i64(read.ts_us),
                    read.app_bundle_id,
                    read.window_title,
                    read.text,
                ],
            )
            .map_err(|e| backend("write model caption", e))?;
        Ok(changed > 0)
    }

    /// How far the re-clean job has got with `version`.
    ///
    /// # Errors
    /// Database failures.
    pub fn moment_reading_progress(&self, version: u32) -> Result<ReadingProgress, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let total: i64 = guard
            .conn()
            .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
            .map_err(|e| backend("count moments", e))?;
        if !table_exists(guard.conn(), "moment_readings")? {
            return Ok(ReadingProgress {
                done: 0,
                total: u64::try_from(total).unwrap_or(0),
                awaiting_model: 0,
            });
        }
        let (done, awaiting): (i64, i64) = guard
            .conn()
            .query_row(
                "SELECT COUNT(*) FILTER (WHERE version >= ?1),
                        COUNT(*) FILTER (WHERE model_tried = 0 AND (caption_by = ?2 OR caption IS NULL))
                 FROM moment_readings",
                params![i64::from(version), CAPTION_BY_TITLE],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|e| backend("count moment readings", e))?;
        Ok(ReadingProgress {
            done: u64::try_from(done).unwrap_or(0),
            total: u64::try_from(total).unwrap_or(0),
            awaiting_model: u64::try_from(awaiting).unwrap_or(0),
        })
    }
}

/// Delete the readings of `event_ids`, inside the caller's deletion
/// transaction and before the events go. The rows also cascade from their
/// events; this keeps them going even on a connection without foreign keys.
pub(crate) fn delete_for_events(tx: &Transaction<'_>, event_ids: &[i64]) -> Result<(), StoreError> {
    if event_ids.is_empty() || !table_exists(tx, "moment_readings")? {
        return Ok(());
    }
    let mut delete = tx
        .prepare("DELETE FROM moment_readings WHERE event_id = ?1")
        .map_err(|e| backend("prepare moment reading deletion", e))?;
    for id in event_ids {
        delete
            .execute(params![id])
            .map_err(|e| backend("delete moment reading", e))?;
    }
    Ok(())
}
