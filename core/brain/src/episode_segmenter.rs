//! Episode segmenter — groups events into episodes by app + time-gap
//! (ADR-0010 §1).
//!
//! An **episode** is a contiguous run of events in the same app with no
//! gap longer than `T_gap`. When the user switches apps OR when the gap
//! between two consecutive events exceeds `T_gap`, the segmenter starts
//! a new episode and writes an `episodes` row (INSERT), then UPDATE's
//! each event's `episode_id`.
//!
//! The heuristic is deliberately simple: no LLM, no embedding, no
//! content-shift proxy. ADR-0010 §2 lists dHash + embedding-cosine as
//! a future enrichment; this baseline lands first.
//!
//! # Privacy invariants
//!
//! - The segmenter only READS `events` rows that are already `.allow`-
//!   stored. It can never see suppressed events (they have no rows).
//! - It only WRITES to `events.episode_id` (existing nullable column)
//!   and INSERTs into `episodes` (existing table). No new write surface
//!   in `BrainStore` trait. No new capture path.
//! - The `cascade_reason` wall is preserved: the worker reads events
//!   that passed cascade (reason=0) only, by construction.

use crate::{Event, EventId, StoreError};

/// Stable identifier for one episode row.
///
/// Newtype over `u64` so episode ids don't mix with event/chunk ids.
/// Maps to `episodes.id` rowid in the `SQLite` schema (ADR-0016 §1.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EpisodeId(pub u64);

impl std::fmt::Display for EpisodeId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "episode:{}", self.0)
    }
}

/// Outcome of segmenting one batch of unsegmented events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SegmentStats {
    /// Events that were assigned an `episode_id` this batch.
    pub events_assigned: u64,
    /// New episode rows inserted this batch.
    pub episodes_created: u64,
}

/// Trait for episode segmentation strategies.
///
/// Given a batch of unsegmented events (ordered by `ts_us` ASC) and
/// access to the most-recent already-segmented event (for continuity),
/// assigns `episode_id` to each event.
pub trait EpisodeSegmenter: Send + Sync {
    /// Segment a batch of events. The `last_segmented` parameter is the
    /// most-recent event that already has an `episode_id` (used to decide
    /// whether the first unsegmented event continues the previous episode
    /// or starts a new one). Returns stats on how many events/episodes
    /// were touched.
    fn segment(
        &self,
        unsegmented: &[Event],
        last_segmented: Option<&Event>,
        writer: &dyn EpisodeWriter,
    ) -> Result<SegmentStats, StoreError>;
}

/// Write surface the segmenter uses. Implemented by `SqlCipherBrainStore`.
///
/// Separated from `BrainStore` to keep the segmenter's write footprint
/// minimal and auditable: it can create episodes and set `episode_id` on
/// events. Nothing else.
pub trait EpisodeWriter: Send + Sync {
    /// Insert a new episode row. Returns the assigned id.
    fn create_episode(
        &self,
        ts_start: u64,
        ts_end: u64,
        app_bundle_id: Option<&str>,
    ) -> Result<EpisodeId, StoreError>;

    /// Set `events.episode_id` for an existing event. Only writes the
    /// single column; never touches other event fields.
    fn set_event_episode(&self, event_id: EventId, episode_id: EpisodeId)
        -> Result<(), StoreError>;

    /// Update an existing episode's `ts_end` (extends the episode as
    /// new events are assigned to it).
    fn extend_episode(&self, episode_id: EpisodeId, ts_end: u64) -> Result<(), StoreError>;
}

/// Default heuristic: episode breaks on (a) `app_bundle_id` change AND/OR
/// (b) >`T_gap` from previous event.
///
/// Same app + ≤`T_gap` = same episode. Different app OR >`T_gap` = new
/// episode. ADR-0010 §2 spirit. `T_gap` defaults to 10 minutes.
pub struct HeuristicEpisodeSegmenter {
    gap_us: u64,
}

impl HeuristicEpisodeSegmenter {
    /// Default gap threshold: 10 minutes in microseconds.
    pub const DEFAULT_GAP_US: u64 = 10 * 60 * 1_000_000;

    /// Create with default 10-minute gap.
    #[must_use]
    pub fn new() -> Self {
        Self {
            gap_us: Self::DEFAULT_GAP_US,
        }
    }

    /// Create with custom gap threshold in microseconds.
    #[must_use]
    pub fn with_gap_us(gap_us: u64) -> Self {
        Self { gap_us }
    }

    fn should_break(&self, prev_app: Option<&str>, prev_ts: u64, cur: &Event) -> bool {
        let app_changed = prev_app != cur.app_bundle_id.as_deref();
        let gap_exceeded = cur.ts_us.saturating_sub(prev_ts) > self.gap_us;
        app_changed || gap_exceeded
    }
}

impl Default for HeuristicEpisodeSegmenter {
    fn default() -> Self {
        Self::new()
    }
}

impl EpisodeSegmenter for HeuristicEpisodeSegmenter {
    fn segment(
        &self,
        unsegmented: &[Event],
        last_segmented: Option<&Event>,
        writer: &dyn EpisodeWriter,
    ) -> Result<SegmentStats, StoreError> {
        if unsegmented.is_empty() {
            return Ok(SegmentStats {
                events_assigned: 0,
                episodes_created: 0,
            });
        }

        let mut stats = SegmentStats {
            events_assigned: 0,
            episodes_created: 0,
        };

        // Carry forward from last segmented event.
        let mut current_episode: Option<EpisodeId> =
            last_segmented.and_then(|e| e.episode_id).map(EpisodeId);
        let mut prev_app: Option<String> = last_segmented.and_then(|e| e.app_bundle_id.clone());
        let mut prev_ts: u64 = last_segmented.map_or(0, |e| e.ts_us);

        for event in unsegmented {
            let need_new =
                current_episode.is_none() || self.should_break(prev_app.as_deref(), prev_ts, event);

            if need_new {
                let ep_id = writer.create_episode(
                    event.ts_us,
                    event.ts_us,
                    event.app_bundle_id.as_deref(),
                )?;
                current_episode = Some(ep_id);
                stats.episodes_created += 1;
            } else if let Some(ep_id) = current_episode {
                writer.extend_episode(ep_id, event.ts_us)?;
            }

            let ep_id = current_episode.expect("episode must exist after create-or-extend");
            writer.set_event_episode(event.id, ep_id)?;
            stats.events_assigned += 1;

            prev_app.clone_from(&event.app_bundle_id);
            prev_ts = event.ts_us;
        }

        Ok(stats)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct MockWriter {
        next_ep_id: Mutex<u64>,
        episodes_created: Mutex<Vec<(u64, u64, Option<String>)>>,
        event_episodes: Mutex<Vec<(EventId, EpisodeId)>>,
        episode_extends: Mutex<Vec<(EpisodeId, u64)>>,
    }

    impl MockWriter {
        fn new() -> Self {
            Self {
                next_ep_id: Mutex::new(1),
                episodes_created: Mutex::new(Vec::new()),
                event_episodes: Mutex::new(Vec::new()),
                episode_extends: Mutex::new(Vec::new()),
            }
        }
    }

    impl EpisodeWriter for MockWriter {
        fn create_episode(
            &self,
            ts_start: u64,
            ts_end: u64,
            app_bundle_id: Option<&str>,
        ) -> Result<EpisodeId, StoreError> {
            let mut id_guard = self.next_ep_id.lock().unwrap();
            let id = *id_guard;
            *id_guard = id + 1;
            self.episodes_created.lock().unwrap().push((
                ts_start,
                ts_end,
                app_bundle_id.map(String::from),
            ));
            Ok(EpisodeId(id))
        }

        fn set_event_episode(
            &self,
            event_id: EventId,
            episode_id: EpisodeId,
        ) -> Result<(), StoreError> {
            self.event_episodes
                .lock()
                .unwrap()
                .push((event_id, episode_id));
            Ok(())
        }

        fn extend_episode(&self, episode_id: EpisodeId, ts_end: u64) -> Result<(), StoreError> {
            self.episode_extends
                .lock()
                .unwrap()
                .push((episode_id, ts_end));
            Ok(())
        }
    }

    fn make_event(id: u64, ts_us: u64, app: Option<&str>) -> Event {
        Event {
            id: EventId(id),
            ts_us,
            app_bundle_id: app.map(String::from),
            window_title: None,
            url: None,
            text: String::new(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: None,
        }
    }

    #[test]
    fn empty_batch_noop() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let stats = seg.segment(&[], None, &w).unwrap();
        assert_eq!(stats.events_assigned, 0);
        assert_eq!(stats.episodes_created, 0);
    }

    #[test]
    fn single_event_creates_one_episode() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let events = [make_event(1, 1_000_000, Some("com.apple.Safari"))];
        let stats = seg.segment(&events, None, &w).unwrap();
        assert_eq!(stats.events_assigned, 1);
        assert_eq!(stats.episodes_created, 1);
        assert_eq!(
            w.event_episodes.lock().unwrap()[0],
            (EventId(1), EpisodeId(1))
        );
    }

    #[test]
    fn same_app_within_gap_stays_same_episode() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let base = 1_000_000u64;
        let events = [
            make_event(1, base, Some("com.apple.Safari")),
            make_event(2, base + 5 * 60 * 1_000_000, Some("com.apple.Safari")),
            make_event(3, base + 9 * 60 * 1_000_000, Some("com.apple.Safari")),
        ];
        let stats = seg.segment(&events, None, &w).unwrap();
        assert_eq!(stats.episodes_created, 1);
        assert_eq!(stats.events_assigned, 3);
        // All three events point to same episode.
        let ee = w.event_episodes.lock().unwrap();
        assert_eq!(ee[0].1, EpisodeId(1));
        assert_eq!(ee[1].1, EpisodeId(1));
        assert_eq!(ee[2].1, EpisodeId(1));
    }

    #[test]
    fn app_change_breaks_episode() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let base = 1_000_000u64;
        let events = [
            make_event(1, base, Some("com.apple.Safari")),
            make_event(2, base + 1_000_000, Some("com.microsoft.VSCode")),
        ];
        let stats = seg.segment(&events, None, &w).unwrap();
        assert_eq!(stats.episodes_created, 2);
        let ee = w.event_episodes.lock().unwrap();
        assert_eq!(ee[0].1, EpisodeId(1));
        assert_eq!(ee[1].1, EpisodeId(2));
    }

    #[test]
    fn time_gap_breaks_episode() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let base = 1_000_000u64;
        // 11 minutes gap > 10 min threshold
        let events = [
            make_event(1, base, Some("com.apple.Safari")),
            make_event(2, base + 11 * 60 * 1_000_000, Some("com.apple.Safari")),
        ];
        let stats = seg.segment(&events, None, &w).unwrap();
        assert_eq!(stats.episodes_created, 2);
    }

    #[test]
    fn exactly_at_gap_stays_same_episode() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let base = 1_000_000u64;
        // Exactly 10 minutes = at threshold, NOT exceeded
        let events = [
            make_event(1, base, Some("com.apple.Safari")),
            make_event(2, base + 10 * 60 * 1_000_000, Some("com.apple.Safari")),
        ];
        let stats = seg.segment(&events, None, &w).unwrap();
        assert_eq!(stats.episodes_created, 1);
    }

    #[test]
    fn continues_from_last_segmented() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let base = 1_000_000u64;

        let last = Event {
            id: EventId(10),
            ts_us: base,
            app_bundle_id: Some("com.apple.Safari".to_owned()),
            window_title: None,
            url: None,
            text: String::new(),
            summary: None,
            entities: None,
            episode_id: Some(42),
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: None,
        };

        // Same app, within gap — should continue episode 42
        let events = [make_event(
            11,
            base + 2 * 60 * 1_000_000,
            Some("com.apple.Safari"),
        )];
        let stats = seg.segment(&events, Some(&last), &w).unwrap();
        assert_eq!(stats.episodes_created, 0);
        assert_eq!(stats.events_assigned, 1);
        let ee = w.event_episodes.lock().unwrap();
        assert_eq!(ee[0], (EventId(11), EpisodeId(42)));
    }

    #[test]
    fn none_app_events_segment_correctly() {
        let seg = HeuristicEpisodeSegmenter::new();
        let w = MockWriter::new();
        let base = 1_000_000u64;
        let events = [
            make_event(1, base, None),
            make_event(2, base + 1_000_000, None),
            make_event(3, base + 2_000_000, Some("com.apple.Safari")),
        ];
        let stats = seg.segment(&events, None, &w).unwrap();
        // None→None = same app (both None), so 1 episode for first two.
        // None→Safari = app change, new episode.
        assert_eq!(stats.episodes_created, 2);
    }

    #[test]
    fn custom_gap_threshold() {
        let seg = HeuristicEpisodeSegmenter::with_gap_us(5 * 60 * 1_000_000); // 5 min
        let w = MockWriter::new();
        let base = 1_000_000u64;
        let events = [
            make_event(1, base, Some("com.apple.Safari")),
            make_event(2, base + 6 * 60 * 1_000_000, Some("com.apple.Safari")),
        ];
        let stats = seg.segment(&events, None, &w).unwrap();
        assert_eq!(stats.episodes_created, 2); // 6 min > 5 min threshold
    }

    #[test]
    fn episode_id_display() {
        assert_eq!(EpisodeId(7).to_string(), "episode:7");
    }
}
