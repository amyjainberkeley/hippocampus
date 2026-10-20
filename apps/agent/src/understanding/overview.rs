//! The day overview: the one read the window's Overview place is drawn from
//! (`mci-agent overview --json`).
//!
//! Sessions ("blocks" here; the word never reaches the screen) are derived
//! from the day's moments, with stored session notes laid over them, so a day
//! the worker has not noted yet still shows what was saved. Nothing here
//! reads what a moment says: only its time, app, window, page and whether a
//! screenshot is kept. Nothing here needs the on-device model either; what a
//! model wrote appears only where it is labelled, and only after the word
//! check below.
//!
//! No clock time or duration is ever written into text. A sentence that
//! needs one is a [`Template`] with `{name}` placeholders and the values as
//! microseconds; the window formats them in the person's locale.

use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use serde::{Deserialize, Serialize};

use mci_brain::understanding::{EventHead, ObservedEvent, SearchRecord, SessionNote};
use mci_brain::{SqlCipherBrainStore, StoreError};

use super::apps::{self, WorkKind};
use super::mind::MindCallError;
use super::{day, observe, query};
use crate::brief_worker::local_date_string;

/// The shape's version; it changes only when a key changes meaning or type.
pub const VERSION: u32 = 1;
/// Most moments read for a day; when there are more, the newest are kept.
pub const READ_LIMIT: usize = 50_000;
/// Most sessions listed for a day; when there are more, the newest are kept.
pub const MAX_BLOCKS: usize = 300;
const MINUTE_US: u64 = 60_000_000;
const HOUR_US: u64 = 3_600_000_000;
/// With nothing saved today yet, "Last saved" looks this far back.
const LOOKBACK_US: u64 = 18 * HOUR_US;
/// A capture receipt older than this says nothing about now.
const RECEIPT_FRESH_US: u64 = 120 * 1_000_000;
/// The strip is at least this wide.
const MIN_STRIP_US: u64 = 4 * HOUR_US;
const TITLE_MAX_CHARS: usize = 200;
const CLEAN_TITLE_CHARS: usize = 60;
const RETURNED_TITLE_CHARS: usize = 40;
const NOTICED_CHARS: usize = 600;
const HEADLINE_CHARS: usize = 200;
const NARRATIVE_CHARS: usize = 2_000;
const BLOCK_SEARCHES: usize = 5;
const DAY_SEARCHES: usize = 20;
const MAX_URL_BYTES: usize = 2_048;

// ---------------------------------------------------------------------------
// Template objects
// ---------------------------------------------------------------------------

/// Text with `{name}` placeholders for times and durations, which Swift
/// fills in the person's locale. A literal brace is doubled.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Template {
    /// The text.
    pub template: String,
    /// Placeholder name to a time, microseconds since the Unix epoch.
    pub times: BTreeMap<String, u64>,
    /// Placeholder name to a duration in microseconds.
    pub durations: BTreeMap<String, u64>,
}

impl Template {
    /// Text with no placeholders filled yet.
    #[must_use]
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            template: text.into(),
            times: BTreeMap::new(),
            durations: BTreeMap::new(),
        }
    }

    /// Add a time.
    #[must_use]
    pub fn time(mut self, name: &str, us: u64) -> Self {
        self.times.insert(name.to_owned(), us);
        self
    }

    /// Add a duration.
    #[must_use]
    pub fn duration(mut self, name: &str, us: u64) -> Self {
        self.durations.insert(name.to_owned(), us);
        self
    }

    /// The text with every placeholder filled in 24-hour form ("14:02",
    /// "5h 30m"), for the CLI's plain-text mode only.
    #[must_use]
    pub fn fill(&self, tz_offset_secs: i32) -> String {
        let mut out = String::new();
        let mut rest = self.template.as_str();
        while let Some(at) = rest.find(['{', '}']) {
            out.push_str(&rest[..at]);
            let tail = &rest[at..];
            if tail.starts_with("{{") || tail.starts_with("}}") {
                out.push_str(&tail[..1]);
                rest = &tail[2..];
                continue;
            }
            if let Some(close) = tail.find('}').filter(|_| tail.starts_with('{')) {
                let name = &tail[1..close];
                if let Some(us) = self.times.get(name) {
                    out.push_str(&observe::clock(*us, tz_offset_secs));
                    rest = &tail[close + 1..];
                    continue;
                }
                if let Some(us) = self.durations.get(name) {
                    out.push_str(&duration_text(*us));
                    rest = &tail[close + 1..];
                    continue;
                }
            }
            out.push_str(&tail[..1]);
            rest = &tail[1..];
        }
        out.push_str(rest);
        out
    }
}

/// "5h 30m", "12m": hours and minutes, rounded to the minute, at least one.
fn duration_text(us: u64) -> String {
    let minutes = ((us + MINUTE_US / 2) / MINUTE_US).max(1);
    match (minutes / 60, minutes % 60) {
        (0, m) => format!("{m}m"),
        (h, 0) => format!("{h}h"),
        (h, m) => format!("{h}h {m}m"),
    }
}

/// Double every brace, so a title or a query written into a template is
/// never read as a placeholder.
#[must_use]
pub fn escape_braces(text: &str) -> String {
    text.replace('{', "{{").replace('}', "}}")
}

/// "one" … "nine", then numerals.
fn number_word(n: usize) -> String {
    const WORDS: [&str; 10] = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    ];
    WORDS
        .get(n)
        .map_or_else(|| n.to_string(), |w| (*w).to_owned())
}

/// "once", "twice", "three times" … "nine times", "10 times".
fn times_word(n: usize) -> String {
    match n {
        1 => "once".into(),
        2 => "twice".into(),
        _ => format!("{} times", number_word(n)),
    }
}

fn clip(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        text.to_owned()
    } else {
        text.chars().take(limit).collect::<String>() + "…"
    }
}

// ---------------------------------------------------------------------------
// The word check
// ---------------------------------------------------------------------------

/// Judgement words. Matched whole and case-insensitively; `*` ends a prefix,
/// and two words match two words in a row. Never applied to window titles,
/// app names, queries or URLs, which are data.
const JUDGEMENT_WORDS: &[&str] = &[
    "distracted",
    "distraction",
    "stuck",
    "struggled",
    "procrastinat*",
    "wasted",
    "lazy",
    "unfocused",
    "productive",
    "unproductive",
    "should",
    "too much",
    "seem*",
    "appear*",
    "probably",
    "frustrat*",
    "confus*",
    "gave up",
    "avoid*",
];
/// Too common in ordinary prose to act on, so checked in templates only.
const TEMPLATE_ONLY_WORDS: &[&str] = &["only", "just"];
/// Input telemetry a model was once shown and may have repeated. A click
/// counts only as a count ("12 clicks").
const INPUT_WORDS: &[&str] = &["paus*", "keystroke*", "key presses", "scroll*"];
const COUNT_WORDS: &[&str] = &[
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "dozens",
    "hundreds", "many",
];

fn words(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !(c.is_alphanumeric() || c == '\'' || c == '’'))
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
}

fn has_entry(entries: &[&str], words: &[String]) -> bool {
    entries.iter().any(|entry| match entry.split_once(' ') {
        Some((a, b)) => words.windows(2).any(|pair| pair[0] == a && pair[1] == b),
        None => match entry.strip_suffix('*') {
            Some(prefix) => words.iter().any(|w| w.starts_with(prefix)),
            None => words.iter().any(|w| w == entry),
        },
    })
}

fn counts_clicks(words: &[String]) -> bool {
    words.windows(2).any(|pair| {
        pair[1].starts_with("click")
            && (pair[0].chars().all(|c| c.is_ascii_digit())
                || COUNT_WORDS.contains(&pair[0].as_str()))
    })
}

/// Whether model prose may be shown or sent: no judgement word and no
/// mention of pauses or input counts.
#[must_use]
pub fn passes_word_check(text: &str) -> bool {
    let words = words(text);
    !has_entry(JUDGEMENT_WORDS, &words) && !has_entry(INPUT_WORDS, &words) && !counts_clicks(&words)
}

/// The stricter check every template is held to, in tests: the model-prose
/// list plus "only" and "just".
#[must_use]
pub fn template_passes_word_check(text: &str) -> bool {
    passes_word_check(text) && !has_entry(TEMPLATE_ONLY_WORDS, &words(text))
}

/// Sentences end after `.`, `!` or `?` followed by a space or the end.
fn sentences(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        if matches!(c, '.' | '!' | '?') && chars.peek().is_none_or(|(_, next)| next.is_whitespace())
        {
            let end = at + c.len_utf8();
            let sentence = text[start..end].trim();
            if !sentence.is_empty() {
                out.push(sentence);
            }
            start = end;
        }
    }
    let rest = text[start..].trim();
    if !rest.is_empty() {
        out.push(rest);
    }
    out
}

/// Model prose without the sentences that fail the word check.
#[must_use]
pub fn model_prose(text: &str) -> String {
    sentences(text)
        .into_iter()
        .filter(|s| passes_word_check(s))
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------------------------------------------------------------------------
// Titles, windows and kinds
// ---------------------------------------------------------------------------

/// A window title as a person would write it: no unread count, no leading
/// bullet, no trailing app name, at most 60 characters.
#[must_use]
pub fn clean_title(title: &str, app_name: &str) -> String {
    let mut text = title.trim();
    if let Some(rest) = text.strip_prefix('(') {
        if let Some(close) = rest.find(')') {
            let inside = &rest[..close];
            if !inside.is_empty() && inside.chars().all(|c| c.is_ascii_digit()) {
                if let Some(after) = rest[close + 1..].strip_prefix(' ') {
                    text = after.trim_start();
                }
            }
        }
    }
    while let Some(rest) = ['•', '●', '◦', '·', '*']
        .iter()
        .find_map(|b| text.strip_prefix(*b))
    {
        text = rest.strip_prefix(' ').unwrap_or(rest).trim_start();
    }
    if !app_name.is_empty() {
        for separator in [" - ", " — ", " | "] {
            if let Some(rest) = text.strip_suffix(&format!("{separator}{app_name}")) {
                text = rest;
                break;
            }
        }
    }
    clip(text.trim(), CLEAN_TITLE_CHARS)
}

/// One window or page held in focus, as a session note stores it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct StoredSegment {
    /// Start.
    pub start_us: u64,
    /// End (where the next began).
    pub end_us: u64,
    /// App bundle id (`unknown` when the moment had none).
    pub app: String,
    /// Raw window title.
    #[serde(default)]
    pub title: Option<String>,
    /// Page host.
    #[serde(default)]
    pub host: Option<String>,
    /// Moments in it, oldest first.
    #[serde(default)]
    pub events: Vec<i64>,
}

impl StoredSegment {
    fn from_observed(segment: &observe::Segment) -> Self {
        Self {
            start_us: segment.start_us,
            end_us: segment.end_us,
            app: segment.app.clone(),
            title: segment.title.clone(),
            host: segment.url.as_deref().and_then(apps::host_of),
            events: segment.event_ids.clone(),
        }
    }

    fn held_us(&self) -> u64 {
        self.end_us.saturating_sub(self.start_us)
    }

    fn kind(&self) -> WorkKind {
        apps::kind_for_host(&self.app, self.host.as_deref())
    }
}

/// A stored note's segments. Its counts of back-and-forth and reworded
/// searches are never read: nothing the window shows counts them.
#[derive(Deserialize)]
struct StoredNoteSignals {
    segments: Vec<StoredSegment>,
}

/// A note's segments from its stored signals, or `None` when they cannot be
/// read.
#[must_use]
pub fn stored_segments(note: &SessionNote) -> Option<Vec<StoredSegment>> {
    serde_json::from_str::<StoredNoteSignals>(&note.signals)
        .ok()
        .map(|stored| stored.segments)
}

/// One window across a session: segments that share app, title and host.
struct WindowHeld {
    bundle_id: String,
    title: Option<String>,
    host: Option<String>,
    held_us: u64,
    /// Index of its longest segment (the earliest on a tie).
    longest: usize,
    segments: Vec<usize>,
}

/// A session's windows, longest held first (first seen on a tie).
fn windows_of(segments: &[StoredSegment]) -> Vec<WindowHeld> {
    let mut out: Vec<WindowHeld> = Vec::new();
    for (index, segment) in segments.iter().enumerate() {
        match out.iter_mut().find(|w| {
            w.bundle_id == segment.app && w.title == segment.title && w.host == segment.host
        }) {
            Some(window) => {
                window.held_us += segment.held_us();
                if segment.held_us() > segments[window.longest].held_us() {
                    window.longest = index;
                }
                window.segments.push(index);
            }
            None => out.push(WindowHeld {
                bundle_id: segment.app.clone(),
                title: segment.title.clone(),
                host: segment.host.clone(),
                held_us: segment.held_us(),
                longest: index,
                segments: vec![index],
            }),
        }
    }
    out.sort_by_key(|w| std::cmp::Reverse(w.held_us));
    out
}

/// The moments of a session's longest-held window.
#[must_use]
pub fn longest_window_events(segments: &[StoredSegment]) -> Vec<i64> {
    windows_of(segments)
        .first()
        .map(|w| {
            w.segments
                .iter()
                .flat_map(|i| segments[*i].events.iter().copied())
                .collect()
        })
        .unwrap_or_default()
}

/// The session's kind (the largest window-held time, ties to the kind
/// declared first) and every kind with its time, largest first.
#[must_use]
pub fn kind_of_segments(segments: &[StoredSegment]) -> (WorkKind, Vec<(WorkKind, u64)>) {
    let total: u64 = segments.iter().map(StoredSegment::held_us).sum();
    let mut held: BTreeMap<WorkKind, (u64, u64)> = BTreeMap::new();
    for segment in segments {
        let entry = held.entry(segment.kind()).or_default();
        entry.0 += segment.held_us();
        // With no time held at all, each window counts once.
        entry.1 += if total > 0 { segment.held_us() } else { 1 };
    }
    let mut kinds: Vec<(WorkKind, u64, u64)> =
        held.into_iter().map(|(k, (h, w))| (k, h, w)).collect();
    kinds.sort_by_key(|k| std::cmp::Reverse(k.2));
    let kind = kinds.first().map_or(WorkKind::Other, |k| k.0);
    (kind, kinds.into_iter().map(|(k, h, _)| (k, h)).collect())
}

/// The title the Overview gives a session from measurements: its longest
/// window's title, cleaned, or that window's app.
fn measured_title(segments: &[StoredSegment]) -> Option<String> {
    let window = windows_of(segments).into_iter().next()?;
    let app = apps::name(&window.bundle_id);
    let title = window
        .title
        .as_deref()
        .map(|t| clean_title(t, &app))
        .unwrap_or_default();
    Some(if title.is_empty() { app } else { title })
}

/// A note's title as the Overview shows it, and who wrote it: a model's
/// title when it passes the word check, otherwise the measured title.
#[must_use]
pub fn note_title(note: &SessionNote) -> (String, String) {
    if let Some(title) = model_title(note) {
        return (title, note.model.clone());
    }
    let measured = stored_segments(note)
        .as_deref()
        .and_then(measured_title)
        .unwrap_or_else(|| {
            // Unreadable signals: the stored measured title is "{App} — {title}".
            let stored = note.title.trim();
            match stored.split_once(" — ") {
                Some((app, title)) if !clean_title(title, app).is_empty() => {
                    clean_title(title, app)
                }
                Some((app, _)) => app.to_owned(),
                None => clean_title(stored, ""),
            }
        });
    (measured, "measured".into())
}

fn model_title(note: &SessionNote) -> Option<String> {
    let title = note.title.trim();
    (note.model != "measured" && !title.is_empty() && passes_word_check(title))
        .then(|| clip(title, TITLE_MAX_CHARS))
}

// ---------------------------------------------------------------------------
// Model status
// ---------------------------------------------------------------------------

/// Whether the on-device model can be used, as the worker last found it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelStatus {
    /// `available`, `unavailable` or `unknown`.
    pub state: String,
    /// When unavailable, why (`apple_intelligence_off`, `not_installed`, …).
    pub reason: Option<String>,
    /// When the worker checked.
    pub checked_us: Option<u64>,
}

impl ModelStatus {
    /// Where the worker keeps it.
    pub const KEY: &'static str = "model_status";

    /// Nothing known.
    #[must_use]
    pub fn unknown() -> Self {
        Self {
            state: "unknown".into(),
            reason: None,
            checked_us: None,
        }
    }

    /// The outcome of a check or of a cycle that called the model.
    #[must_use]
    pub fn from_check(result: &Result<(), MindCallError>, now_us: u64) -> Self {
        match result {
            Ok(()) => Self {
                state: "available".into(),
                reason: None,
                checked_us: Some(now_us),
            },
            Err(MindCallError::Unavailable(reason)) => Self {
                state: "unavailable".into(),
                reason: Some(reason.clone()),
                checked_us: Some(now_us),
            },
            Err(_) => Self {
                state: "unavailable".into(),
                reason: Some("unavailable".into()),
                checked_us: Some(now_us),
            },
        }
    }

    /// The stored status; anything missing or unreadable is `unknown`.
    #[must_use]
    pub fn read(store: &SqlCipherBrainStore) -> Self {
        let stored = store
            .understanding_state(Self::KEY)
            .ok()
            .flatten()
            .and_then(|value| serde_json::from_str::<Self>(&value).ok());
        match stored {
            Some(status) if status.state == "available" => Self {
                reason: None,
                ..status
            },
            Some(status) if status.state == "unavailable" => Self {
                reason: Some(
                    status
                        .reason
                        .filter(|r| !r.is_empty())
                        .unwrap_or_else(|| "unavailable".into()),
                ),
                ..status
            },
            _ => Self::unknown(),
        }
    }

    /// Store it.
    ///
    /// # Errors
    /// Store failures.
    pub fn write(&self, store: &SqlCipherBrainStore) -> Result<(), StoreError> {
        store.set_understanding_state(Self::KEY, &serde_json::to_string(self).unwrap_or_default())
    }
}

// ---------------------------------------------------------------------------
// What the day overview needs from outside the memory
// ---------------------------------------------------------------------------

/// Facts the overview takes from beside the memory.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OverviewEnv {
    /// Hippocampus is saving right now: a fresh capture receipt with no
    /// block and no skip. False when unknown.
    pub remembering: bool,
    /// The session hook is installed for at least one AI tool.
    pub hook_installed: bool,
}

impl OverviewEnv {
    /// Read both from disk: the capture receipt beside the memory at
    /// `db_path`, and the AI tools' hook files under `home`.
    #[must_use]
    pub fn read(
        db_path: &Path,
        home: Option<&Path>,
        codex_home: Option<&Path>,
        now_us: u64,
    ) -> Self {
        Self {
            remembering: remembering_now(&db_path.with_file_name("capture-status.json"), now_us),
            hook_installed: home.is_some_and(|home| hook_installed(home, codex_home)),
        }
    }
}

/// Whether the capture receipt says something is being saved now: it exists,
/// is version 1, was written in the last two minutes, and names no block and
/// no skipped window. A paused or quit Hippocampus stops writing it.
#[must_use]
pub fn remembering_now(receipt: &Path, now_us: u64) -> bool {
    let Some(status) = std::fs::read(receipt).ok().and_then(|bytes| {
        serde_json::from_slice::<crate::capture_status::CaptureStatus>(&bytes).ok()
    }) else {
        return false;
    };
    let fresh = crate::wall_clock::parse_unix_ms(&status.updated_at)
        .map(|ms| ms.saturating_mul(1_000))
        .is_some_and(|updated_us| {
            updated_us <= now_us + RECEIPT_FRESH_US
                && now_us.saturating_sub(updated_us) <= RECEIPT_FRESH_US
        });
    status.schema_version == 1
        && fresh
        && status.blocked_reason.is_none()
        && status.suppression_reason.is_none()
}

/// Whether the Hippocampus session hook is installed for Claude Code or
/// Codex, by the check `mci-agent doctor` uses.
#[must_use]
// The `let` ends the borrow of `paths` before `paths` is dropped; returning
// the expression directly does not compile (E0597).
#[allow(clippy::let_and_return)]
pub fn hook_installed(home: &Path, codex_home: Option<&Path>) -> bool {
    use crate::client_hooks::{detect_handoff_hook, HookPaths, HookPresence};
    let paths = HookPaths::for_home(home, codex_home);
    let installed = [&paths.claude_settings, &paths.codex_hooks]
        .into_iter()
        .any(|path| detect_handoff_hook(path) == HookPresence::Installed);
    installed
}

// ---------------------------------------------------------------------------
// The shape
// ---------------------------------------------------------------------------

/// The day overview.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Overview {
    /// [`VERSION`].
    pub version: u32,
    /// `YYYY-MM-DD`.
    pub date: String,
    /// Whether `date` is today.
    pub is_today: bool,
    /// The agent's clock.
    pub now_us: u64,
    /// The offset used, seconds east of UTC.
    pub tz_offset_secs: i32,
    /// Local midnight starting `date`.
    pub day_start_us: u64,
    /// The next local midnight.
    pub day_end_us: u64,
    /// `measured` or `estimated`.
    pub basis: String,
    /// The day had more moments than [`READ_LIMIT`] or sessions than
    /// [`MAX_BLOCKS`]; its earliest part is missing.
    pub truncated: bool,
    /// Whether the on-device model can be used.
    pub model_status: ModelStatus,
    /// The Right now card.
    pub now: Now,
    /// The span the day strip covers.
    pub strip: Option<Span>,
    /// The day's sessions, oldest first.
    pub blocks: Vec<Block>,
    /// Five minutes or more with nothing saved, between sessions.
    pub gaps: Vec<Span>,
    /// The legend, from `blocks`.
    pub kinds: Vec<LegendKind>,
    /// At most four facts about the day.
    pub facts: Vec<Fact>,
    /// The day's searches, newest first, at most 20.
    pub searches: Vec<Search>,
    /// The day's summary, written by a model.
    pub account: Option<Account>,
    /// What a connected AI is given right now.
    pub ai_knows: AiKnows,
}

/// The Right now card.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Now {
    /// `in_progress`, `last_saved` or `none`.
    pub state: String,
    /// The start of the run of touching sessions ending with this one.
    pub since_us: Option<u64>,
    /// The session's start.
    pub start_us: Option<u64>,
    /// The session's newest saved moment.
    pub last_saved_us: Option<u64>,
    /// The session's id in `blocks`, when it is there.
    pub block_id: Option<u64>,
    /// Its title.
    pub title: Option<String>,
    /// Who wrote the title.
    pub written_by: Option<String>,
    /// The app of its newest moment.
    pub app_name: Option<String>,
    /// Its newest moment.
    pub open_event_id: Option<i64>,
    /// What "Open {App}" or "Open Page" opens.
    pub reopen: Option<Reopen>,
}

/// A time span.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Span {
    /// Start.
    pub start_us: u64,
    /// End.
    pub end_us: u64,
}

/// One session.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[allow(clippy::struct_excessive_bools)] // each flag is its own field for the window
pub struct Block {
    /// The session's own start; provisional until a note backs it.
    pub id: u64,
    /// No stored note backs it yet.
    pub provisional: bool,
    /// First saved moment, clipped to the day.
    pub start_us: u64,
    /// Last saved moment, clipped to the day and to now.
    pub end_us: u64,
    /// Work in it is still going on.
    pub in_progress: bool,
    /// It starts less than five minutes after the previous one ends.
    pub touches_previous: bool,
    /// Never empty.
    pub title: String,
    /// `measured` or a model id.
    pub written_by: String,
    /// Its kind of work.
    pub kind: String,
    /// The kind's label.
    pub kind_label: String,
    /// The largest kind holds under half the time.
    pub mixed: bool,
    /// Kinds by window-held time, at most 3.
    pub kinds: Vec<KindHeld>,
    /// Apps by window-held time, at most 3.
    pub apps: Vec<AppHeld>,
    /// Windows by window-held time, at most 3.
    pub windows: Vec<WindowOut>,
    /// At most two sentences.
    pub sentences: Vec<Sentence>,
    /// Searches made during it, oldest first, at most 5.
    pub searches: Vec<Search>,
    /// A stored screenshot to show.
    pub screenshot_event_id: Option<i64>,
    /// Its newest saved moment.
    pub open_event_id: i64,
    /// What its primary action opens.
    pub reopen: Option<Reopen>,
    /// What a model wrote about it.
    pub noticed: Option<Noticed>,
}

/// A kind with its window-held time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct KindHeld {
    /// The kind.
    pub kind: String,
    /// Its label.
    pub kind_label: String,
    /// Window-held time.
    pub held_us: u64,
}

/// An app with its window-held time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AppHeld {
    /// Bundle id.
    pub bundle_id: String,
    /// Readable name.
    pub name: String,
    /// Window-held time.
    pub held_us: u64,
}

/// A window with its window-held time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WindowOut {
    /// Bundle id.
    pub bundle_id: String,
    /// Readable app name.
    pub name: String,
    /// Cleaned title.
    pub title: Option<String>,
    /// Page host.
    pub host: Option<String>,
    /// Window-held time.
    pub held_us: u64,
    /// The newest moment of its longest segment.
    pub event_id: i64,
}

/// A measured sentence about a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Sentence {
    /// `switched_between` or `reworded_search`.
    pub id: String,
    /// The text.
    #[serde(flatten)]
    pub text: Template,
}

/// A search.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Search {
    /// As typed.
    pub query: String,
    /// Short engine name.
    pub engine: String,
    /// When.
    pub ts_us: u64,
    /// The moment whose URL carried it.
    pub event_id: i64,
    /// The URL as stored.
    pub url: Option<String>,
}

impl From<&SearchRecord> for Search {
    fn from(s: &SearchRecord) -> Self {
        Self {
            query: s.query.clone(),
            engine: s.engine.clone(),
            ts_us: s.ts_us,
            event_id: s.event_id,
            url: s.url.clone(),
        }
    }
}

/// What to reopen.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Reopen {
    /// An http or https page.
    pub url: Option<String>,
    /// The app.
    pub bundle_id: String,
    /// Its readable name.
    pub app_name: String,
}

/// What a model wrote about a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Noticed {
    /// The text.
    pub text: String,
    /// The model.
    pub written_by: String,
}

/// One legend entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LegendKind {
    /// The kind.
    pub kind: String,
    /// Its label.
    pub kind_label: String,
    /// Total length of its sessions.
    pub duration_us: u64,
}

/// A fact about the day.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Fact {
    /// `active`, `longest`, `returned` or `searched`.
    pub id: String,
    /// The text.
    #[serde(flatten)]
    pub text: Template,
    /// What clicking it does.
    pub action: Option<Action>,
}

/// What clicking a fact does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Action {
    /// `select_blocks` or `show_searches`.
    #[serde(rename = "type")]
    pub kind: String,
    /// The sessions to select, oldest first.
    pub block_ids: Vec<u64>,
}

/// The day's summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Account {
    /// One line.
    pub headline: String,
    /// A paragraph.
    pub narrative: String,
    /// The model id.
    pub written_by: String,
    /// When it was written.
    pub generated_us: u64,
}

/// What a connected AI is given at the start of a session.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AiKnows {
    /// The "Recent work" lines, newest first.
    pub recent_work: Vec<Template>,
    /// The "About the user" lines, in the order sent.
    pub about_you: Vec<AboutLine>,
    /// The session hook is installed for at least one AI tool.
    pub hook_installed: bool,
}

/// One "About the user" line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AboutLine {
    /// The proposition id.
    pub id: i64,
    /// The statement as sent.
    pub text: String,
}

// ---------------------------------------------------------------------------
// Building sessions from moments and notes
// ---------------------------------------------------------------------------

/// A session before it is shaped for the window.
struct Draft {
    /// Its own start, before clipping.
    own_start_us: u64,
    start_us: u64,
    end_us: u64,
    /// Its newest focus moment.
    last_us: u64,
    note: Option<SessionNote>,
    segments: Vec<StoredSegment>,
    newest: Option<EventHead>,
}

fn observed(head: &EventHead) -> ObservedEvent {
    ObservedEvent {
        id: head.id,
        ts_us: head.ts_us,
        app_bundle_id: head.app_bundle_id.clone(),
        window_title: head.window_title.clone(),
        url: head.url.clone(),
        text: String::new(),
        source: head.source.clone(),
    }
}

fn is_focus(head: &EventHead) -> bool {
    !matches!(
        head.source.as_str(),
        "screen_context" | "transcript_import" | "mcp_resource"
    )
}

fn is_noise(head: &EventHead) -> bool {
    head.app_bundle_id.as_deref().is_some_and(apps::is_noise)
}

/// Segments and signals measured from moments (no text is read).
fn measure(heads: &[&EventHead], end_us: u64) -> Vec<StoredSegment> {
    let events: Vec<ObservedEvent> = heads.iter().map(|h| observed(h)).collect();
    observe::segments(&events, &[], end_us)
        .iter()
        .map(StoredSegment::from_observed)
        .collect()
}

/// Sessions in `[from, to)`: one per stored note, and the moments outside
/// every note split as the worker splits them. `focus` is oldest first, with
/// noise and background windows already left out.
fn drafts(
    focus: &[EventHead],
    notes: &[SessionNote],
    from: u64,
    to: u64,
    now_us: u64,
) -> Vec<Draft> {
    let mut out = Vec::new();
    let mut notes: Vec<&SessionNote> = notes
        .iter()
        .filter(|n| n.end_us >= from && n.start_us < to)
        .collect();
    notes.sort_by_key(|n| n.start_us);
    let inside = |head: &EventHead| {
        notes
            .iter()
            .any(|n| n.start_us <= head.ts_us && head.ts_us <= n.end_us)
    };
    for note in &notes {
        let heads: Vec<&EventHead> = focus
            .iter()
            .filter(|h| note.start_us <= h.ts_us && h.ts_us <= note.end_us)
            .collect();
        let segments = match serde_json::from_str::<StoredNoteSignals>(&note.signals) {
            Ok(stored) => stored.segments,
            Err(_) => measure(&heads, note.end_us),
        };
        out.push(Draft {
            own_start_us: note.start_us,
            start_us: note.start_us,
            end_us: note.end_us,
            last_us: heads.last().map_or(note.end_us, |h| h.ts_us),
            note: Some((*note).clone()),
            segments,
            newest: heads.last().map(|h| (*h).clone()),
        });
    }
    // Moments outside every note, split between the notes so an unnoted
    // session never reaches across a noted one.
    let mut region: Vec<&EventHead> = Vec::new();
    let flush = |region: &mut Vec<&EventHead>, out: &mut Vec<Draft>| {
        let events: Vec<ObservedEvent> = region.iter().map(|h| observed(h)).collect();
        for span in observe::split_sessions(&events) {
            let heads = &region[span.start..span.end];
            out.push(Draft {
                own_start_us: span.start_us,
                start_us: span.start_us,
                end_us: span.end_us,
                last_us: span.end_us,
                note: None,
                segments: measure(heads, span.end_us),
                newest: heads.last().map(|h| (*h).clone()),
            });
        }
        region.clear();
    };
    let mut next_note = 0;
    for head in focus.iter().filter(|h| h.ts_us >= from && h.ts_us < to) {
        while next_note < notes.len() && notes[next_note].end_us < head.ts_us {
            next_note += 1;
            flush(&mut region, &mut out);
        }
        if !inside(head) {
            region.push(head);
        }
    }
    flush(&mut region, &mut out);
    for draft in &mut out {
        draft.start_us = draft.start_us.clamp(from, to);
        draft.end_us = draft
            .end_us
            .min(to.saturating_sub(1))
            .min(now_us)
            .max(draft.start_us);
    }
    out.retain(|d| d.newest.is_some() || d.segments.iter().any(|s| !s.events.is_empty()));
    out.sort_by_key(|d| (d.start_us, d.own_start_us));
    out
}

/// Everything a draft adds up to besides its JSON.
struct Shaped {
    block: Block,
    /// Every window, cleaned title with its kind and time, for "returned".
    windows: Vec<(String, WorkKind, u64, String)>,
}

/// The sentences said about a session: none that count what the person did.
/// Today never shows how often someone switched windows or reworded a
/// search, nor their keys, clicks or scrolls (RULINGS W4, SPEC 3.1), so the
/// overview the window reads carries neither `switched_between` nor
/// `reworded_search` any more. The list stays, empty, for the contract.
fn block_sentences(_draft: &Draft) -> Vec<Sentence> {
    Vec::new()
}

fn reopen_of(head: &EventHead) -> Option<Reopen> {
    let bundle_id = head.app_bundle_id.clone().filter(|b| !b.is_empty())?;
    let url = head.url.clone().filter(|url| {
        let lower = url.get(..8).unwrap_or(url).to_ascii_lowercase();
        (lower.starts_with("http://") || lower.starts_with("https://"))
            && url.len() <= MAX_URL_BYTES
    });
    Some(Reopen {
        url,
        app_name: apps::name(&bundle_id),
        bundle_id,
    })
}

fn noticed_of(note: &SessionNote) -> Option<Noticed> {
    if note.model == "measured" {
        return None;
    }
    let beneath = note.beneath.trim();
    if beneath.is_empty() || beneath == "Nothing notable." {
        return None;
    }
    let kept = model_prose(beneath);
    (!kept.is_empty() && kept != "Nothing notable.").then(|| Noticed {
        text: clip(&kept, NOTICED_CHARS),
        written_by: note.model.clone(),
    })
}

/// The screenshot to show: the stored one nearest the middle of the longest
/// window's longest segment, from that window's app; else nearest the middle
/// of the session, from that app; else none.
fn screenshot(
    store: &SqlCipherBrainStore,
    block_span: Span,
    segments: &[StoredSegment],
    window: Option<&WindowHeld>,
) -> Option<i64> {
    let window = window?;
    let segment = &segments[window.longest];
    let pick = |start: u64, end: u64| {
        store
            .keyframe_events_near(start, end, start + (end - start) / 2, 8)
            .ok()?
            .into_iter()
            .find(|h| h.app_bundle_id.as_deref() == Some(window.bundle_id.as_str()))
            .map(|h| h.id)
    };
    pick(segment.start_us, segment.end_us.max(segment.start_us))
        .or_else(|| pick(block_span.start_us, block_span.end_us))
}

#[allow(clippy::too_many_lines)] // every field of a session, in the order the window shows them
fn shape(store: &SqlCipherBrainStore, draft: &Draft, searches: &[SearchRecord]) -> Option<Shaped> {
    let windows = windows_of(&draft.segments);
    let open = if let Some(head) = &draft.newest {
        head.clone()
    } else {
        let id = *draft.segments.iter().rev().find_map(|s| s.events.last())?;
        store.event_heads(&[id]).ok()?.into_iter().next()?
    };
    let (kind, kinds) = kind_of_segments(&draft.segments);
    let total: u64 = kinds.iter().map(|k| k.1).sum();
    let mixed = total > 0 && kinds.first().is_some_and(|k| k.1 * 2 < total);
    let mut app_time: Vec<(String, u64)> = Vec::new();
    for segment in &draft.segments {
        match app_time.iter_mut().find(|(app, _)| *app == segment.app) {
            Some(entry) => entry.1 += segment.held_us(),
            None => app_time.push((segment.app.clone(), segment.held_us())),
        }
    }
    app_time.sort_by_key(|a| std::cmp::Reverse(a.1));
    let measured = measured_title(&draft.segments).unwrap_or_else(|| {
        open.app_bundle_id
            .as_deref()
            .map(apps::name)
            .unwrap_or_default()
    });
    let (title, written_by) = match draft.note.as_ref().and_then(model_title) {
        Some(title) => (
            title,
            draft
                .note
                .as_ref()
                .map(|n| n.model.clone())
                .unwrap_or_default(),
        ),
        None => (clip(&measured, TITLE_MAX_CHARS), "measured".to_owned()),
    };
    let title = if title.trim().is_empty() {
        "Untitled".to_owned()
    } else {
        title
    };
    let span = Span {
        start_us: draft.start_us,
        end_us: draft.end_us,
    };
    let block = Block {
        id: draft.own_start_us,
        provisional: draft.note.is_none(),
        start_us: draft.start_us,
        end_us: draft.end_us,
        in_progress: false,
        touches_previous: false,
        title,
        written_by,
        kind: kind.as_str().into(),
        kind_label: kind.label().into(),
        mixed,
        kinds: kinds
            .iter()
            .take(3)
            .map(|(k, held)| KindHeld {
                kind: k.as_str().into(),
                kind_label: k.label().into(),
                held_us: *held,
            })
            .collect(),
        apps: app_time
            .iter()
            .take(3)
            .map(|(app, held)| AppHeld {
                bundle_id: app.clone(),
                name: apps::name(app),
                held_us: *held,
            })
            .collect(),
        windows: windows
            .iter()
            .take(3)
            .map(|w| {
                let name = apps::name(&w.bundle_id);
                WindowOut {
                    title: w
                        .title
                        .as_deref()
                        .filter(|t| !t.trim().is_empty())
                        .map(|t| clean_title(t, &name)),
                    name,
                    bundle_id: w.bundle_id.clone(),
                    host: w.host.clone(),
                    held_us: w.held_us,
                    event_id: draft.segments[w.longest]
                        .events
                        .last()
                        .copied()
                        .unwrap_or(open.id),
                }
            })
            .collect(),
        sentences: block_sentences(draft),
        searches: searches
            .iter()
            .filter(|s| s.ts_us >= draft.start_us && s.ts_us <= draft.end_us)
            .take(BLOCK_SEARCHES)
            .map(Search::from)
            .collect(),
        screenshot_event_id: screenshot(store, span, &draft.segments, windows.first()),
        open_event_id: open.id,
        reopen: reopen_of(&open),
        noticed: draft.note.as_ref().and_then(noticed_of),
    };
    let all_windows = windows
        .iter()
        .map(|w| {
            let name = apps::name(&w.bundle_id);
            let title = w
                .title
                .as_deref()
                .map(|t| clean_title(t, &name))
                .unwrap_or_default();
            (
                title,
                apps::kind_for_host(&w.bundle_id, w.host.as_deref()),
                w.held_us,
                name,
            )
        })
        .collect();
    Some(Shaped {
        block,
        windows: all_windows,
    })
}

/// The moments of `[from, to)` without their text, oldest first, with
/// noise left out; and whether the read limit cut the earliest part.
fn heads_in(
    store: &SqlCipherBrainStore,
    from: u64,
    to: u64,
) -> Result<(Vec<EventHead>, bool), StoreError> {
    let mut heads = store.event_heads_in_range(from, to, READ_LIMIT + 1)?;
    let truncated = heads.len() > READ_LIMIT;
    if truncated {
        heads.remove(0);
    }
    heads.retain(|h| !is_noise(h));
    Ok((heads, truncated))
}

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

const GENERIC_TITLES: &[&str] = &[
    "new tab",
    "untitled",
    "inbox",
    "home",
    "google",
    "start page",
    "downloads",
];

fn active_fact(day: &day::DayBreakdown) -> Option<Fact> {
    let (first, last) = (day.first_active_us?, day.last_active_us?);
    if day.active_us < 10 * MINUTE_US {
        return None;
    }
    let text = if day.basis == "measured" {
        "Active {active}, {first} to {last}."
    } else {
        "Active about {active}, {first} to {last}."
    };
    Some(Fact {
        id: "active".into(),
        text: Template::new(text)
            .duration("active", day.active_us)
            .time("first", first)
            .time("last", last),
        action: None,
    })
}

fn select(blocks: Vec<u64>) -> Option<Action> {
    (!blocks.is_empty()).then(|| Action {
        kind: "select_blocks".into(),
        block_ids: blocks,
    })
}

fn longest_fact(day: &day::DayBreakdown, blocks: &[Block]) -> Option<Fact> {
    let mut longest: Option<&day::FocusBlock> = None;
    for focus in &day.focus_blocks {
        if longest.is_none_or(|l| focus.end_us - focus.start_us > l.end_us - l.start_us) {
            longest = Some(focus);
        }
    }
    let focus = longest?;
    let of_kind = match focus.kind {
        WorkKind::Other => String::new(),
        WorkKind::Ai => " of AI tools".to_owned(),
        kind => format!(" of {}", kind.label().to_lowercase()),
    };
    let in_app = if focus.app.is_empty() {
        String::new()
    } else {
        format!(", mostly in {}", escape_braces(&focus.app))
    };
    Some(Fact {
        id: "longest".into(),
        text: Template::new(format!(
            "Longest run: about {{length}}{of_kind}{in_app}, from {{start}}."
        ))
        .duration("length", focus.end_us - focus.start_us)
        .time("start", focus.start_us),
        action: select(
            blocks
                .iter()
                .filter(|b| b.start_us < focus.end_us && b.end_us >= focus.start_us)
                .map(|b| b.id)
                .collect(),
        ),
    })
}

/// "You came back to …": a window title in three or more runs of sessions,
/// where a run is broken by a gap or by a session without the title.
fn returned_fact(shaped: &[Shaped]) -> Option<Fact> {
    struct Candidate {
        title: String,
        runs: Vec<Vec<usize>>,
        held_us: u64,
    }
    let mut candidates: Vec<Candidate> = Vec::new();
    for (index, block) in shaped.iter().enumerate() {
        let mut seen_here: HashSet<String> = HashSet::new();
        for (title, kind, held, app) in &block.windows {
            let eligible = title.chars().count() >= 4
                && !GENERIC_TITLES.contains(&title.to_lowercase().as_str())
                && !title.eq_ignore_ascii_case(app)
                && !matches!(
                    kind,
                    WorkKind::Communication | WorkKind::Media | WorkKind::Other | WorkKind::Ai
                );
            if !eligible {
                continue;
            }
            let candidate = if let Some(at) = candidates.iter_mut().position(|c| c.title == *title)
            {
                &mut candidates[at]
            } else {
                candidates.push(Candidate {
                    title: title.clone(),
                    runs: Vec::new(),
                    held_us: 0,
                });
                candidates.last_mut().expect("just pushed")
            };
            candidate.held_us += held;
            if seen_here.insert(title.clone()) {
                let continues = candidate
                    .runs
                    .last()
                    .and_then(|run| run.last())
                    .is_some_and(|last| *last + 1 == index && block.block.touches_previous);
                if continues {
                    candidate.runs.last_mut().expect("checked").push(index);
                } else {
                    candidate.runs.push(vec![index]);
                }
            }
        }
    }
    let best = candidates.into_iter().filter(|c| c.runs.len() >= 3).fold(
        None::<Candidate>,
        |best, c| match best {
            None => Some(c),
            Some(b) => {
                let better = c.runs.len() > b.runs.len()
                    || (c.runs.len() == b.runs.len() && c.held_us > b.held_us);
                Some(if better { c } else { b })
            }
        },
    )?;
    let returns = best.runs.len() - 1;
    Some(Fact {
        id: "returned".into(),
        text: Template::new(format!(
            "You came back to “{}” {}.",
            escape_braces(&clip(&best.title, RETURNED_TITLE_CHARS)),
            times_word(returns)
        )),
        action: select(
            best.runs
                .iter()
                .flatten()
                .map(|i| shaped[*i].block.id)
                .collect(),
        ),
    })
}

fn searched_fact(count: usize) -> Option<Fact> {
    let text = match count {
        0 => return None,
        1 => "You looked up one thing.".to_owned(),
        n => format!("You looked up {} things.", number_word(n)),
    };
    Some(Fact {
        id: "searched".into(),
        text: Template::new(text),
        action: Some(Action {
            kind: "show_searches".into(),
            block_ids: Vec::new(),
        }),
    })
}

// ---------------------------------------------------------------------------
// The read
// ---------------------------------------------------------------------------

fn account_of(store: &SqlCipherBrainStore, date: &str) -> Result<Option<Account>, StoreError> {
    let Some(report) = store.day_report(date)? else {
        return Ok(None);
    };
    if report.model == "measured" {
        return Ok(None);
    }
    let body: serde_json::Value = serde_json::from_str(&report.body).unwrap_or_default();
    let text = |key: &str| {
        body["narrative"][key]
            .as_str()
            .map(model_prose)
            .unwrap_or_default()
    };
    let headline = clip(&text("headline"), HEADLINE_CHARS);
    let narrative = clip(&text("narrative"), NARRATIVE_CHARS);
    Ok(
        (!headline.is_empty() || !narrative.is_empty()).then_some(Account {
            headline,
            narrative,
            written_by: report.model,
            generated_us: report.generated_us,
        }),
    )
}

/// The lines a connected AI is given at the start of a session right now:
/// the same functions the context packet uses, with no focus.
#[must_use]
pub fn ai_knows(
    store: &SqlCipherBrainStore,
    tz: i32,
    now_us: u64,
    hook_installed: bool,
) -> AiKnows {
    AiKnows {
        recent_work: query::recent_work(store, now_us)
            .iter()
            .map(query::RecentWork::template)
            .collect(),
        about_you: query::about_you(store, tz, now_us, None)
            .into_iter()
            .map(|p| AboutLine {
                id: p.id,
                text: clip(&p.text, query::STATEMENT_CHARS),
            })
            .collect(),
        hook_installed,
    }
}

fn round_down_hour(ts: u64, day_start: u64) -> u64 {
    if ts <= day_start {
        return day_start;
    }
    day_start + (ts - day_start) / HOUR_US * HOUR_US
}

fn round_up_hour(ts: u64, day_start: u64) -> u64 {
    let down = round_down_hour(ts, day_start);
    if down == ts {
        ts
    } else {
        down + HOUR_US
    }
}

/// Build the day overview for `date` (today when `None`) in `tz`.
///
/// # Errors
/// Store failures, or a malformed date.
#[allow(clippy::too_many_lines)] // the day, then each part of the page in order
pub fn overview(
    store: &SqlCipherBrainStore,
    date: Option<&str>,
    tz: i32,
    now_us: u64,
    env: &OverviewEnv,
) -> Result<Overview, StoreError> {
    let today = local_date_string(i64::try_from(now_us / 1_000_000).unwrap_or(0), tz);
    let date = date.map_or_else(|| today.clone(), str::to_owned);
    let (day_start, day_end) = query::day_bounds(&date, tz)?;
    let is_today = date == today;

    let (heads, mut truncated) = heads_in(store, day_start, day_end)?;
    let focus: Vec<EventHead> = heads.iter().filter(|h| is_focus(h)).cloned().collect();
    let notes = store.session_notes_in_range(day_start, day_end)?;
    let mut searches = store.search_queries_in_range(day_start, day_end, usize::MAX)?;
    let newest_first: Vec<SearchRecord> = searches.clone();
    searches.reverse();

    // Each session with its newest focus moment.
    let mut shaped: Vec<(Shaped, u64)> = drafts(&focus, &notes, day_start, day_end, now_us)
        .iter()
        .filter_map(|draft| shape(store, draft, &searches).map(|s| (s, draft.last_us)))
        .collect();
    if shaped.len() > MAX_BLOCKS {
        shaped.drain(..shaped.len() - MAX_BLOCKS);
        truncated = true;
    }
    for index in 1..shaped.len() {
        let previous_end = shaped[index - 1].0.block.end_us;
        shaped[index].0.block.touches_previous =
            shaped[index].0.block.start_us < previous_end + observe::SESSION_GAP_US;
    }

    // Right now.
    let mut now = Now {
        state: "none".into(),
        ..Now::default()
    };
    if is_today {
        if let Some((last, last_saved)) = shaped.last() {
            let going =
                now_us.saturating_sub(*last_saved) < observe::SESSION_GAP_US && env.remembering;
            let mut since = last.block.start_us;
            if going {
                for pair in shaped.windows(2).rev() {
                    if !pair[1].0.block.touches_previous {
                        break;
                    }
                    since = pair[0].0.block.start_us;
                }
            }
            now = now_card(
                &last.block,
                *last_saved,
                Some(last.block.id),
                going.then_some(since),
            );
        } else {
            let from = now_us.saturating_sub(LOOKBACK_US).min(day_start);
            let (earlier, _) = heads_in(store, from, day_start)?;
            let earlier_focus: Vec<EventHead> = earlier.into_iter().filter(is_focus).collect();
            let earlier_notes = store.session_notes_in_range(from, day_start)?;
            let earlier_drafts = drafts(&earlier_focus, &earlier_notes, from, day_start, now_us);
            if let Some(draft) = earlier_drafts.last() {
                if let Some(shaped_earlier) = shape(store, draft, &[]) {
                    now = now_card(&shaped_earlier.block, draft.last_us, None, None);
                }
            }
        }
    }
    if now.state == "in_progress" {
        if let Some((last, _)) = shaped.last_mut() {
            last.block.in_progress = true;
        }
    }
    let shaped: Vec<Shaped> = shaped.into_iter().map(|(s, _)| s).collect();

    let blocks: Vec<Block> = shaped.iter().map(|s| s.block.clone()).collect();
    let gaps: Vec<Span> = blocks
        .windows(2)
        .filter(|pair| pair[1].start_us >= pair[0].end_us + observe::SESSION_GAP_US)
        .map(|pair| Span {
            start_us: pair[0].end_us,
            end_us: pair[1].start_us,
        })
        .collect();
    let strip = match (blocks.first(), blocks.last()) {
        (Some(first), Some(last)) => {
            let mut start = round_down_hour(first.start_us, day_start);
            let reach = if is_today {
                last.end_us.max(now_us.min(day_end))
            } else {
                last.end_us
            };
            let mut end = round_up_hour(reach, day_start).min(day_end);
            if end - start < MIN_STRIP_US {
                start = end.saturating_sub(MIN_STRIP_US).max(day_start);
            }
            if end - start < MIN_STRIP_US {
                end = (start + MIN_STRIP_US).min(day_end);
            }
            Some(Span {
                start_us: start,
                end_us: end,
            })
        }
        _ => None,
    };
    let mut legend: Vec<(WorkKind, u64)> = Vec::new();
    for block in &blocks {
        let kind = WorkKind::ALL
            .into_iter()
            .find(|k| k.as_str() == block.kind)
            .unwrap_or(WorkKind::Other);
        match legend.iter_mut().find(|(k, _)| *k == kind) {
            Some(entry) => entry.1 += block.end_us - block.start_us,
            None => legend.push((kind, block.end_us - block.start_us)),
        }
    }
    legend.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));

    // The day's measured time, from activity samples (or moments).
    let mut activity = store.activity_intervals_in_range(day_start, day_end)?;
    activity.retain(|a| !a.app_bundle_id.as_deref().is_some_and(apps::is_noise));
    let events: Vec<ObservedEvent> = heads.iter().map(observed).collect();
    let breakdown = day::breakdown(
        &date,
        day_start,
        day_end,
        tz,
        &activity,
        &[],
        &events,
        Vec::new(),
        &notes,
    );
    let facts: Vec<Fact> = [
        active_fact(&breakdown),
        longest_fact(&breakdown, &blocks),
        returned_fact(&shaped),
        searched_fact(newest_first.len()),
    ]
    .into_iter()
    .flatten()
    .collect();

    Ok(Overview {
        version: VERSION,
        date: date.clone(),
        is_today,
        now_us,
        tz_offset_secs: tz,
        day_start_us: day_start,
        day_end_us: day_end,
        basis: breakdown.basis.clone(),
        truncated,
        model_status: ModelStatus::read(store),
        now,
        strip,
        kinds: legend
            .into_iter()
            .map(|(k, us)| LegendKind {
                kind: k.as_str().into(),
                kind_label: k.label().into(),
                duration_us: us,
            })
            .collect(),
        blocks,
        gaps,
        facts,
        searches: newest_first
            .iter()
            .take(DAY_SEARCHES)
            .map(Search::from)
            .collect(),
        account: account_of(store, &date)?,
        ai_knows: ai_knows(store, tz, now_us, env.hook_installed),
    })
}

fn now_card(block: &Block, last_saved_us: u64, block_id: Option<u64>, since: Option<u64>) -> Now {
    Now {
        state: if since.is_some() {
            "in_progress"
        } else {
            "last_saved"
        }
        .into(),
        since_us: since,
        start_us: Some(block.start_us),
        last_saved_us: Some(last_saved_us),
        block_id,
        title: Some(block.title.clone()),
        written_by: Some(block.written_by.clone()),
        app_name: block.reopen.as_ref().map(|r| r.app_name.clone()),
        open_event_id: Some(block.open_event_id),
        reopen: block.reopen.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::understanding::{NewProposition, PropositionKind};
    use mci_brain::{BrainStore, Event, EventId, EventSource};
    use mci_core::crypto::DbKey;

    const MIN: u64 = MINUTE_US;
    /// 2027-01-15 00:00 UTC; the tests use offset 0.
    const DAY0: u64 = 1_800_000_000_000_000 - 1_800_000_000_000_000 % DAY_US_TEST;
    const DAY_US_TEST: u64 = 86_400_000_000;

    fn store() -> (tempfile::TempDir, SqlCipherBrainStore) {
        let dir = tempfile::tempdir().unwrap();
        let store =
            SqlCipherBrainStore::new(&dir.path().join("b.sqlite"), &DbKey::from_bytes([5; 32]))
                .unwrap();
        (dir, store)
    }

    fn put(
        store: &SqlCipherBrainStore,
        ts_us: u64,
        app: &str,
        title: &str,
        url: Option<&str>,
    ) -> i64 {
        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(app.into()),
            window_title: Some(title.into()),
            url: url.map(str::to_owned),
            text: "synthetic text".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        };
        let source = if url.is_some() {
            EventSource::BrowserPage
        } else {
            EventSource::ScreenOcr
        };
        i64::try_from(store.put_event_with_source(&event, source).unwrap().0).unwrap()
    }

    /// One moment a minute in `app`/`title` from `from` for `minutes`.
    fn run(
        store: &SqlCipherBrainStore,
        from: u64,
        minutes: u64,
        app: &str,
        title: &str,
    ) -> Vec<i64> {
        (0..minutes)
            .map(|m| put(store, from + m * MIN, app, title, None))
            .collect()
    }

    fn env(remembering: bool) -> OverviewEnv {
        OverviewEnv {
            remembering,
            hook_installed: false,
        }
    }

    fn day(store: &SqlCipherBrainStore, now: u64, remembering: bool) -> Overview {
        overview(store, None, 0, now, &env(remembering)).unwrap()
    }

    fn texts(o: &Overview) -> Vec<String> {
        let mut out: Vec<String> = o.facts.iter().map(|f| f.text.template.clone()).collect();
        for block in &o.blocks {
            out.extend(block.sentences.iter().map(|s| s.text.template.clone()));
            out.push(block.title.clone());
        }
        out
    }

    #[test]
    fn a_session_in_progress_is_right_now_and_has_no_note() {
        let (_dir, store) = store();
        let start = DAY0 + 10 * 60 * MIN;
        run(&store, start, 20, "com.apple.Notes", "Launch plan");
        let now = start + 20 * MIN;
        let o = day(&store, now, true);
        assert_eq!(o.blocks.len(), 1);
        let block = &o.blocks[0];
        assert!(block.provisional && block.in_progress);
        assert_eq!(block.title, "Launch plan");
        assert_eq!(block.written_by, "measured");
        assert_eq!(o.now.state, "in_progress");
        assert_eq!(o.now.since_us, Some(start));
        assert_eq!(o.now.block_id, Some(block.id));
        assert_eq!(o.now.last_saved_us, Some(start + 19 * MIN));
        assert_eq!(o.now.app_name.as_deref(), Some("Notes"));
        assert_eq!(
            o.now.reopen.as_ref().map(|r| r.app_name.as_str()),
            Some("Notes")
        );
    }

    #[test]
    fn five_quiet_minutes_turn_right_now_into_last_saved() {
        let (_dir, store) = store();
        let start = DAY0 + 10 * 60 * MIN;
        run(&store, start, 20, "com.apple.Notes", "Launch plan");
        let o = day(&store, start + 19 * MIN + 5 * MIN, true);
        assert_eq!(o.now.state, "last_saved");
        assert_eq!(o.now.since_us, None);
        assert!(!o.blocks[0].in_progress);
        // A past day has no Right now card.
        let past = overview(
            &store,
            Some("2027-01-15"),
            0,
            DAY0 + 3 * DAY_US_TEST,
            &env(true),
        )
        .unwrap();
        assert!(!past.is_today);
        assert_eq!(past.now.state, "none");
        assert_eq!(past.blocks.len(), 1);
    }

    #[test]
    fn a_paused_or_skipped_front_app_is_never_in_progress() {
        let (dir, store) = store();
        let start = DAY0 + 10 * 60 * MIN;
        run(&store, start, 10, "com.apple.Notes", "Launch plan");
        let now = start + 10 * MIN;
        // No receipt, a stale one, a skipped window, a block: never "Now".
        let receipt = dir.path().join("capture-status.json");
        let stamp = |us: u64| crate::wall_clock::format_unix_ms(u128::from(us / 1_000));
        let write = |updated_us: u64, suppression: Option<&str>, blocked: Option<&str>| {
            let status = serde_json::json!({
                "schema_version": 1, "updated_at": stamp(updated_us), "last_stored_frame_at": null,
                "stored_frame_count": 1, "stored_screenshot_count": 0,
                "suppression_reason": suppression, "blocked_reason": blocked,
            });
            std::fs::write(&receipt, status.to_string()).unwrap();
        };
        assert!(!remembering_now(&receipt, now), "no receipt");
        write(now - 10 * 1_000_000, None, None);
        assert!(remembering_now(&receipt, now));
        write(now - 10 * 60 * 1_000_000, None, None);
        assert!(
            !remembering_now(&receipt, now),
            "paused: the receipt stops being written"
        );
        write(now - 10 * 1_000_000, Some("excluded_app"), None);
        assert!(
            !remembering_now(&receipt, now),
            "an excluded app is in front"
        );
        write(now - 10 * 1_000_000, None, Some("capture_disabled"));
        assert!(!remembering_now(&receipt, now));
        let db = dir.path().join("b.sqlite");
        write(now - 10 * 1_000_000, Some("secure_input"), None);
        let o = overview(
            &store,
            None,
            0,
            now,
            &OverviewEnv::read(&db, None, None, now),
        )
        .unwrap();
        assert_eq!(o.now.state, "last_saved");
        assert!(o.blocks.iter().all(|b| !b.in_progress));
    }

    #[test]
    fn blocks_take_their_kind_from_window_time_and_gaps_are_listed() {
        let (_dir, store) = store();
        let a = DAY0 + 9 * 60 * MIN;
        run(&store, a, 12, "com.microsoft.VSCode", "tax.rs — shop");
        run(
            &store,
            a + 12 * MIN,
            5,
            "com.apple.Safari",
            "Rounding · Dev Notes",
        );
        // A gap of 20 minutes, then a browser tab that is mail.
        let b = a + 37 * MIN;
        for m in 0..10 {
            put(
                &store,
                b + m * MIN,
                "com.google.Chrome",
                "Inbox (3)",
                Some("https://mail.google.com/mail/u/0"),
            );
        }
        let o = day(&store, b + 60 * MIN, false);
        assert_eq!(o.blocks.len(), 2);
        assert_eq!(o.blocks[0].kind, "code");
        assert_eq!(o.blocks[0].kinds[0].kind, "code");
        assert_eq!(o.blocks[0].kinds[1].kind, "research");
        assert!(!o.blocks[0].mixed);
        assert_eq!(
            o.blocks[1].kind, "communication",
            "a mail tab is communication"
        );
        assert_eq!(
            o.gaps,
            vec![Span {
                start_us: o.blocks[0].end_us,
                end_us: o.blocks[1].start_us
            }]
        );
        assert!(!o.blocks[1].touches_previous);
        let legend: Vec<&str> = o.kinds.iter().map(|k| k.kind.as_str()).collect();
        assert_eq!(
            legend,
            vec!["code", "communication"],
            "the legend comes from the sessions"
        );
        // 09:00 to now (10:37) is under four hours: the strip starts earlier.
        let strip = o.strip.unwrap();
        assert_eq!(
            (strip.start_us, strip.end_us),
            (DAY0 + 7 * 60 * MIN, DAY0 + 11 * 60 * MIN)
        );
        assert!(strip.start_us >= o.day_start_us && strip.end_us <= o.day_end_us);
    }

    #[test]
    fn the_thirty_minute_cap_makes_touching_sessions_not_gaps() {
        let (_dir, store) = store();
        let start = DAY0 + 9 * 60 * MIN;
        run(&store, start, 70, "com.apple.Notes", "Pricing page draft");
        let o = day(&store, start + 3 * 60 * MIN, false);
        assert_eq!(o.blocks.len(), 3);
        assert!(o.blocks[1].touches_previous && o.blocks[2].touches_previous);
        assert!(o.gaps.is_empty());
    }

    #[test]
    fn a_stored_note_lays_its_title_and_what_it_noticed_over_its_moments() {
        let (_dir, store) = store();
        let start = DAY0 + 9 * 60 * MIN;
        let ids = run(&store, start, 20, "com.apple.Notes", "Pricing page draft");
        let segments = serde_json::json!({
            "signals": { "back_and_forth": [], "reworded_searches": 0 },
            "segments": [{ "start_us": start, "end_us": start + 19 * MIN, "app": "com.apple.Notes", "name": "Notes",
                "title": "Pricing page draft", "host": null, "activity": "typing", "keys": 9, "events": ids }],
        });
        let note = |title: &str, beneath: &str, model: &str| SessionNote {
            start_us: start,
            end_us: start + 19 * MIN,
            title: title.into(),
            surface: "You drafted plan names.".into(),
            beneath: beneath.into(),
            signals: segments.to_string(),
            event_count: 20,
            generated_us: start + 25 * MIN,
            model: model.into(),
        };
        store
            .put_session_note(&note(
                "Plan names",
                "You seemed stuck on the price. You kept the shortest name.",
                "apple-foundation-models",
            ))
            .unwrap();
        let o = day(&store, start + 60 * MIN, false);
        let block = &o.blocks[0];
        assert!(!block.provisional);
        assert_eq!(block.title, "Plan names");
        assert_eq!(block.written_by, "apple-foundation-models");
        assert_eq!(
            block.noticed.as_ref().unwrap().text,
            "You kept the shortest name.",
            "the judging sentence is dropped"
        );
        // A title that judges is replaced by the measured one; a measured note is never shown.
        store
            .put_session_note(&note(
                "Distracted pricing",
                "Nothing notable.",
                "apple-foundation-models",
            ))
            .unwrap();
        let o = day(&store, start + 60 * MIN, false);
        assert_eq!(
            (o.blocks[0].title.as_str(), o.blocks[0].written_by.as_str()),
            ("Pricing page draft", "measured")
        );
        assert!(o.blocks[0].noticed.is_none());
        store
            .put_session_note(&note(
                "Notes — Pricing page draft",
                "Paused 4 min with no input.",
                "measured",
            ))
            .unwrap();
        let o = day(&store, start + 60 * MIN, false);
        assert_eq!(o.blocks[0].title, "Pricing page draft");
        assert!(o.blocks[0].noticed.is_none());
    }

    fn draft_with(segments: &[(&str, &str)]) -> Draft {
        let segs: Vec<StoredSegment> = segments
            .iter()
            .enumerate()
            .map(|(i, (app, title))| StoredSegment {
                start_us: i as u64 * MIN,
                end_us: (i as u64 + 1) * MIN,
                app: (*app).into(),
                title: Some((*title).into()),
                host: None,
                events: vec![i64::try_from(i).unwrap()],
            })
            .collect();
        Draft {
            own_start_us: 0,
            start_us: 0,
            end_us: segs.last().map_or(0, |s| s.end_us),
            last_us: 0,
            note: None,
            segments: segs,
            newest: None,
        }
    }

    /// No session says how often the person switched windows or reworded a
    /// search, however often they did (RULINGS W4, SPEC 3.1): the overview
    /// carries neither `switched_between` nor `reworded_search`.
    #[test]
    fn no_session_says_a_sentence_that_counts() {
        let figma = ("com.figma.Desktop", "Trailhead pricing v3");
        let notes = ("com.apple.Notes", "Pricing page draft");
        let alternate = |n: usize, a, b| {
            (0..=n)
                .map(|i| if i % 2 == 0 { a } else { b })
                .collect::<Vec<_>>()
        };
        for n in [3usize, 4, 5, 10, 40] {
            assert!(
                block_sentences(&draft_with(&alternate(n, figma, notes))).is_empty(),
                "{n} switches"
            );
        }
    }

    /// A stored note whose signals count back-and-forth and reworded
    /// searches, as notes written before this release do, still gives a
    /// session with no sentence, and neither count reaches the overview.
    #[test]
    fn stored_counts_never_reach_the_overview() {
        let (_dir, store) = store();
        let start = DAY0 + 9 * 60 * MIN;
        let ids = run(
            &store,
            start,
            20,
            "com.figma.Desktop",
            "Trailhead pricing v3",
        );
        let signals = serde_json::json!({
            "signals": {
                "back_and_forth": [["Figma — Trailhead pricing v3", "Notes — Pricing page draft", 9]],
                "reworded_searches": 4
            },
            "segments": [{ "start_us": start, "end_us": start + 19 * MIN, "app": "com.figma.Desktop",
                "name": "Figma", "title": "Trailhead pricing v3", "host": null, "events": ids }],
        });
        store
            .put_session_note(&SessionNote {
                start_us: start,
                end_us: start + 19 * MIN,
                title: "Figma — Trailhead pricing v3".into(),
                surface: "Working in Figma".into(),
                beneath: String::new(),
                signals: signals.to_string(),
                event_count: 20,
                generated_us: start + 25 * MIN,
                model: "measured".into(),
            })
            .unwrap();
        let o = day(&store, start + 60 * MIN, false);
        assert!(!o.blocks.is_empty());
        assert!(o.blocks.iter().all(|b| b.sentences.is_empty()));
        let json = serde_json::to_string(&o).unwrap();
        for said in [
            "switched_between",
            "reworded_search",
            "You switched",
            "You reworded",
        ] {
            assert!(!json.contains(said), "{said} reached the overview");
        }
    }

    #[test]
    fn no_template_contains_a_judgement_word_or_a_raw_count() {
        let mut templates: Vec<String> = Vec::new();
        for n in [2usize, 3, 4, 9, 10, 12] {
            templates.push(format!(
                "You came back to “Pricing page draft” {}.",
                times_word(n)
            ));
            templates.extend(searched_fact(n).map(|f| f.text.template));
        }
        templates.extend(searched_fact(1).map(|f| f.text.template));
        templates.push("Active {active}, {first} to {last}.".into());
        templates.push("Active about {active}, {first} to {last}.".into());
        for kind in WorkKind::ALL {
            let mut breakdown = day::breakdown(
                "2027-01-15",
                DAY0,
                DAY0 + DAY_US_TEST,
                0,
                &[],
                &[],
                &[],
                Vec::new(),
                &[],
            );
            breakdown.focus_blocks = vec![day::FocusBlock {
                start_us: DAY0,
                end_us: DAY0 + 50 * MIN,
                kind,
                app: "Notes".into(),
            }];
            templates.extend(longest_fact(&breakdown, &[]).map(|f| f.text.template));
        }
        templates.push(RecentWorkProbe::line());
        for template in &templates {
            assert!(template_passes_word_check(template), "{template}");
            let lower = template.to_lowercase();
            for counted in ["key", "click", "scroll", "switches", "%", "keystroke"] {
                assert!(!lower.contains(counted), "{template} mentions {counted}");
            }
            // Counts under ten are words; times and durations are placeholders.
            assert!(
                !template.chars().any(|c| c.is_ascii_digit())
                    || template.contains("10")
                    || template.contains("12"),
                "{template}"
            );
            let chars: Vec<char> = template.chars().collect();
            assert!(
                !chars
                    .windows(3)
                    .any(|w| w[0].is_ascii_digit() && w[1] == ':' && w[2].is_ascii_digit()),
                "no clock time in {template}"
            );
        }
        assert!(
            !template_passes_word_check("You only switched once."),
            "templates are held to the long list"
        );
        assert!(
            passes_word_check("You only switched once."),
            "model prose is not"
        );
    }

    /// The fixed words of a recent work line.
    struct RecentWorkProbe;
    impl RecentWorkProbe {
        fn line() -> String {
            query::RecentWork {
                start_us: 0,
                end_us: 1,
                title: "Title".into(),
                detail: Some("Detail.".into()),
            }
            .template()
            .template
        }
    }

    #[test]
    fn the_word_check_matches_whole_words_and_drops_only_failing_sentences() {
        assert!(
            passes_word_check("You adjusted the commonly used layout."),
            "substrings do not match"
        );
        assert!(!passes_word_check("You seemed unsure."));
        assert!(!passes_word_check("It was too much."));
        assert!(passes_word_check("It was too late, much later."));
        assert!(!passes_word_check(
            "You paused for 3 minutes between searches."
        ));
        assert!(!passes_word_check("You made 12 clicks in Figma."));
        assert!(passes_word_check("You clicked through the checkout."));
        assert_eq!(
            model_prose("You wrote tests. You probably got frustrated! Then you shipped it."),
            "You wrote tests. Then you shipped it."
        );
        assert_eq!(
            model_prose("Version 2.5 shipped. You should rest."),
            "Version 2.5 shipped."
        );
    }

    #[test]
    fn titles_are_cleaned_as_a_person_would_write_them() {
        assert_eq!(clean_title("(3) Inbox - Slack", "Slack"), "Inbox");
        assert_eq!(clean_title("● query.rs — Code", "Code"), "query.rs");
        assert_eq!(clean_title("  Pricing | Notes ", "Notes"), "Pricing");
        assert_eq!(clean_title("(x) Draft", "Notes"), "(x) Draft");
        let long = "a".repeat(70);
        assert_eq!(clean_title(&long, ""), format!("{}…", "a".repeat(60)));
    }

    #[test]
    fn facts_are_at_most_four_and_absent_without_support() {
        let (_dir, store) = store();
        // Three runs on one title, separated by gaps, with a search.
        let mut at = DAY0 + 9 * 60 * MIN;
        for _ in 0..3 {
            run(&store, at, 10, "com.apple.Notes", "Pricing page draft");
            run(&store, at + 10 * MIN, 5, "com.microsoft.VSCode", "tax.rs");
            at += 60 * MIN;
        }
        let searched = put(
            &store,
            at,
            "com.google.Chrome",
            "rust rounding - Google Search",
            Some("https://www.google.com/search?q=rust+rounding"),
        );
        store.backfill_search_queries(0, 100).unwrap();
        let o = day(&store, at + 60 * MIN, false);
        let ids: Vec<&str> = o.facts.iter().map(|f| f.id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["active", "returned", "searched"],
            "no 25-minute run, so no longest"
        );
        let returned = &o.facts[1];
        assert_eq!(
            returned.text.template,
            "You came back to “Pricing page draft” twice."
        );
        assert_eq!(returned.action.as_ref().unwrap().block_ids.len(), 3);
        assert_eq!(o.facts[2].text.template, "You looked up one thing.");
        assert_eq!(o.searches[0].event_id, searched);
        assert_eq!(
            o.facts[0].text.template, "Active about {active}, {first} to {last}.",
            "estimated from moments"
        );
        assert!(o.facts.len() <= 4);
    }

    #[test]
    fn an_empty_day_has_no_broken_text() {
        let (_dir, store) = store();
        let o = day(&store, DAY0 + 10 * 60 * MIN, true);
        assert!(
            o.blocks.is_empty()
                && o.facts.is_empty()
                && o.searches.is_empty()
                && o.kinds.is_empty()
                && o.gaps.is_empty()
        );
        assert!(o.strip.is_none() && o.account.is_none());
        assert_eq!(o.now.state, "none");
        assert_eq!(o.model_status.state, "unknown");
        let json = serde_json::to_value(&o).unwrap();
        assert!(json.get("open_loops").is_none());
        assert_eq!(json["now"]["title"], serde_json::Value::Null);
    }

    #[test]
    fn last_night_is_last_saved_when_today_is_empty() {
        let (_dir, store) = store();
        let evening = DAY0 - 2 * 60 * MIN;
        run(&store, evening, 15, "com.apple.Notes", "Launch plan");
        let o = day(&store, DAY0 + 7 * 60 * MIN, true);
        assert!(o.blocks.is_empty());
        assert_eq!(o.now.state, "last_saved");
        assert_eq!(o.now.block_id, None);
        assert_eq!(o.now.last_saved_us, Some(evening + 14 * MIN));
    }

    #[test]
    fn overview_is_complete_without_the_model() {
        let (_dir, store) = store();
        let start = DAY0 + 9 * 60 * MIN;
        for m in 0..40 {
            let (app, title) = if (m / 5) % 2 == 0 {
                ("com.figma.Desktop", "Trailhead pricing v3")
            } else {
                ("com.apple.Notes", "Pricing page draft")
            };
            put(&store, start + m * MIN, app, title, None);
        }
        let e = put(
            &store,
            start + 41 * MIN,
            "com.apple.Notes",
            "Pricing page draft",
            None,
        );
        let id = store
            .insert_proposition(
                &NewProposition {
                    text: "Sam is redesigning the pricing page.".into(),
                    reasoning: String::new(),
                    kind: PropositionKind::Project,
                    confidence: 0.8,
                    decay: 0.3,
                    model: "t".into(),
                },
                &[e],
                start,
            )
            .unwrap();
        let o = day(&store, start + 3 * 60 * MIN, false);
        assert_eq!(o.model_status.state, "unknown");
        assert!(o.account.is_none());
        assert!(!o.blocks.is_empty() && !o.facts.is_empty());
        assert!(o
            .blocks
            .iter()
            .all(|b| !b.title.is_empty() && b.written_by == "measured"));
        assert!(
            o.blocks.iter().all(|b| b.sentences.is_empty()),
            "a session never counts the person's switches"
        );
        assert!(
            o.ai_knows.about_you.is_empty(),
            "a line seen in one session goes to no AI tool"
        );
        assert!(store.confirm_proposition(id, start).unwrap());
        let o = day(&store, start + 3 * 60 * MIN, false);
        assert_eq!(
            o.ai_knows
                .about_you
                .iter()
                .map(|a| a.id)
                .collect::<Vec<_>>(),
            vec![id],
            "once confirmed, it does"
        );
        assert!(!o.ai_knows.hook_installed);
        for text in texts(&o) {
            assert!(!text.is_empty());
        }
        // Model status, once the worker has checked.
        ModelStatus::from_check(
            &Err(MindCallError::Unavailable("apple_intelligence_off".into())),
            start,
        )
        .write(&store)
        .unwrap();
        let o = day(&store, start + 3 * 60 * MIN, false);
        assert_eq!(
            (
                o.model_status.state.as_str(),
                o.model_status.reason.as_deref()
            ),
            ("unavailable", Some("apple_intelligence_off"))
        );
        store
            .set_understanding_state(ModelStatus::KEY, "{\"state\":\"warming\"}")
            .unwrap();
        assert_eq!(
            ModelStatus::read(&store),
            ModelStatus::unknown(),
            "an unknown state reads as unknown"
        );
    }

    fn put_with_screenshot(
        store: &SqlCipherBrainStore,
        ts_us: u64,
        app: &str,
        title: &str,
        source: EventSource,
        n: u8,
    ) -> i64 {
        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(app.into()),
            window_title: Some(title.into()),
            url: None,
            text: "synthetic text".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: Some(format!("{n:02x}").repeat(32)),
            tab_id: None,
            embedding: None,
        };
        i64::try_from(store.put_event_with_source(&event, source).unwrap().0).unwrap()
    }

    #[test]
    fn the_screenshot_is_the_keyframe_nearest_the_middle() {
        let (_dir, store) = store();
        let start = DAY0 + 9 * 60 * MIN;
        // Notes held for 20 minutes (the longest window), then Figma for 6.
        for m in 0..20 {
            let (title, ts) = ("Pricing page draft", start + m * MIN);
            match m {
                3 => put_with_screenshot(
                    &store,
                    ts,
                    "com.apple.Notes",
                    title,
                    EventSource::ScreenOcr,
                    1,
                ),
                12 => put_with_screenshot(
                    &store,
                    ts,
                    "com.apple.Notes",
                    title,
                    EventSource::ScreenOcr,
                    2,
                ),
                _ => put(&store, ts, "com.apple.Notes", title, None),
            };
        }
        let figma = put_with_screenshot(
            &store,
            start + 20 * MIN,
            "com.figma.Desktop",
            "Trailhead pricing v3",
            EventSource::ScreenOcr,
            3,
        );
        run(
            &store,
            start + 21 * MIN,
            5,
            "com.figma.Desktop",
            "Trailhead pricing v3",
        );
        // A window beside Notes, right at the middle of its time, with a
        // screenshot: another app, so never chosen.
        let beside = put_with_screenshot(
            &store,
            start + 10 * MIN,
            "com.tinyspeck.slackmacgap",
            "#design",
            EventSource::ScreenContext,
            4,
        );
        let o = day(&store, start + 3 * 60 * MIN, false);
        assert_eq!(o.blocks.len(), 1);
        let shown = o.blocks[0].screenshot_event_id.expect("a screenshot");
        let heads = store.event_heads(&[shown]).unwrap();
        assert_eq!(
            heads[0].ts_us,
            start + 12 * MIN,
            "the Notes screenshot nearest the middle of its own time"
        );
        assert_ne!(shown, figma);
        assert_ne!(shown, beside);
        // With no screenshot of the longest window, none of another app is shown.
        let (_dir2, other) = self::store();
        run(&other, start, 20, "com.apple.Notes", "Pricing page draft");
        put_with_screenshot(
            &other,
            start + 10 * MIN,
            "com.tinyspeck.slackmacgap",
            "#design",
            EventSource::ScreenContext,
            5,
        );
        assert_eq!(
            day(&other, start + 3 * 60 * MIN, false).blocks[0].screenshot_event_id,
            None
        );
    }

    #[test]
    fn an_error_on_screen_is_never_a_sentence() {
        // The error sentence was cut (RULINGS I3): a code session whose
        // stored signals hold an error says nothing about it.
        let (_dir, store) = store();
        let start = DAY0 + 9 * 60 * MIN;
        let ids = run(&store, start, 20, "com.microsoft.VSCode", "tax.rs — shop");
        let signals = serde_json::json!({
            "signals": { "back_and_forth": [], "reworded_searches": 0, "errors": ["error[E0308]: mismatched types"],
                "pauses": [[start, 240_000_000u64, "Code — tax.rs — shop"]], "keys": 900, "clicks": 40, "scrolls": 12 },
            "segments": [{ "start_us": start, "end_us": start + 19 * MIN, "app": "com.microsoft.VSCode", "name": "Code",
                "title": "tax.rs — shop", "host": null, "activity": "typing", "keys": 900, "events": ids }],
        });
        store
            .put_session_note(&SessionNote {
                start_us: start,
                end_us: start + 19 * MIN,
                title: "Code — tax.rs — shop".into(),
                surface: "Typing in Code (tax.rs — shop)".into(),
                beneath:
                    "Paused 4 min with no input in Code — tax.rs — shop; had an error on screen."
                        .into(),
                signals: signals.to_string(),
                event_count: 20,
                generated_us: start + 25 * MIN,
                model: "measured".into(),
            })
            .unwrap();
        let o = day(&store, start + 60 * MIN, false);
        assert_eq!(o.blocks[0].kind, "code");
        assert!(
            o.blocks[0].sentences.is_empty(),
            "{:?}",
            o.blocks[0].sentences
        );
        assert!(o.blocks[0].noticed.is_none());
        let json = serde_json::to_string(&o).unwrap().to_lowercase();
        for said in ["error", "paus", "keys\":", "clicks"] {
            assert!(!json.contains(said), "{said} reached the overview");
        }
    }

    #[test]
    fn templates_fill_in_plain_text_and_keep_escaped_braces() {
        let t = Template::new("Active {active}, {first} to {last}. {{x}} {missing}")
            .duration("active", 5 * HOUR_US + 30 * MIN)
            .time("first", DAY0 + 9 * HOUR_US + 2 * MIN)
            .time("last", DAY0 + 18 * HOUR_US);
        assert_eq!(t.fill(0), "Active 5h 30m, 09:02 to 18:00. {x} {missing}");
        assert_eq!(escape_braces("a {b} c"), "a {{b}} c");
    }
}
