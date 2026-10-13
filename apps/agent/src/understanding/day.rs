//! The measured shape of a day: when you were at the computer, on what, in
//! what kind of work, where focus held and where it broke.
//!
//! Time comes from measured activity (5-second samples of input, attributed
//! to the focused app). When no samples exist for the day (older history, or
//! measurement off), time is estimated from capture events instead and the
//! breakdown says so.

use serde::{Deserialize, Serialize};

use mci_brain::understanding::{InteractionCounts, ObservedEvent, SearchRecord, SessionNote};
use mci_brain::{ActivityInterval, ActivityState};

use super::apps::{self, WorkKind};

const SLOT_US: u64 = 5 * 60 * 1_000_000;
/// A focus block is at least this many consecutive slots of one kind.
const FOCUS_MIN_SLOTS: usize = 5;
/// Estimated time per capture event, when there are no measured samples.
const ESTIMATE_CAP_US: u64 = 2 * 60 * 1_000_000;

/// Time in one app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppTime {
    /// Bundle id.
    pub bundle_id: String,
    /// Readable name.
    pub name: String,
    /// Active time, microseconds.
    pub active_us: u64,
}

/// Time in one kind of work.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KindTime {
    /// The kind.
    pub kind: WorkKind,
    /// Label for people.
    pub label: String,
    /// Active time, microseconds.
    pub active_us: u64,
}

/// One hour of the day.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct HourTime {
    /// Local hour, 0–23.
    pub hour: u8,
    /// Active time, microseconds.
    pub active_us: u64,
    /// The kind of work that took most of it.
    pub top_kind: Option<WorkKind>,
    /// App switches in the hour.
    pub switches: u32,
}

/// A stretch of sustained work of one kind.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusBlock {
    /// Start.
    pub start_us: u64,
    /// End.
    pub end_us: u64,
    /// The kind of work.
    pub kind: WorkKind,
    /// The app that took most of it.
    pub app: String,
}

/// A session, as listed in the day.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionLine {
    /// Start.
    pub start_us: u64,
    /// End.
    pub end_us: u64,
    /// Title.
    pub title: String,
    /// What a model wrote lay beneath; empty for a measured note.
    pub beneath: String,
}

/// The measured breakdown of one local day.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DayBreakdown {
    /// `YYYY-MM-DD`.
    pub date_local: String,
    /// Day start (local midnight).
    pub start_us: u64,
    /// Day end.
    pub end_us: u64,
    /// `measured` (activity samples) or `estimated` (capture events).
    pub basis: String,
    /// Time with input, microseconds.
    pub active_us: u64,
    /// First and last moment of activity.
    pub first_active_us: Option<u64>,
    /// Last moment of activity.
    pub last_active_us: Option<u64>,
    /// Per hour that had any activity.
    pub hours: Vec<HourTime>,
    /// Apps by time, most first (top 12).
    pub apps: Vec<AppTime>,
    /// Kinds of work by time, most first.
    pub kinds: Vec<KindTime>,
    /// Sustained stretches of one kind of work (25 min or more).
    pub focus_blocks: Vec<FocusBlock>,
    /// App switches across the day.
    pub switches: u32,
    /// Switches per active hour.
    pub switches_per_hour: f64,
    /// Input totals.
    pub keys: u64,
    /// Input totals.
    pub clicks: u64,
    /// Input totals.
    pub scrolls: u64,
    /// Searches, newest first.
    pub searches: Vec<SearchRecord>,
    /// Sessions with notes.
    pub sessions: Vec<SessionLine>,
}

impl DayBreakdown {
    /// The longest focus block.
    #[must_use]
    pub fn longest_focus_us(&self) -> u64 {
        self.focus_blocks.iter().map(|b| b.end_us - b.start_us).max().unwrap_or(0)
    }

    /// Plain-language facts for the model and for AI tools: time, kinds,
    /// apps, focus blocks and searches. Never how often the person switched
    /// apps or where the day "broke".
    #[must_use]
    pub fn facts(&self, tz_offset_secs: i32) -> String {
        use super::observe::clock;
        let h = |us: u64| {
            let minutes = us / 60_000_000;
            if minutes >= 60 {
                format!("{} h {} min", minutes / 60, minutes % 60)
            } else {
                format!("{minutes} min")
            }
        };
        let mut lines = Vec::new();
        let basis = if self.basis == "measured" { "" } else { " (estimated from captures)" };
        lines.push(format!("Active at the computer: {}{basis}.", h(self.active_us)));
        if let (Some(first), Some(last)) = (self.first_active_us, self.last_active_us) {
            lines.push(format!("First activity {}, last {}.", clock(first, tz_offset_secs), clock(last, tz_offset_secs)));
        }
        if !self.kinds.is_empty() {
            lines.push(format!(
                "By kind of work: {}.",
                self.kinds.iter().take(6).map(|k| format!("{} {}", k.label, h(k.active_us))).collect::<Vec<_>>().join(", ")
            ));
        }
        if !self.apps.is_empty() {
            lines.push(format!(
                "By app: {}.",
                self.apps.iter().take(8).map(|a| format!("{} {}", a.name, h(a.active_us))).collect::<Vec<_>>().join(", ")
            ));
        }
        if !self.focus_blocks.is_empty() {
            lines.push(format!(
                "Focus blocks: {}.",
                self.focus_blocks
                    .iter()
                    .map(|b| format!(
                        "{}–{} {} in {}",
                        clock(b.start_us, tz_offset_secs),
                        clock(b.end_us, tz_offset_secs),
                        WorkKind::label(b.kind).to_lowercase(),
                        b.app
                    ))
                    .collect::<Vec<_>>()
                    .join("; ")
            ));
        }
        if !self.searches.is_empty() {
            lines.push(format!(
                "Searches ({}): {}.",
                self.searches.len(),
                self.searches.iter().take(12).map(|s| format!("\"{}\"", s.query)).collect::<Vec<_>>().join(", ")
            ));
        }
        lines.join("\n")
    }
}

/// Compute a day's breakdown from what the brain holds for it.
#[must_use]
#[allow(clippy::too_many_arguments)]
pub fn breakdown(
    date_local: &str,
    start_us: u64,
    end_us: u64,
    tz_offset_secs: i32,
    activity: &[ActivityInterval],
    counts: &[InteractionCounts],
    events: &[ObservedEvent],
    searches: Vec<SearchRecord>,
    notes: &[SessionNote],
) -> DayBreakdown {
    // (start, end, app, url) spans of attributed active time.
    let mut spans: Vec<(u64, u64, String)> = activity
        .iter()
        .filter(|interval| interval.state == ActivityState::InputActive)
        .filter_map(|interval| Some((interval.start_us, interval.end_us, interval.app_bundle_id.clone()?)))
        .collect();
    let basis = if spans.is_empty() { "estimated" } else { "measured" };
    let focus_events: Vec<&ObservedEvent> = events
        .iter()
        .filter(|e| !matches!(e.source.as_str(), "screen_context" | "transcript_import" | "mcp_resource"))
        .collect();
    if spans.is_empty() {
        for pair in focus_events.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            if let Some(app) = &a.app_bundle_id {
                let length = b.ts_us.saturating_sub(a.ts_us).min(ESTIMATE_CAP_US);
                if length > 0 {
                    spans.push((a.ts_us, a.ts_us + length, app.clone()));
                }
            }
        }
    }
    spans.sort_by_key(|s| s.0);

    // A browser's time takes the kind of the page it last showed.
    let kind_of = |start: u64, app: &str| -> WorkKind {
        if apps::kind(app) != WorkKind::Research {
            return apps::kind(app);
        }
        let url = focus_events
            .iter()
            .rev()
            .find(|e| e.ts_us <= start + 5_000_000 && e.app_bundle_id.as_deref() == Some(app) && start.saturating_sub(e.ts_us) < 15 * 60 * 1_000_000)
            .and_then(|e| e.url.as_deref());
        apps::kind_for(app, url)
    };

    let local_hour = |ts: u64| -> u8 {
        let secs = i64::try_from(ts / 1_000_000).unwrap_or(0) + i64::from(tz_offset_secs);
        u8::try_from(secs.rem_euclid(86_400) / 3600).unwrap_or(0)
    };

    let mut by_app: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
    let mut by_kind: std::collections::BTreeMap<WorkKind, u64> = std::collections::BTreeMap::new();
    let mut hours: Vec<HourTime> = (0..24).map(|hour| HourTime { hour, ..HourTime::default() }).collect();
    let mut hour_kinds: Vec<std::collections::BTreeMap<WorkKind, u64>> = vec![Default::default(); 24];
    let slots = usize::try_from((end_us.saturating_sub(start_us)) / SLOT_US + 1).unwrap_or(0);
    let mut slot_kinds: Vec<std::collections::BTreeMap<(WorkKind, String), u64>> = vec![Default::default(); slots];
    let mut active_us = 0u64;
    let mut switches = 0u32;
    let mut previous_app: Option<&str> = None;
    for (start, end, app) in &spans {
        let (start, end) = ((*start).max(start_us), (*end).min(end_us));
        if end <= start {
            continue;
        }
        let length = end - start;
        let kind = kind_of(start, app);
        active_us += length;
        *by_app.entry(app.clone()).or_default() += length;
        *by_kind.entry(kind).or_default() += length;
        let hour = usize::from(local_hour(start));
        hours[hour].active_us += length;
        *hour_kinds[hour].entry(kind).or_default() += length;
        if previous_app.is_some_and(|prev| prev != app) {
            switches += 1;
            hours[hour].switches += 1;
        }
        previous_app = Some(app);
        let slot = usize::try_from((start - start_us) / SLOT_US).unwrap_or(0);
        if let Some(entry) = slot_kinds.get_mut(slot) {
            *entry.entry((kind, app.clone())).or_default() += length;
        }
    }
    for (hour, kinds) in hours.iter_mut().zip(&hour_kinds) {
        hour.top_kind = kinds.iter().max_by_key(|(_, us)| **us).map(|(kind, _)| *kind);
    }

    // Focus blocks: runs of 5-minute slots, each at least half active, whose
    // dominant kind is the same.
    let mut focus_blocks = Vec::new();
    let mut run: Option<(usize, WorkKind, std::collections::BTreeMap<String, u64>)> = None;
    let close = |run: &mut Option<(usize, WorkKind, std::collections::BTreeMap<String, u64>)>, end_slot: usize, out: &mut Vec<FocusBlock>| {
        if let Some((first, kind, apps_in)) = run.take() {
            if end_slot - first >= FOCUS_MIN_SLOTS {
                let app = apps_in.iter().max_by_key(|(_, us)| **us).map(|(a, _)| apps::name(a)).unwrap_or_default();
                out.push(FocusBlock {
                    start_us: start_us + first as u64 * SLOT_US,
                    end_us: start_us + end_slot as u64 * SLOT_US,
                    kind,
                    app,
                });
            }
        }
    };
    for (index, slot) in slot_kinds.iter().enumerate() {
        let total: u64 = slot.values().sum();
        let mut per_kind: std::collections::BTreeMap<WorkKind, u64> = std::collections::BTreeMap::new();
        for ((kind, _), us) in slot {
            *per_kind.entry(*kind).or_default() += us;
        }
        let dominant = per_kind.iter().max_by_key(|(_, us)| **us).map(|(kind, _)| *kind);
        let qualifies = total * 2 >= SLOT_US && dominant.is_some();
        match (&mut run, qualifies, dominant) {
            (Some((_, kind, apps_in)), true, Some(d)) if *kind == d => {
                for ((k, app), us) in slot {
                    if *k == d {
                        *apps_in.entry(app.clone()).or_default() += us;
                    }
                }
            }
            (_, true, Some(d)) => {
                close(&mut run, index, &mut focus_blocks);
                let mut apps_in = std::collections::BTreeMap::new();
                for ((k, app), us) in slot {
                    if *k == d {
                        *apps_in.entry(app.clone()).or_default() += us;
                    }
                }
                run = Some((index, d, apps_in));
            }
            _ => close(&mut run, index, &mut focus_blocks),
        }
    }
    close(&mut run, slot_kinds.len(), &mut focus_blocks);

    let mut apps_out: Vec<AppTime> = by_app
        .into_iter()
        .map(|(bundle_id, active_us)| AppTime { name: apps::name(&bundle_id), bundle_id, active_us })
        .collect();
    apps_out.sort_by(|a, b| b.active_us.cmp(&a.active_us));
    apps_out.truncate(12);
    let mut kinds: Vec<KindTime> = by_kind
        .into_iter()
        .map(|(kind, active_us)| KindTime { kind, label: kind.label().to_owned(), active_us })
        .collect();
    kinds.sort_by(|a, b| b.active_us.cmp(&a.active_us));
    let active_hours = (active_us as f64 / 3_600_000_000.0).max(0.25);
    let in_day = |c: &&InteractionCounts| c.start_us >= start_us && c.start_us < end_us;
    DayBreakdown {
        date_local: date_local.to_owned(),
        start_us,
        end_us,
        basis: basis.into(),
        active_us,
        first_active_us: spans.iter().map(|s| s.0).find(|ts| *ts >= start_us && *ts < end_us),
        last_active_us: spans.iter().rev().map(|s| s.1).find(|ts| *ts > start_us && *ts <= end_us),
        hours: hours.into_iter().filter(|h| h.active_us > 0).collect(),
        apps: apps_out,
        kinds,
        focus_blocks,
        switches,
        switches_per_hour: f64::from(switches) / active_hours,
        keys: counts.iter().filter(in_day).map(|c| u64::from(c.keys)).sum(),
        clicks: counts.iter().filter(in_day).map(|c| u64::from(c.clicks)).sum(),
        scrolls: counts.iter().filter(in_day).map(|c| u64::from(c.scrolls)).sum(),
        searches,
        sessions: notes
            .iter()
            // A note written from measurements has only input telemetry
            // beneath it, which is never shown or sent.
            .map(|n| SessionLine {
                start_us: n.start_us,
                end_us: n.end_us,
                title: n.title.clone(),
                beneath: if n.model == "measured" { String::new() } else { n.beneath.clone() },
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: u64 = 60_000_000;
    const DAY0: u64 = 1_800_000_000_000_000;

    fn active(from_min: u64, to_min: u64, app: &str) -> Vec<ActivityInterval> {
        (from_min * 12..to_min * 12)
            .map(|i| ActivityInterval {
                start_us: DAY0 + i * 5_000_000,
                end_us: DAY0 + (i + 1) * 5_000_000,
                state: ActivityState::InputActive,
                app_bundle_id: Some(app.into()),
                capture_generation: "g".into(),
            })
            .collect()
    }

    #[test]
    fn measured_time_kinds_focus_and_switches() {
        let mut activity = active(0, 40, "com.microsoft.VSCode");
        activity.extend(active(40, 45, "com.tinyspeck.slackmacgap"));
        activity.extend(active(45, 50, "com.microsoft.VSCode"));
        let day = breakdown("2027-01-15", DAY0, DAY0 + 24 * 60 * MIN, 0, &activity, &[], &[], Vec::new(), &[]);
        assert_eq!(day.basis, "measured");
        assert_eq!(day.active_us, 50 * MIN);
        assert_eq!(day.apps[0].name, "VS Code");
        assert_eq!(day.apps[0].active_us, 45 * MIN);
        assert_eq!(day.kinds[0].kind, WorkKind::Code);
        assert_eq!(day.switches, 2);
        assert_eq!(day.focus_blocks.len(), 1, "40 minutes of code is one block; Slack breaks it");
        assert_eq!(day.focus_blocks[0].end_us - day.focus_blocks[0].start_us, 40 * MIN);
        assert!(day.facts(0).contains("Code 45 min"), "{}", day.facts(0));
    }

    #[test]
    fn browser_time_takes_the_kind_of_the_page() {
        let activity = active(0, 10, "com.google.Chrome");
        let events = vec![ObservedEvent {
            id: 1,
            ts_us: DAY0,
            app_bundle_id: Some("com.google.Chrome".into()),
            window_title: Some("Inbox".into()),
            url: Some("https://mail.google.com/mail/u/0/#inbox".into()),
            text: "Inbox".into(),
            source: "browser_page".into(),
        }];
        let day = breakdown("2027-01-15", DAY0, DAY0 + 24 * 60 * MIN, 0, &activity, &[], &events, Vec::new(), &[]);
        assert_eq!(day.kinds[0].kind, WorkKind::Communication);
    }

    #[test]
    fn without_samples_time_is_estimated_from_captures() {
        let events: Vec<ObservedEvent> = (0..4)
            .map(|i| ObservedEvent {
                id: i,
                ts_us: DAY0 + i as u64 * MIN,
                app_bundle_id: Some("com.apple.Notes".into()),
                window_title: None,
                url: None,
                text: "t".into(),
                source: "screen_ocr".into(),
            })
            .collect();
        let day = breakdown("2027-01-15", DAY0, DAY0 + 24 * 60 * MIN, 0, &[], &[], &events, Vec::new(), &[]);
        assert_eq!(day.basis, "estimated");
        assert_eq!(day.active_us, 3 * MIN);
        assert!(day.facts(0).contains("estimated"));
    }
}
