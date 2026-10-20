//! What the `work` read is made of: the sessions the understanding worker
//! noted, and the stretch after the last note, as windows held in front;
//! what each window was about (`mci_brain::subject`); and from those, the
//! person's items, the pages they read, and which item each moment is part
//! of (SPEC 3.12).
//!
//! Only window titles, hosts, app ids and moment ids are read, never what a
//! moment said, with two exceptions that never leave this module: a Notes
//! window's first line, which is its note's name (the caption rule), and the
//! file paths a code project's moments showed, for its folder guess.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use mci_brain::apps::{self, WorkKind};
use mci_brain::caption::{self, Moment};
use mci_brain::reading::{screen_reading, TERMINAL_APPS};
use mci_brain::subject::{
    conversation_of, folded, identity, subject_of_at, terminal_folder_at, Subject, SubjectKind,
};
use mci_brain::understanding::{EventHead, ObservedEvent};
use mci_brain::{EventSource, SqlCipherBrainStore, StoreError};
use mci_core::crypto::DbKey;

use crate::understanding::observe;
use crate::understanding::overview::stored_segments;

pub(crate) const DAY_US: u64 = 86_400_000_000;
/// Time in front that makes an item: 30 minutes in all (SPEC 2.3).
pub(crate) const ITEM_US: u64 = 30 * 60 * 1_000_000;
/// The sidebar's window, in days of use.
pub(crate) const FORTNIGHT_DAYS: usize = 14;
/// Ranking's window, in days of use.
pub(crate) const WEEK_DAYS: usize = 7;
/// How far back the stretch no note covers yet is read from moments.
const TAIL_US: u64 = 36 * 3_600_000_000;
/// The most moments that stretch reads.
const TAIL_LIMIT: usize = 50_000;
/// A Notes window's moments read for their first lines, at most.
const NOTES_SAMPLES: usize = 6;
/// Notes moments read in all, at most.
const NOTES_BUDGET: usize = 4_000;
/// What counts as open around the same time as an item.
const NEAR_US: u64 = 10 * 60 * 1_000_000;
/// A candidate in more than this share of sessions is open beside
/// everything (a calendar, an inbox, localhost), once there are enough
/// sessions to say so.
const EVERYWHERE_SHARE: f64 = 0.4;
const EVERYWHERE_MIN_SESSIONS: usize = 10;

/// One window held in front: a stretch of a session's note, or of the
/// moments after the last note.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Held {
    pub start_us: u64,
    pub end_us: u64,
    /// The app's bundle id.
    pub app: String,
    pub title: Option<String>,
    pub host: Option<String>,
    /// Its moments, oldest first.
    pub events: Vec<i64>,
    /// For Notes, the note's first line: its name.
    pub first_line: Option<String>,
}

impl Held {
    pub(crate) fn held_us(&self) -> u64 {
        self.end_us.saturating_sub(self.start_us)
    }

    /// Its newest moment.
    pub(crate) fn newest(&self) -> Option<i64> {
        self.events.last().copied()
    }
}

/// A work session: windows held in front, oldest first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Session {
    pub start_us: u64,
    pub end_us: u64,
    /// The local day it started on, in days since the epoch.
    pub day: i64,
    pub held: Vec<Held>,
}

/// What one held window was about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum About {
    /// A Working On candidate, by identity.
    Item { identity: String, subject: Subject },
    /// A web page: Web Pages' row, and a candidate for Seen alongside.
    Page { key: String, name: String },
    /// A search's results page.
    Search { key: String, query: String },
    /// A chat with an AI tool.
    AiChat { key: String, title: String },
    /// A conversation with people: only its name.
    Conversation { name: String },
    /// Nothing the window lists.
    Nothing,
}

/// Everything one item gathered across the sessions read.
#[derive(Debug, Clone, Default)]
pub(crate) struct ItemAcc {
    pub identity: String,
    pub kind: Option<SubjectKind>,
    /// Its name as last written.
    pub name: String,
    pub name_at: u64,
    pub total_us: u64,
    pub fortnight_us: u64,
    pub week_us: u64,
    pub week_days: BTreeSet<i64>,
    pub last_us: u64,
    /// Time held by app.
    pub apps: HashMap<String, u64>,
    /// (segment end, moment), to sort newest first.
    pub moments: Vec<(u64, i64)>,
    /// Files by folded name: (name, last, newest moment).
    pub files: HashMap<String, (String, u64, i64)>,
    /// The sessions it has time in, by index.
    pub sessions: BTreeSet<usize>,
    /// Its own windows' spans, for what was open around the same time.
    pub spans: Vec<(u64, u64)>,
    /// Folder paths its terminals' titles showed.
    pub terminal_paths: Vec<String>,
}

/// The read, before it is shaped as JSON.
pub(crate) struct Model {
    pub sessions: Vec<Session>,
    /// What each held window was about, by session and window.
    pub about: Vec<Vec<About>>,
    /// Every item that reached 30 minutes, ranked.
    pub items: Vec<(String, ItemAcc)>,
    /// The day of use that starts the last 14.
    pub fortnight_floor: i64,
}

/// Local day of `ts_us` for a time zone `tz` seconds east of UTC.
pub(crate) fn local_day(ts_us: u64, tz: i32) -> i64 {
    let secs = i64::try_from(ts_us / 1_000_000).unwrap_or(i64::MAX) + i64::from(tz);
    secs.div_euclid(86_400)
}

/// The id of the item with `identity`: a keyed hash, "w_" and 20 hex digits.
pub(crate) fn item_id(key: &DbKey, identity: &str) -> String {
    let digest = key.keyed_id("work-item", identity.as_bytes());
    digest[..10]
        .iter()
        .fold(String::from("w_"), |mut id, byte| {
            use std::fmt::Write as _;
            let _ = write!(id, "{byte:02x}");
            id
        })
}

/// Read and resolve every session from `from_us` to `now_us`.
pub(crate) fn build(
    store: &SqlCipherBrainStore,
    key: &DbKey,
    from_us: u64,
    now_us: u64,
    tz: i32,
    home: Option<&str>,
) -> Result<Model, StoreError> {
    let mut sessions = read_sessions(store, from_us, now_us, tz)?;
    name_notes(store, &mut sessions)?;
    let days: BTreeSet<i64> = sessions.iter().map(|s| s.day).collect();
    let recent: Vec<i64> = days.iter().rev().copied().collect();
    let floor = |count: usize| {
        recent
            .get(count - 1)
            .or(recent.last())
            .copied()
            .unwrap_or(i64::MAX)
    };
    let week_floor = floor(WEEK_DAYS);
    let fortnight_floor = floor(FORTNIGHT_DAYS);

    let about = resolve(&sessions, home);
    let mut accs: HashMap<String, ItemAcc> = HashMap::new();
    for (index, session) in sessions.iter().enumerate() {
        for (held, what) in session.held.iter().zip(&about[index]) {
            let About::Item { identity, subject } = what else {
                continue;
            };
            let acc = accs.entry(identity.clone()).or_insert_with(|| ItemAcc {
                identity: identity.clone(),
                kind: Some(subject.kind),
                ..ItemAcc::default()
            });
            let held_us = held.held_us();
            acc.total_us += held_us;
            if session.day >= fortnight_floor {
                acc.fortnight_us += held_us;
            }
            if session.day >= week_floor {
                acc.week_us += held_us;
                if held_us > 0 {
                    acc.week_days.insert(session.day);
                }
            }
            if held.end_us >= acc.name_at {
                acc.name.clone_from(&subject.name);
                acc.name_at = held.end_us;
            }
            acc.last_us = acc.last_us.max(held.end_us);
            *acc.apps.entry(held.app.clone()).or_default() += held_us;
            acc.moments
                .extend(held.events.iter().map(|id| (held.end_us, *id)));
            if let (Some(part), Some(newest)) = (&subject.part, held.newest()) {
                let entry = acc
                    .files
                    .entry(folded(part))
                    .or_insert_with(|| (part.clone(), 0, newest));
                if held.end_us >= entry.1 {
                    *entry = (part.clone(), held.end_us, newest);
                }
            }
            acc.sessions.insert(index);
            acc.spans.push((held.start_us, held.end_us));
            if TERMINAL_APPS.contains(&held.app.as_str()) {
                if let Some(path) = held
                    .title
                    .as_deref()
                    .and_then(|title| terminal_folder_at(title, home))
                    .and_then(|folder| folder.path)
                {
                    acc.terminal_paths.push(path);
                }
            }
        }
    }
    let mut items: Vec<(String, ItemAcc)> = accs
        .into_values()
        .filter(|acc| acc.total_us >= ITEM_US)
        .map(|mut acc| {
            acc.moments.sort_by(|a, b| b.cmp(a));
            acc.moments.dedup_by_key(|moment| moment.1);
            (item_id(key, &acc.identity), acc)
        })
        .collect();
    items.sort_by(|a, b| {
        b.1.week_us
            .cmp(&a.1.week_us)
            .then(b.1.last_us.cmp(&a.1.last_us))
            .then(a.1.identity.cmp(&b.1.identity))
    });
    Ok(Model {
        sessions,
        about,
        items,
        fortnight_floor,
    })
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// Sessions from the notes in `[from_us, now_us]`, then the moments after
/// the last note (at most the last 36 hours), split as the worker splits
/// them. Oldest first.
fn read_sessions(
    store: &SqlCipherBrainStore,
    from_us: u64,
    now_us: u64,
    tz: i32,
) -> Result<Vec<Session>, StoreError> {
    let mut sessions = Vec::new();
    let mut noted_through = 0u64;
    for note in store.session_notes_in_range(from_us, now_us.saturating_add(1))? {
        noted_through = noted_through.max(note.end_us);
        let Some(segments) = stored_segments(&note) else {
            continue;
        };
        let held: Vec<Held> = segments
            .into_iter()
            .filter(|segment| !apps::is_noise(&segment.app) && segment.app != "unknown")
            .map(|segment| Held {
                start_us: segment.start_us,
                end_us: segment.end_us.max(segment.start_us),
                app: segment.app,
                title: segment.title,
                host: segment.host,
                events: segment.events,
                first_line: None,
            })
            .collect();
        if !held.is_empty() {
            sessions.push(Session {
                start_us: note.start_us,
                end_us: note.end_us,
                day: local_day(note.start_us, tz),
                held,
            });
        }
    }
    let tail_from = noted_through
        .saturating_add(1)
        .max(now_us.saturating_sub(TAIL_US))
        .max(from_us);
    if tail_from <= now_us {
        let heads = store.event_heads_in_range(tail_from, now_us.saturating_add(1), TAIL_LIMIT)?;
        let events: Vec<ObservedEvent> = heads
            .iter()
            .filter(|head| is_focus(head) && !is_noise(head))
            .map(observed)
            .collect();
        for span in observe::split_sessions(&events) {
            let slice = &events[span.start..span.end];
            let held: Vec<Held> = observe::segments(slice, &[], span.end_us)
                .into_iter()
                .map(|segment| Held {
                    start_us: segment.start_us,
                    end_us: segment.end_us.max(segment.start_us),
                    host: segment.url.as_deref().and_then(apps::host_of),
                    app: segment.app,
                    title: segment.title,
                    events: segment.event_ids,
                    first_line: None,
                })
                .collect();
            if !held.is_empty() {
                sessions.push(Session {
                    start_us: span.start_us,
                    end_us: span.end_us,
                    day: local_day(span.start_us, tz),
                    held,
                });
            }
        }
    }
    sessions.sort_by_key(|session| (session.start_us, session.end_us));
    Ok(sessions)
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

/// Notes' title is only "Notes": a note's name is its first line. Each
/// Notes window is read at a few of its moments, and split where the note
/// changes, its time shared by moments.
fn name_notes(store: &SqlCipherBrainStore, sessions: &mut [Session]) -> Result<(), StoreError> {
    const NOTES: &str = "com.apple.Notes";
    let mut wanted: Vec<i64> = Vec::new();
    let mut budget = NOTES_BUDGET;
    for session in sessions.iter() {
        for held in session.held.iter().filter(|held| held.app == NOTES) {
            let take = NOTES_SAMPLES.min(budget.max(1)).min(held.events.len());
            wanted.extend(samples(&held.events, take));
            budget = budget.saturating_sub(take);
        }
    }
    if wanted.is_empty() {
        return Ok(());
    }
    let mut lines: HashMap<i64, Option<String>> = HashMap::new();
    for batch in wanted.chunks(500) {
        for event in store.observed_events_by_id(batch)? {
            let reading = screen_reading(
                &event.text,
                EventSource::from_stored(&event.source),
                event.app_bundle_id.as_deref(),
                event.window_title.as_deref(),
            );
            let first = reading
                .main
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .map(str::to_owned);
            lines.insert(event.id, first);
        }
    }
    for session in sessions.iter_mut() {
        let mut split: Vec<Held> = Vec::with_capacity(session.held.len());
        for held in session.held.drain(..) {
            if held.app != NOTES || held.events.is_empty() {
                split.push(held);
                continue;
            }
            split.extend(split_by_first_line(&held, &lines));
        }
        session.held = split;
    }
    Ok(())
}

/// Up to `count` of `events`, spread evenly, always with the newest.
fn samples(events: &[i64], count: usize) -> Vec<i64> {
    if events.is_empty() || count == 0 {
        return Vec::new();
    }
    if events.len() <= count {
        return events.to_vec();
    }
    let last = events.len() - 1;
    let mut picked: Vec<i64> = (0..count)
        .map(|n| events[n * last / (count - 1).max(1)])
        .collect();
    picked.dedup();
    picked
}

/// One Notes window as runs of one note each: every moment takes the name
/// read at the nearest sampled moment at or before it (or the first), and
/// each run's time is its share of the window's moments.
fn split_by_first_line(held: &Held, lines: &HashMap<i64, Option<String>>) -> Vec<Held> {
    let count = held.events.len();
    let mut names: Vec<Option<String>> = Vec::with_capacity(count);
    let mut current: Option<Option<String>> = None;
    let first_read = held
        .events
        .iter()
        .find_map(|id| lines.get(id).cloned())
        .unwrap_or(None);
    for id in &held.events {
        if let Some(line) = lines.get(id) {
            current = Some(line.clone());
        }
        names.push(current.clone().unwrap_or_else(|| first_read.clone()));
    }
    let span = held.held_us();
    let mut runs: Vec<Held> = Vec::new();
    let mut start = 0;
    while start < count {
        let mut end = start + 1;
        while end < count && names[end] == names[start] {
            end += 1;
        }
        let share = |at: usize| held.start_us + span * at as u64 / count as u64;
        runs.push(Held {
            start_us: share(start),
            end_us: if end == count {
                held.end_us
            } else {
                share(end)
            },
            app: held.app.clone(),
            title: held.title.clone(),
            host: held.host.clone(),
            events: held.events[start..end].to_vec(),
            first_line: names[start].clone(),
        });
        start = end;
    }
    runs
}

// ---------------------------------------------------------------------------
// What each window was about
// ---------------------------------------------------------------------------

/// Editors' own titles name code projects surely; a terminal's folder is
/// the project an editor uses with that name, at any depth of its path.
fn resolve(sessions: &[Session], home: Option<&str>) -> Vec<Vec<About>> {
    let mut editor_names: HashMap<String, String> = HashMap::new();
    for held in sessions.iter().flat_map(|session| &session.held) {
        if TERMINAL_APPS.contains(&held.app.as_str()) {
            continue;
        }
        if let Some(subject) = subject_of_at(
            Some(&held.app),
            held.title.as_deref(),
            held.host.as_deref(),
            None,
            home,
        )
        .filter(|subject| subject.kind == SubjectKind::Code)
        {
            editor_names.insert(folded(&subject.name), subject.name);
        }
    }
    sessions
        .iter()
        .map(|session| {
            session
                .held
                .iter()
                .map(|held| about(held, &editor_names, home))
                .collect()
        })
        .collect()
}

fn about(held: &Held, editor_names: &HashMap<String, String>, home: Option<&str>) -> About {
    let app = held.app.as_str();
    if TERMINAL_APPS.contains(&app) {
        return held
            .title
            .as_deref()
            .and_then(|title| terminal_folder_at(title, home))
            .and_then(|folder| {
                let in_editor = folder
                    .path
                    .as_deref()
                    .and_then(|path| {
                        path.split('/')
                            .rev()
                            .find_map(|part| editor_names.get(&folded(part)))
                    })
                    .or_else(|| editor_names.get(&folded(&folder.name)));
                match in_editor {
                    Some(name) => Some(name.clone()),
                    None if folder.sure => Some(folder.name),
                    None => None,
                }
            })
            .map_or(About::Nothing, |name| {
                let subject = Subject {
                    kind: SubjectKind::Code,
                    name,
                    part: None,
                };
                About::Item {
                    identity: identity(SubjectKind::Code, &subject.name),
                    subject,
                }
            });
    }
    match subject_of_at(
        Some(app),
        held.title.as_deref(),
        held.host.as_deref(),
        held.first_line.as_deref(),
        home,
    ) {
        Some(subject) if subject.kind.is_item() => About::Item {
            identity: identity(subject.kind, &subject.name),
            subject,
        },
        Some(subject) if subject.kind == SubjectKind::Page => About::Page {
            key: format!(
                "{}|{}",
                held.host.as_deref().unwrap_or_default(),
                folded(&subject.name)
            ),
            name: subject.name,
        },
        Some(subject) => About::Search {
            key: folded(&subject.name),
            query: subject.name,
        },
        None => match apps::kind_for_host(app, held.host.as_deref()) {
            WorkKind::Ai => ai_chat(held),
            WorkKind::Communication => {
                conversation_of(Some(app), held.title.as_deref(), held.host.as_deref())
                    .map_or(About::Nothing, |name| About::Conversation { name })
            }
            _ => About::Nothing,
        },
    }
}

/// A chat with an AI tool, by its caption ("Asking Claude about “Rounding
/// modes”"); a tool's own blank window is none.
fn ai_chat(held: &Held) -> About {
    let url = held.host.as_deref().map(|host| format!("https://{host}/"));
    let moment = Moment {
        app: Some(&held.app),
        title: held.title.as_deref(),
        url: url.as_deref(),
        text: "",
        beside: false,
    };
    match caption::fallback(&moment) {
        Some(line) if line.starts_with("Asking ") => About::AiChat {
            key: format!(
                "{}|{}",
                held.host.as_deref().unwrap_or(&held.app),
                folded(&line)
            ),
            title: line,
        },
        _ => About::Nothing,
    }
}

// ---------------------------------------------------------------------------
// Seen alongside and conversations
// ---------------------------------------------------------------------------

/// A page, search or AI chat, or a conversation, seen near an item.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Near {
    /// `page`, `search`, `ai_chat` or `conversation`.
    pub kind: &'static str,
    pub key: String,
    pub title: String,
    pub host: Option<String>,
    pub app: String,
    pub moment: i64,
    pub last_us: u64,
    pub score: u64,
    pub together: u32,
}

/// Pages, searches and AI chats open in the item's sessions or within 10
/// minutes of its windows, ranked by lift: how often each appears with the
/// item over how often it appears in the last 14 days of use. One open
/// beside everything is left out, at most two per site, `limit` in all
/// (SPEC 3.12.5). Conversations are ranked the same way, by name only.
pub(crate) fn near(model: &Model, acc: &ItemAcc, conversations: bool, limit: usize) -> Vec<Near> {
    let recent: Vec<usize> = (0..model.sessions.len())
        .filter(|index| model.sessions[*index].day >= model.fortnight_floor)
        .collect();
    let seen_in = appearances(model, &recent, conversations);
    let (found, together) = gather(model, acc, conversations);
    let everywhere = recent.len() >= EVERYWHERE_MIN_SESSIONS;
    let mut ranked: Vec<Near> = found
        .into_values()
        .filter_map(|mut near| {
            let with =
                u32::try_from(together.get(&near.key).map_or(0, BTreeSet::len)).unwrap_or(u32::MAX);
            let all = seen_in
                .get(&near.key)
                .copied()
                .unwrap_or(0)
                .max(with)
                .max(1);
            #[allow(clippy::cast_precision_loss)] // counts of sessions
            let share = f64::from(all) / recent.len().max(1) as f64;
            if everywhere && share > EVERYWHERE_SHARE {
                return None;
            }
            near.together = with;
            // Lift in thousandths: with this item over everywhere.
            near.score = u64::from(with) * 1_000 / u64::from(all);
            Some(near)
        })
        .collect();
    ranked.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then(b.together.cmp(&a.together))
            .then(b.last_us.cmp(&a.last_us))
            .then(a.key.cmp(&b.key))
    });
    let mut per_site: HashMap<String, usize> = HashMap::new();
    let mut out = Vec::new();
    for near in ranked {
        if near.kind == "page" {
            let site = near.host.clone().unwrap_or_else(|| near.app.clone());
            let count = per_site.entry(site).or_default();
            if *count >= 2 {
                continue;
            }
            *count += 1;
        }
        out.push(near);
        if out.len() == limit {
            break;
        }
    }
    out
}

/// What a window is as a candidate: its kind, key and title. Pages,
/// searches and AI chats for Seen alongside; conversations by name.
fn candidate(what: &About, conversations: bool) -> Option<(&'static str, String, String)> {
    match (what, conversations) {
        (About::Page { key, name }, false) => Some(("page", key.clone(), name.clone())),
        (About::Search { key, query }, false) => Some(("search", key.clone(), query.clone())),
        (About::AiChat { key, title }, false) => Some(("ai_chat", key.clone(), title.clone())),
        (About::Conversation { name }, true) => Some(("conversation", folded(name), name.clone())),
        _ => None,
    }
}

/// How many of the `recent` sessions each candidate appears in.
fn appearances(model: &Model, recent: &[usize], conversations: bool) -> HashMap<String, u32> {
    let mut seen_in: HashMap<String, u32> = HashMap::new();
    for index in recent {
        let keys: HashSet<String> = model.about[*index]
            .iter()
            .filter_map(|what| candidate(what, conversations).map(|found| found.1))
            .collect();
        for key in keys {
            *seen_in.entry(key).or_default() += 1;
        }
    }
    seen_in
}

/// The candidates in the item's sessions or within 10 minutes of its
/// windows, each with its newest sighting, and the sessions it shares
/// with the item.
fn gather(
    model: &Model,
    acc: &ItemAcc,
    conversations: bool,
) -> (HashMap<String, Near>, HashMap<String, BTreeSet<usize>>) {
    let close = |start: u64, end: u64| {
        acc.spans.iter().any(|(from, to)| {
            start <= to.saturating_add(NEAR_US) && end.saturating_add(NEAR_US) >= *from
        })
    };
    let mut found: HashMap<String, Near> = HashMap::new();
    let mut together: HashMap<String, BTreeSet<usize>> = HashMap::new();
    for (index, session) in model.sessions.iter().enumerate() {
        let in_session = acc.sessions.contains(&index);
        if !in_session && !close(session.start_us, session.end_us) {
            continue;
        }
        for (held, what) in session.held.iter().zip(&model.about[index]) {
            let Some((kind, key, title)) = candidate(what, conversations) else {
                continue;
            };
            let Some(moment) = held.newest() else {
                continue;
            };
            if !in_session && !close(held.start_us, held.end_us) {
                continue;
            }
            together.entry(key.clone()).or_default().insert(index);
            let entry = found.entry(key.clone()).or_insert_with(|| Near {
                kind,
                key,
                title: title.clone(),
                host: held.host.clone(),
                app: held.app.clone(),
                moment,
                last_us: held.end_us,
                score: 0,
                together: 0,
            });
            if held.end_us >= entry.last_us {
                entry.title = title;
                entry.host.clone_from(&held.host);
                entry.app.clone_from(&held.app);
                entry.moment = moment;
                entry.last_us = held.end_us;
            }
        }
    }
    (found, together)
}

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------

/// One page across days, before it is shaped as JSON.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PageAcc {
    pub title: String,
    pub host: Option<String>,
    pub path: Option<String>,
    pub app: String,
    pub days: BTreeSet<i64>,
    pub last_us: u64,
    /// (segment end, moment).
    pub moments: Vec<(u64, i64)>,
}

/// Pages read in a browser while it was the window in front, one per
/// address (host and path, never the query or fragment), or without an
/// address one per browser and title; newest first, at most `limit`.
pub(crate) fn pages(
    store: &SqlCipherBrainStore,
    model: &Model,
    tz: i32,
    limit: usize,
) -> Result<Vec<PageAcc>, StoreError> {
    // The address of each page window, from its newest moment.
    let mut newest: Vec<i64> = Vec::new();
    for (index, session) in model.sessions.iter().enumerate() {
        for (held, what) in session.held.iter().zip(&model.about[index]) {
            if matches!(what, About::Page { .. }) && is_browser_app(&held.app) {
                newest.extend(held.newest());
            }
        }
    }
    let mut urls: HashMap<i64, String> = HashMap::new();
    for batch in newest.chunks(500) {
        for head in store.event_heads(batch)? {
            if let Some(url) = head.url {
                urls.insert(head.id, url);
            }
        }
    }
    let mut pages: BTreeMap<String, PageAcc> = BTreeMap::new();
    for (index, session) in model.sessions.iter().enumerate() {
        for (held, what) in session.held.iter().zip(&model.about[index]) {
            let About::Page { name, .. } = what else {
                continue;
            };
            if !is_browser_app(&held.app) {
                continue;
            }
            let address = held
                .newest()
                .and_then(|id| urls.get(&id))
                .and_then(|url| address_of(url));
            let key = match &address {
                Some((host, path)) => format!("{host}{path}"),
                None => format!("{}|{}", held.app, folded(name)),
            };
            let page = pages.entry(key).or_insert_with(|| PageAcc {
                title: name.clone(),
                host: address
                    .as_ref()
                    .map(|(host, _)| host.clone())
                    .or_else(|| held.host.clone()),
                path: address.as_ref().map(|(_, path)| path.clone()),
                app: held.app.clone(),
                days: BTreeSet::new(),
                last_us: 0,
                moments: Vec::new(),
            });
            if held.end_us >= page.last_us {
                page.title.clone_from(name);
                page.app.clone_from(&held.app);
                page.last_us = held.end_us;
            }
            page.days.insert(local_day(held.start_us, tz));
            page.moments
                .extend(held.events.iter().map(|id| (held.end_us, *id)));
        }
    }
    let mut out: Vec<PageAcc> = pages
        .into_values()
        .map(|mut page| {
            page.moments.sort_by(|a, b| b.cmp(a));
            page.moments.dedup_by_key(|moment| moment.1);
            page
        })
        .collect();
    out.sort_by(|a, b| b.last_us.cmp(&a.last_us).then(a.title.cmp(&b.title)));
    out.truncate(limit);
    Ok(out)
}

fn is_browser_app(app: &str) -> bool {
    mci_brain::chrome::is_browser(Some(app))
}

/// A page's address without its query and fragment: the host, lower case
/// and without "www.", and the path ("/" when none).
pub(crate) fn address_of(url: &str) -> Option<(String, String)> {
    let host = apps::host_of(url)?;
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let path = rest
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .split_once('/')
        .map_or("/".to_owned(), |(_, path)| format!("/{path}"));
    let path = if path.len() > 1 {
        path.trim_end_matches('/').to_owned()
    } else {
        path
    };
    Some((host, path))
}

// ---------------------------------------------------------------------------
// Moments and folders
// ---------------------------------------------------------------------------

/// The item each of `moments` is part of: the item its own window was
/// about, or, for a page, search or AI chat read in a session with items,
/// the item with the most time in that session. Chats with people are never
/// part of one.
pub(crate) fn moment_items(model: &Model, moments: &[u64]) -> BTreeMap<String, String> {
    let wanted: HashSet<i64> = moments
        .iter()
        .filter_map(|id| i64::try_from(*id).ok())
        .collect();
    let ids: HashMap<&str, &str> = model
        .items
        .iter()
        .map(|(id, acc)| (acc.identity.as_str(), id.as_str()))
        .collect();
    let mut out = BTreeMap::new();
    if wanted.is_empty() {
        return out;
    }
    for (index, session) in model.sessions.iter().enumerate() {
        // The session's item with the most time, for pages read in it.
        let mut time: HashMap<&str, u64> = HashMap::new();
        for (held, what) in session.held.iter().zip(&model.about[index]) {
            if let About::Item { identity, .. } = what {
                if ids.contains_key(identity.as_str()) {
                    *time.entry(identity.as_str()).or_default() += held.held_us();
                }
            }
        }
        let main = time
            .into_iter()
            .max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(a.0)))
            .map(|(identity, _)| identity);
        for (held, what) in session.held.iter().zip(&model.about[index]) {
            let owner = match what {
                About::Item { identity, .. } => ids.get(identity.as_str()).copied(),
                About::Page { .. } | About::Search { .. } | About::AiChat { .. } => {
                    main.and_then(|identity| ids.get(identity).copied())
                }
                About::Conversation { .. } | About::Nothing => None,
            };
            let Some(owner) = owner else {
                continue;
            };
            for id in held.events.iter().filter(|id| wanted.contains(id)) {
                out.insert(id.to_string(), owner.to_owned());
            }
        }
    }
    out
}

/// A code project's folder, with `~` for the home folder: the folder named
/// like the project in the paths its moments showed or its terminals'
/// titles, the one seen most (SPEC 3.12.4). `None` when no path names it.
pub(crate) fn folder_guess(
    store: &SqlCipherBrainStore,
    acc: &ItemAcc,
    home_path: Option<&str>,
) -> Result<Option<String>, StoreError> {
    let name = folded(&acc.name);
    let mut counts: HashMap<String, u32> = HashMap::new();
    let mut add = |path: &str, weight: u32| {
        let parts: Vec<&str> = path.split('/').collect();
        if let Some(at) = parts.iter().rposition(|part| folded(part) == name) {
            let folder = parts[..=at].join("/");
            if !folder.is_empty() {
                *counts.entry(tilde(&folder, home_path)).or_default() += weight;
            }
        }
    };
    for path in &acc.terminal_paths {
        add(path, 1);
    }
    let recent: Vec<i64> = acc
        .moments
        .iter()
        .take(400)
        .map(|moment| moment.1)
        .collect();
    for (path, seen) in store.file_paths_seen(&recent, 50)? {
        add(&path, seen);
    }
    Ok(counts
        .into_iter()
        .max_by(|a, b| {
            a.1.cmp(&b.1)
                .then(b.0.len().cmp(&a.0.len()))
                .then(b.0.cmp(&a.0))
        })
        .map(|(folder, _)| folder))
}

/// A path with the home folder written `~`.
pub(crate) fn tilde(path: &str, home_path: Option<&str>) -> String {
    match home_path.map(|home| home.trim_end_matches('/')) {
        Some(home) if !home.is_empty() && path == home => "~".to_owned(),
        Some(home) if !home.is_empty() => path
            .strip_prefix(&format!("{home}/"))
            .map_or_else(|| path.to_owned(), |rest| format!("~/{rest}")),
        _ => path.to_owned(),
    }
}

/// The newest of `moments` (newest first) that kept a screenshot, and the
/// time of the newest that exists, reading at most `budget` heads.
pub(crate) fn newest_with_screenshot(
    store: &SqlCipherBrainStore,
    moments: &[i64],
    budget: usize,
) -> Result<(Option<i64>, Option<u64>), StoreError> {
    let mut newest_ts = None;
    for batch in moments
        .iter()
        .take(budget)
        .copied()
        .collect::<Vec<_>>()
        .chunks(64)
    {
        let mut heads = store.event_heads(batch)?;
        heads.sort_by(|a, b| b.ts_us.cmp(&a.ts_us).then(b.id.cmp(&a.id)));
        if newest_ts.is_none() {
            newest_ts = heads.first().map(|head| head.ts_us);
        }
        if let Some(shot) = heads.iter().find(|head| head.has_screenshot) {
            return Ok((Some(shot.id), newest_ts));
        }
    }
    Ok((None, newest_ts))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn days_follow_the_time_zone() {
        // 2026-10-12 23:30 at UTC-7 is 2026-10-13 06:30 UTC.
        let ts = 1_791_873_000_000_000;
        assert_eq!(local_day(ts, -7 * 3600) + 1, local_day(ts, 0));
    }

    #[test]
    fn addresses_drop_the_query_and_fragment() {
        assert_eq!(
            address_of("https://www.DevNotes.example/rounding?utm=x#top"),
            Some(("devnotes.example".into(), "/rounding".into()))
        );
        assert_eq!(
            address_of("https://devnotes.example"),
            Some(("devnotes.example".into(), "/".into()))
        );
        assert_eq!(
            address_of("https://devnotes.example/a/b/"),
            Some(("devnotes.example".into(), "/a/b".into()))
        );
        assert_eq!(address_of("file:///Users/dev/notes.txt"), None);
    }

    #[test]
    fn a_home_path_is_written_with_a_tilde() {
        assert_eq!(
            tilde("/Users/dev/trailhead-shop", Some("/Users/dev")),
            "~/trailhead-shop"
        );
        assert_eq!(tilde("/Users/dev", Some("/Users/dev/")), "~");
        assert_eq!(
            tilde("/Users/devon/x", Some("/Users/dev")),
            "/Users/devon/x"
        );
        assert_eq!(tilde("/srv/x", None), "/srv/x");
    }

    #[test]
    fn samples_spread_evenly_and_keep_the_newest() {
        assert_eq!(samples(&[1, 2, 3], 6), vec![1, 2, 3]);
        assert_eq!(samples(&(1..=10).collect::<Vec<_>>(), 3), vec![1, 5, 10]);
        assert!(samples(&[], 3).is_empty());
    }

    #[test]
    fn a_notes_window_splits_where_the_note_changes() {
        let held = Held {
            start_us: 0,
            end_us: 600,
            app: "com.apple.Notes".into(),
            title: Some("Notes".into()),
            host: None,
            events: vec![1, 2, 3, 4, 5, 6],
            first_line: None,
        };
        let lines: HashMap<i64, Option<String>> = [
            (1, Some("Launch checklist".to_owned())),
            (4, Some("Pricing page draft".to_owned())),
        ]
        .into_iter()
        .collect();
        let runs = split_by_first_line(&held, &lines);
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].events, vec![1, 2, 3]);
        assert_eq!(runs[0].first_line.as_deref(), Some("Launch checklist"));
        assert_eq!((runs[0].start_us, runs[0].end_us), (0, 300));
        assert_eq!(runs[1].events, vec![4, 5, 6]);
        assert_eq!((runs[1].start_us, runs[1].end_us), (300, 600));
    }

    #[test]
    fn item_ids_are_keyed_hashes_in_the_id_shape() {
        let key = DbKey::from_bytes([0x5a; 32]);
        let id = item_id(&key, "code:trailhead-shop");
        assert_eq!(id.len(), 22);
        assert!(id.starts_with("w_"));
        assert!(super::super::is_item_id(&id));
        assert_eq!(id, item_id(&key, "code:trailhead-shop"));
        assert_ne!(
            id,
            item_id(&DbKey::from_bytes([1; 32]), "code:trailhead-shop")
        );
        assert!(!id.contains("trailhead"));
    }
}
