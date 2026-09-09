//! Synthetic fixtures for the measured-activity storage foundation, not sampler evidence.

use mci_brain::{
    ActivityInterval, ActivityState, BrainStore, Event, EventId, SqlCipherBrainStore, StoreError,
};
use mci_core::{crypto::DbKey, store::open};
use rusqlite::params;

fn interval(start_us: u64, end_us: u64) -> ActivityInterval {
    ActivityInterval {
        start_us,
        end_us,
        state: ActivityState::InputActive,
        app_bundle_id: Some("com.example.fixture".into()),
        capture_generation: "fixture-generation-1".into(),
    }
}

fn fixture() -> (tempfile::TempDir, DbKey, SqlCipherBrainStore) {
    let dir = tempfile::tempdir().unwrap();
    let key = DbKey::from_bytes([0xAC; 32]);
    let store = SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &key).unwrap();
    (dir, key, store)
}

#[test]
fn write_read_clips_half_open_intersections_without_mutating_storage() {
    let (_dir, _key, store) = fixture();
    let active = interval(10, 100);
    let mut idle = interval(100, 200);
    idle.state = ActivityState::InputIdle;
    let mut unknown = interval(200, 300);
    unknown.state = ActivityState::Unknown;
    unknown.app_bundle_id = None;
    for item in [&unknown, &active, &idle] {
        assert!(store.append_activity_interval(item).unwrap());
    }
    assert_eq!(
        store.activity_intervals_in_range(50, 250).unwrap(),
        vec![
            ActivityInterval {
                start_us: 50,
                ..active.clone()
            },
            idle.clone(),
            ActivityInterval {
                end_us: 250,
                ..unknown.clone()
            },
        ]
    );
    assert_eq!(
        store.activity_intervals_in_range(100, 200).unwrap(),
        vec![idle.clone()]
    );
    assert_eq!(
        store.activity_intervals_in_range(0, 400).unwrap(),
        vec![active, idle, unknown]
    );
    for (start, end) in [(0, 0), (100, 100), (200, 100), (0, u64::MAX)] {
        assert!(matches!(
            store.activity_intervals_in_range(start, end),
            Err(StoreError::InvalidInput(_))
        ));
    }
    assert!(store
        .activity_intervals_in_range(300, 400)
        .unwrap()
        .is_empty());
}

#[test]
fn rejects_invalid_times_generations_and_privacy_fields_before_writing() {
    let (_dir, _key, store) = fixture();
    let mut invalid = vec![
        interval(0, 1),
        interval(10, 10),
        interval(20, 10),
        interval(1, 5_000_002),
        interval(i64::MAX as u64, i64::MAX as u64 + 1),
        interval(u64::MAX - 1, u64::MAX),
    ];
    for generation in [
        "",
        "space secret",
        "with/slash",
        "with\nnewline",
        "nul\0hidden",
        "génération",
    ] {
        invalid.push(ActivityInterval {
            capture_generation: generation.into(),
            ..interval(1, 2)
        });
    }
    invalid.push(ActivityInterval {
        capture_generation: "g".repeat(129),
        ..interval(1, 2)
    });
    for app in [
        None,
        Some(""),
        Some("unknown"),
        Some("com..app"),
        Some(".com.app"),
        Some("com.app."),
        Some("com.-app"),
        Some("com.app-"),
        Some("com.app/secret"),
        Some("com.app name"),
        Some("com.app\0secret"),
        Some("com.éxample"),
    ] {
        for state in [ActivityState::InputActive, ActivityState::InputIdle] {
            invalid.push(ActivityInterval {
                state,
                app_bundle_id: app.map(str::to_owned),
                ..interval(1, 2)
            });
        }
    }
    invalid.push(ActivityInterval {
        app_bundle_id: Some(format!("com.{}", "a".repeat(252))),
        ..interval(1, 2)
    });
    invalid.push(ActivityInterval {
        state: ActivityState::Unknown,
        ..interval(1, 2)
    });
    for item in invalid {
        let error = store.append_activity_interval(&item).unwrap_err();
        assert!(matches!(error, StoreError::InvalidInput(_)));
        assert!(!error.to_string().contains("secret"));
        assert!(!error.to_string().contains("fixture-generation"));
    }
    assert!(store
        .activity_intervals_in_range(0, 10_000_000)
        .unwrap()
        .is_empty());
    assert!(store
        .append_activity_interval(&interval(1, 5_000_001))
        .unwrap());
    let encoded = serde_json::to_value(interval(1, 2)).unwrap();
    assert_eq!(encoded["state"], "input_active");
    assert_eq!(encoded.as_object().unwrap().len(), 5);
    let mut extra = encoded.clone();
    extra["window_title"] = "private".into();
    assert!(serde_json::from_value::<ActivityInterval>(extra).is_err());
    let mut negative = encoded;
    negative["start_us"] = (-1).into();
    assert!(serde_json::from_value::<ActivityInterval>(negative).is_err());
}

#[test]
fn replay_is_exact_and_conflicts_cannot_double_count_across_generations() {
    let (dir, key, store) = fixture();
    let original = interval(100, 200);
    assert!(store.append_activity_interval(&original).unwrap());
    drop(store);
    let store = SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &key).unwrap();
    assert!(!store.append_activity_interval(&original).unwrap());
    for conflict in [
        interval(99, 101),
        interval(199, 201),
        interval(100, 150),
        interval(110, 190),
        interval(90, 210),
        ActivityInterval {
            capture_generation: "other-generation".into(),
            ..original.clone()
        },
        ActivityInterval {
            state: ActivityState::InputIdle,
            ..original.clone()
        },
        ActivityInterval {
            app_bundle_id: Some("org.example.other".into()),
            ..original.clone()
        },
    ] {
        assert!(matches!(
            store.append_activity_interval(&conflict),
            Err(StoreError::ActivityOverlap)
        ));
    }
    assert!(store.append_activity_interval(&interval(200, 300)).unwrap());
    assert_eq!(
        store.activity_intervals_in_range(0, 300).unwrap(),
        vec![original, interval(200, 300)]
    );
}

#[test]
fn inclusive_privacy_deletion_clips_splits_and_wipes_activity_without_events() {
    let (dir, key, store) = fixture();
    for item in [
        interval(10, 100),
        interval(100, 200),
        interval(200, 300),
        interval(400, 500),
    ] {
        store.append_activity_interval(&item).unwrap();
    }
    assert_eq!(store.delete_events_in_range(50, 249).unwrap(), 0);
    assert_eq!(
        store.activity_intervals_in_range(0, 600).unwrap(),
        vec![interval(10, 50), interval(250, 300), interval(400, 500)]
    );
    assert_eq!(store.delete_events_in_range(420, 429).unwrap(), 0);
    assert_eq!(
        store.activity_intervals_in_range(400, 500).unwrap(),
        vec![interval(400, 420), interval(430, 500)]
    );
    assert_eq!(store.delete_events_in_range(430, 430).unwrap(), 0);
    assert_eq!(
        store.activity_intervals_in_range(430, 500).unwrap(),
        vec![interval(431, 500)]
    );
    assert!(!store.append_activity_interval(&interval(400, 500)).unwrap());
    drop(store);
    let store = SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &key).unwrap();
    assert_eq!(
        store.activity_intervals_in_range(400, 500).unwrap(),
        vec![interval(400, 420), interval(431, 500)]
    );
    assert_eq!(store.wipe_all_with_outcome().unwrap().events_deleted, 0);
    assert!(store
        .activity_intervals_in_range(0, 600)
        .unwrap()
        .is_empty());
    // A delayed or replayed sample must not restore wiped activity.
    assert!(!store.append_activity_interval(&interval(400, 500)).unwrap());
    store.delete_events_in_range(0, u64::MAX).unwrap();
    assert!(store
        .activity_intervals_in_range(0, 600)
        .unwrap()
        .is_empty());
}

#[test]
fn deleting_one_event_keeps_independent_sampler_interval() {
    let (_dir, _key, store) = fixture();
    store.append_activity_interval(&interval(100, 200)).unwrap();
    let id = store
        .put_event(&Event {
            id: EventId(0),
            ts_us: 150,
            app_bundle_id: None,
            window_title: None,
            url: None,
            text: "synthetic fixture".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        })
        .unwrap();
    assert_eq!(store.delete_event(id).unwrap(), 1);
    assert_eq!(
        store.activity_intervals_in_range(0, 300).unwrap(),
        vec![interval(100, 200)]
    );
}

#[test]
fn retention_clips_at_cutoff_even_without_events_and_preserves_safety_floor() {
    use mci_brain::retention_purger::{purge_once, RetentionConfig};
    let (_dir, _key, store) = fixture();
    let now = 100 * 86_400_000_000;
    let cutoff = 70 * 86_400_000_000;
    for item in [
        interval(1, 2),
        interval(cutoff - 100, cutoff + 100),
        interval(now - 100, now),
    ] {
        store.append_activity_interval(&item).unwrap();
    }
    purge_once(&store, &RetentionConfig::Forever, now).unwrap();
    assert_eq!(store.activity_intervals_in_range(0, now).unwrap().len(), 3);
    purge_once(&store, &RetentionConfig::Days(30), now).unwrap();
    assert_eq!(
        store.activity_intervals_in_range(0, now).unwrap(),
        vec![interval(cutoff, cutoff + 100), interval(now - 100, now)]
    );
    assert!(!store.append_activity_interval(&interval(1, 2)).unwrap());
    assert!(!store
        .append_activity_interval(&interval(cutoff - 100, cutoff + 100))
        .unwrap());
    purge_once(&store, &RetentionConfig::Days(0), now).unwrap();
    assert_eq!(
        store.activity_intervals_in_range(0, now).unwrap(),
        vec![interval(now - 100, now)]
    );
}

#[test]
fn deletion_barrier_blocks_delayed_spanning_and_replayed_samples_across_handles_and_reopen() {
    let (dir, key, store) = fixture();
    let path = dir.path().join("brain.sqlite");
    let other_writer = SqlCipherBrainStore::new(&path, &key).unwrap();
    store.append_activity_interval(&interval(100, 200)).unwrap();
    store.delete_events_in_range(120, 179).unwrap();
    for sample in [
        interval(100, 200),
        interval(119, 121),
        interval(179, 181),
        interval(120, 180),
    ] {
        assert!(!other_writer.append_activity_interval(&sample).unwrap());
    }
    let mut replay = interval(120, 180);
    replay.capture_generation = "different-generation".into();
    assert!(!other_writer.append_activity_interval(&replay).unwrap());
    drop(store);
    drop(other_writer);
    let reopened = SqlCipherBrainStore::new(&path, &key).unwrap();
    assert!(!reopened
        .append_activity_interval(&interval(100, 200))
        .unwrap());
    assert!(reopened
        .append_activity_interval(&interval(200, 250))
        .unwrap());
    assert_eq!(
        reopened.activity_intervals_in_range(0, 300).unwrap(),
        vec![interval(100, 120), interval(180, 200), interval(200, 250),]
    );
}

#[test]
fn deletion_barrier_records_empty_ranges_and_keeps_half_open_boundaries() {
    let (_dir, _key, store) = fixture();
    assert_eq!(store.delete_events_in_range(100, 199).unwrap(), 0);
    for sample in [interval(100, 200), interval(50, 101), interval(199, 250)] {
        assert!(!store.append_activity_interval(&sample).unwrap());
    }
    for sample in [interval(1, 50), interval(50, 100), interval(200, 250)] {
        assert!(store.append_activity_interval(&sample).unwrap());
    }
    store.delete_events_in_range(250, 250).unwrap();
    assert!(!store.append_activity_interval(&interval(250, 251)).unwrap());
    assert!(store.append_activity_interval(&interval(251, 252)).unwrap());
}

#[test]
fn deletion_barrier_merges_overlapping_adjacent_nested_and_bridging_ranges() {
    let (dir, key, store) = fixture();
    for (start, end) in [
        (300, 399),
        (100, 199),
        (200, 299),
        (140, 159),
        (50, 99),
        (100, 399),
        (500, 599),
    ] {
        store.delete_events_in_range(start, end).unwrap();
    }
    assert!(!store.append_activity_interval(&interval(50, 600)).unwrap());
    assert!(store.append_activity_interval(&interval(400, 500)).unwrap());
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    let mut statement = db
        .conn()
        .prepare("SELECT start_us,end_us FROM activity_deletion_barriers ORDER BY start_us")
        .unwrap();
    let ranges = statement
        .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)))
        .unwrap()
        .collect::<std::result::Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(ranges, [(50, 400), (500, 600)]);
    for (start, end) in [
        (-1, 10),
        (0, 0),
        (0, 50),
        (60, 70),
        (400, 450),
        (450, 500),
        (300, 700),
    ] {
        assert!(db
            .conn()
            .execute(
                "INSERT INTO activity_deletion_barriers (start_us,end_us) VALUES (?1,?2)",
                params![start, end],
            )
            .is_err());
    }
    assert!(db
        .conn()
        .execute(
            "UPDATE activity_deletion_barriers SET end_us=500 WHERE start_us=50",
            [],
        )
        .is_err());
}

#[test]
fn deletion_barrier_wipe_blocks_unrecorded_past_and_accepts_future_work() {
    let (_dir, _key, store) = fixture();
    let before = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap();
    store.wipe_all().unwrap();
    let after = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap();
    assert!(!store
        .append_activity_interval(&interval(before - 1, before + 1))
        .unwrap());
    assert!(store
        .append_activity_interval(&interval(after + 5_000_000, after + 5_000_001))
        .unwrap());
}

#[test]
fn deletion_barrier_wipe_covers_last_recorded_end_and_preserves_existing_future_barriers() {
    let (dir, key, store) = fixture();
    let now = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap();
    let future = now + 86_400_000_000;
    store
        .delete_events_in_range(future + 100, future + 199)
        .unwrap();
    store
        .append_activity_interval(&interval(future, future + 10))
        .unwrap();
    store.wipe_all().unwrap();
    for sample in [
        interval(1, 2),
        interval(future, future + 10),
        interval(future + 100, future + 200),
    ] {
        assert!(!store.append_activity_interval(&sample).unwrap());
    }
    drop(store);
    let store = SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &key).unwrap();
    store.wipe_all().unwrap();
    assert!(!store
        .append_activity_interval(&interval(future, future + 10))
        .unwrap());
    assert!(!store
        .append_activity_interval(&interval(future + 100, future + 200))
        .unwrap());
    assert!(store
        .append_activity_interval(&interval(future + 10, future + 100))
        .unwrap());
    assert!(store
        .append_activity_interval(&interval(future + 200, future + 201))
        .unwrap());
}

#[test]
fn deletion_barrier_rolls_back_when_range_delete_or_wipe_fails() {
    let (dir, key, store) = fixture();
    store.append_activity_interval(&interval(100, 200)).unwrap();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn().execute_batch("CREATE TRIGGER fail_activity_delete BEFORE DELETE ON measured_activity BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
    assert!(store.delete_events_in_range(100, 199).is_err());
    assert!(store.wipe_all().is_err());
    db.conn()
        .execute_batch("DROP TRIGGER fail_activity_delete;")
        .unwrap();
    assert!(store.append_activity_interval(&interval(1, 2)).unwrap());
    assert!(matches!(
        store.append_activity_interval(&interval(120, 180)),
        Err(StoreError::ActivityOverlap)
    ));
    let barriers: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM activity_deletion_barriers",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(barriers, 0);
    assert_eq!(
        store.activity_intervals_in_range(0, 300).unwrap(),
        vec![interval(1, 2), interval(100, 200)]
    );
}

#[test]
fn legacy_readonly_is_empty_without_migration_and_writer_upgrades() {
    let (dir, key, store) = fixture();
    drop(store);
    let path = dir.path().join("brain.sqlite");
    {
        let db = open(&path, &key).unwrap();
        db.conn().execute_batch("DROP TABLE measured_activity; DROP TABLE activity_deletion_barriers; UPDATE meta SET value='9' WHERE key='brain_schema_version';").unwrap();
    }
    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    assert!(reader
        .activity_intervals_in_range(0, 300)
        .unwrap()
        .is_empty());
    assert!(reader.append_activity_interval(&interval(1, 2)).is_err());
    {
        let db = mci_core::store::open_readonly(&path, &key).unwrap();
        let version: String = db
            .conn()
            .query_row(
                "SELECT value FROM meta WHERE key='brain_schema_version'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(version, "9");
        let count: i64 = db
            .conn()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name='measured_activity'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
    }
    let writer = SqlCipherBrainStore::new(&path, &key).unwrap();
    writer.append_activity_interval(&interval(1, 2)).unwrap();
    assert_eq!(
        reader.activity_intervals_in_range(0, 300).unwrap(),
        vec![interval(1, 2)]
    );
    assert!(reader.append_activity_interval(&interval(2, 3)).is_err());
    assert!(reader.append_activity_interval(&interval(1, 2)).is_err());
}

#[test]
fn backup_persists_activity_in_encrypted_brain_only() {
    let (dir, key, store) = fixture();
    store.append_activity_interval(&interval(1, 2)).unwrap();
    store.delete_events_in_range(100, 199).unwrap();
    let backup = dir.path().join("backup.sqlite");
    store.vacuum_into(&backup).unwrap();
    let restored = SqlCipherBrainStore::open_readonly(&backup, &key).unwrap();
    assert_eq!(
        restored.activity_intervals_in_range(0, 3).unwrap(),
        vec![interval(1, 2)]
    );
    let backup_writer = SqlCipherBrainStore::new(&backup, &key).unwrap();
    assert!(!backup_writer
        .append_activity_interval(&interval(100, 200))
        .unwrap());
    drop(backup_writer);
    for path in [dir.path().join("brain.sqlite"), backup] {
        let bytes = std::fs::read(&path).unwrap();
        for plain in [
            b"SQLite format 3".as_slice(),
            b"com.example.fixture",
            b"fixture-generation-1",
        ] {
            assert!(!bytes.windows(plain.len()).any(|chunk| chunk == plain));
        }
        let no_key = rusqlite::Connection::open(&path).unwrap();
        assert!(no_key
            .query_row("SELECT count(*) FROM measured_activity", [], |r| r
                .get::<_, i64>(0))
            .is_err());
        assert!(SqlCipherBrainStore::open_readonly(&path, &DbKey::from_bytes([0xBC; 32])).is_err());
    }
}

#[test]
fn sql_constraints_reject_invalid_identity_time_state_and_overlap() {
    let (dir, key, _store) = fixture();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    for (start, end, state, app, generation) in [
        (0, 1, "input_active", Some("com.example.app"), "gen"),
        (-1, 1, "input_active", Some("com.example.app"), "gen"),
        (10, 10, "input_active", Some("com.example.app"), "gen"),
        (20, 10, "input_active", Some("com.example.app"), "gen"),
        (1, 5_000_002, "input_active", Some("com.example.app"), "gen"),
        (1, 2, "unknown", Some("com.example.app"), "gen"),
        (1, 2, "input_idle", None, "gen"),
        (1, 2, "input_active", Some("private/identity"), "gen"),
        (1, 2, "input_active", Some("com..app"), "gen"),
        (1, 2, "input_active", Some("com.-app"), "gen"),
        (1, 2, "input_active", Some("com.app-"), "gen"),
        (1, 2, "input_active", Some("com.app\0secret"), "gen"),
        (1, 2, "unexpected", Some("com.example.app"), "gen"),
        (1, 2, "input_active", Some("com.example.app"), ""),
        (1, 2, "input_active", Some("com.example.app"), "gen\0secret"),
    ] {
        assert!(db
            .conn()
            .execute(
                "INSERT INTO measured_activity VALUES (?1,?2,?3,?4,?5)",
                params![start, end, state, app, generation]
            )
            .is_err());
    }
    db.conn()
        .execute(
            "INSERT INTO measured_activity VALUES (10,20,'unknown',NULL,'gen')",
            [],
        )
        .unwrap();
    assert!(db
        .conn()
        .execute(
            "INSERT INTO measured_activity VALUES (19,30,'unknown',NULL,'other')",
            []
        )
        .is_err());
    db.conn()
        .execute(
            "INSERT INTO measured_activity VALUES (20,30,'unknown',NULL,'gen')",
            [],
        )
        .unwrap();
    assert!(db
        .conn()
        .execute(
            "UPDATE measured_activity SET end_us=21 WHERE start_us=10",
            []
        )
        .is_err());
}

#[test]
fn activity_deletion_rolls_back_with_existing_event_deletion_transaction() {
    let (dir, key, store) = fixture();
    store.append_activity_interval(&interval(100, 300)).unwrap();
    store
        .put_event(&Event {
            id: EventId(0),
            ts_us: 150,
            app_bundle_id: None,
            window_title: None,
            url: None,
            text: "synthetic fixture".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        })
        .unwrap();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn().execute_batch("CREATE TRIGGER fixture_refuse_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'fixture abort'); END;").unwrap();
    assert!(store.delete_events_in_range(125, 175).is_err());
    assert_eq!(
        store.activity_intervals_in_range(0, 400).unwrap(),
        vec![interval(100, 300)]
    );
    assert!(store.wipe_all().is_err());
    assert_eq!(
        store.activity_intervals_in_range(0, 400).unwrap(),
        vec![interval(100, 300)]
    );
}

#[test]
fn read_rejects_corrupt_privacy_fields_without_exposing_them() {
    let (dir, key, store) = fixture();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn().execute_batch("PRAGMA ignore_check_constraints=ON; INSERT INTO measured_activity VALUES (1,2,'unknown','com.secret.fixture','gen');").unwrap();
    let error = store.activity_intervals_in_range(0, 3).unwrap_err();
    assert!(matches!(error, StoreError::Backend(_)));
    assert!(!error.to_string().contains("com.secret.fixture"));
}

#[test]
fn overlap_classification_preserves_invalid_input_and_corrupt_read_errors() {
    let (dir, key, store) = fixture();
    let original = interval(100_000_000, 104_000_000);
    store.append_activity_interval(&original).unwrap();
    let mut conflicting = interval(102_000_000, 106_000_000);
    conflicting.capture_generation = "invalid secret generation".into();
    assert!(matches!(
        store.append_activity_interval(&conflicting),
        Err(StoreError::InvalidInput(_))
    ));
    assert_eq!(
        store.activity_intervals_in_range(0, 110_000_000).unwrap(),
        vec![original]
    );
    conflicting.capture_generation = "generation-2".into();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn()
        .execute_batch(
            "PRAGMA ignore_check_constraints=ON;
         UPDATE measured_activity SET state='unknown',app_bundle_id='com.secret.fixture';",
        )
        .unwrap();
    let error = store.append_activity_interval(&conflicting).unwrap_err();
    assert!(matches!(error, StoreError::Backend(_)));
    assert!(!error.to_string().contains("com.secret.fixture"));
    assert!(store.activity_intervals_in_range(0, 110_000_000).is_err());
}

#[test]
fn independent_writer_handles_serialize_exact_replay() {
    let (dir, key, first) = fixture();
    let second = SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &key).unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let other_barrier = barrier.clone();
    let writer = std::thread::spawn(move || {
        other_barrier.wait();
        first.append_activity_interval(&interval(100, 200)).unwrap()
    });
    barrier.wait();
    let result = second
        .append_activity_interval(&interval(100, 200))
        .unwrap();
    assert_ne!(writer.join().unwrap(), result);
    assert_eq!(
        second.activity_intervals_in_range(0, 300).unwrap(),
        vec![interval(100, 200)]
    );
}

#[test]
fn missing_current_activity_table_is_not_reported_as_an_empty_legacy_range() {
    let (dir, key, store) = fixture();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn()
        .execute_batch("DROP TABLE measured_activity;")
        .unwrap();
    assert!(matches!(
        store.activity_intervals_in_range(0, 10),
        Err(StoreError::Backend(_))
    ));
}

#[test]
fn sql_does_not_generate_a_timestamp_when_start_is_null() {
    let (dir, key, _store) = fixture();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    assert!(db
        .conn()
        .execute(
            "INSERT INTO measured_activity VALUES (NULL,2,'unknown',NULL,'gen')",
            []
        )
        .is_err());
}

#[test]
fn maximum_sqlite_timestamp_remains_exact_through_read_and_delete() {
    let (_dir, _key, store) = fixture();
    let max = i64::MAX as u64;
    store
        .append_activity_interval(&interval(max - 2, max))
        .unwrap();
    assert_eq!(
        store.activity_intervals_in_range(max - 1, max).unwrap(),
        vec![interval(max - 1, max)]
    );
    store.delete_events_in_range(max + 1, u64::MAX).unwrap();
    assert_eq!(
        store.activity_intervals_in_range(max - 2, max).unwrap(),
        vec![interval(max - 2, max)]
    );
    store.delete_events_in_range(max - 1, u64::MAX).unwrap();
    assert_eq!(
        store.activity_intervals_in_range(max - 2, max).unwrap(),
        vec![interval(max - 2, max - 1)]
    );
    assert!(!store
        .append_activity_interval(&interval(max - 2, max))
        .unwrap());
    assert!(!store
        .append_activity_interval(&interval(max - 1, max))
        .unwrap());
    assert!(store
        .append_activity_interval(&interval(max - 3, max - 2))
        .unwrap());
}

#[test]
fn activity_page_orders_clips_and_honors_zero_limit() {
    let (_dir, _key, store) = fixture();
    for item in [interval(200, 300), interval(10, 100), interval(100, 200)] {
        store.append_activity_interval(&item).unwrap();
    }
    assert!(store
        .activity_intervals_page(50, 250, 0)
        .unwrap()
        .is_empty());
    assert_eq!(
        store.activity_intervals_page(50, 250, 1).unwrap(),
        vec![interval(50, 100)]
    );
    assert_eq!(
        store.activity_intervals_page(50, 250, 2).unwrap(),
        vec![interval(50, 100), interval(100, 200)]
    );
    assert_eq!(
        store.activity_intervals_page(50, 250, 3).unwrap(),
        vec![interval(50, 100), interval(100, 200), interval(200, 250)]
    );
    assert_eq!(
        store.activity_intervals_page(100, 200, 3).unwrap(),
        vec![interval(100, 200)]
    );
    for (start, end) in [(10, 10), (20, 10), (0, u64::MAX)] {
        assert!(matches!(
            store.activity_intervals_page(start, end, 0),
            Err(StoreError::InvalidInput(_))
        ));
    }
}

#[test]
fn activity_page_limits_sql_before_decoding_rows() {
    let (dir, key, store) = fixture();
    store.append_activity_interval(&interval(10, 20)).unwrap();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn()
        .execute_batch(
            "PRAGMA ignore_check_constraints=ON;
        INSERT INTO measured_activity VALUES (30,40,'unknown','com.secret.fixture','gen');",
        )
        .unwrap();
    assert_eq!(
        store.activity_intervals_page(0, 50, 1).unwrap(),
        vec![interval(10, 20)]
    );
    assert!(store.activity_intervals_page(0, 50, 2).is_err());
    assert!(store.activity_intervals_in_range(0, 50).is_err());
}

#[test]
fn activity_page_caps_at_50001_before_materialization_and_preserves_full_range_api() {
    let (dir, key, store) = fixture();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn()
        .execute_batch(
            "WITH RECURSIVE samples(n) AS (
            VALUES(1) UNION ALL SELECT n+1 FROM samples WHERE n < 50002
         ) INSERT INTO measured_activity
         SELECT n*6000000,n*6000000+1,'unknown',NULL,'fixture-page' FROM samples;",
        )
        .unwrap();
    let end = 50_003 * 6_000_000;
    assert_eq!(
        store.activity_intervals_in_range(0, end).unwrap().len(),
        50_002
    );
    db.conn().execute_batch(
        "PRAGMA ignore_check_constraints=ON;
         UPDATE measured_activity SET app_bundle_id='com.secret.fixture' WHERE start_us=50002*6000000;",
    ).unwrap();
    for limit in [50_001, 50_002, usize::MAX] {
        let page = store.activity_intervals_page(0, end, limit).unwrap();
        assert_eq!(page.len(), 50_001);
        assert_eq!(page.first().unwrap().start_us, 6_000_000);
        assert_eq!(page.last().unwrap().start_us, 50_001 * 6_000_000);
        assert!(page
            .iter()
            .all(|item| item.state == ActivityState::Unknown && item.app_bundle_id.is_none()));
    }
    assert!(store.activity_intervals_in_range(0, end).is_err());
}

fn assert_activity_open_fails(path: &std::path::Path, key: &DbKey, readonly: bool) {
    let result = if readonly {
        SqlCipherBrainStore::open_readonly(path, key)
    } else {
        SqlCipherBrainStore::new(path, key)
    };
    let Err(error) = result else {
        panic!("invalid activity storage opened (readonly={readonly})");
    };
    assert!(matches!(error, StoreError::Backend(_)));
    assert!(!error.to_string().contains("private-fixture"));
}

fn missing_activity_schema_is_not_repaired(readonly: bool) {
    for (kind, name) in [
        ("TABLE", "activity_deletion_barriers"),
        ("TABLE", "measured_activity"),
        ("TRIGGER", "activity_deletion_barriers_no_insert_overlap"),
        ("TRIGGER", "activity_deletion_barriers_no_update_overlap"),
        ("TRIGGER", "measured_activity_no_insert_overlap"),
        ("TRIGGER", "measured_activity_no_update_overlap"),
    ] {
        let (dir, key, store) = fixture();
        store.delete_events_in_range(100, 199).unwrap();
        drop(store);
        let path = dir.path().join("brain.sqlite");
        let db = open(&path, &key).unwrap();
        db.conn()
            .execute_batch(&format!("DROP {kind} {name}"))
            .unwrap();
        assert_activity_open_fails(&path, &key, readonly);
        let exists: bool = db
            .conn()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?1)",
                [name],
                |row| row.get(0),
            )
            .unwrap();
        assert!(!exists, "a failed open must not repair privacy schema");
    }
}

#[test]
fn activity_writer_open_rejects_missing_current_schema_without_repair() {
    missing_activity_schema_is_not_repaired(false);
}

#[test]
fn activity_readonly_open_rejects_missing_current_schema_without_repair() {
    missing_activity_schema_is_not_repaired(true);
}

#[test]
fn activity_open_rejects_noncanonical_tables_and_triggers() {
    for sql in [
        "DROP TABLE activity_deletion_barriers;
         CREATE TABLE activity_deletion_barriers (
             start_us INTEGER PRIMARY KEY NOT NULL, end_us INTEGER NOT NULL
         ) WITHOUT ROWID;",
        "DROP TRIGGER activity_deletion_barriers_no_insert_overlap;
         CREATE TRIGGER activity_deletion_barriers_no_insert_overlap
         BEFORE INSERT ON activity_deletion_barriers BEGIN SELECT 1; END;",
        "DROP TABLE measured_activity;
         CREATE TABLE measured_activity (
             start_us INTEGER PRIMARY KEY NOT NULL, end_us INTEGER NOT NULL,
             state TEXT NOT NULL, app_bundle_id TEXT, capture_generation TEXT NOT NULL
         ) WITHOUT ROWID;",
    ] {
        let (dir, key, store) = fixture();
        drop(store);
        let path = dir.path().join("brain.sqlite");
        let db = open(&path, &key).unwrap();
        db.conn().execute_batch(sql).unwrap();
        db.conn()
            .execute_batch(include_str!("../migrations/0010_measured_activity.sql"))
            .unwrap();
        for readonly in [false, true] {
            assert_activity_open_fails(&path, &key, readonly);
        }
    }
}

#[test]
fn activity_open_rejects_malformed_barriers_without_exposing_values() {
    for assignment in [
        "end_us=99",
        "end_us=100",
        "start_us=-1",
        "end_us=9223372036854775808",
        "end_us='private-fixture'",
        "start_us=100.5",
    ] {
        let (dir, key, store) = fixture();
        store.delete_events_in_range(100, 299).unwrap();
        drop(store);
        let path = dir.path().join("brain.sqlite");
        let db = open(&path, &key).unwrap();
        db.conn()
            .execute_batch(&format!(
                "PRAGMA ignore_check_constraints=ON;
             DROP TRIGGER activity_deletion_barriers_no_update_overlap;
             UPDATE activity_deletion_barriers SET {assignment};"
            ))
            .unwrap();
        db.conn()
            .execute_batch(include_str!("../migrations/0010_measured_activity.sql"))
            .unwrap();
        for readonly in [false, true] {
            assert_activity_open_fails(&path, &key, readonly);
        }
    }
}

#[test]
fn activity_open_rejects_nested_overlapping_or_adjacent_barriers_under_canonical_schema() {
    for (start, end) in [(150, 160), (200, 400), (300, 400)] {
        let (dir, key, store) = fixture();
        store.delete_events_in_range(100, 299).unwrap();
        drop(store);
        let path = dir.path().join("brain.sqlite");
        let db = open(&path, &key).unwrap();
        db.conn()
            .execute_batch("DROP TRIGGER activity_deletion_barriers_no_insert_overlap;")
            .unwrap();
        db.conn()
            .execute(
                "INSERT INTO activity_deletion_barriers VALUES (?1,?2)",
                params![start, end],
            )
            .unwrap();
        // Restore the actual trigger, isolating row validation from DDL validation.
        db.conn()
            .execute_batch(include_str!("../migrations/0010_measured_activity.sql"))
            .unwrap();
        for readonly in [false, true] {
            assert_activity_open_fails(&path, &key, readonly);
        }
        let count: i64 = db
            .conn()
            .query_row(
                "SELECT count(*) FROM activity_deletion_barriers",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 2, "rejected open must not rewrite deletion history");
    }
}

#[test]
fn activity_live_append_rejects_a_malformed_barrier_candidate() {
    let (dir, key, store) = fixture();
    store.delete_events_in_range(100, 199).unwrap();
    let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
    db.conn()
        .execute_batch(
            "PRAGMA ignore_check_constraints=ON;
         UPDATE activity_deletion_barriers SET end_us=99;",
        )
        .unwrap();
    assert!(matches!(
        store.append_activity_interval(&interval(120, 130)),
        Err(StoreError::Backend(_))
    ));
    assert!(store
        .activity_intervals_in_range(0, 300)
        .unwrap()
        .is_empty());
}

#[test]
fn activity_live_delete_and_wipe_reject_malformed_merge_candidates_atomically() {
    for wipe in [false, true] {
        let (dir, key, store) = fixture();
        store.append_activity_interval(&interval(200, 300)).unwrap();
        store.delete_events_in_range(100, 199).unwrap();
        let db = open(&dir.path().join("brain.sqlite"), &key).unwrap();
        db.conn()
            .execute_batch(
                "PRAGMA ignore_check_constraints=ON;
             UPDATE activity_deletion_barriers SET end_us=99;",
            )
            .unwrap();
        if wipe {
            assert!(store.wipe_all().is_err());
        } else {
            assert!(store.delete_events_in_range(150, 249).is_err());
        }
        assert_eq!(
            store.activity_intervals_in_range(0, 400).unwrap(),
            vec![interval(200, 300)]
        );
        let end: i64 = db
            .conn()
            .query_row(
                "SELECT end_us FROM activity_deletion_barriers WHERE start_us=100",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(end, 99);
    }
}

#[test]
fn activity_legacy_upgrade_rejects_partial_schema_but_preserves_complete_history() {
    let (dir, key, store) = fixture();
    store.delete_events_in_range(100, 199).unwrap();
    drop(store);
    let path = dir.path().join("brain.sqlite");
    let db = open(&path, &key).unwrap();
    db.conn()
        .execute_batch("UPDATE meta SET value='9' WHERE key='brain_schema_version';")
        .unwrap();
    let upgraded = SqlCipherBrainStore::new(&path, &key).unwrap();
    assert!(!upgraded
        .append_activity_interval(&interval(120, 130))
        .unwrap());
    drop(upgraded);
    db.conn()
        .execute_batch(
            "UPDATE meta SET value='9' WHERE key='brain_schema_version';
         DROP TABLE activity_deletion_barriers;",
        )
        .unwrap();
    assert_activity_open_fails(&path, &key, false);
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, "9");
}

#[test]
fn activity_open_rejects_missing_entire_current_schema_and_unknown_versions() {
    for version in ["10", "11", "private-fixture"] {
        let (dir, key, store) = fixture();
        drop(store);
        let path = dir.path().join("brain.sqlite");
        let db = open(&path, &key).unwrap();
        db.conn()
            .execute_batch("DROP TABLE measured_activity; DROP TABLE activity_deletion_barriers;")
            .unwrap();
        db.conn()
            .execute(
                "UPDATE meta SET value=?1 WHERE key='brain_schema_version'",
                [version],
            )
            .unwrap();
        for readonly in [false, true] {
            assert_activity_open_fails(&path, &key, readonly);
        }
        let count: i64 = db.conn().query_row(
            "SELECT count(*) FROM sqlite_master WHERE name IN ('measured_activity','activity_deletion_barriers')",
            [], |row| row.get(0),
        ).unwrap();
        assert_eq!(count, 0);
    }
}

#[test]
fn activity_reopen_and_admission_with_many_disjoint_barriers() {
    let (dir, key, store) = fixture();
    drop(store);
    let path = dir.path().join("brain.sqlite");
    let db = open(&path, &key).unwrap();
    db.conn()
        .execute_batch(
            "WITH RECURSIVE ranges(n) AS (
             VALUES(1) UNION ALL SELECT n+1 FROM ranges WHERE n < 20000
         ) INSERT INTO activity_deletion_barriers SELECT n*10,n*10+5 FROM ranges;",
        )
        .unwrap();
    let reopened = SqlCipherBrainStore::new(&path, &key).unwrap();
    assert!(!reopened
        .append_activity_interval(&interval(199_999, 200_001))
        .unwrap());
    assert!(!reopened
        .append_activity_interval(&interval(10, 11))
        .unwrap());
    assert!(reopened
        .append_activity_interval(&interval(200_005, 200_006))
        .unwrap());
    assert!(reopened
        .append_activity_interval(&interval(15, 20))
        .unwrap());
}
