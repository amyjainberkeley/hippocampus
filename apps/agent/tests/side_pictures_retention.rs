//! The retention worker looks after pictures of side windows (SPEC 6.5):
//! it carries out Forget Pictures of Other Windows…, thins to the budget the
//! person chose, and writes a content-free `pictures-usage.json` beside the
//! capture receipt. Everything here is synthetic and stays in a temporary
//! folder; the person's own settings are never read.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use mci_agent::retention_worker::{
    run_retention_worker_with_side_pictures, PicturesUsage, RetentionSchedule,
    SidePictureMaintenance, PICTURES_USAGE_FILE,
};
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const SECOND: u64 = 1_000_000;
const HOUR: u64 = 3_600 * SECOND;
const NOW: u64 = 1_791_829_800_000_000;

struct Fixture {
    dir: tempfile::TempDir,
    store: Arc<SqlCipherBrainStore>,
    next: u32,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store =
            SqlCipherBrainStore::new(&dir.path().join("mci.sqlite"), &DbKey::from_bytes([3; 32]))
                .unwrap();
        std::fs::create_dir(dir.path().join("blobs")).unwrap();
        std::fs::create_dir_all(dir.path().join("home/.config/hippocampus")).unwrap();
        Self {
            dir,
            store: Arc::new(store),
            next: 1,
        }
    }

    fn settings_path(&self) -> PathBuf {
        self.dir
            .path()
            .join("home/.config/hippocampus/runtime.toml")
    }

    fn retention_json(&self) -> PathBuf {
        self.dir.path().join("retention.json")
    }

    fn usage_path(&self) -> PathBuf {
        self.dir.path().join(PICTURES_USAGE_FILE)
    }

    fn maintenance(&self) -> SidePictureMaintenance {
        SidePictureMaintenance::for_home(&self.dir.path().join("home"), &self.retention_json())
    }

    fn settings(&self, text: &str) {
        std::fs::write(self.settings_path(), text).unwrap();
    }

    /// A blob file `bytes` long; sparse, so a large one costs no disk.
    fn blob(&mut self, bytes: u64) -> String {
        let digest = format!("{:064x}", self.next);
        self.next += 1;
        let file =
            std::fs::File::create(self.dir.path().join("blobs").join(format!("{digest}.bin")))
                .unwrap();
        file.set_len(bytes).unwrap();
        digest
    }

    fn blob_exists(&self, digest: &str) -> bool {
        self.dir
            .path()
            .join("blobs")
            .join(format!("{digest}.bin"))
            .exists()
    }

    fn put(
        &self,
        ts_us: u64,
        title: &str,
        keyframe: Option<String>,
        source: EventSource,
    ) -> EventId {
        self.store
            .put_event_with_source(
                &Event {
                    id: EventId(0),
                    ts_us,
                    app_bundle_id: Some("com.tinyspeck.slackmacgap".into()),
                    window_title: Some(title.into()),
                    url: None,
                    text: format!("synthetic text for {title}"),
                    summary: None,
                    entities: None,
                    episode_id: None,
                    cascade_reason: 0,
                    keyframe_blob: keyframe,
                    tab_id: None,
                    embedding: None,
                },
                source,
            )
            .unwrap()
    }

    fn keyframe(&self, id: EventId) -> Option<String> {
        self.store.get_event(id).unwrap().unwrap().keyframe_blob
    }

    fn usage(&self) -> PicturesUsage {
        serde_json::from_slice(&std::fs::read(self.usage_path()).unwrap()).unwrap()
    }
}

#[test]
fn a_cycle_writes_content_free_usage_beside_the_receipt() {
    let mut fixture = Fixture::new();
    fixture.settings("capture_enabled = true\nside_window_pictures = true\n");
    let front = fixture.blob(300_000);
    fixture.put(NOW - HOUR, "Sam Lee", Some(front), EventSource::ScreenOcr);
    let side = fixture.blob(200_000);
    fixture.put(
        NOW - HOUR,
        "launch (Channel) - Northwind Studio - Slack",
        Some(side),
        EventSource::ScreenContext,
    );

    let stats = fixture
        .maintenance()
        .run_cycle(&fixture.store, NOW)
        .unwrap();

    assert!(stats.usage_written);
    let usage = fixture.usage();
    assert_eq!(usage.schema_version, 1);
    assert_eq!(usage.front_bytes, 300_000);
    assert_eq!(usage.side_bytes, 200_000);
    assert_eq!(usage.side_count, 1);
    assert_eq!(
        usage.side_budget_bytes.min(2_000_000_000),
        usage.side_budget_bytes
    );
    assert!(usage.side_pictures_on);
    assert!(usage.updated_at.ends_with('Z'));
    // Sizes and a count, nothing that was on screen.
    let raw = std::fs::read_to_string(fixture.usage_path()).unwrap();
    for word in ["Slack", "Sam", "launch", "synthetic", "slackmacgap"] {
        assert!(!raw.contains(word), "{word}");
    }
    let keys: std::collections::BTreeSet<String> = serde_json::from_str::<serde_json::Value>(&raw)
        .unwrap()
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    assert_eq!(
        keys.into_iter().collect::<Vec<_>>(),
        [
            "front_bytes",
            "schema_version",
            "side_budget_bytes",
            "side_bytes",
            "side_count",
            "side_pictures_on",
            "updated_at"
        ]
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(fixture.usage_path())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}

#[test]
fn turned_off_still_reports_and_thins_what_is_kept() {
    let mut fixture = Fixture::new();
    // No settings file at all: side pictures read as off.
    let side = fixture.blob(1_000);
    fixture.put(NOW, "launch", Some(side), EventSource::ScreenContext);
    let stats = fixture
        .maintenance()
        .run_cycle(&fixture.store, NOW)
        .unwrap();
    assert!(stats.usage_written);
    let usage = fixture.usage();
    assert!(!usage.side_pictures_on);
    assert_eq!(usage.side_count, 1);
}

#[test]
fn forget_pictures_of_other_windows_clears_them_once_and_keeps_the_text() {
    let mut fixture = Fixture::new();
    let front_digest = fixture.blob(1_000);
    let front = fixture.put(
        NOW - 2 * HOUR,
        "Sam Lee",
        Some(front_digest.clone()),
        EventSource::ScreenOcr,
    );
    let old_digest = fixture.blob(1_000);
    let old = fixture.put(
        NOW - 2 * HOUR,
        "launch",
        Some(old_digest.clone()),
        EventSource::ScreenContext,
    );
    let new_digest = fixture.blob(1_000);
    let new = fixture.put(
        NOW - 10 * SECOND,
        "launch",
        Some(new_digest.clone()),
        EventSource::ScreenContext,
    );
    // Confirmed an hour ago, in Unix seconds.
    let requested = (NOW - HOUR) / SECOND;
    fixture.settings(&format!(
        "side_window_pictures = false\ndelete_side_pictures_requested_at = {requested}\n"
    ));

    let mut maintenance = fixture.maintenance();
    let stats = maintenance.run_cycle(&fixture.store, NOW).unwrap();

    assert_eq!(stats.forgotten, 1);
    assert!(fixture.keyframe(old).is_none());
    assert!(!fixture.blob_exists(&old_digest));
    assert_eq!(fixture.keyframe(new), Some(new_digest));
    assert_eq!(fixture.keyframe(front), Some(front_digest.clone()));
    assert!(fixture.blob_exists(&front_digest));
    assert_eq!(
        fixture.store.get_event(old).unwrap().unwrap().text,
        "synthetic text for launch"
    );
    // The same request is carried out once.
    let again = maintenance.run_cycle(&fixture.store, NOW).unwrap();
    assert_eq!(again.forgotten, 0);
    assert_eq!(fixture.usage().side_count, 1);
}

#[test]
fn the_chosen_budget_is_kept_to() {
    let mut fixture = Fixture::new();
    fixture.settings("side_window_pictures = true\nside_pictures_budget_mb = 1000\n");
    // Two 600 MB pictures (sparse files): 1.2 GB over a 1 GB budget.
    let older = fixture.blob(600_000_000);
    let older_id = fixture.put(
        NOW - 2 * HOUR,
        "Document A",
        Some(older.clone()),
        EventSource::ScreenContext,
    );
    let newer = fixture.blob(600_000_000);
    let newer_id = fixture.put(
        NOW - HOUR,
        "Document B",
        Some(newer.clone()),
        EventSource::ScreenContext,
    );

    let stats = fixture
        .maintenance()
        .run_cycle(&fixture.store, NOW)
        .unwrap();

    assert_eq!(stats.thinned, 1);
    assert!(fixture.keyframe(older_id).is_none());
    assert!(!fixture.blob_exists(&older));
    assert_eq!(fixture.keyframe(newer_id), Some(newer));
    let usage = fixture.usage();
    assert_eq!(usage.side_budget_bytes, 1_000_000_000);
    assert!(usage.side_bytes <= 900_000_000);
}

#[test]
fn a_changed_settings_file_is_noticed() {
    let fixture = Fixture::new();
    fixture.settings("side_window_pictures = true\n");
    let mut maintenance = fixture.maintenance();
    assert!(maintenance.settings_changed());
    maintenance.run_cycle(&fixture.store, NOW).unwrap();
    assert!(!maintenance.settings_changed());
    fixture.settings("side_window_pictures = false\nside_pictures_budget_mb = 5000\n");
    assert!(maintenance.settings_changed());
}

fn wait_for(path: &Path, what: impl Fn(&PicturesUsage) -> bool) -> PicturesUsage {
    for _ in 0..200 {
        if let Some(usage) = std::fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<PicturesUsage>(&bytes).ok())
            .filter(|usage| what(usage))
        {
            return usage;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("the usage file never showed it");
}

#[test]
fn the_worker_runs_at_start_and_again_when_settings_change() {
    let mut fixture = Fixture::new();
    fixture.settings("side_window_pictures = true\n");
    // The worker runs on the real clock: a picture from an hour ago.
    let now_real = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap();
    let digest = fixture.blob(5_000);
    let id = fixture.put(
        now_real - HOUR,
        "launch",
        Some(digest.clone()),
        EventSource::ScreenContext,
    );
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let worker = runtime.spawn(run_retention_worker_with_side_pictures(
        Arc::clone(&fixture.store),
        fixture.retention_json(),
        fixture.maintenance(),
        RetentionSchedule {
            purge: Duration::from_secs(3_600),
            side_pictures: Duration::from_secs(3_600),
            settings_poll: Duration::from_millis(20),
        },
        shutdown_rx,
        None,
    ));

    // At start: the usage file is written.
    let usage = wait_for(&fixture.usage_path(), |usage| usage.side_count == 1);
    assert!(usage.side_pictures_on);

    // Forget Pictures of Other Windows… is carried out without waiting for
    // the next scheduled cycle.
    let requested = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    fixture.settings(&format!(
        "side_window_pictures = false\ndelete_side_pictures_requested_at = {requested}\n"
    ));
    let usage = wait_for(&fixture.usage_path(), |usage| usage.side_count == 0);
    assert!(!usage.side_pictures_on);
    assert!(fixture.keyframe(id).is_none());
    assert!(!fixture.blob_exists(&digest));

    shutdown_tx.send(true).unwrap();
    let stats = runtime.block_on(worker).unwrap().unwrap();
    assert_eq!(stats.cycles_run, 1);
    assert!(stats.side_cycles_run >= 2);
    assert_eq!(stats.total_side_pictures_forgotten, 1);
    assert_eq!(stats.side_cycle_errors, 0);
}
