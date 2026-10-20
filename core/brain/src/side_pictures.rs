//! Pictures of the windows beside the one in front (SPEC 6): the settings
//! that govern them, the disk budget they share, and how they are thinned
//! out as they age. Text is never thinned.
//!
//! The capture helper keeps a picture of a side window when its text
//! changes meaningfully, sealed and stored exactly as front-window
//! screenshots are, and puts its digest on that window's own moment
//! (`screen_context`). Everything here works on those pictures only:
//! front-window screenshots are not counted and not thinned, and no
//! moment's text, caption or search changes. A thinned moment shows its
//! app tile, as before side pictures existed.
//!
//! # Thinning (SPEC 6.5)
//!
//! | Age | Side pictures kept |
//! |---|---|
//! | Last 24 hours | all of them |
//! | 1 to 7 days | at most one per window per 15 minutes: the one whose text changed most |
//! | 7 to 30 days | one per window per 2 hours |
//! | 30 days to retention | one per window per day |
//! | Over budget at any age | the oldest days first, down to one per window per day, then the oldest pictures, until under 90% of the budget |
//!
//! A window is its app and title. Buckets are aligned to the clock in UTC,
//! so a picture's bucket never moves while it ages through a tier; which
//! picture a bucket keeps is the one whose text changed most since the
//! window's previous picture (the newest on a tie). Retention removes whole
//! moments, pictures with them, as before.
//!
//! # Settings
//!
//! The app's Preferences write them to `~/.config/hippocampus/runtime.toml`:
//!
//! - `side_window_pictures` (boolean): keep pictures of side windows.
//!   Missing, or anything but a boolean, reads as off: consent never grows
//!   from a damaged file.
//! - `side_pictures_budget_mb` (integer): 1000, 2000 or 5000. Missing or
//!   anything else is the default budget: 2 GB, or 2% of the startup disk
//!   if that is less.
//! - `delete_side_pictures_requested_at` (integer, Unix seconds): the moment
//!   Forget Pictures of Other Windows… was confirmed. Every side picture kept
//!   at or before it is removed; the text stays.
//!
//! # Privacy
//!
//! - Content-free: nothing here logs or writes text, titles or apps; the
//!   usage record holds byte counts and a count.
//! - The only change to memory is clearing a side moment's `keyframe_blob`
//!   (`retention_purger::clear_side_pictures`), then deleting a blob file no
//!   moment references. Nothing is inserted. A side moment's text is read
//!   in this process only to judge how much it changed.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use rusqlite::params;

use crate::sqlcipher_brain_store::{has_event_sources, is_keyframe_digest};
use crate::{SqlCipherBrainStore, StoreError};

/// The stored source kind of a side window's moment.
pub const SIDE_SOURCE_KIND: &str = "screen_context";

/// One megabyte as the Mac shows sizes (decimal, like Finder).
pub const MB: u64 = 1_000_000;
/// One gigabyte as the Mac shows sizes.
pub const GB: u64 = 1_000 * MB;

/// Preferences' choices for "Use at most", in MB: 1 GB, 2 GB and 5 GB.
pub const BUDGET_CHOICES_MB: [u64; 3] = [1_000, 2_000, 5_000];
/// The budget when none was chosen, unless 2% of the disk is less.
pub const DEFAULT_BUDGET_BYTES: u64 = 2 * GB;
/// The share of the startup disk the default budget never exceeds.
pub const DEFAULT_BUDGET_DISK_PERCENT: u64 = 2;
/// An over-budget store is thinned until it uses at most this share.
pub const THIN_TO_PERCENT: u64 = 90;

/// Below this much free disk no new side picture is kept (text continues).
pub const DISK_FLOOR_BYTES: u64 = 10 * GB;
/// Side pictures resume once the disk has this much free again.
pub const DISK_RESUME_BYTES: u64 = 12 * GB;

const SECOND_US: u64 = 1_000_000;
const MINUTE_US: u64 = 60 * SECOND_US;
const HOUR_US: u64 = 60 * MINUTE_US;
const DAY_US: u64 = 24 * HOUR_US;

/// The settings file the app's Preferences write, under `home`.
#[must_use]
pub fn settings_path(home: &Path) -> PathBuf {
    home.join(".config/hippocampus/runtime.toml")
}

/// What `runtime.toml` says about side pictures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SidePictureSettings {
    /// Keep pictures of side windows.
    pub enabled: bool,
    /// The chosen budget in MB, one of [`BUDGET_CHOICES_MB`]; `None` is the
    /// default budget.
    pub budget_mb: Option<u64>,
    /// Forget Pictures of Other Windows… was confirmed at this time, in
    /// microseconds since the Unix epoch.
    pub delete_requested_at_us: Option<u64>,
}

impl SidePictureSettings {
    /// Reads the three settings from a `runtime.toml` document. A document
    /// that is not valid TOML reads as all defaults: off, the default
    /// budget, and no request.
    #[must_use]
    pub fn parse(text: &str) -> Self {
        let Ok(table) = text.parse::<toml::Table>() else {
            return Self::default();
        };
        let enabled = matches!(
            table.get("side_window_pictures"),
            Some(toml::Value::Boolean(true))
        );
        let budget_mb = match table.get("side_pictures_budget_mb") {
            Some(toml::Value::Integer(mb)) => u64::try_from(*mb)
                .ok()
                .filter(|mb| BUDGET_CHOICES_MB.contains(mb)),
            _ => None,
        };
        let delete_requested_at_us = match table.get("delete_side_pictures_requested_at") {
            Some(toml::Value::Integer(seconds)) => u64::try_from(*seconds)
                .ok()
                .filter(|seconds| *seconds > 0)
                .and_then(|seconds| seconds.checked_mul(SECOND_US)),
            _ => None,
        };
        Self {
            enabled,
            budget_mb,
            delete_requested_at_us,
        }
    }

    /// Reads `path`. A missing or unreadable file reads as all defaults.
    #[must_use]
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .map(|text| Self::parse(&text))
            .unwrap_or_default()
    }

    /// The budget in bytes on a startup disk of `disk_total_bytes`.
    #[must_use]
    pub fn budget_bytes(&self, disk_total_bytes: Option<u64>) -> u64 {
        match self.budget_mb {
            Some(mb) => mb.saturating_mul(MB),
            None => default_budget_bytes(disk_total_bytes),
        }
    }
}

/// 2 GB, or 2% of the startup disk if that is less. An unknown disk size
/// gives 2 GB.
#[must_use]
pub fn default_budget_bytes(disk_total_bytes: Option<u64>) -> u64 {
    disk_total_bytes
        .map(|total| total / 100 * DEFAULT_BUDGET_DISK_PERCENT)
        .filter(|share| *share > 0)
        .map_or(DEFAULT_BUDGET_BYTES, |share| {
            share.min(DEFAULT_BUDGET_BYTES)
        })
}

/// One kept picture of a side window, as thinning sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidePicture {
    /// The side moment that kept it.
    pub event_id: u64,
    /// When it was kept, microseconds since the Unix epoch.
    pub ts_us: u64,
    /// The window it shows: its app.
    pub app: Option<String>,
    /// The window it shows: its title.
    pub title: Option<String>,
    /// Lowercase SHA-256 hex naming the sealed blob.
    pub digest: String,
    /// The sealed blob's size on disk; 0 when the file is gone.
    pub bytes: u64,
}

impl SidePicture {
    fn window(&self) -> (&str, &str) {
        (
            self.app.as_deref().map_or("", str::trim),
            self.title.as_deref().map_or("", str::trim),
        )
    }
}

/// Sizes of sealed blobs by digest, kept between cycles: a blob is
/// content-addressed and never changes, so each is measured once.
#[derive(Debug, Default)]
pub struct BlobSizes {
    sizes: HashMap<String, u64>,
}

impl BlobSizes {
    /// An empty cache.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn measure(&mut self, blob_dir: &Path, digest: &str, seen: &mut HashMap<String, u64>) -> u64 {
        if let Some(size) = seen.get(digest) {
            return *size;
        }
        let size = if let Some(size) = self.sizes.get(digest) {
            *size
        } else {
            let size = std::fs::symlink_metadata(blob_dir.join(format!("{digest}.bin")))
                .ok()
                .filter(std::fs::Metadata::is_file)
                .map_or(0, |metadata| metadata.len());
            if size > 0 {
                self.sizes.insert(digest.to_owned(), size);
            }
            size
        };
        seen.insert(digest.to_owned(), size);
        size
    }

    /// Keep only the sizes measured in the latest pass, so the cache never
    /// outgrows the store.
    fn keep_only(&mut self, seen: HashMap<String, u64>) {
        // A gone blob measured 0 is measured again next time: it may be a
        // picture still being written when this pass ran.
        self.sizes = seen.into_iter().filter(|(_, size)| *size > 0).collect();
    }
}

/// How much the screenshots use, content-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PictureUsage {
    /// Sealed screenshots of the window in front, in bytes.
    pub front_bytes: u64,
    /// Sealed pictures of the windows beside it, in bytes.
    pub side_bytes: u64,
    /// Side moments that keep a picture.
    pub side_count: u64,
}

/// Every side moment that keeps a picture, oldest first, with its blob's
/// size. Empty for a store from before sources were recorded.
///
/// # Errors
/// A content-free backend error when the store cannot be read.
pub fn list_side_pictures(
    store: &SqlCipherBrainStore,
    sizes: &mut BlobSizes,
) -> Result<Vec<SidePicture>, StoreError> {
    let mut pictures = side_picture_rows(store)?;
    let blob_dir = store.keyframe_blob_dir().to_path_buf();
    let mut seen = HashMap::new();
    for picture in &mut pictures {
        picture.bytes = sizes.measure(&blob_dir, &picture.digest, &mut seen);
    }
    Ok(pictures)
}

/// The side moments that keep a picture, oldest first, sizes not measured.
fn side_picture_rows(store: &SqlCipherBrainStore) -> Result<Vec<SidePicture>, StoreError> {
    let guard = store.db.lock().expect("brain store mutex poisoned");
    let connection = guard.conn();
    if !has_event_sources(connection)? {
        return Ok(Vec::new());
    }
    let mut statement = connection
        .prepare(
            "SELECT e.id, e.ts_us, e.app_bundle_id, e.window_title, e.keyframe_blob
             FROM event_sources s JOIN events e ON e.id = s.event_id
             WHERE s.source_kind = 'screen_context' AND e.keyframe_blob IS NOT NULL
             ORDER BY e.ts_us, e.id",
        )
        .map_err(|e| StoreError::Backend(format!("prepare side pictures: {e}")))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, String>(4)?,
            ))
        })
        .map_err(|e| StoreError::Backend(format!("query side pictures: {e}")))?;
    let mut out = Vec::new();
    for row in rows {
        let (id, ts_us, app, title, digest) =
            row.map_err(|e| StoreError::Backend(format!("read side pictures: {e}")))?;
        let digest = digest.trim().to_owned();
        let (Ok(id), Ok(ts_us)) = (u64::try_from(id), u64::try_from(ts_us)) else {
            continue;
        };
        if !is_keyframe_digest(&digest) {
            continue;
        }
        out.push(SidePicture {
            event_id: id,
            ts_us,
            app,
            title,
            digest,
            bytes: 0,
        });
    }
    Ok(out)
}

/// What the screenshots use: each sealed blob counted once, by the kind of
/// moment that keeps it. A blob a side moment and a front moment both keep
/// counts as the front window's, since it is not thinned.
///
/// # Errors
/// A content-free backend error when the store cannot be read.
pub fn usage(
    store: &SqlCipherBrainStore,
    sizes: &mut BlobSizes,
) -> Result<PictureUsage, StoreError> {
    let (front, side) = {
        let guard = store.db.lock().expect("brain store mutex poisoned");
        let connection = guard.conn();
        let sources = has_event_sources(connection)?;
        let sql = if sources {
            "SELECT e.keyframe_blob,
                    EXISTS (SELECT 1 FROM event_sources s
                            WHERE s.event_id = e.id AND s.source_kind = 'screen_context')
             FROM events e WHERE e.keyframe_blob IS NOT NULL"
        } else {
            "SELECT keyframe_blob, 0 FROM events WHERE keyframe_blob IS NOT NULL"
        };
        let mut statement = connection
            .prepare(sql)
            .map_err(|e| StoreError::Backend(format!("prepare picture usage: {e}")))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?))
            })
            .map_err(|e| StoreError::Backend(format!("query picture usage: {e}")))?;
        // digest -> moments that keep it: front ones, side ones.
        let mut front: BTreeMap<String, u64> = BTreeMap::new();
        let mut side: BTreeMap<String, u64> = BTreeMap::new();
        for row in rows {
            let (digest, beside) =
                row.map_err(|e| StoreError::Backend(format!("read picture usage: {e}")))?;
            let digest = digest.trim().to_owned();
            if !is_keyframe_digest(&digest) {
                continue;
            }
            let counts = if beside { &mut side } else { &mut front };
            *counts.entry(digest).or_insert(0) += 1;
        }
        (front, side)
    };
    let blob_dir = store.keyframe_blob_dir().to_path_buf();
    let mut seen = HashMap::new();
    let mut usage = PictureUsage::default();
    for digest in front.keys() {
        usage.front_bytes = usage
            .front_bytes
            .saturating_add(sizes.measure(&blob_dir, digest, &mut seen));
    }
    for (digest, moments) in &side {
        usage.side_count = usage.side_count.saturating_add(*moments);
        if !front.contains_key(digest) {
            usage.side_bytes = usage
                .side_bytes
                .saturating_add(sizes.measure(&blob_dir, digest, &mut seen));
        }
    }
    sizes.keep_only(seen);
    Ok(usage)
}

/// The side moments' text, by id, for judging how much each changed.
/// Read in this process only; it never leaves it.
///
/// # Errors
/// A content-free backend error when the store cannot be read.
pub(crate) fn moment_text(
    store: &SqlCipherBrainStore,
    event_id: u64,
) -> Result<String, StoreError> {
    let Ok(id) = i64::try_from(event_id) else {
        return Ok(String::new());
    };
    let guard = store.db.lock().expect("brain store mutex poisoned");
    guard
        .conn()
        .prepare_cached("SELECT text FROM events WHERE id = ?1")
        .and_then(|mut statement| {
            statement
                .query_row(params![id], |row| row.get::<_, String>(0))
                .or_else(|error| match error {
                    rusqlite::Error::QueryReturnedNoRows => Ok(String::new()),
                    other => Err(other),
                })
        })
        .map_err(|e| StoreError::Backend(format!("read side moment text: {e}")))
}

/// How many of `current`'s lines `previous` did not have: the lines a
/// picture's moment added or changed since the window's previous picture.
/// With no previous picture every line is new. Blank lines do not count.
#[must_use]
pub fn changed_lines(current: &str, previous: Option<&str>) -> u64 {
    let before: std::collections::HashSet<&str> = previous
        .map(|text| {
            text.lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let count = current
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !before.contains(line))
        .count();
    u64::try_from(count).unwrap_or(u64::MAX)
}

/// The bucket size that applies to a picture `age_us` old: none in the
/// last 24 hours (all are kept), then 15 minutes, 2 hours and a day.
#[must_use]
pub fn bucket_for_age(age_us: u64) -> Option<u64> {
    if age_us < DAY_US {
        None
    } else if age_us < 7 * DAY_US {
        Some(15 * MINUTE_US)
    } else if age_us < 30 * DAY_US {
        Some(2 * HOUR_US)
    } else {
        Some(DAY_US)
    }
}

/// Which of `pictures` (oldest first, as [`list_side_pictures`] gives
/// them) to clear: the age tiers, then the budget. `score(i, previous)` is
/// how much picture `i`'s text changed since its window's previous picture
/// `previous` ([`changed_lines`]); it is asked only where a bucket holds
/// more than one picture. Returns indices into `pictures`, ascending.
pub fn plan_thinning(
    pictures: &[SidePicture],
    now_us: u64,
    budget_bytes: u64,
    mut score: impl FnMut(usize, Option<usize>) -> u64,
) -> Vec<usize> {
    let mut cleared = vec![false; pictures.len()];
    // Each picture's window and the window's previous picture.
    let mut previous: Vec<Option<usize>> = vec![None; pictures.len()];
    {
        let mut last: HashMap<(&str, &str), usize> = HashMap::new();
        for (index, picture) in pictures.iter().enumerate() {
            previous[index] = last.insert(picture.window(), index);
        }
    }
    let mut scores: HashMap<usize, u64> = HashMap::new();
    let mut score_of = |index: usize, scores: &mut HashMap<usize, u64>| -> u64 {
        *scores
            .entry(index)
            .or_insert_with(|| score(index, previous[index]))
    };

    // The age tiers: one picture per window per bucket.
    let mut buckets: BTreeMap<(u64, u64, &str, &str), Vec<usize>> = BTreeMap::new();
    for (index, picture) in pictures.iter().enumerate() {
        let age = now_us.saturating_sub(picture.ts_us);
        if let Some(size) = bucket_for_age(age) {
            let (app, title) = picture.window();
            buckets
                .entry((size, picture.ts_us / size, app, title))
                .or_default()
                .push(index);
        }
    }
    for members in buckets.values() {
        if members.len() < 2 {
            continue;
        }
        let keep = pick_keeper(members, pictures, &mut scores, &mut score_of);
        for &index in members {
            if index != keep {
                cleared[index] = true;
            }
        }
    }

    // The budget: what is left, each blob counted once.
    let mut references: HashMap<&str, u64> = HashMap::new();
    let mut used: u64 = 0;
    for (index, picture) in pictures.iter().enumerate() {
        if cleared[index] {
            continue;
        }
        let count = references.entry(picture.digest.as_str()).or_insert(0);
        if *count == 0 {
            used = used.saturating_add(picture.bytes);
        }
        *count += 1;
    }
    if budget_bytes == 0 || used < budget_bytes {
        return indices(&cleared);
    }
    let target = budget_bytes / 100 * THIN_TO_PERCENT;
    let mut drop_picture = |index: usize, cleared: &mut Vec<bool>, used: &mut u64| {
        if cleared[index] {
            return;
        }
        cleared[index] = true;
        let picture = &pictures[index];
        if let Some(count) = references.get_mut(picture.digest.as_str()) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                *used = used.saturating_sub(picture.bytes);
            }
        }
    };
    // The oldest days first, down to one picture per window per day.
    let mut days: BTreeMap<u64, BTreeMap<(&str, &str), Vec<usize>>> = BTreeMap::new();
    for (index, picture) in pictures.iter().enumerate() {
        if !cleared[index] {
            days.entry(picture.ts_us / DAY_US)
                .or_default()
                .entry(picture.window())
                .or_default()
                .push(index);
        }
    }
    for windows in days.values() {
        if used <= target {
            break;
        }
        for members in windows.values() {
            if members.len() < 2 {
                continue;
            }
            let keep = pick_keeper(members, pictures, &mut scores, &mut score_of);
            for &index in members {
                if index != keep {
                    drop_picture(index, &mut cleared, &mut used);
                }
            }
        }
    }
    // Then the oldest pictures.
    for index in 0..pictures.len() {
        if used <= target {
            break;
        }
        drop_picture(index, &mut cleared, &mut used);
    }
    indices(&cleared)
}

/// The picture a bucket keeps: the one whose text changed most, the newest
/// on a tie.
fn pick_keeper(
    members: &[usize],
    pictures: &[SidePicture],
    scores: &mut HashMap<usize, u64>,
    score_of: &mut impl FnMut(usize, &mut HashMap<usize, u64>) -> u64,
) -> usize {
    let mut best = members[0];
    let mut best_score = score_of(best, scores);
    for &index in &members[1..] {
        let candidate = score_of(index, scores);
        let newer = (pictures[index].ts_us, pictures[index].event_id)
            > (pictures[best].ts_us, pictures[best].event_id);
        if candidate > best_score || (candidate == best_score && newer) {
            best = index;
            best_score = candidate;
        }
    }
    best
}

fn indices(cleared: &[bool]) -> Vec<usize> {
    cleared
        .iter()
        .enumerate()
        .filter_map(|(index, cleared)| cleared.then_some(index))
        .collect()
}

/// Content-free stats from one thinning or forgetting pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ThinningStats {
    /// Side moments whose picture was cleared.
    pub pictures_cleared: u64,
    /// Bytes of sealed pictures cleared (each blob once).
    pub bytes_cleared: u64,
    /// Blob files deleted because no moment keeps them any more.
    pub blobs_deleted: u64,
}

/// Thin the side pictures by age and to the budget (SPEC 6.5).
///
/// # Errors
/// A content-free backend error when the store cannot be read or written.
pub fn thin(
    store: &SqlCipherBrainStore,
    sizes: &mut BlobSizes,
    now_us: u64,
    budget_bytes: u64,
) -> Result<ThinningStats, StoreError> {
    let pictures = list_side_pictures(store, sizes)?;
    let mut texts: HashMap<u64, String> = HashMap::new();
    let mut read_error = None;
    let mut text_of = |event_id: u64, texts: &mut HashMap<u64, String>| -> Option<String> {
        if let Some(text) = texts.get(&event_id) {
            return Some(text.clone());
        }
        match moment_text(store, event_id) {
            Ok(text) => {
                texts.insert(event_id, text.clone());
                Some(text)
            }
            Err(error) => {
                read_error.get_or_insert(error);
                None
            }
        }
    };
    let plan = plan_thinning(&pictures, now_us, budget_bytes, |index, previous| {
        let Some(current) = text_of(pictures[index].event_id, &mut texts) else {
            return 0;
        };
        let before = previous.and_then(|previous| text_of(pictures[previous].event_id, &mut texts));
        changed_lines(&current, before.as_deref())
    });
    if let Some(error) = read_error {
        return Err(error);
    }
    clear(store, &pictures, &plan)
}

/// Forget Pictures of Other Windows…: clear every side picture kept at or
/// before `through_us`. Their text stays.
///
/// # Errors
/// A content-free backend error when the store cannot be read or written.
pub fn forget_through(
    store: &SqlCipherBrainStore,
    sizes: &mut BlobSizes,
    through_us: u64,
) -> Result<ThinningStats, StoreError> {
    let pictures = list_side_pictures(store, sizes)?;
    let plan = pictures
        .iter()
        .enumerate()
        .filter_map(|(index, picture)| (picture.ts_us <= through_us).then_some(index))
        .collect::<Vec<_>>();
    clear(store, &pictures, &plan)
}

fn clear(
    store: &SqlCipherBrainStore,
    pictures: &[SidePicture],
    plan: &[usize],
) -> Result<ThinningStats, StoreError> {
    if plan.is_empty() {
        return Ok(ThinningStats::default());
    }
    let targets = plan
        .iter()
        .map(|&index| (pictures[index].event_id, pictures[index].digest.clone()))
        .collect::<Vec<_>>();
    let cleared = crate::retention_purger::clear_side_pictures(store, &targets)?;
    let mut counted = std::collections::HashSet::new();
    let bytes_cleared = plan
        .iter()
        .filter(|&&index| counted.insert(pictures[index].digest.as_str()))
        .map(|&index| pictures[index].bytes)
        .fold(0_u64, u64::saturating_add);
    Ok(ThinningStats {
        pictures_cleared: cleared.pictures_cleared,
        bytes_cleared,
        blobs_deleted: cleared.blobs_deleted,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_read_as_off_unless_the_file_says_yes() {
        assert_eq!(
            SidePictureSettings::parse(""),
            SidePictureSettings::default()
        );
        assert!(!SidePictureSettings::parse("side_window_pictures = false").enabled);
        assert!(SidePictureSettings::parse("side_window_pictures = true").enabled);
        // Not a boolean, or not TOML: off, so consent never grows from a
        // damaged file.
        assert!(!SidePictureSettings::parse("side_window_pictures = \"true\"").enabled);
        assert!(!SidePictureSettings::parse("side_window_pictures = 1").enabled);
        assert!(!SidePictureSettings::parse("side_window_pictures = true\n[[").enabled);
        // Only the root key counts.
        assert!(!SidePictureSettings::parse("[other]\nside_window_pictures = true").enabled);
    }

    #[test]
    fn the_budget_is_one_of_the_three_choices_or_the_default() {
        for mb in BUDGET_CHOICES_MB {
            let settings = SidePictureSettings::parse(&format!("side_pictures_budget_mb = {mb}"));
            assert_eq!(settings.budget_mb, Some(mb));
            assert_eq!(settings.budget_bytes(Some(500 * GB)), mb * MB);
        }
        for odd in [
            "side_pictures_budget_mb = 3000",
            "side_pictures_budget_mb = -1",
            "side_pictures_budget_mb = \"2000\"",
            "side_pictures_budget_mb = 0",
        ] {
            assert_eq!(SidePictureSettings::parse(odd).budget_mb, None, "{odd}");
        }
        let unset = SidePictureSettings::default();
        assert_eq!(unset.budget_bytes(Some(500 * GB)), 2 * GB);
        assert_eq!(unset.budget_bytes(None), 2 * GB);
        // 2% of a small disk is less than 2 GB.
        assert_eq!(unset.budget_bytes(Some(50 * GB)), GB);
        // A chosen budget is the person's, whatever the disk.
        let chosen = SidePictureSettings::parse("side_pictures_budget_mb = 5000");
        assert_eq!(chosen.budget_bytes(Some(50 * GB)), 5 * GB);
    }

    #[test]
    fn the_delete_request_is_a_time_in_seconds() {
        let settings = SidePictureSettings::parse(
            "capture_enabled = true\ndelete_side_pictures_requested_at = 1792444800",
        );
        assert_eq!(
            settings.delete_requested_at_us,
            Some(1_792_444_800 * SECOND_US)
        );
        for odd in [
            "delete_side_pictures_requested_at = 0",
            "delete_side_pictures_requested_at = -5",
            "delete_side_pictures_requested_at = \"yesterday\"",
        ] {
            assert_eq!(
                SidePictureSettings::parse(odd).delete_requested_at_us,
                None,
                "{odd}"
            );
        }
    }

    #[test]
    fn changed_lines_counts_what_the_previous_picture_did_not_have() {
        assert_eq!(changed_lines("a\nb\n\nc", None), 3);
        assert_eq!(changed_lines("a\nb\nc", Some("a\nb\nc")), 0);
        assert_eq!(changed_lines("a\nb\nc\nd", Some("a\nb")), 2);
        assert_eq!(changed_lines("  a \nz", Some("a")), 1);
    }

    #[test]
    fn age_tiers_follow_the_spec() {
        assert_eq!(bucket_for_age(0), None);
        assert_eq!(bucket_for_age(DAY_US - 1), None);
        assert_eq!(bucket_for_age(DAY_US), Some(15 * MINUTE_US));
        assert_eq!(bucket_for_age(7 * DAY_US - 1), Some(15 * MINUTE_US));
        assert_eq!(bucket_for_age(7 * DAY_US), Some(2 * HOUR_US));
        assert_eq!(bucket_for_age(30 * DAY_US - 1), Some(2 * HOUR_US));
        assert_eq!(bucket_for_age(30 * DAY_US), Some(DAY_US));
        assert_eq!(bucket_for_age(89 * DAY_US), Some(DAY_US));
    }
}
