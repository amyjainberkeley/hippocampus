//! Forget Pictures of Other Windows… while remembering is paused or off
//! (SPEC 6.7). Preferences saves the request for the retention worker, and
//! no worker runs while no agent does, so the app runs
//! `mci-agent forget-side-pictures` once. Under the writer lease it clears
//! the side pictures kept until the request, keeps their text and every
//! front-window screenshot, writes the usage file and exits; it refuses
//! while another writer holds the memory, and makes nothing when there is
//! no memory yet. Everything is synthetic and stays in a temporary folder;
//! the person's own settings and memory are never read.

use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use mci_agent::crash_recovery::{acquire_lock, lock_path_for_brain};
use mci_agent::retention_worker::{PicturesUsage, PICTURES_USAGE_FILE};
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const AGENT: &str = env!("CARGO_BIN_EXE_mci-agent");
const KEY: [u8; 32] = [7; 32];
const SECOND: u64 = 1_000_000;
const HOUR: u64 = 3_600 * SECOND;

fn now_us() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap()
}

/// A made-up memory, its blobs and a home of its own.
struct Memory {
    dir: tempfile::TempDir,
    next: u32,
}

impl Memory {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("blobs")).unwrap();
        std::fs::create_dir_all(dir.path().join("home/.config/hippocampus")).unwrap();
        Self { dir, next: 1 }
    }

    fn db(&self) -> PathBuf {
        self.dir.path().join("mci.sqlite")
    }

    fn open(&self) -> SqlCipherBrainStore {
        SqlCipherBrainStore::new(&self.db(), &DbKey::from_bytes(KEY)).unwrap()
    }

    /// A sealed blob's stand-in, `bytes` long.
    fn blob(&mut self, bytes: u64) -> String {
        let digest = format!("{:064x}", self.next);
        self.next += 1;
        let file = std::fs::File::create(self.blob_path(&digest)).unwrap();
        file.set_len(bytes).unwrap();
        digest
    }

    fn blob_path(&self, digest: &str) -> PathBuf {
        self.dir.path().join("blobs").join(format!("{digest}.bin"))
    }

    fn put(
        store: &SqlCipherBrainStore,
        ts_us: u64,
        title: &str,
        keyframe: Option<String>,
        source: EventSource,
    ) -> EventId {
        store
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

    /// Preferences' switch off and Forget confirmed at `at_us`.
    fn request(&self, at_us: u64) {
        std::fs::write(
            self.dir
                .path()
                .join("home/.config/hippocampus/runtime.toml"),
            format!(
                "side_window_pictures = false\ndelete_side_pictures_requested_at = {}\n",
                at_us / SECOND
            ),
        )
        .unwrap();
    }

    /// What the app runs, with the made-up memory's key.
    fn forget_now(&self) -> Output {
        Command::new(AGENT)
            .arg("forget-side-pictures")
            .arg("--db-path")
            .arg(self.db())
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", self.dir.path().join("home"))
            .env("MCI_DEVELOPMENT_FILE_KEY", "1")
            // KEY's 32 bytes of 7, as hexadecimal.
            .env("MCI_DB_KEY_HEX", "07".repeat(32))
            .output()
            .unwrap()
    }

    fn usage_path(&self) -> PathBuf {
        self.dir.path().join(PICTURES_USAGE_FILE)
    }
}

#[test]
fn forgets_the_pictures_now_and_keeps_their_text_and_the_front_screenshots() {
    let mut memory = Memory::new();
    let now = now_us();
    let front_digest = memory.blob(300_000);
    let old_digest = memory.blob(200_000);
    let new_digest = memory.blob(200_000);
    let (front, old, new) = {
        let store = memory.open();
        let front = Memory::put(
            &store,
            now - 2 * HOUR,
            "Sam Lee",
            Some(front_digest.clone()),
            EventSource::ScreenOcr,
        );
        let old = Memory::put(
            &store,
            now - 2 * HOUR,
            "launch (Channel) - Northwind Studio - Slack",
            Some(old_digest.clone()),
            EventSource::ScreenContext,
        );
        let new = Memory::put(
            &store,
            now - 10 * SECOND,
            "launch (Channel) - Northwind Studio - Slack",
            Some(new_digest.clone()),
            EventSource::ScreenContext,
        );
        (front, old, new)
    };
    // Confirmed an hour ago: the picture kept since stays.
    memory.request(now - HOUR);

    let output = memory.forget_now();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "status {:?}, stderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(stdout.contains("forgotten=1"), "{stdout}");
    assert!(stdout.contains("usage_written=true"), "{stdout}");
    for word in ["Slack", "Sam", "launch", "synthetic", "Northwind"] {
        assert!(!stdout.contains(word), "{word} in what it printed");
    }

    let store = memory.open();
    let old_event = store.get_event(old).unwrap().unwrap();
    assert!(old_event.keyframe_blob.is_none(), "the picture is gone");
    assert!(!memory.blob_path(&old_digest).exists());
    assert!(
        old_event.text.contains("synthetic text"),
        "its text stays: {}",
        old_event.text
    );
    assert_eq!(
        store.get_event(new).unwrap().unwrap().keyframe_blob,
        Some(new_digest.clone()),
        "a picture kept after the request stays"
    );
    assert!(memory.blob_path(&new_digest).exists());
    assert_eq!(
        store.get_event(front).unwrap().unwrap().keyframe_blob,
        Some(front_digest.clone()),
        "front-window screenshots are never touched"
    );
    assert!(memory.blob_path(&front_digest).exists());

    // What Preferences and Privacy read: counted again, content-free.
    let usage: PicturesUsage =
        serde_json::from_slice(&std::fs::read(memory.usage_path()).unwrap()).unwrap();
    assert_eq!(usage.side_count, 1);
    assert_eq!(usage.side_bytes, 200_000);
    assert_eq!(usage.front_bytes, 300_000);
    assert!(!usage.side_pictures_on);

    // The lease went with the pass: an agent can start now.
    drop(store);
    let (_, lease) = acquire_lock(&lock_path_for_brain(&memory.db())).expect("the lease is free");
    lease.release().unwrap();
}

#[test]
fn refuses_while_another_writer_holds_the_memory() {
    let mut memory = Memory::new();
    let now = now_us();
    let digest = memory.blob(1_000);
    let side = {
        let store = memory.open();
        Memory::put(
            &store,
            now - 2 * HOUR,
            "launch",
            Some(digest.clone()),
            EventSource::ScreenContext,
        )
    };
    memory.request(now - HOUR);
    let (_, running) = acquire_lock(&lock_path_for_brain(&memory.db())).unwrap();

    let output = memory.forget_now();

    assert_eq!(
        output.status.code(),
        Some(26),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    running.release().unwrap();
    let store = memory.open();
    assert_eq!(
        store.get_event(side).unwrap().unwrap().keyframe_blob,
        Some(digest.clone())
    );
    assert!(memory.blob_path(&digest).exists());
    assert!(!memory.usage_path().exists());
}

#[test]
fn makes_nothing_when_there_is_no_memory_yet() {
    let memory = Memory::new();
    memory.request(now_us());

    let output = memory.forget_now();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!memory.db().exists(), "no memory is made");
    assert!(!lock_path_for_brain(&memory.db()).exists());
    assert!(!memory.usage_path().exists());
}
