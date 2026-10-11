//! Understanding: what lay beneath what was on screen.
//!
//! Each cycle, the agent:
//! 1. reads searches out of newly captured URLs;
//! 2. splits recent activity into work sessions and writes a note for each
//!    finished one: what was on the surface, and what lay beneath it, from
//!    measured signals (typing, reading, pauses, switching, reworded
//!    searches, errors on screen);
//! 3. folds what each session says about the user into a general user model
//!    ([`gum`]);
//! 4. keeps a written account of today (and of yesterday, once) current.
//!
//! The model is Apple's on-device Foundation Models, through
//! `hippocampus-mind`. When it is unavailable, notes and day accounts are
//! written from the measurements alone, and the user model waits.

pub mod apps;
pub mod day;
pub mod gum;
pub mod mind;
pub mod observe;
pub mod query;

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use mci_brain::understanding::{DayReport, ObservedEvent, PropositionStatus, SessionNote};
use mci_brain::{SqlCipherBrainStore, StoreError};

use crate::brief_worker::{local_date_start_secs, local_date_string};
use mind::{MindCallError, MindClient};
use observe::SessionSpan;

const SESSIONS_CURSOR: &str = "sessions_through_us";
const PIPELINE_KEY: &str = "pipeline_version";
/// Bump when prompts or rules change enough that earlier inferences should
/// be redone; the next cycle clears them and starts again.
const PIPELINE_VERSION: &str = "3";
const SEARCH_CURSOR: &str = "searches_through_event_id";
/// How far back the first cycle looks.
const FIRST_LOOKBACK_US: u64 = 24 * 3_600_000_000;
/// A session shorter than this gets a note from measurements only.
const MIN_MODEL_SESSION_US: u64 = 2 * 60 * 1_000_000;
/// Today's account is refreshed at most this often.
const DAY_REFRESH_US: u64 = 60 * 60 * 1_000_000;
const OBSERVATION_CHARS: usize = 5_200;
const MODEL_LABEL: &str = gum::MODEL;
const MEASURED_LABEL: &str = "measured";

/// What one cycle did.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize)]
pub struct CycleStats {
    /// Searches found.
    pub searches: usize,
    /// Session notes written.
    pub sessions: u32,
    /// …of which by the model.
    pub sessions_by_model: u32,
    /// User-model changes.
    pub propositions_added: u32,
    /// User-model revisions.
    pub propositions_revised: u32,
    /// Day accounts written.
    pub days: u32,
    /// Why the model was not used, if it was not.
    pub model_unavailable: Option<String>,
}

/// The written account of a day.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Narrative {
    /// One line.
    pub headline: String,
    /// A paragraph.
    pub narrative: String,
    /// Specific observations.
    pub insights: Vec<String>,
    /// One suggestion.
    pub suggestion: String,
}

/// A day: the measured breakdown and its written account.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Day {
    /// The measurements.
    pub breakdown: day::DayBreakdown,
    /// The account, if written.
    pub narrative: Option<Narrative>,
    /// Who wrote it: the on-device model or the measurements alone.
    pub written_by: Option<String>,
    /// When it was written.
    pub generated_us: Option<u64>,
}

#[derive(Deserialize)]
struct EpisodeOut {
    title: String,
    surface: String,
    beneath: String,
}

/// The understanding layer over one brain.
pub struct Understanding {
    store: Arc<SqlCipherBrainStore>,
    mind: Arc<MindClient>,
    tz_offset_secs: i32,
    user_name: String,
}

impl Understanding {
    /// Build over a store and a mind client.
    #[must_use]
    pub fn new(store: Arc<SqlCipherBrainStore>, mind: Arc<MindClient>, tz_offset_secs: i32, user_name: String) -> Self {
        Self { store, mind, tz_offset_secs, user_name }
    }

    /// The user's first name from the account's full name, or empty.
    #[must_use]
    pub fn account_first_name() -> String {
        std::process::Command::new("/usr/bin/id")
            .arg("-F")
            .env_clear()
            .output()
            .ok()
            .filter(|out| out.status.success())
            .and_then(|out| String::from_utf8(out.stdout).ok())
            .and_then(|name| name.split_whitespace().next().map(str::to_owned))
            .unwrap_or_default()
    }

    /// Run one cycle. `max_sessions` bounds the model work per cycle.
    ///
    /// # Errors
    /// Store failures.
    pub fn run_cycle(&self, now_us: u64, max_sessions: usize) -> Result<CycleStats, StoreError> {
        let mut stats = CycleStats::default();
        if self.store.understanding_state(PIPELINE_KEY)?.as_deref() != Some(PIPELINE_VERSION) {
            self.store.reset_understanding()?;
            self.store.set_understanding_state(PIPELINE_KEY, PIPELINE_VERSION)?;
        }
        let after: i64 = self.store.understanding_state(SEARCH_CURSOR)?.and_then(|v| v.parse().ok()).unwrap_or(0);
        let (added, last) = self.store.backfill_search_queries(after.max(0), 5_000)?;
        stats.searches = added;
        if last != after {
            self.store.set_understanding_state(SEARCH_CURSOR, &last.to_string())?;
        }
        self.run_sessions_and_days(now_us, max_sessions, stats)
    }

    fn run_sessions_and_days(&self, now_us: u64, max_sessions: usize, mut stats: CycleStats) -> Result<CycleStats, StoreError> {
        let from: u64 = self
            .store
            .understanding_state(SESSIONS_CURSOR)?
            .and_then(|v| v.parse().ok())
            .unwrap_or_else(|| now_us.saturating_sub(FIRST_LOOKBACK_US));
        let mut events = self.store.observed_events_in_range(from, now_us, 20_000)?;
        events.retain(|e| !e.app_bundle_id.as_deref().is_some_and(apps::is_noise));
        let spans = observe::split_sessions(&events);
        let mut processed = 0;
        for (index, span) in spans.iter().enumerate() {
            let last = index + 1 == spans.len();
            if last && span.end_us + observe::SESSION_GAP_US > now_us {
                break; // still going
            }
            if processed >= max_sessions {
                break;
            }
            self.note_session(&events, *span, now_us, &mut stats)?;
            processed += 1;
            let through = events[span.end - 1].ts_us.max(span.end_us) + 1;
            self.store.set_understanding_state(SESSIONS_CURSOR, &through.to_string())?;
        }
        if processed > 0 || stats.searches > 0 {
            let today = local_date_string(i64::try_from(now_us / 1_000_000).unwrap_or(0), self.tz_offset_secs);
            let stale = self
                .store
                .day_report(&today)?
                .map_or(true, |r| now_us.saturating_sub(r.generated_us) >= DAY_REFRESH_US);
            if stale && self.write_day(&today, now_us).is_ok() {
                stats.days += 1;
            }
        }
        let yesterday = local_date_string(
            i64::try_from(now_us / 1_000_000).unwrap_or(0) - 86_400,
            self.tz_offset_secs,
        );
        if self.store.day_report(&yesterday)?.is_none() {
            let day = self.day(&yesterday, now_us)?;
            if day.breakdown.active_us > 0 && self.write_day(&yesterday, now_us).is_ok() {
                stats.days += 1;
            }
        }
        Ok(stats)
    }

    fn note_session(
        &self,
        events: &[ObservedEvent],
        span: SessionSpan,
        now_us: u64,
        stats: &mut CycleStats,
    ) -> Result<(), StoreError> {
        let slice = &events[span.start..span.end];
        let counts = self.store.interaction_counts_in_range(span.start_us, span.end_us + 1)?;
        let segments = observe::segments(slice, &counts, span.end_us);
        if segments.is_empty() {
            return Ok(());
        }
        let mut searches = self.store.search_queries_in_range(span.start_us, span.end_us + 1, 50)?;
        searches.reverse();
        let signals = observe::signals(slice, &segments, &searches);
        let observation = format!(
            "{}\n{}",
            weekday_and_date(span.start_us, self.tz_offset_secs),
            observe::render(&segments, &signals, self.tz_offset_secs, OBSERVATION_CHARS)
        );
        let duration = span.end_us.saturating_sub(span.start_us);
        let signals_json = serde_json::json!({
            "signals": &signals,
            "segments": segments.iter().map(|s| serde_json::json!({
                "start_us": s.start_us, "end_us": s.end_us, "app": s.app, "name": apps::name(&s.app),
                "title": s.title, "host": s.url.as_deref().and_then(apps::host_of),
                "activity": s.activity(), "keys": s.keys, "events": s.event_ids,
            })).collect::<Vec<_>>(),
        })
        .to_string();

        let mut note = measured_note(&segments, &signals, span, slice.len(), now_us, &signals_json);
        if duration >= MIN_MODEL_SESSION_US {
            match self.mind.call::<_, EpisodeOut>(
                "episode",
                &serde_json::json!({ "user_name": self.user_name, "observation": observation }),
                Duration::from_secs(60),
            ) {
                Ok(out) => {
                    note.title = gum::ungender(&out.title, &self.user_name);
                    note.surface = gum::ungender(&out.surface, &self.user_name);
                    note.beneath = gum::ungender(&out.beneath, &self.user_name);
                    note.model = MODEL_LABEL.into();
                    stats.sessions_by_model += 1;
                }
                Err(MindCallError::Unavailable(reason)) => stats.model_unavailable = Some(reason),
                Err(_) => {}
            }
            if stats.model_unavailable.is_none() {
                let known: Vec<String> = self
                    .store
                    .propositions_with_status(PropositionStatus::Active, 8)?
                    .into_iter()
                    .map(|p| p.text)
                    .collect();
                match gum::propose(&self.mind, &self.user_name, &observation, &known) {
                    Ok(drafts) => {
                        let drafts = gum::specific(drafts, &observation, &self.user_name);
                        let evidence = observe::evidence(&segments, 8);
                        match gum::integrate(&self.store, &self.mind, &self.user_name, &drafts, &evidence, now_us) {
                            Ok(done) => {
                                stats.propositions_added += done.added;
                                stats.propositions_revised += done.revised;
                            }
                            Err(gum::GumError::Store(error)) => return Err(error),
                            Err(gum::GumError::Mind(MindCallError::Unavailable(reason))) => {
                                stats.model_unavailable = Some(reason);
                            }
                            Err(gum::GumError::Mind(_)) => {}
                        }
                    }
                    Err(MindCallError::Unavailable(reason)) => stats.model_unavailable = Some(reason),
                    Err(_) => {}
                }
            }
        }
        self.store.put_session_note(&note)?;
        stats.sessions += 1;
        Ok(())
    }

    /// Compute a day (breakdown, plus any stored account).
    ///
    /// # Errors
    /// Store failures, or a malformed date.
    pub fn day(&self, date_local: &str, _now_us: u64) -> Result<Day, StoreError> {
        let start_secs = local_date_start_secs(date_local, self.tz_offset_secs)
            .ok_or_else(|| StoreError::InvalidInput("date must be YYYY-MM-DD".into()))?;
        let start_us = u64::try_from(start_secs).unwrap_or(0).saturating_mul(1_000_000);
        let end_us = start_us + 86_400_000_000;
        let mut activity = self.store.activity_intervals_in_range(start_us, end_us)?;
        activity.retain(|a| !a.app_bundle_id.as_deref().is_some_and(apps::is_noise));
        let counts = self.store.interaction_counts_in_range(start_us, end_us)?;
        let mut events = self.store.observed_events_in_range(start_us, end_us, 50_000)?;
        events.retain(|e| !e.app_bundle_id.as_deref().is_some_and(apps::is_noise));
        let searches = self.store.search_queries_in_range(start_us, end_us, 200)?;
        let notes = self.store.session_notes_in_range(start_us, end_us)?;
        let breakdown = day::breakdown(
            date_local, start_us, end_us, self.tz_offset_secs, &activity, &counts, &events, searches, &notes,
        );
        let stored = self.store.day_report(date_local)?;
        let (narrative, written_by, generated_us) = match stored {
            Some(report) => {
                let body: serde_json::Value = serde_json::from_str(&report.body).unwrap_or_default();
                (
                    serde_json::from_value::<Narrative>(body["narrative"].clone()).ok(),
                    Some(report.model),
                    Some(report.generated_us),
                )
            }
            None => (None, None, None),
        };
        Ok(Day { breakdown, narrative, written_by, generated_us })
    }

    /// Write (or rewrite) a day's account.
    ///
    /// # Errors
    /// Store failures.
    pub fn write_day(&self, date_local: &str, now_us: u64) -> Result<Day, StoreError> {
        let mut day = self.day(date_local, now_us)?;
        let facts = day.breakdown.facts(self.tz_offset_secs);
        let episodes: Vec<String> = day
            .breakdown
            .sessions
            .iter()
            .map(|s| {
                format!(
                    "{}–{} {}: {}",
                    observe::clock(s.start_us, self.tz_offset_secs),
                    observe::clock(s.end_us, self.tz_offset_secs),
                    s.title,
                    s.beneath
                )
            })
            .collect();
        let propositions: Vec<String> = self
            .store
            .propositions_with_status(PropositionStatus::Active, 8)?
            .into_iter()
            .map(|p| p.text)
            .collect();
        let (narrative, model) = match self.mind.call::<_, Narrative>(
            "day",
            &serde_json::json!({
                "user_name": self.user_name, "facts": facts, "episodes": episodes, "propositions": propositions,
            }),
            Duration::from_secs(90),
        ) {
            Ok(narrative) => (narrative, MODEL_LABEL),
            Err(_) => (measured_narrative(&day.breakdown, self.tz_offset_secs), MEASURED_LABEL),
        };
        self.store.put_day_report(&DayReport {
            date_local: date_local.to_owned(),
            start_us: day.breakdown.start_us,
            end_us: day.breakdown.end_us,
            generated_us: now_us,
            model: model.into(),
            body: serde_json::json!({ "narrative": narrative }).to_string(),
        })?;
        day.narrative = Some(narrative);
        day.written_by = Some(model.into());
        day.generated_us = Some(now_us);
        Ok(day)
    }
}

fn measured_note(
    segments: &[observe::Segment],
    signals: &observe::Signals,
    span: SessionSpan,
    event_count: usize,
    now_us: u64,
    signals_json: &str,
) -> SessionNote {
    let longest = segments.iter().max_by_key(|s| s.duration_us()).expect("segments is not empty");
    let title = match &longest.title {
        Some(title) if !title.trim().is_empty() => format!("{} — {}", apps::name(&longest.app), title.trim()),
        _ => apps::name(&longest.app),
    };
    let mut by_window: Vec<&observe::Segment> = segments.iter().collect();
    by_window.sort_by(|a, b| b.duration_us().cmp(&a.duration_us()));
    let surface = by_window
        .iter()
        .take(3)
        .map(|s| {
            format!(
                "{} in {}{}",
                s.activity(),
                apps::name(&s.app),
                s.title.as_deref().map(|t| format!(" ({})", t.trim())).unwrap_or_default()
            )
        })
        .collect::<Vec<_>>()
        .join("; ");
    let mut beneath = Vec::new();
    if let Some((_, pause, window)) = signals.pauses.iter().max_by_key(|p| p.1) {
        beneath.push(format!("paused {} min with no input in {window}", (pause + 30_000_000) / 60_000_000));
    }
    for (a, b, n) in &signals.back_and_forth {
        beneath.push(format!("switched between {a} and {b} {n} times"));
    }
    if signals.reworded_searches > 0 {
        beneath.push(format!("reworded a search {} time(s)", signals.reworded_searches));
    }
    if let Some(error) = signals.errors.first() {
        beneath.push(format!("had an error on screen (\"{error}\")"));
    }
    SessionNote {
        start_us: span.start_us,
        end_us: span.end_us,
        title,
        surface: capitalize(&surface),
        beneath: if beneath.is_empty() {
            "Nothing notable.".into()
        } else {
            capitalize(&format!("{}.", beneath.join("; ")))
        },
        signals: signals_json.to_owned(),
        event_count: u32::try_from(event_count).unwrap_or(u32::MAX),
        generated_us: now_us,
        model: MEASURED_LABEL.into(),
    }
}

/// "Saturday, 2026-10-11", so the model knows a weekend from a workday.
fn weekday_and_date(ts_us: u64, tz_offset_secs: i32) -> String {
    const DAYS: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    let local = i64::try_from(ts_us / 1_000_000).unwrap_or(0) + i64::from(tz_offset_secs);
    // 1970-01-01 was a Thursday.
    let weekday = DAYS[usize::try_from((local.div_euclid(86_400) + 4).rem_euclid(7)).unwrap_or(0)];
    format!("{weekday}, {}", local_date_string(local - i64::from(tz_offset_secs), tz_offset_secs))
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
}

fn measured_narrative(day: &day::DayBreakdown, tz_offset_secs: i32) -> Narrative {
    let hours = day.active_us as f64 / 3_600_000_000.0;
    let top = day.kinds.first().map(|k| k.label.to_lowercase()).unwrap_or_else(|| "nothing measured".into());
    let mut insights = Vec::new();
    if let Some(block) = day.focus_blocks.iter().max_by_key(|b| b.end_us - b.start_us) {
        insights.push(format!(
            "Longest focus: {}–{}, {} in {}.",
            observe::clock(block.start_us, tz_offset_secs),
            observe::clock(block.end_us, tz_offset_secs),
            block.kind.label().to_lowercase(),
            block.app
        ));
    }
    if let Some(peak) = day.hours.iter().max_by_key(|h| h.switches) {
        if peak.switches > 0 {
            insights.push(format!("Most switching around {:02}:00 ({} app switches).", peak.hour, peak.switches));
        }
    }
    if !day.searches.is_empty() {
        insights.push(format!(
            "You searched for {}.",
            day.searches.iter().take(4).map(|s| format!("\"{}\"", s.query)).collect::<Vec<_>>().join(", ")
        ));
    }
    Narrative {
        headline: format!("{hours:.1} hours at the computer, mostly {top}."),
        narrative: day.facts(tz_offset_secs),
        insights,
        suggestion: String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::{BrainStore, Event, EventId, EventSource};
    use mci_core::crypto::DbKey;

    fn event(ts_us: u64, app: &str, title: &str, url: Option<&str>, text: &str) -> Event {
        Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(app.into()),
            window_title: Some(title.into()),
            url: url.map(str::to_owned),
            text: text.into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        }
    }

    #[test]
    fn observations_name_the_weekday() {
        // 2026-10-11 00:30 UTC is Saturday evening in Los Angeles (UTC-7).
        let ts = 1_791_678_600_000_000;
        assert_eq!(weekday_and_date(ts, -7 * 3600), "Saturday, 2026-10-10");
        assert_eq!(weekday_and_date(ts, 0), "Sunday, 2026-10-11");
    }

    #[test]
    fn a_cycle_without_the_model_notes_finished_sessions_and_writes_the_day() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(SqlCipherBrainStore::new(&dir.path().join("b.sqlite"), &DbKey::from_bytes([3; 32])).unwrap());
        let now = 1_800_000_000_000_000u64;
        let min = 60_000_000u64;
        let start = now - 60 * min;
        store
            .put_event_with_source(
                &event(start, "com.google.Chrome", "Pricing | Stripe", Some("https://www.google.com/search?q=stripe+per+seat"), "results"),
                EventSource::BrowserPage,
            )
            .unwrap();
        store
            .put_event_with_source(&event(start + 4 * min, "com.apple.Notes", "Launch plan", None, "Team: $18/seat"), EventSource::ScreenOcr)
            .unwrap();
        // A session that is still going must not be noted yet.
        store
            .put_event_with_source(&event(now - min, "com.apple.Notes", "Launch plan", None, "more"), EventSource::ScreenOcr)
            .unwrap();
        let understanding = Understanding::new(Arc::clone(&store), Arc::new(MindClient::new(None)), 0, "Amy".into());
        let stats = understanding.run_cycle(now, 8).unwrap();
        assert_eq!(stats.searches, 1);
        assert_eq!(stats.sessions, 1);
        assert_eq!(stats.sessions_by_model, 0);
        assert_eq!(stats.model_unavailable.as_deref(), Some("not_installed"));
        let notes = store.session_notes_in_range(0, u64::MAX / 2).unwrap();
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].model, "measured");
        assert!(notes[0].title.contains("Notes") || notes[0].title.contains("Chrome"));
        let again = understanding.run_cycle(now, 8).unwrap();
        assert_eq!(again.sessions, 0, "a noted session is not noted twice");
        let today = local_date_string(i64::try_from(now / 1_000_000).unwrap(), 0);
        let day = understanding.day(&today, now).unwrap();
        assert_eq!(day.breakdown.basis, "estimated");
        assert_eq!(day.written_by.as_deref(), Some("measured"));
        assert!(day.narrative.unwrap().headline.contains("hours at the computer"));
        assert_eq!(day.breakdown.searches[0].query, "stripe per seat");
    }
}
