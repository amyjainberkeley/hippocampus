//! Pictures of the windows beside the front one (SPEC 6.5): thinning by
//! age and by budget, what they use, and forgetting them. Pictures go,
//! text never does, and front-window screenshots are never touched.
//! Everything here is synthetic.

use std::path::PathBuf;

use mci_brain::retention_purger::clear_side_pictures;
use mci_brain::side_pictures::{
    self, BlobSizes, PictureUsage, SidePicture, SidePictureSettings, GB, MB,
};
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

/// Blob file sizes, in bytes, for `Brain::blob`.
const MB_FILE: usize = 1_000_000;
const HALF_MB_FILE: usize = 500_000;

const SECOND: u64 = 1_000_000;
const MINUTE: u64 = 60 * SECOND;
const HOUR: u64 = 60 * MINUTE;
const DAY: u64 = 24 * HOUR;
/// Monday, October 12, 2026, midnight UTC: a day boundary.
const NOW: u64 = 1_791_763_200_000_000 + 40 * DAY;

const SLACK: &str = "com.tinyspeck.slackmacgap";
const LAUNCH: &str = "launch (Channel) - Northwind Studio - Slack";
const NOTES: &str = "com.apple.Notes";
const CHECKLIST: &str = "Launch checklist";
const CODE: &str = "com.microsoft.VSCode";
const TAX: &str = "tax.rs \u{2014} trailhead-shop";

struct Brain {
    _dir: tempfile::TempDir,
    blobs: PathBuf,
    store: SqlCipherBrainStore,
    next: u32,
}

impl Brain {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mci.sqlite");
        let store = SqlCipherBrainStore::new(&path, &DbKey::from_bytes([9; 32])).unwrap();
        let blobs = dir.path().join("blobs");
        std::fs::create_dir(&blobs).unwrap();
        Self {
            _dir: dir,
            blobs,
            store,
            next: 1,
        }
    }

    /// A fresh digest with a blob file of `bytes` bytes behind it.
    fn blob(&mut self, bytes: usize) -> String {
        let digest = format!("{:064x}", self.next);
        self.next += 1;
        std::fs::write(self.blobs.join(format!("{digest}.bin")), vec![7_u8; bytes]).unwrap();
        digest
    }

    fn put(
        &self,
        ts_us: u64,
        app: &str,
        title: &str,
        text: &str,
        keyframe: Option<String>,
        source: EventSource,
    ) -> EventId {
        self.store
            .put_event_with_source(
                &Event {
                    id: EventId(0),
                    ts_us,
                    app_bundle_id: Some(app.into()),
                    window_title: Some(title.into()),
                    url: None,
                    text: text.into(),
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

    /// A side moment that kept a picture of `bytes` bytes.
    fn side(&mut self, ts_us: u64, app: &str, title: &str, text: &str, bytes: usize) -> EventId {
        let digest = self.blob(bytes);
        self.put(
            ts_us,
            app,
            title,
            text,
            Some(digest),
            EventSource::ScreenContext,
        )
    }

    fn keyframe(&self, id: EventId) -> Option<String> {
        self.store.get_event(id).unwrap().unwrap().keyframe_blob
    }

    fn text(&self, id: EventId) -> String {
        self.store.get_event(id).unwrap().unwrap().text
    }

    fn blob_exists(&self, digest: &str) -> bool {
        self.blobs.join(format!("{digest}.bin")).exists()
    }

    fn pictures(&self) -> Vec<SidePicture> {
        side_pictures::list_side_pictures(&self.store, &mut BlobSizes::new()).unwrap()
    }

    fn usage(&self) -> PictureUsage {
        side_pictures::usage(&self.store, &mut BlobSizes::new()).unwrap()
    }
}

#[test]
fn the_last_day_keeps_every_picture() {
    let mut brain = Brain::new();
    let ids = (0..20)
        .map(|n| {
            brain.side(
                NOW - 23 * HOUR + n * MINUTE,
                SLACK,
                LAUNCH,
                &format!("line {n}"),
                1_000,
            )
        })
        .collect::<Vec<_>>();
    let stats = side_pictures::thin(&brain.store, &mut BlobSizes::new(), NOW, 2 * GB).unwrap();
    assert_eq!(stats.pictures_cleared, 0);
    assert!(ids.iter().all(|id| brain.keyframe(*id).is_some()));
}

#[test]
fn older_pictures_thin_to_one_per_window_per_bucket_keeping_the_biggest_change() {
    let mut brain = Brain::new();
    // Three days ago, one 15-minute bucket (aligned to the clock): three
    // pictures of the channel. The middle one's text changed the most.
    let base = NOW - 3 * DAY;
    let first = brain.side(
        base + MINUTE,
        SLACK,
        LAUNCH,
        "Jordan: staging is green",
        1_000,
    );
    let biggest = brain.side(
        base + 5 * MINUTE,
        SLACK,
        LAUNCH,
        "Jordan: staging is green\nPriya: changelog next\nMaya: gift cards ready\nSam: shipping at 4",
        1_000,
    );
    let small = brain.side(
        base + 9 * MINUTE,
        SLACK,
        LAUNCH,
        "Jordan: staging is green\nPriya: changelog next\nMaya: gift cards ready\nSam: shipping at 4\nok",
        1_000,
    );
    // Another window in the same bucket keeps its own.
    let notes = brain.side(
        base + 2 * MINUTE,
        NOTES,
        CHECKLIST,
        "Rounding fix merged",
        1_000,
    );
    // The next bucket keeps its own as well.
    let next = brain.side(base + 16 * MINUTE, SLACK, LAUNCH, "Jordan: shipped", 1_000);

    let stats = side_pictures::thin(&brain.store, &mut BlobSizes::new(), NOW, 2 * GB).unwrap();

    assert_eq!(stats.pictures_cleared, 2);
    assert!(brain.keyframe(first).is_none());
    assert!(brain.keyframe(biggest).is_some());
    assert!(brain.keyframe(small).is_none());
    assert!(brain.keyframe(notes).is_some());
    assert!(brain.keyframe(next).is_some());
    // Text is never thinned.
    assert_eq!(brain.text(first), "Jordan: staging is green");
    assert!(brain.text(small).ends_with("\nok"));
    assert_eq!(brain.store.stats().unwrap().event_count, 5);
}

#[test]
fn each_age_tier_keeps_one_picture_per_window_per_bucket() {
    let mut brain = Brain::new();
    let mut kept_per_tier = Vec::new();
    // Ten days old: 2-hour buckets. Four pictures within one bucket.
    let ten = NOW - 10 * DAY;
    let tens = (0..4)
        .map(|n| {
            brain.side(
                ten + n * 20 * MINUTE,
                CODE,
                TAX,
                &format!("change {n}"),
                1_000,
            )
        })
        .collect::<Vec<_>>();
    // Forty days old: day buckets. Five pictures across one day.
    let forty = NOW - 40 * DAY;
    let forties = (0..5)
        .map(|n| brain.side(forty + n * 3 * HOUR, CODE, TAX, &format!("edit {n}"), 1_000))
        .collect::<Vec<_>>();
    side_pictures::thin(&brain.store, &mut BlobSizes::new(), NOW, 2 * GB).unwrap();
    kept_per_tier.push(
        tens.iter()
            .filter(|id| brain.keyframe(**id).is_some())
            .count(),
    );
    kept_per_tier.push(
        forties
            .iter()
            .filter(|id| brain.keyframe(**id).is_some())
            .count(),
    );
    assert_eq!(kept_per_tier, vec![1, 1]);
    // Every picture's moment is still there, with its text.
    assert_eq!(brain.store.stats().unwrap().event_count, 9);
}

#[test]
fn over_budget_thins_the_oldest_days_first_then_the_oldest_pictures_to_under_ninety_percent() {
    let mut brain = Brain::new();
    // Ten pictures a day over the last three days, half a MB each: 15 MB.
    let mut by_day: Vec<Vec<EventId>> = Vec::new();
    for day in (0..3).rev() {
        let start = NOW - day * DAY - 20 * HOUR;
        let ids = (0..10)
            .map(|n| {
                let (app, title) = if n % 2 == 0 {
                    (SLACK, LAUNCH)
                } else {
                    (NOTES, CHECKLIST)
                };
                brain.side(
                    start + n * HOUR,
                    app,
                    title,
                    &format!("day {day} item {n}"),
                    HALF_MB_FILE,
                )
            })
            .collect::<Vec<_>>();
        by_day.push(ids);
    }
    assert_eq!(brain.usage().side_bytes, 15 * MB);

    // A 10 MB budget: thin to at most 9 MB.
    let stats = side_pictures::thin(&brain.store, &mut BlobSizes::new(), NOW, 10 * MB).unwrap();
    let left = brain.usage();
    assert!(left.side_bytes <= 9 * MB, "left {}", left.side_bytes);
    assert_eq!(stats.bytes_cleared, 15 * MB - left.side_bytes);
    let kept = |ids: &[EventId]| {
        ids.iter()
            .filter(|id| brain.keyframe(**id).is_some())
            .count()
    };
    // The oldest day went down to one picture per window first...
    assert_eq!(kept(&by_day[0]), 2);
    // ...and the second day before the newest, which lost nothing.
    assert!(kept(&by_day[1]) < 10);
    assert_eq!(kept(&by_day[2]), 10);
    // Thinned blobs are deleted from disk; text stays.
    assert_eq!(brain.store.stats().unwrap().event_count, 30);
    for picture in brain.pictures() {
        assert!(brain.blob_exists(&picture.digest));
    }
}

#[test]
fn over_budget_reaches_today_down_to_one_picture_per_window() {
    let mut brain = Brain::new();
    // One window, one picture an hour in the last day.
    let ids = (0..10)
        .map(|n| {
            brain.side(
                NOW - 10 * HOUR + n * HOUR,
                SLACK,
                LAUNCH,
                &format!("t{n}"),
                MB_FILE,
            )
        })
        .collect::<Vec<_>>();
    side_pictures::thin(&brain.store, &mut BlobSizes::new(), NOW, 5 * MB).unwrap();
    let kept = ids
        .iter()
        .map(|id| brain.keyframe(*id).is_some())
        .collect::<Vec<_>>();
    // Each changed as much as the others, so the newest stays.
    assert_eq!(
        kept,
        [false, false, false, false, false, false, false, false, false, true]
    );
}

#[test]
fn a_store_still_over_budget_loses_its_oldest_pictures() {
    let mut brain = Brain::new();
    // Ten windows with one picture each: one per window per day already.
    let titles = (0..10).map(|n| format!("Document {n}")).collect::<Vec<_>>();
    let ids = titles
        .iter()
        .enumerate()
        .map(|(n, title)| {
            brain.side(
                NOW - 10 * HOUR + n as u64 * HOUR,
                NOTES,
                title,
                "text",
                MB_FILE,
            )
        })
        .collect::<Vec<_>>();
    side_pictures::thin(&brain.store, &mut BlobSizes::new(), NOW, 5 * MB).unwrap();
    assert!(brain.usage().side_bytes <= 4_500_000);
    let kept = ids
        .iter()
        .map(|id| brain.keyframe(*id).is_some())
        .collect::<Vec<_>>();
    // The newest four stay.
    assert_eq!(
        kept,
        [false, false, false, false, false, false, true, true, true, true]
    );
}

#[test]
fn front_window_screenshots_are_not_counted_or_thinned() {
    let mut brain = Brain::new();
    let front_digest = brain.blob(3 * MB_FILE);
    let front = brain.put(
        NOW - 40 * DAY,
        CODE,
        TAX,
        "pub fn order_total",
        Some(front_digest.clone()),
        EventSource::ScreenOcr,
    );
    let later_front = brain.put(
        NOW - 40 * DAY + MINUTE,
        CODE,
        TAX,
        "pub fn",
        None,
        EventSource::ScreenOcr,
    );
    let side = brain.side(
        NOW - 40 * DAY + 2 * MINUTE,
        SLACK,
        LAUNCH,
        "Jordan",
        MB_FILE,
    );
    let usage = brain.usage();
    assert_eq!(
        usage,
        PictureUsage {
            front_bytes: 3 * MB,
            side_bytes: MB,
            side_count: 1
        }
    );

    // Even a budget of nothing touches only the side picture.
    side_pictures::thin(&brain.store, &mut BlobSizes::new(), NOW, 1).unwrap();
    assert_eq!(brain.keyframe(front), Some(front_digest.clone()));
    assert!(brain.blob_exists(&front_digest));
    assert!(brain.keyframe(side).is_none());
    // And the front window's borrowing is as before.
    let event = brain.store.get_event(later_front).unwrap().unwrap();
    let shown = brain
        .store
        .screenshot_for_event(&event, EventSource::ScreenOcr)
        .unwrap()
        .map(|shot| shot.digest);
    assert_eq!(shown, Some(front_digest));
}

#[test]
fn forgetting_pictures_of_other_windows_keeps_their_text_and_everything_after() {
    let mut brain = Brain::new();
    let front_digest = brain.blob(1_000);
    let front = brain.put(
        NOW - HOUR,
        CODE,
        TAX,
        "fn main",
        Some(front_digest.clone()),
        EventSource::ScreenOcr,
    );
    let old = brain.side(NOW - 2 * HOUR, SLACK, LAUNCH, "before the request", 1_000);
    let at = brain.side(NOW - HOUR, NOTES, CHECKLIST, "at the request", 1_000);
    let after = brain.side(
        NOW - HOUR + SECOND,
        SLACK,
        LAUNCH,
        "after the request",
        1_000,
    );
    let old_digest = brain.keyframe(old).unwrap();

    let stats =
        side_pictures::forget_through(&brain.store, &mut BlobSizes::new(), NOW - HOUR).unwrap();

    assert_eq!(stats.pictures_cleared, 2);
    assert_eq!(stats.blobs_deleted, 2);
    assert!(brain.keyframe(old).is_none());
    assert!(brain.keyframe(at).is_none());
    assert!(!brain.blob_exists(&old_digest));
    assert!(brain.keyframe(after).is_some());
    assert_eq!(brain.keyframe(front), Some(front_digest.clone()));
    assert!(brain.blob_exists(&front_digest));
    assert_eq!(brain.text(old), "before the request");
    // Search still finds the moment by its text.
    let hits = brain
        .store
        .fts5_search_filtered("request", 10, None, None)
        .unwrap();
    assert_eq!(hits.len(), 3);
    // Doing it again changes nothing.
    let again =
        side_pictures::forget_through(&brain.store, &mut BlobSizes::new(), NOW - HOUR).unwrap();
    assert_eq!(again.pictures_cleared, 0);
}

#[test]
fn clearing_touches_only_side_moments_that_still_hold_that_picture() {
    let mut brain = Brain::new();
    let front_digest = brain.blob(1_000);
    let front = brain.put(
        NOW,
        CODE,
        TAX,
        "x",
        Some(front_digest.clone()),
        EventSource::ScreenOcr,
    );
    let side = brain.side(NOW, SLACK, LAUNCH, "y", 1_000);
    let side_digest = brain.keyframe(side).unwrap();
    let stats = clear_side_pictures(
        &brain.store,
        &[
            (front.0, front_digest.clone()),
            (side.0, "f".repeat(64)),
            (999_999, side_digest.clone()),
        ],
    )
    .unwrap();
    assert_eq!(stats.pictures_cleared, 0);
    assert_eq!(brain.keyframe(front), Some(front_digest));
    assert_eq!(brain.keyframe(side), Some(side_digest.clone()));
    let stats = clear_side_pictures(&brain.store, &[(side.0, side_digest.clone())]).unwrap();
    assert_eq!(stats.pictures_cleared, 1);
    assert_eq!(stats.blobs_deleted, 1);
    assert!(!brain.blob_exists(&side_digest));
}

#[test]
fn usage_counts_each_blob_once_and_survives_missing_files() {
    let mut brain = Brain::new();
    let shared = brain.blob(2_000);
    brain.put(
        NOW,
        SLACK,
        LAUNCH,
        "a",
        Some(shared.clone()),
        EventSource::ScreenContext,
    );
    brain.put(
        NOW + SECOND,
        SLACK,
        LAUNCH,
        "b",
        Some(shared),
        EventSource::ScreenContext,
    );
    // A picture whose file is gone counts, with no bytes.
    brain.put(
        NOW + 2 * SECOND,
        NOTES,
        CHECKLIST,
        "c",
        Some("a".repeat(64)),
        EventSource::ScreenContext,
    );
    let usage = brain.usage();
    assert_eq!(usage.side_bytes, 2_000);
    assert_eq!(usage.side_count, 3);
    assert_eq!(usage.front_bytes, 0);
}

#[test]
fn a_cached_size_is_reused_and_a_gone_blob_is_measured_again() {
    let mut brain = Brain::new();
    let id = brain.side(NOW, SLACK, LAUNCH, "a", 4_000);
    let digest = brain.keyframe(id).unwrap();
    let mut sizes = BlobSizes::new();
    assert_eq!(
        side_pictures::usage(&brain.store, &mut sizes)
            .unwrap()
            .side_bytes,
        4_000
    );
    // The cache answers without the file.
    std::fs::remove_file(brain.blobs.join(format!("{digest}.bin"))).unwrap();
    assert_eq!(
        side_pictures::usage(&brain.store, &mut sizes)
            .unwrap()
            .side_bytes,
        4_000
    );
    // A fresh cache sees it gone.
    assert_eq!(brain.usage().side_bytes, 0);
}

#[test]
fn settings_load_from_the_file_and_default_when_it_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    let path = side_pictures::settings_path(dir.path());
    assert!(path.ends_with(".config/hippocampus/runtime.toml"));
    assert_eq!(
        SidePictureSettings::load(&path),
        SidePictureSettings::default()
    );
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        &path,
        "capture_enabled = true\nside_window_pictures = true\nside_pictures_budget_mb = 1000\n",
    )
    .unwrap();
    let settings = SidePictureSettings::load(&path);
    assert!(settings.enabled);
    assert_eq!(settings.budget_bytes(None), GB);
}
