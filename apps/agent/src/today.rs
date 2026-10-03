//! Daily packet: what happened across projects on one local calendar day.
//!
//! See `docs/handoff/CONTRACT.md` section 6. The per-project lines come from
//! the same extractor the handoff packet uses ([`extract_project_state`]),
//! so "Goal" and "Stopped at" here match what a new session in that project
//! would be told. Screen totals come from episodes when the screen events
//! belong to one, else from the spacing of the events themselves.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use mci_brain::{Event, EventSource, SqlCipherBrainStore};
use serde::{Deserialize, Serialize};

use crate::brief_worker::local_date_start_secs;
use crate::handoff::{
    agent_counts, app_display_name, collect_git_evidence, commits_between, cut,
    extract_project_state, parse_transcript_event, plural, resolve_project_root, GitCommit,
    LocalTz, ProjectSources, ProjectState, RenderClock,
};

/// Upper bound on events read for one day.
const MAX_DAY_EVENTS: usize = 20_000;
/// Upper bound on episodes consulted for screen totals.
const MAX_EPISODES: usize = 4_000;
/// A screen event with no episode counts until the next same-app event,
/// capped here, so a lone event never inflates a total.
const SCREEN_GAP_CAP_SECS: u64 = 60;
/// Credit given to the last screen event of an app when nothing follows it.
const SCREEN_TAIL_SECS: u64 = 30;
/// Commit subjects shown per project.
const COMMITS_SHOWN: usize = 3;
/// File names shown per project.
const FILES_SHOWN: usize = 6;
/// Apps shown in the Screen section.
const SCREEN_APPS_SHOWN: usize = 6;

/// Output shapes of the `today` command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TodayFormat {
    /// The packet as written.
    Markdown,
    /// The report structure, for automation.
    Json,
}

impl TodayFormat {
    /// Parse a `--format` value.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "markdown" => Some(Self::Markdown),
            "json" => Some(Self::Json),
            _ => None,
        }
    }
}

/// One project's day.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectDay {
    /// Extracted state over the day's events in this project.
    pub state: ProjectState,
    /// Commits made in the project during the day, newest first.
    pub commits: Vec<GitCommit>,
}

/// Screen time attributed to one app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScreenTotal {
    /// Display name of the app.
    pub app: String,
    /// Seconds attributed.
    pub seconds: u64,
}

/// The compiled daily report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TodayReport {
    /// `YYYY-MM-DD` local date.
    pub date: String,
    /// Zone the day was cut in.
    pub tz: LocalTz,
    /// Inclusive window start in microseconds.
    pub start_us: u64,
    /// Inclusive window end in microseconds.
    pub end_us: u64,
    /// Agent sessions active during the day, across projects.
    pub sessions: usize,
    /// `Claude Code 3, Codex 1` style counts.
    pub agent_counts: String,
    /// First transcript event of the day.
    pub first_ts_us: Option<u64>,
    /// Last transcript event of the day.
    pub last_ts_us: Option<u64>,
    /// Projects, most recently active first.
    pub projects: Vec<ProjectDay>,
    /// Screen time per app, largest first.
    pub screen: Vec<ScreenTotal>,
    /// `episodes` or `events`, saying where the screen totals came from.
    pub screen_basis: Option<String>,
}

impl TodayReport {
    /// Total attributed screen seconds.
    #[must_use]
    pub fn screen_seconds(&self) -> u64 {
        self.screen.iter().map(|total| total.seconds).sum()
    }
}

/// `3h 10m` style duration.
#[must_use]
pub fn format_duration(seconds: u64) -> String {
    let hours = seconds / 3600;
    let minutes = (seconds % 3600) / 60;
    if hours > 0 && minutes > 0 {
        format!("{hours}h {minutes}m")
    } else if hours > 0 {
        format!("{hours}h")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        "<1m".to_owned()
    }
}

fn next_date(date: &str, tz: &LocalTz) -> Option<String> {
    let start = local_date_start_secs(date, tz.offset_secs)?;
    let next = u64::try_from(start.checked_add(86_400)?).ok()?;
    Some(tz.format_date(next.checked_mul(1_000_000)?))
}

/// Screen seconds per app for the day's screen events.
fn screen_totals(
    store: &SqlCipherBrainStore,
    screen_events: &[Event],
    start_us: u64,
    end_us: u64,
) -> (Vec<ScreenTotal>, Option<String>) {
    if screen_events.is_empty() {
        return (Vec::new(), None);
    }
    let mut seconds_by_app: BTreeMap<String, u64> = BTreeMap::new();
    let episode_ids: BTreeSet<u64> = screen_events
        .iter()
        .filter_map(|event| event.episode_id)
        .collect();
    let mut covered: BTreeSet<u64> = BTreeSet::new();
    if !episode_ids.is_empty() {
        let episodes = store.recent_episodes(MAX_EPISODES).unwrap_or_default();
        for episode in episodes
            .iter()
            .filter(|episode| episode_ids.contains(&episode.id))
        {
            let clipped_start = episode.ts_start.max(start_us);
            let clipped_end = episode.ts_end.min(end_us);
            if clipped_end <= clipped_start {
                continue;
            }
            let app = episode
                .app_bundle_id
                .as_deref()
                .or_else(|| {
                    screen_events
                        .iter()
                        .find(|event| event.episode_id == Some(episode.id))
                        .and_then(|event| event.app_bundle_id.as_deref())
                })
                .map_or_else(|| "screen".to_owned(), app_display_name);
            *seconds_by_app.entry(app).or_insert(0) += (clipped_end - clipped_start) / 1_000_000;
            covered.insert(episode.id);
        }
    }
    let basis = if covered.is_empty() {
        "events"
    } else {
        "episodes"
    };

    // Events outside any found episode: credit the gap to the next event
    // of the same app, capped, so a lone capture never inflates a total.
    let mut by_app: HashMap<String, Vec<u64>> = HashMap::new();
    for event in screen_events
        .iter()
        .filter(|event| !event.episode_id.is_some_and(|id| covered.contains(&id)))
    {
        let app = event
            .app_bundle_id
            .as_deref()
            .map_or_else(|| "screen".to_owned(), app_display_name);
        by_app.entry(app).or_default().push(event.ts_us);
    }
    for (app, mut stamps) in by_app {
        stamps.sort_unstable();
        let mut seconds = 0;
        for pair in stamps.windows(2) {
            seconds += ((pair[1] - pair[0]) / 1_000_000).min(SCREEN_GAP_CAP_SECS);
        }
        seconds += SCREEN_TAIL_SECS;
        *seconds_by_app.entry(app).or_insert(0) += seconds;
    }

    let mut totals: Vec<ScreenTotal> = seconds_by_app
        .into_iter()
        .map(|(app, seconds)| ScreenTotal { app, seconds })
        .collect();
    totals.sort_by(|a, b| b.seconds.cmp(&a.seconds).then_with(|| a.app.cmp(&b.app)));
    (totals, Some(basis.to_owned()))
}

/// Compile the report for `date` (default: the clock's local today).
///
/// # Errors
/// An invalid date, or a store read failure, as text for diagnostics.
pub fn compile_today(
    store: &SqlCipherBrainStore,
    date: Option<&str>,
    clock: &RenderClock,
) -> Result<TodayReport, String> {
    let tz = &clock.tz;
    let date = date.map_or_else(|| tz.format_date(clock.now_us), str::to_owned);
    let start_secs = local_date_start_secs(&date, tz.offset_secs)
        .ok_or_else(|| format!("--date must be a real YYYY-MM-DD date, got {date}"))?;
    let start_us = u64::try_from(start_secs)
        .ok()
        .and_then(|secs| secs.checked_mul(1_000_000))
        .ok_or_else(|| "date is before 1970".to_owned())?;
    let end_us = start_us + 86_400 * 1_000_000 - 1;

    let mut events = store
        .events_in_range(start_us, end_us, MAX_DAY_EVENTS)
        .map_err(|error| format!("read events for {date}: {error}"))?;
    events.sort_by_key(|event| (event.ts_us, event.id.0));

    // Group transcript events by the project root that contains their cwd.
    let mut root_for_cwd: HashMap<String, PathBuf> = HashMap::new();
    let mut by_root: BTreeMap<PathBuf, Vec<Event>> = BTreeMap::new();
    let mut first_ts_us = None;
    let mut last_ts_us = None;
    for event in &events {
        let Some(parsed) = parse_transcript_event(event, tz) else {
            continue;
        };
        let Some(cwd) = parsed.cwd.clone() else {
            continue;
        };
        first_ts_us = first_ts_us.or(Some(event.ts_us));
        last_ts_us = Some(event.ts_us);
        let root = root_for_cwd
            .entry(cwd.clone())
            .or_insert_with(|| resolve_project_root(Path::new(&cwd)))
            .clone();
        by_root.entry(root).or_default().push(event.clone());
    }

    let screen_events = store
        .events_by_source_in_range(EventSource::ScreenOcr, start_us, end_us, MAX_DAY_EVENTS)
        .unwrap_or_default();

    let since_iso = format!("{date}T00:00:00{}", tz.offset_iso());
    let until_iso = next_date(&date, tz).map_or_else(
        || since_iso.clone(),
        |next| format!("{next}T00:00:00{}", tz.offset_iso()),
    );
    let mut projects: Vec<ProjectDay> = by_root
        .iter()
        .map(|(root, project_events)| {
            let git = collect_git_evidence(root);
            let commits = if git.is_some() {
                commits_between(root, &since_iso, &until_iso)
            } else {
                Vec::new()
            };
            let sources = ProjectSources {
                root,
                screen_events: &screen_events,
                git,
                tz,
            };
            ProjectDay {
                state: extract_project_state(project_events, &sources),
                commits,
            }
        })
        .collect();
    projects.sort_by(|a, b| {
        b.state
            .last_ts_us
            .cmp(&a.state.last_ts_us)
            .then_with(|| a.state.root.cmp(&b.state.root))
    });

    let all_sessions: Vec<_> = projects
        .iter()
        .flat_map(|project| project.state.sessions.iter().cloned())
        .collect();
    let (screen, screen_basis) = screen_totals(store, &screen_events, start_us, end_us);

    Ok(TodayReport {
        date,
        tz: tz.clone(),
        start_us,
        end_us,
        sessions: all_sessions.len(),
        agent_counts: agent_counts(&all_sessions),
        first_ts_us,
        last_ts_us,
        projects,
        screen,
        screen_basis,
    })
}

/// One `## project (root)` block of the daily packet.
fn render_project_day(out: &mut String, project: &ProjectDay, tz: &LocalTz) {
    let state = &project.state;
    let _ = write!(out, "\n## {} ({})\n", state.name, state.root);
    if let Some(goal) = state.goal.as_ref().or(state.earlier_goals.first()) {
        let _ = writeln!(
            out,
            "- Goal: {} ({}, {}, event {})",
            goal.text,
            goal.agent,
            tz.format_datetime(goal.ts_us),
            goal.event_id
        );
    }
    if let Some(stopped) = &state.stopped {
        let _ = writeln!(
            out,
            "- Stopped at: {} ({}, {}, event {})",
            stopped.text,
            stopped.agent,
            tz.format_datetime(stopped.ts_us),
            stopped.event_id
        );
    }
    if !project.commits.is_empty() {
        let shown: Vec<String> = project
            .commits
            .iter()
            .take(COMMITS_SHOWN)
            .map(|commit| {
                format!(
                    "{} \"{}\"",
                    commit.hash,
                    cut(&commit.subject.replace('\u{2014}', "-"), 60)
                )
            })
            .collect();
        let more = project.commits.len().saturating_sub(COMMITS_SHOWN);
        let _ = write!(
            out,
            "- Commits: {} ({}",
            project.commits.len(),
            shown.join(", ")
        );
        if more > 0 {
            let _ = write!(out, ", and {more} more");
        }
        out.push_str(")\n");
    }
    if !state.files_touched.is_empty() {
        let names: Vec<&str> = state
            .files_touched
            .iter()
            .take(FILES_SHOWN)
            .map(|file| file.path.rsplit('/').next().unwrap_or(&file.path))
            .collect();
        let _ = writeln!(out, "- Files: {}", names.join(", "));
    }
}

/// Render the daily packet as markdown.
#[must_use]
pub fn render_today(report: &TodayReport) -> String {
    let tz = &report.tz;
    let mut out = format!("# Today, {} ({})\n", report.date, tz.abbreviation);
    let mut summary = String::new();
    if report.sessions == 0 {
        summary.push_str("Agents: no sessions.");
    } else {
        let _ = write!(
            summary,
            "Agents: {} ({})",
            plural(report.sessions, "session"),
            report.agent_counts
        );
        if let (Some(first), Some(last)) = (report.first_ts_us, report.last_ts_us) {
            let _ = write!(
                summary,
                ", {} to {}",
                tz.format_time(first),
                tz.format_time(last)
            );
        }
        summary.push('.');
    }
    if !report.screen.is_empty() {
        let _ = write!(
            summary,
            " Screen: {} across {}.",
            format_duration(report.screen_seconds()),
            plural(report.screen.len(), "app")
        );
    }
    out.push_str(&summary);
    out.push('\n');

    if report.projects.is_empty() && report.screen.is_empty() {
        out.push_str("\nNothing recorded for this day.\n");
        return out;
    }

    for project in &report.projects {
        render_project_day(&mut out, project, tz);
    }

    if !report.screen.is_empty() {
        out.push_str("\n## Screen\n");
        let shown: Vec<String> = report
            .screen
            .iter()
            .take(SCREEN_APPS_SHOWN)
            .map(|total| format!("{} {}", total.app, format_duration(total.seconds)))
            .collect();
        let _ = writeln!(
            out,
            "- {} (from {})",
            shown.join(", "),
            report.screen_basis.as_deref().unwrap_or("events")
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_read_naturally() {
        assert_eq!(format_duration(0), "<1m");
        assert_eq!(format_duration(59), "<1m");
        assert_eq!(format_duration(55 * 60), "55m");
        assert_eq!(format_duration(3600), "1h");
        assert_eq!(format_duration(3 * 3600 + 10 * 60), "3h 10m");
    }

    #[test]
    fn next_date_crosses_month_ends() {
        let tz = LocalTz::fixed(-25_200, "PDT");
        assert_eq!(next_date("2026-09-30", &tz).as_deref(), Some("2026-10-01"));
        assert_eq!(next_date("2026-02-28", &tz).as_deref(), Some("2026-03-01"));
        assert_eq!(next_date("not-a-date", &tz), None);
    }
}
