//! Measured-activity storage foundation. Only a dedicated sampler may supply
//! intervals; screenshot counts and event spacing are not activity evidence.
//!
//! Opens validate the canonical activity schema and stream all deletion barriers
//! once, checking integer endpoints and strictly separated ordering. Subsequent
//! store writes preserve that invariant transactionally; admission uses one
//! indexed seek and validates its candidate, not a scan of deletion history.
//! This is launch-time consistency validation, not authentication of history:
//! bypassed constraints or valid-looking edits to a live database are outside
//! the guarantee. An unseen nested barrier introduced after open cannot be
//! detected by the bounded seek. Missing tables and malformed candidates fail closed.

use rusqlite::{params, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{SqlCipherBrainStore, StoreError};

/// Input state measured by the dedicated sampler, not inferred productivity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityState {
    /// Input was recently observed in a permitted, identified application.
    InputActive,
    /// Input was idle in a permitted, identified application.
    InputIdle,
    /// The sampler cannot attribute activity; no app identity may accompany it.
    Unknown,
}

impl ActivityState {
    fn as_str(self) -> &'static str {
        match self {
            Self::InputActive => "input_active",
            Self::InputIdle => "input_idle",
            Self::Unknown => "unknown",
        }
    }
}

/// A half-open, at most five-second sample persisted in the encrypted brain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActivityInterval {
    /// Positive microseconds since UNIX epoch, inclusive.
    pub start_us: u64,
    /// Positive microseconds since UNIX epoch, exclusive.
    pub end_us: u64,
    /// Measured input state; not a judgement about productive work.
    pub state: ActivityState,
    /// Normal application bundle ID; required for active/idle, absent for unknown.
    pub app_bundle_id: Option<String>,
    /// Opaque sampler generation, never a title, URL, path, or other content.
    pub capture_generation: String,
}

impl ActivityInterval {
    /// Maximum duration admitted from a dedicated sampler, in microseconds.
    pub const MAX_DURATION_US: u64 = 5_000_000;

    /// Validate timestamps, bounded opaque generation, and state/app identity.
    ///
    /// Generations contain 1..=128 ASCII letters, digits, hyphens or underscores.
    /// App IDs contain at most 255 ASCII bytes and at least two nonempty
    /// dot-separated components. Components contain letters, digits or hyphens
    /// and begin/end with a letter or digit. Input is never normalized.
    /// This checks shape only; the sampler owns consent and app suppression.
    ///
    /// # Errors
    /// Returns a content-free invalid-input error for an inadmissible sample.
    pub fn validate(&self) -> Result<(), StoreError> {
        if self.start_us == 0
            || self.start_us >= self.end_us
            || self.end_us > i64::MAX as u64
            || self.end_us - self.start_us > Self::MAX_DURATION_US
        {
            return Err(StoreError::InvalidInput(
                "invalid activity interval timestamps".into(),
            ));
        }
        if self.capture_generation.is_empty()
            || self.capture_generation.len() > 128
            || !self
                .capture_generation
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(StoreError::InvalidInput(
                "invalid activity capture generation".into(),
            ));
        }
        let valid_app = match self.state {
            ActivityState::Unknown => self.app_bundle_id.is_none(),
            ActivityState::InputActive | ActivityState::InputIdle => self
                .app_bundle_id
                .as_deref()
                .is_some_and(valid_app_bundle_id),
        };
        if !valid_app {
            return Err(StoreError::InvalidInput(
                "invalid activity state/app identity".into(),
            ));
        }
        Ok(())
    }
}

fn valid_app_bundle_id(app: &str) -> bool {
    app.len() <= 255
        && app.contains('.')
        && app.split('.').all(|part| {
            let bytes = part.as_bytes();
            bytes.first().is_some_and(u8::is_ascii_alphanumeric)
                && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
                && bytes
                    .iter()
                    .all(|b| b.is_ascii_alphanumeric() || *b == b'-')
        })
}

impl SqlCipherBrainStore {
    /// Append a measured interval; returns false for a surviving replay or a
    /// sample intersecting a durable privacy-deletion barrier.
    ///
    /// Idempotence covers equality of all five fields of an existing row.
    /// Every other overlap, including across generations, is rejected. Adjacent
    /// and disjoint out-of-order samples are allowed. Checks and insertion share
    /// an immediate writer transaction, including across separate store handles.
    /// Deletion barriers contain only merged time ranges. A delayed or spanning
    /// sample is dropped in full, including across capture generations, before
    /// overlap checks. This may discard up to five seconds around a deletion.
    ///
    /// # Errors
    /// Returns [`StoreError::ActivityOverlap`] for a valid nonidentical overlap.
    /// Invalid samples, read failures, and read-only writes remain strict errors.
    pub fn append_activity_interval(
        &self,
        interval: &ActivityInterval,
    ) -> Result<bool, StoreError> {
        interval.validate()?;
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        if guard
            .conn()
            .is_readonly("main")
            .map_err(|_| backend("probe activity writer"))?
        {
            return Err(backend("activity store is read-only"));
        }
        let tx = guard
            .conn_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|_| backend("begin activity append"))?;
        if intersects_deletion_barrier(
            &tx,
            sqlite_time(interval.start_us)?,
            sqlite_time(interval.end_us)?,
        )? {
            tx.commit()
                .map_err(|_| backend("commit activity privacy drop"))?;
            return Ok(false);
        }
        let overlaps = read_intervals(
            &tx,
            sqlite_time(interval.start_us)?,
            sqlite_time(interval.end_us)?,
            2,
        )?;
        if !overlaps.is_empty() {
            if overlaps.len() == 1 && overlaps[0] == *interval {
                tx.commit().map_err(|_| backend("commit activity replay"))?;
                return Ok(false);
            }
            return Err(StoreError::ActivityOverlap);
        }
        insert_interval(&tx, interval)?;
        tx.commit().map_err(|_| backend("commit activity append"))?;
        Ok(true)
    }

    /// Read a bounded, ordered page clipped to `[start_us, end_us)`.
    ///
    /// SQL limits the read to `min(limit, 50_001)` rows before decoding or
    /// allocating the result. Use 50,001 for a 50,000-row UI plus one row of
    /// truncation evidence. A zero limit returns no rows after validating bounds.
    /// Continue from the final returned `end_us` for the next disjoint page.
    /// Legacy schema and privacy validation match the unrestricted range API.
    ///
    /// # Errors
    /// Rejects invalid bounds or a database read failure.
    pub fn activity_intervals_page(
        &self,
        start_us: u64,
        end_us: u64,
        limit: usize,
    ) -> Result<Vec<ActivityInterval>, StoreError> {
        self.read_activity_range(start_us, end_us, limit.min(50_001))
    }

    /// Read ordered activity clipped to the half-open range `[start_us, end_us)`.
    ///
    /// Bounds may start at zero and must be increasing and fit signed `SQLite`
    /// timestamps. No row limit or gap filling is applied. Pre-0010 read-only
    /// brains return an empty range without applying migrations. Stored rows are
    /// validated before clipping; invalid privacy fields fail the entire read.
    ///
    /// # Errors
    /// Rejects invalid bounds or a database read failure.
    pub fn activity_intervals_in_range(
        &self,
        start_us: u64,
        end_us: u64,
    ) -> Result<Vec<ActivityInterval>, StoreError> {
        self.read_activity_range(start_us, end_us, usize::MAX)
    }

    fn read_activity_range(
        &self,
        start_us: u64,
        end_us: u64,
        limit: usize,
    ) -> Result<Vec<ActivityInterval>, StoreError> {
        if start_us >= end_us || end_us > i64::MAX as u64 {
            return Err(StoreError::InvalidInput(
                "invalid activity read range".into(),
            ));
        }
        if limit == 0 {
            return Ok(Vec::new());
        }
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|_| backend("begin activity read"))?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='measured_activity')",
            [], |row| row.get(0),
        ).map_err(|_| backend("probe activity schema"))?;
        if !exists {
            let version: Option<String> = tx
                .query_row(
                    "SELECT value FROM meta WHERE key='brain_schema_version'",
                    [],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|_| backend("read activity schema version"))?;
            if let Some(version) = version {
                if version
                    .parse::<u64>()
                    .map_err(|_| backend("invalid activity schema version"))?
                    >= 10
                {
                    return Err(backend("missing measured activity table"));
                }
            }
            return Ok(Vec::new());
        }
        let mut intervals =
            read_intervals(&tx, sqlite_time(start_us)?, sqlite_time(end_us)?, limit)?;
        for interval in &mut intervals {
            interval.start_us = interval.start_us.max(start_us);
            interval.end_us = interval.end_us.min(end_us);
        }
        Ok(intervals)
    }
}

fn backend(operation: &str) -> StoreError {
    StoreError::Backend(operation.into())
}

fn sqlite_time(value: u64) -> Result<i64, StoreError> {
    i64::try_from(value).map_err(|_| StoreError::InvalidInput("invalid activity timestamp".into()))
}

fn row_to_interval(row: &Row<'_>) -> rusqlite::Result<ActivityInterval> {
    let state: String = row.get(2)?;
    let state = match state.as_str() {
        "input_active" => ActivityState::InputActive,
        "input_idle" => ActivityState::InputIdle,
        "unknown" => ActivityState::Unknown,
        _ => return Err(rusqlite::Error::InvalidQuery),
    };
    let interval = ActivityInterval {
        start_us: u64::try_from(row.get::<_, i64>(0)?)
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
        end_us: u64::try_from(row.get::<_, i64>(1)?).map_err(|_| rusqlite::Error::InvalidQuery)?,
        state,
        app_bundle_id: row.get(3)?,
        capture_generation: row.get(4)?,
    };
    interval
        .validate()
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    Ok(interval)
}

fn read_intervals(
    conn: &Connection,
    start_us: i64,
    end_us: i64,
    limit: usize,
) -> Result<Vec<ActivityInterval>, StoreError> {
    // The five-second bound allows an indexed seek without scanning all history.
    let mut stmt = conn
        .prepare(
            "SELECT start_us,end_us,state,app_bundle_id,capture_generation FROM measured_activity
         WHERE start_us > ?1 - 5000000 AND start_us < ?2 AND end_us > ?1
         ORDER BY start_us LIMIT ?3",
        )
        .map_err(|_| backend("prepare activity range"))?;
    let rows = stmt
        .query_map(
            params![start_us, end_us, i64::try_from(limit).unwrap_or(i64::MAX)],
            row_to_interval,
        )
        .map_err(|_| backend("query activity range"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|_| backend("invalid stored activity interval"))
}

fn insert_interval(tx: &Transaction<'_>, interval: &ActivityInterval) -> Result<(), StoreError> {
    tx.execute(
        "INSERT INTO measured_activity (start_us,end_us,state,app_bundle_id,capture_generation)
         VALUES (?1,?2,?3,?4,?5)",
        params![
            sqlite_time(interval.start_us)?,
            sqlite_time(interval.end_us)?,
            interval.state.as_str(),
            interval.app_bundle_id,
            interval.capture_generation
        ],
    )
    .map_err(|_| backend("insert activity interval"))?;
    Ok(())
}

type ActivitySchemaObject = (String, String, String, Option<String>);

fn activity_schema_objects(conn: &Connection) -> Result<Vec<ActivitySchemaObject>, StoreError> {
    // Six canonical objects plus one sentinel; also catch reserved names on
    // another table. The reference below lets SQLite parse DDL, not Rust strings.
    let mut stmt = conn
        .prepare(
            "SELECT type,name,tbl_name,sql FROM sqlite_master
         WHERE tbl_name IN ('measured_activity','activity_deletion_barriers')
            OR name IN ('measured_activity','activity_deletion_barriers',
                'measured_activity_no_insert_overlap','measured_activity_no_update_overlap',
                'activity_deletion_barriers_no_insert_overlap',
                'activity_deletion_barriers_no_update_overlap')
         ORDER BY name LIMIT 7",
        )
        .map_err(|_| backend("prepare activity schema validation"))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .map_err(|_| backend("query activity schema validation"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|_| backend("read activity schema validation"))
}

/// Validate before any migration can recreate missing privacy objects. Returns
/// false only for a pre-0010 brain with no activity schema at all. A complete
/// existing schema under an older stamp is validated and preserved, never reset.
pub(crate) fn validate_activity_schema(
    conn: &Connection,
    starting_version: Option<&str>,
) -> Result<bool, StoreError> {
    let version = starting_version
        .map(str::parse::<u64>)
        .transpose()
        .map_err(|_| backend("invalid activity schema version"))?
        .unwrap_or(0);
    if version > 10 {
        return Err(backend("unsupported activity schema version"));
    }
    let actual = activity_schema_objects(conn)?;
    if actual.is_empty() && version < 10 {
        return Ok(false);
    }
    // Contains shipped DDL only, never brain rows or other private data.
    let reference =
        Connection::open_in_memory().map_err(|_| backend("open activity schema reference"))?;
    reference
        .execute_batch(include_str!("../migrations/0010_measured_activity.sql"))
        .map_err(|_| backend("parse activity schema reference"))?;
    if actual != activity_schema_objects(&reference)? {
        return Err(backend("missing or noncanonical activity schema"));
    }
    let mut stmt = conn
        .prepare("SELECT start_us,end_us FROM activity_deletion_barriers ORDER BY start_us")
        .map_err(|_| backend("prepare activity barrier validation"))?;
    let rows = stmt
        .query_map([], row_to_barrier)
        .map_err(|_| backend("query activity barrier validation"))?;
    let mut previous_end = None;
    for row in rows {
        let (start, end) = row.map_err(|_| backend("invalid stored activity deletion barrier"))?;
        if previous_end.is_some_and(|previous| previous >= start) {
            return Err(backend("activity deletion barriers are not separated"));
        }
        previous_end = Some(end);
    }
    Ok(true)
}

fn row_to_barrier(row: &Row<'_>) -> rusqlite::Result<(i64, i64)> {
    let start: i64 = row.get(0)?;
    let end: i64 = row.get(1)?;
    if start < 0 || start >= end {
        return Err(rusqlite::Error::InvalidQuery);
    }
    Ok((start, end))
}

fn intersects_deletion_barrier(
    tx: &Transaction<'_>,
    start_us: i64,
    end_us: i64,
) -> Result<bool, StoreError> {
    // Disjoint ordered barriers make the last start before end the only
    // candidate needed. This is a primary-key seek, not a scan of past deletions.
    let barrier: Option<(i64, i64)> = tx
        .query_row(
            "SELECT start_us,end_us FROM activity_deletion_barriers
         WHERE start_us < ?1 ORDER BY start_us DESC LIMIT 1",
            params![end_us],
            row_to_barrier,
        )
        .optional()
        .map_err(|_| backend("read activity deletion barrier"))?;
    Ok(barrier.is_some_and(|(_, end)| end > start_us))
}

fn record_deletion_barrier(
    tx: &Transaction<'_>,
    start_us: i64,
    end_us: i64,
) -> Result<(), StoreError> {
    if start_us < 0 || start_us >= end_us {
        return Err(backend("invalid activity deletion barrier"));
    }
    let previous: Option<(i64, i64)> = tx
        .query_row(
            "SELECT start_us,end_us FROM activity_deletion_barriers
         WHERE start_us <= ?1 ORDER BY start_us DESC LIMIT 1",
            params![start_us],
            row_to_barrier,
        )
        .optional()
        .map_err(|_| backend("seek activity deletion predecessor"))?;
    let merged_start = previous
        .filter(|(_, end)| *end >= start_us)
        .map_or(start_us, |(start, _)| start);
    // Existing barriers are non-overlapping and non-adjacent. The last start
    // inside the new range therefore also gives the end of the entire merge.
    let last: Option<(i64, i64)> = tx
        .query_row(
            "SELECT start_us,end_us FROM activity_deletion_barriers
         WHERE start_us >= ?1 AND start_us <= ?2 ORDER BY start_us DESC LIMIT 1",
            params![merged_start, end_us],
            row_to_barrier,
        )
        .optional()
        .map_err(|_| backend("seek activity deletion successor"))?;
    let merged_end = end_us.max(last.map_or(end_us, |(_, end)| end));
    tx.execute(
        "DELETE FROM activity_deletion_barriers WHERE start_us >= ?1 AND start_us <= ?2",
        params![merged_start, end_us],
    )
    .map_err(|_| backend("merge activity deletion barriers"))?;
    tx.execute(
        "INSERT INTO activity_deletion_barriers (start_us,end_us) VALUES (?1,?2)",
        params![merged_start, merged_end],
    )
    .map_err(|_| backend("record activity deletion barrier"))?;
    Ok(())
}

/// Preserve deletion decisions and block pending samples before wiping rows.
pub(crate) fn wipe_activity(tx: &Transaction<'_>) -> Result<(), StoreError> {
    let now_us = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| backend("read activity wipe clock"))?
        .as_micros();
    let now_end = i64::try_from(now_us.saturating_add(1)).unwrap_or(i64::MAX);
    let last_end: Option<i64> = tx
        .query_row(
            "SELECT end_us FROM measured_activity ORDER BY start_us DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| backend("read activity wipe boundary"))?;
    record_deletion_barrier(tx, 0, now_end.max(last_end.unwrap_or(0)))?;
    tx.execute("DELETE FROM measured_activity", [])
        .map_err(|_| backend("wipe measured activity"))?;
    Ok(())
}

/// Remove a half-open span inside the caller's existing deletion transaction.
pub(crate) fn delete_activity_in_range(
    tx: &Transaction<'_>,
    start_us: i64,
    end_us: i64,
) -> Result<(), StoreError> {
    if start_us >= end_us {
        return Ok(());
    }
    let start = u64::try_from(start_us).map_err(|_| backend("invalid activity deletion bound"))?;
    let end = u64::try_from(end_us).map_err(|_| backend("invalid activity deletion bound"))?;
    record_deletion_barrier(tx, start_us, end_us)?;
    // Only the (at most two) boundary rows can survive; expired history stays in SQL.
    let boundaries = {
        let mut stmt = tx.prepare(
            "SELECT start_us,end_us,state,app_bundle_id,capture_generation FROM measured_activity
             WHERE (start_us > ?1 - 5000000 AND start_us < ?1 AND end_us > ?1)
                OR (start_us > ?2 - 5000000 AND start_us < ?2 AND end_us > ?2)
             ORDER BY start_us",
        ).map_err(|_| backend("prepare activity deletion boundaries"))?;
        let rows = stmt
            .query_map(params![start_us, end_us], row_to_interval)
            .map_err(|_| backend("read activity deletion boundaries"))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|_| backend("invalid stored activity boundary"))?
    };
    tx.execute(
        "DELETE FROM measured_activity
         WHERE start_us > ?1 - 5000000 AND start_us < ?2 AND end_us > ?1",
        params![start_us, end_us],
    )
    .map_err(|_| backend("delete activity intervals"))?;
    for interval in boundaries {
        if interval.start_us < start {
            insert_interval(
                tx,
                &ActivityInterval {
                    end_us: start,
                    ..interval.clone()
                },
            )?;
        }
        if interval.end_us > end {
            insert_interval(
                tx,
                &ActivityInterval {
                    start_us: end,
                    ..interval
                },
            )?;
        }
    }
    Ok(())
}
