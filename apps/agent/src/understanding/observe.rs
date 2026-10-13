//! From captured events to observations: work sessions, the windows within
//! them, and the measured signals beneath the surface.
//!
//! Signals come from counts the system already keeps (keys, clicks, scrolls,
//! pointer moves per interval; never which keys) and from the order of what
//! was on screen:
//! - **typing**: sustained key presses in a window;
//! - **reading**: scrolling with little typing;
//! - **pause**: the window held with no keys, clicks or scrolls for 45 s to
//!   5 min (longer is "away");
//! - **back and forth**: alternating between the same two windows;
//! - **reworded search**: a search that shares words with the one before it;
//! - **error on screen**: lines that read like an error message.

use serde::{Deserialize, Serialize};

use mci_brain::reading::reading;
use mci_brain::understanding::{InteractionCounts, ObservedEvent, SearchRecord};
use mci_brain::EventSource;

use super::apps;

/// Sessions break at an idle gap this long.
pub const SESSION_GAP_US: u64 = 5 * 60 * 1_000_000;
/// …and are cut at this length so each fits the model's window.
pub const SESSION_MAX_US: u64 = 30 * 60 * 1_000_000;
const PAUSE_MIN_US: u64 = 45 * 1_000_000;
const PAUSE_MAX_US: u64 = 5 * 60 * 1_000_000;

/// Sources that describe the user's focus (not background windows).
fn is_focus(source: &str) -> bool {
    !matches!(source, "screen_context" | "transcript_import" | "mcp_resource")
}

/// A stretch of activity: indices into the event slice, inclusive start,
/// exclusive end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionSpan {
    /// First event index.
    pub start: usize,
    /// One past the last event index.
    pub end: usize,
    /// First event time.
    pub start_us: u64,
    /// Last event time.
    pub end_us: u64,
}

/// Split ordered events into sessions at idle gaps and at the length cap.
/// Background-window events do not keep a session alive on their own.
#[must_use]
pub fn split_sessions(events: &[ObservedEvent]) -> Vec<SessionSpan> {
    let mut out = Vec::new();
    let mut start: Option<usize> = None;
    let mut last_focus_us = 0u64;
    for (index, event) in events.iter().enumerate() {
        if !is_focus(&event.source) {
            continue;
        }
        match start {
            None => {
                start = Some(index);
                last_focus_us = event.ts_us;
            }
            Some(first) => {
                let gap = event.ts_us.saturating_sub(last_focus_us);
                let length = event.ts_us.saturating_sub(events[first].ts_us);
                if gap >= SESSION_GAP_US || length >= SESSION_MAX_US {
                    out.push(span(events, first, index, last_focus_us));
                    start = Some(index);
                }
                last_focus_us = event.ts_us;
            }
        }
    }
    if let Some(first) = start {
        out.push(span(events, first, events.len(), last_focus_us));
    }
    out
}

fn span(events: &[ObservedEvent], start: usize, end: usize, last_focus_us: u64) -> SessionSpan {
    SessionSpan {
        start,
        end,
        start_us: events[start].ts_us,
        end_us: last_focus_us,
    }
}

/// One window or page held in focus.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    /// Start time.
    pub start_us: u64,
    /// End time (start of the next segment, or the last event).
    pub end_us: u64,
    /// App bundle id.
    pub app: String,
    /// Window or page title.
    pub title: Option<String>,
    /// Page URL.
    pub url: Option<String>,
    /// Events in it.
    pub event_ids: Vec<i64>,
    /// What the person was reading in it: the reading's `main` of its most
    /// complete capture, without the stored header or the window's chrome.
    pub text: String,
    /// Key presses.
    pub keys: u64,
    /// Clicks.
    pub clicks: u64,
    /// Scroll steps.
    pub scrolls: u64,
    /// Pauses (held, no input) in microseconds.
    pub pauses_us: Vec<u64>,
}

impl Segment {
    /// Length in microseconds.
    #[must_use]
    pub fn duration_us(&self) -> u64 {
        self.end_us.saturating_sub(self.start_us)
    }

    /// What the input says the user was doing.
    #[must_use]
    pub fn activity(&self) -> &'static str {
        let minutes = (self.duration_us() as f64 / 60_000_000.0).max(0.25);
        let keys_per_minute = self.keys as f64 / minutes;
        if keys_per_minute >= 25.0 {
            "typing"
        } else if self.scrolls >= 3 && keys_per_minute < 10.0 {
            "reading"
        } else if self.clicks >= 4 && keys_per_minute < 10.0 {
            "clicking through"
        } else if self.keys > 0 {
            "typing a little"
        } else {
            "looking"
        }
    }
}

/// What the person was reading in one capture: the reading's `main`.
fn read_text(event: &ObservedEvent) -> String {
    reading(
        &event.text,
        EventSource::from_stored(&event.source),
        event.app_bundle_id.as_deref(),
        event.window_title.as_deref(),
    )
    .main
}

/// Merge a session's focused events into segments and attach input counts.
#[must_use]
pub fn segments(events: &[ObservedEvent], counts: &[InteractionCounts], session_end_us: u64) -> Vec<Segment> {
    let mut out: Vec<Segment> = Vec::new();
    // The capture each segment's text comes from: its longest stored text.
    let mut fullest: Vec<&ObservedEvent> = Vec::new();
    for event in events.iter().filter(|e| is_focus(&e.source)) {
        let app = event.app_bundle_id.clone().unwrap_or_else(|| "unknown".into());
        let same = out.last().is_some_and(|last: &Segment| {
            last.app == app
                && last.title == event.window_title
                && last.url.as_deref().and_then(apps::host_of) == event.url.as_deref().and_then(apps::host_of)
        });
        if same {
            let last = out.last_mut().expect("checked");
            last.event_ids.push(event.id);
            last.end_us = event.ts_us;
            let chosen = fullest.last_mut().expect("one capture per segment");
            if event.text.len() > chosen.text.len() {
                *chosen = event;
            }
            if last.url.is_none() {
                last.url = event.url.clone();
            }
        } else {
            if let Some(last) = out.last_mut() {
                last.end_us = event.ts_us;
            }
            out.push(Segment {
                start_us: event.ts_us,
                end_us: event.ts_us,
                app,
                title: event.window_title.clone(),
                url: event.url.clone(),
                event_ids: vec![event.id],
                text: String::new(),
                keys: 0,
                clicks: 0,
                scrolls: 0,
                pauses_us: Vec::new(),
            });
            fullest.push(event);
        }
    }
    for (segment, event) in out.iter_mut().zip(fullest) {
        segment.text = read_text(event);
    }
    if let Some(last) = out.last_mut() {
        last.end_us = last.end_us.max(session_end_us);
    }
    for segment in &mut out {
        let mut quiet_run = 0u64;
        for sample in counts
            .iter()
            .filter(|c| c.start_us >= segment.start_us && c.start_us < segment.end_us.max(segment.start_us + 1))
        {
            segment.keys += u64::from(sample.keys);
            segment.clicks += u64::from(sample.clicks);
            segment.scrolls += u64::from(sample.scrolls);
            if sample.keys == 0 && sample.clicks == 0 && sample.scrolls == 0 {
                quiet_run += sample.end_us - sample.start_us;
            } else {
                if (PAUSE_MIN_US..=PAUSE_MAX_US).contains(&quiet_run) {
                    segment.pauses_us.push(quiet_run);
                }
                quiet_run = 0;
            }
        }
        if (PAUSE_MIN_US..=PAUSE_MAX_US).contains(&quiet_run) {
            segment.pauses_us.push(quiet_run);
        }
    }
    out
}

/// What the session's signals add up to.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Signals {
    /// Window switches.
    pub switches: u32,
    /// Pairs of windows alternated between, with how many alternations.
    pub back_and_forth: Vec<(String, String, u32)>,
    /// Searches, in order: (time, engine, query).
    pub searches: Vec<(u64, String, String)>,
    /// Searches that reworded the one before.
    pub reworded_searches: u32,
    /// Pauses (held, no input) with the window they were in.
    pub pauses: Vec<(u64, u64, String)>,
    /// Short lines that read like errors.
    pub errors: Vec<String>,
    /// Background windows also visible (app, title).
    pub also_visible: Vec<(String, String)>,
    /// Totals.
    pub keys: u64,
    /// Totals.
    pub clicks: u64,
    /// Totals.
    pub scrolls: u64,
}

const ERROR_MARKERS: &[&str] = &[
    "error", "failed", "exception", "traceback", "not found", "denied", "cannot ", "can't ", "unable to", "panicked", "fatal:",
];

/// Derive the session's signals.
#[must_use]
pub fn signals(events: &[ObservedEvent], segments: &[Segment], searches: &[SearchRecord]) -> Signals {
    let mut out = Signals {
        switches: u32::try_from(segments.len().saturating_sub(1)).unwrap_or(u32::MAX),
        ..Signals::default()
    };
    let label = |s: &Segment| format!("{} — {}", apps::name(&s.app), s.title.clone().unwrap_or_default());
    // Back and forth: A B A B … between the same two windows.
    let mut pairs: Vec<(String, String, u32)> = Vec::new();
    for window in segments.windows(3) {
        let (a, b, c) = (label(&window[0]), label(&window[1]), label(&window[2]));
        if a == c && a != b {
            let key = if a < b { (a, b) } else { (b, a) };
            match pairs.iter_mut().find(|(x, y, _)| *x == key.0 && *y == key.1) {
                Some(pair) => pair.2 += 1,
                None => pairs.push((key.0, key.1, 2)),
            }
        }
    }
    pairs.retain(|(_, _, n)| *n >= 3);
    out.back_and_forth = pairs;
    let mut previous: Option<&str> = None;
    for search in searches {
        if let Some(prev) = previous {
            if prev != search.query && shares_words(prev, &search.query) {
                out.reworded_searches += 1;
            }
        }
        previous = Some(&search.query);
        out.searches.push((search.ts_us, search.engine.clone(), search.query.clone()));
    }
    for segment in segments {
        out.keys += segment.keys;
        out.clicks += segment.clicks;
        out.scrolls += segment.scrolls;
        for pause in &segment.pauses_us {
            out.pauses.push((segment.start_us, *pause, label(segment)));
        }
        for line in segment.text.lines() {
            let lower = line.to_lowercase();
            if line.len() <= 160 && ERROR_MARKERS.iter().any(|m| lower.contains(m)) && out.errors.len() < 3 {
                let line = line.trim().to_owned();
                if !line.is_empty() && !out.errors.contains(&line) {
                    out.errors.push(line);
                }
            }
        }
    }
    for event in events.iter().filter(|e| e.source == "screen_context") {
        let entry = (
            apps::name(event.app_bundle_id.as_deref().unwrap_or("")),
            event.window_title.clone().unwrap_or_default(),
        );
        if !out.also_visible.contains(&entry) && out.also_visible.len() < 4 {
            out.also_visible.push(entry);
        }
    }
    out
}

fn shares_words(a: &str, b: &str) -> bool {
    let words = |s: &str| {
        s.to_lowercase()
            .split_whitespace()
            .filter(|w| w.len() >= 3)
            .map(str::to_owned)
            .collect::<std::collections::BTreeSet<_>>()
    };
    let (a, b) = (words(a), words(b));
    !a.is_empty() && a.intersection(&b).count() * 2 >= a.len().min(b.len())
}

/// Clock time `HH:MM` for a timestamp in the user's zone.
#[must_use]
pub fn clock(ts_us: u64, tz_offset_secs: i32) -> String {
    let secs = i64::try_from(ts_us / 1_000_000).unwrap_or(0) + i64::from(tz_offset_secs);
    let day_secs = secs.rem_euclid(86_400);
    format!("{:02}:{:02}", day_secs / 3600, (day_secs % 3600) / 60)
}

fn minutes(us: u64) -> String {
    let m = us as f64 / 60_000_000.0;
    if m < 1.0 {
        format!("{} s", (us / 1_000_000).max(1))
    } else {
        format!("{} min", m.round() as u64)
    }
}

fn excerpt(text: &str, limit: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= limit {
        collapsed
    } else {
        collapsed.chars().take(limit).collect::<String>() + "…"
    }
}

/// Write the observation the model reads: one line per window held, with what
/// the input says, an excerpt of what was on screen, then the session's
/// searches and signals. Bounded to `max_chars`.
#[must_use]
pub fn render(segments: &[Segment], signals: &Signals, tz_offset_secs: i32, max_chars: usize) -> String {
    let mut lines = Vec::new();
    // Give each window a share of the budget, more for longer ones.
    let total: u64 = segments.iter().map(|s| s.duration_us().max(1)).sum::<u64>().max(1);
    let text_budget = max_chars.saturating_sub(1_200);
    for segment in segments {
        let share = ((segment.duration_us().max(1) as f64 / total as f64) * text_budget as f64) as usize;
        let mut line = format!(
            "{}–{} {} — \"{}\"",
            clock(segment.start_us, tz_offset_secs),
            clock(segment.end_us, tz_offset_secs),
            apps::name(&segment.app),
            excerpt(segment.title.as_deref().unwrap_or("untitled"), 90),
        );
        if let Some(host) = segment.url.as_deref().and_then(apps::host_of) {
            line.push_str(&format!(" ({host})"));
        }
        line.push_str(&format!(": {} for {}", segment.activity(), minutes(segment.duration_us())));
        if segment.keys > 0 {
            line.push_str(&format!(", {} keys", segment.keys));
        }
        if let Some(longest) = segment.pauses_us.iter().max() {
            line.push_str(&format!(", paused {} with no input", minutes(*longest)));
        }
        let budget = share.clamp(80, 700);
        if !segment.text.trim().is_empty() {
            line.push_str(&format!(". Text: {}", excerpt(&segment.text, budget)));
        }
        lines.push(line);
    }
    for (ts, engine, query) in &signals.searches {
        lines.push(format!("{} searched {engine}: \"{}\"", clock(*ts, tz_offset_secs), excerpt(query, 120)));
    }
    let mut notes = Vec::new();
    if signals.reworded_searches > 0 {
        notes.push(format!("reworded a search {} time(s)", signals.reworded_searches));
    }
    for (a, b, n) in &signals.back_and_forth {
        notes.push(format!("switched back and forth between {a} and {b} {n} times"));
    }
    if !signals.errors.is_empty() {
        notes.push(format!(
            "error text on screen: {}",
            signals.errors.iter().map(|e| format!("\"{}\"", excerpt(e, 100))).collect::<Vec<_>>().join("; ")
        ));
    }
    if !signals.also_visible.is_empty() {
        notes.push(format!(
            "also visible: {}",
            signals
                .also_visible
                .iter()
                .map(|(app, title)| format!("{app} — {}", excerpt(title, 50)))
                .collect::<Vec<_>>()
                .join("; ")
        ));
    }
    if !notes.is_empty() {
        lines.push(format!("Signals: {}.", notes.join("; ")));
    }
    let mut out = lines.join("\n");
    if out.chars().count() > max_chars {
        out = out.chars().take(max_chars).collect::<String>() + "…";
    }
    out
}

/// Representative evidence: up to `limit` event ids, spread across segments.
#[must_use]
pub fn evidence(segments: &[Segment], limit: usize) -> Vec<i64> {
    let mut out = Vec::new();
    let mut round = 0;
    while out.len() < limit {
        let mut added = false;
        for segment in segments {
            if let Some(id) = segment.event_ids.get(segment.event_ids.len().saturating_sub(1 + round)) {
                if !out.contains(id) && out.len() < limit {
                    out.push(*id);
                    added = true;
                }
            }
        }
        if !added {
            break;
        }
        round += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: u64 = 60_000_000;

    fn ev(id: i64, minute: u64, app: &str, title: &str, source: &str, text: &str) -> ObservedEvent {
        ObservedEvent {
            id,
            ts_us: 1_800_000_000_000_000 + minute * MIN,
            app_bundle_id: Some(app.into()),
            window_title: Some(title.into()),
            url: None,
            text: text.into(),
            source: source.into(),
        }
    }

    fn counts(minute_from: u64, minute_to: u64, keys: u32, scrolls: u32) -> Vec<InteractionCounts> {
        let base = 1_800_000_000_000_000;
        (minute_from * 12..minute_to * 12)
            .map(|i| InteractionCounts {
                start_us: base + i * 5_000_000,
                end_us: base + (i + 1) * 5_000_000,
                keys,
                clicks: 0,
                scrolls,
                moves: 3,
            })
            .collect()
    }

    #[test]
    fn sessions_break_at_idle_gaps_and_ignore_background_windows() {
        let events = vec![
            ev(1, 0, "com.apple.Notes", "Plan", "screen_ocr", "a"),
            ev(2, 3, "com.apple.Notes", "Plan", "screen_ocr", "b"),
            ev(3, 6, "com.tinyspeck.slackmacgap", "#pricing", "screen_context", "bg"),
            ev(4, 12, "com.apple.Notes", "Plan", "screen_ocr", "c"),
        ];
        let spans = split_sessions(&events);
        assert_eq!(spans.len(), 2, "a background read does not bridge a 9-minute gap");
        assert_eq!((spans[0].start, spans[0].end), (0, 3));
        assert_eq!(spans[1].start, 3);
    }

    #[test]
    fn segments_measure_typing_reading_and_pauses() {
        let events = vec![
            ev(1, 0, "com.google.Chrome", "Pricing | Stripe", "browser_page", "Per-seat pricing. Tiered pricing."),
            ev(2, 4, "com.apple.Notes", "Launch plan", "screen_ocr", "Team: $18/seat"),
            ev(3, 9, "com.apple.Notes", "Launch plan", "screen_ocr", "Team: $18/seat annual"),
        ];
        let mut c = counts(0, 4, 0, 2);
        c.extend(counts(4, 6, 0, 0)); // two quiet minutes in Notes
        c.extend(counts(6, 9, 4, 0)); // then typing
        let segs = segments(&events, &c, events[2].ts_us);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0].activity(), "reading");
        assert_eq!(segs[1].text, "Team: $18/seat annual", "the most complete text wins");
        assert_eq!(segs[1].pauses_us, vec![2 * MIN]);
        assert_eq!(segs[1].activity(), "typing", "144 keys in five minutes");
    }

    #[test]
    fn signals_find_back_and_forth_reworded_searches_and_errors() {
        let mut events = Vec::new();
        for i in 0..6 {
            let (app, title) = if i % 2 == 0 { ("com.apple.Notes", "Plan") } else { ("com.tinyspeck.slackmacgap", "#pricing") };
            events.push(ev(i, i as u64, app, title, "screen_ocr", if i == 5 { "Error: payment failed" } else { "ok" }));
        }
        let segs = segments(&events, &[], events[5].ts_us);
        let searches = vec![
            SearchRecord { event_id: 1, ts_us: 1, engine: "google".into(), query: "stripe per seat pricing".into(), app_bundle_id: None, url: None },
            SearchRecord { event_id: 2, ts_us: 2, engine: "google".into(), query: "stripe seat pricing annual".into(), app_bundle_id: None, url: None },
        ];
        let s = signals(&events, &segs, &searches);
        assert_eq!(s.switches, 5);
        assert_eq!(s.back_and_forth.len(), 1);
        assert!(s.back_and_forth[0].2 >= 3);
        assert_eq!(s.reworded_searches, 1);
        assert_eq!(s.errors, vec!["Error: payment failed".to_owned()]);
        let text = render(&segs, &s, 0, 4_000);
        assert!(text.contains("switched back and forth between"));
        assert!(text.contains("searched google: \"stripe seat pricing annual\""));
        assert!(text.chars().count() <= 4_001);
    }

    #[test]
    fn a_segment_reads_what_the_person_read_without_the_header_or_status_bar() {
        let stored = "[app=com.microsoft.VSCode | title=retention_worker.rs | url=? | ts=2026-10-12T14:02:00.000Z]\nfn sweep(store: &Store) -> u64 {\n    store.vacuum()\n}\n\n\u{1e}\n0 errors, 2 warnings Ln 14, Col 37 UTF-8 Rust";
        let events = vec![ev(1, 0, "com.microsoft.VSCode", "retention_worker.rs", "screen_ocr", stored)];
        let segs = segments(&events, &[], events[0].ts_us);
        assert_eq!(segs[0].text, "fn sweep(store: &Store) -> u64 {\n    store.vacuum()\n}");
        let s = signals(&events, &segs, &[]);
        assert!(s.errors.is_empty(), "a status bar is not an error on screen: {:?}", s.errors);
        let observation = render(&segs, &s, 0, 4_000);
        assert!(!observation.contains("[app="), "{observation}");
        assert!(observation.contains("fn sweep(store: &Store)"));
    }

    #[test]
    fn a_segment_reads_its_fullest_capture() {
        let short = "[app=com.apple.Notes | title=Plan | url=? | ts=1]\nTeam plan";
        let long = "[app=com.apple.Notes | title=Plan | url=? | ts=2]\n\u{4e09} Team plan at $18 a seat\n\n\u{1e}\nNotes 17";
        let events = vec![
            ev(1, 0, "com.apple.Notes", "Plan", "screen_ocr", short),
            ev(2, 1, "com.apple.Notes", "Plan", "screen_ocr", long),
        ];
        let segs = segments(&events, &[], events[1].ts_us);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].text, "Team plan at $18 a seat");
    }

    #[test]
    fn evidence_spreads_across_windows() {
        let events: Vec<_> = (0..9)
            .map(|i| ev(i, i as u64, if i < 6 { "com.apple.Notes" } else { "com.google.Chrome" }, if i < 6 { "A" } else { "B" }, "screen_ocr", "t"))
            .collect();
        let segs = segments(&events, &[], events[8].ts_us);
        let picked = evidence(&segs, 4);
        assert_eq!(picked.len(), 4);
        assert!(picked.contains(&5) && picked.contains(&8), "the latest of each window comes first");
    }
}
