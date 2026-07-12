//! Integration tests for the daily-briefs storage surface added by
//! migration `0002_briefs.sql` (see `docs/design/brief-viewer-spec.md`).
//!
//! Each test opens an ephemeral encrypted DB under a `tempfile::tempdir()`
//! with a fresh `InMemoryKeyWrap`-derived `DbKey` (test-only key wrap;
//! the shipped agent binary cannot construct it).
//!
//! Coverage:
//!
//!   • migration creates the `briefs` table and stamps the sub-schema
//!     version,
//!   • migration is reversible (down → up round-trip),
//!   • `put_brief` → `brief_for_date` round-trip preserves every column,
//!   • UNIQUE(date_local) makes regeneration an upsert,
//!   • `latest_brief` returns the most-recently-generated row,
//!   • `brief_dates` returns the date strings ordered most-recent first.

use std::path::{Path, PathBuf};

use mci_brain::{BriefRow, SqlCipherBrainStore};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use mci_core::store::{open as mci_core_open, Db};
use rusqlite::params;
use tempfile::TempDir;

fn tmp(name: &str) -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(name);
    (dir, path)
}

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn raw_open(path: &Path, key: &DbKey) -> Db {
    mci_core_open(path, key).expect("mci_core::store::open")
}

fn sample_brief(date_local: &str, generated_ts_us: u64) -> BriefRow {
    BriefRow {
        id: 0,
        date_local: date_local.into(),
        generated_ts_us,
        model_id: "qwen3-1.7b-int4".into(),
        model_version: "1.0".into(),
        title: format!("Friday, {date_local}"),
        body: "## Highlights\n\nA full day of brain-building.\n".into(),
        word_count: 7,
        source_event_count: 142,
    }
}

// ---------------------------------------------------------------------------
// 1. Migration creates the `briefs` table and stamps the sub-schema version
// ---------------------------------------------------------------------------

#[test]
fn migration_0002_creates_briefs_table_and_stamp() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    {
        let _store = SqlCipherBrainStore::new(&path, &key).expect("open");
    }
    let db = raw_open(&path, &key);

    // briefs table is materialized.
    let n: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE name = 'briefs'",
            [],
            |r| r.get(0),
        )
        .expect("query briefs table presence");
    assert_eq!(n, 1, "briefs table must be materialized by migration 0002");

    // Both indices exist.
    for idx in ["briefs_date_uniq", "briefs_generated"] {
        let n: i64 = db
            .conn()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = ?1",
                params![idx],
                |r| r.get(0),
            )
            .expect("query brief index presence");
        assert_eq!(n, 1, "index {idx} must exist after migration 0002");
    }

    // Sub-schema version stamp present + = "1".
    let v: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key = 'briefs_schema_version'",
            [],
            |r| r.get(0),
        )
        .expect("briefs_schema_version stamp");
    assert_eq!(v, "1");
}

// ---------------------------------------------------------------------------
// 2. Down migration drops the table; up re-creates it (reversibility test)
// ---------------------------------------------------------------------------

#[test]
fn briefs_schema_round_trips_up_down_up() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    {
        let _store = SqlCipherBrainStore::new(&path, &key).expect("open");
    }
    let db = raw_open(&path, &key);

    // Run the DOWN migration manually.
    let down = include_str!("../migrations/0002_briefs_down.sql");
    db.conn().execute_batch(down).expect("apply 0002 down");

    // briefs table is gone.
    let n: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE name = 'briefs'",
            [],
            |r| r.get(0),
        )
        .expect("query");
    assert_eq!(n, 0, "DOWN must drop the briefs table");

    // Stamp is gone.
    let stamp_count: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM meta WHERE key = 'briefs_schema_version'",
            [],
            |r| r.get(0),
        )
        .expect("query");
    assert_eq!(stamp_count, 0, "DOWN must remove the schema version stamp");

    // Re-applying the UP migration (idempotent — re-opens the store)
    // recreates the table and re-stamps the version.
    drop(db);
    {
        let _store = SqlCipherBrainStore::new(&path, &key).expect("re-open after down");
    }
    let db = raw_open(&path, &key);
    let n: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE name = 'briefs'",
            [],
            |r| r.get(0),
        )
        .expect("query");
    assert_eq!(n, 1, "re-applied UP must re-create briefs table");
    let v: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key = 'briefs_schema_version'",
            [],
            |r| r.get(0),
        )
        .expect("stamp");
    assert_eq!(v, "1");
}

// ---------------------------------------------------------------------------
// 3. put_brief → brief_for_date round-trip preserves every column
// ---------------------------------------------------------------------------

#[test]
fn put_brief_then_brief_for_date_round_trip() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let brief = sample_brief("2026-05-22", 1_716_429_780_000_000);
    let id = store.put_brief(&brief).expect("put_brief");
    assert!(id > 0, "put_brief returns a non-zero id");

    let got = store
        .brief_for_date("2026-05-22")
        .expect("brief_for_date")
        .expect("present");
    assert_eq!(got.date_local, brief.date_local);
    assert_eq!(got.generated_ts_us, brief.generated_ts_us);
    assert_eq!(got.model_id, brief.model_id);
    assert_eq!(got.model_version, brief.model_version);
    assert_eq!(got.title, brief.title);
    assert_eq!(got.body, brief.body);
    assert_eq!(got.word_count, brief.word_count);
    assert_eq!(got.source_event_count, brief.source_event_count);
}

#[test]
fn brief_for_date_returns_none_for_unknown_date() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let got = store.brief_for_date("1999-01-01").expect("brief_for_date");
    assert!(got.is_none());
}

// ---------------------------------------------------------------------------
// 4. UNIQUE(date_local) ⇒ regeneration is an upsert (one row per day)
// ---------------------------------------------------------------------------

#[test]
fn put_brief_is_upsert_on_date_local() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let mut brief = sample_brief("2026-05-22", 1_716_429_780_000_000);
    store.put_brief(&brief).expect("put 1");

    brief.body = "## Regenerated\n\nNew summary.\n".into();
    brief.word_count = 4;
    brief.generated_ts_us = 1_716_429_900_000_000;
    store.put_brief(&brief).expect("put 2 (regenerate)");

    let got = store
        .brief_for_date("2026-05-22")
        .expect("read")
        .expect("present");
    assert_eq!(got.body, "## Regenerated\n\nNew summary.\n");
    assert_eq!(got.word_count, 4);
    assert_eq!(got.generated_ts_us, 1_716_429_900_000_000);

    // Only one row exists.
    assert_eq!(store.brief_count().expect("count"), 1);
}

// ---------------------------------------------------------------------------
// 5. latest_brief returns the row with the largest generated_ts_us
// ---------------------------------------------------------------------------

#[test]
fn latest_brief_returns_most_recent_by_generated_ts() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let earlier = sample_brief("2026-05-20", 1_000_000);
    let middle = sample_brief("2026-05-21", 2_000_000);
    let later = sample_brief("2026-05-22", 3_000_000);
    store.put_brief(&earlier).expect("put 1");
    store.put_brief(&later).expect("put 2");
    store.put_brief(&middle).expect("put 3");

    let got = store
        .latest_brief()
        .expect("latest_brief")
        .expect("present");
    assert_eq!(got.date_local, "2026-05-22");
    assert_eq!(got.generated_ts_us, 3_000_000);
}

#[test]
fn latest_brief_on_empty_store_returns_none() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let got = store.latest_brief().expect("latest_brief");
    assert!(got.is_none());
}

// ---------------------------------------------------------------------------
// 6. brief_dates returns date strings most-recent first, capped at `limit`
// ---------------------------------------------------------------------------

#[test]
fn brief_dates_returns_dates_desc_capped_by_limit() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    for (date, ts) in [
        ("2026-05-20", 1_000_000),
        ("2026-05-22", 3_000_000),
        ("2026-05-21", 2_000_000),
    ] {
        store.put_brief(&sample_brief(date, ts)).expect("put");
    }

    let all = store.brief_dates(10).expect("brief_dates");
    assert_eq!(all, vec!["2026-05-22", "2026-05-21", "2026-05-20"]);

    let two = store.brief_dates(2).expect("brief_dates limit");
    assert_eq!(two, vec!["2026-05-22", "2026-05-21"]);

    let zero = store.brief_dates(0).expect("zero limit");
    assert!(zero.is_empty());
}

// ---------------------------------------------------------------------------
// 7. brief_count is content-free aggregate
// ---------------------------------------------------------------------------

#[test]
fn brief_count_counts_rows() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    assert_eq!(store.brief_count().expect("count"), 0);
    store
        .put_brief(&sample_brief("2026-05-21", 2_000_000))
        .expect("put");
    assert_eq!(store.brief_count().expect("count"), 1);
    store
        .put_brief(&sample_brief("2026-05-22", 3_000_000))
        .expect("put");
    assert_eq!(store.brief_count().expect("count"), 2);
}
