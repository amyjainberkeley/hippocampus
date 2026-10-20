//! The demo week: a made-up founder's busy week for Demo Memory
//! (SPEC-DELTA 6), the memory the launch video and the website pictures are
//! taken in.
//!
//! Ren Alder runs Pebblewick, a made-up company that sells class booking to
//! small studios. This week Ren launches a Studio plan with yearly billing:
//! its prices in Stripe, the pricing page, the billing code and its tests,
//! the Q4 investor update, a chat and a call with investors, the October
//! changelog, the 2027 budget, and a team sync with its Slack thread. Every
//! company, person, number and line here is invented; well-known products
//! appear only as the apps and sites in use.
//!
//! The week is a pure function of the clock and the time zone: it always
//! ends now, so it always looks like this week, and two runs with the same
//! clock write the same memory. [`World::screens`] lists the screenshots the
//! week needs, for the drawing tool (`apps/demo-memory`) to draw and seal
//! with the capture helper's codec; [`seed`] writes the moments, their
//! readings and screenshots, the session notes, searches, day summaries and
//! lines about Ren; [`World::calendar`] is the demo calendar the window shows
//! while Demo Memory is in use.

#[path = "demo_week/story.rs"]
mod story;

use std::collections::{BTreeMap, HashMap};

use serde_json::{json, Value};

use mci_agent::understanding::observe;
use mci_agent::understanding::overview::ModelStatus;
use mci_brain::reading::Reading;
use mci_brain::understanding::{
    DayReport, NewProposition, ObservedEvent, PropositionKind, SessionNote,
};
use mci_brain::{
    ActivityInterval, ActivityState, BrainStore, Event, EventId, EventSource, MomentReading,
    SqlCipherBrainStore, StoredMoment, READING_VERSION,
};

/// One minute, in microseconds.
pub const MIN: u64 = 60_000_000;
/// One day, in microseconds.
pub const DAY: u64 = 24 * 60 * MIN;
/// The model the made-up notes, captions and lines say wrote them.
pub const MODEL: &str = "apple-foundation-models";
/// The newest moment is this old: the one just saved.
const NEWEST_AGE_US: u64 = 30_000_000;
/// The capture helper keeps a screenshot when the window in front changes
/// and after five quiet minutes; the moments between show the one before.
const SCREENSHOT_EVERY_MINUTES: u64 = 5;
/// The version of the screen list the drawing tool reads.
pub const SCREENS_VERSION: u32 = 1;
/// The version of the demo calendar the window reads.
pub const CALENDAR_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// Local time
// ---------------------------------------------------------------------------

/// Local midnight starting the day `back` days before the one that holds
/// `now_us`, for a fixed offset of `tz` seconds east of UTC.
#[must_use]
pub fn day_start(now_us: u64, tz: i32, back: u64) -> u64 {
    let offset = i128::from(tz) * 1_000_000;
    let local = i128::from(now_us) + offset;
    let day = i128::from(DAY);
    let today = local.div_euclid(day) * day - offset;
    u64::try_from(today.max(0))
        .unwrap_or(0)
        .saturating_sub(back.saturating_mul(DAY))
}

/// A local date and time, from microseconds since the epoch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Local {
    /// Year.
    pub year: i64,
    /// Month, 1 to 12.
    pub month: u32,
    /// Day of the month.
    pub day: u32,
    /// 0 for Sunday to 6 for Saturday.
    pub weekday: u32,
    /// Hour, 0 to 23.
    pub hour: u32,
    /// Minute.
    pub minute: u32,
}

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];
const WEEKDAYS: [&str; 7] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
];

impl Local {
    /// The local date and time of `ts_us` at `tz` seconds east of UTC.
    #[must_use]
    pub fn of(ts_us: u64, tz: i32) -> Self {
        let local_secs = i128::from(ts_us / 1_000_000) + i128::from(tz);
        let days = local_secs.div_euclid(86_400);
        let secs = local_secs.rem_euclid(86_400);
        // Days to a civil date (Howard Hinnant's algorithm).
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z - era * 146_097;
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = if mp < 10 { mp + 3 } else { mp - 9 };
        let year = yoe + era * 400 + i128::from(month <= 2);
        let small = |value: i128| u32::try_from(value).unwrap_or(0);
        Self {
            year: i64::try_from(year).unwrap_or(0),
            month: small(month),
            day: small(day),
            weekday: small((days + 4).rem_euclid(7)),
            hour: small(secs / 3_600),
            minute: small(secs % 3_600 / 60),
        }
    }

    /// "9:02 AM".
    #[must_use]
    pub fn clock(&self) -> String {
        let hour = match self.hour % 12 {
            0 => 12,
            hour => hour,
        };
        let half = if self.hour < 12 { "AM" } else { "PM" };
        format!("{hour}:{:02} {half}", self.minute)
    }

    /// "October".
    #[must_use]
    pub fn month_name(&self) -> &'static str {
        MONTHS[usize::try_from(self.month.clamp(1, 12) - 1).unwrap_or(0)]
    }

    /// "Monday".
    #[must_use]
    pub fn weekday_name(&self) -> &'static str {
        WEEKDAYS[usize::try_from(self.weekday % 7).unwrap_or(0)]
    }

    /// "Oct 19".
    #[must_use]
    pub fn short_date(&self) -> String {
        format!("{} {}", &self.month_name()[..3], self.day)
    }

    /// "Monday, October 19".
    #[must_use]
    pub fn long_date(&self) -> String {
        format!(
            "{}, {} {}",
            self.weekday_name(),
            self.month_name(),
            self.day
        )
    }

    /// `YYYY-MM-DD`.
    #[must_use]
    pub fn date_string(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }

    /// Saturday or Sunday.
    #[must_use]
    pub fn is_weekend(&self) -> bool {
        self.weekday == 0 || self.weekday == 6
    }
}

// ---------------------------------------------------------------------------
// The world
// ---------------------------------------------------------------------------

/// A screenshot the week needs: what the drawing tool draws for it.
#[derive(Debug, Clone, PartialEq)]
pub struct Screen {
    /// Stable id, as the moments name it.
    pub id: String,
    /// The drawing to use: `editor`, `terminal`, `browser`, `slack`, `zoom`,
    /// `notion`, `figma` or `calendar`.
    pub template: &'static str,
    /// Everything the drawing needs beyond the window's text.
    pub meta: Value,
}

/// One window as it was on screen: what each of its moments stores.
#[derive(Debug, Clone, PartialEq)]
pub struct Win {
    /// The app's bundle id.
    pub app: &'static str,
    /// The window title.
    pub title: String,
    /// The page address, for a browser.
    pub url: Option<String>,
    /// What the window said: the reading's text.
    pub main: String,
    /// The window's own tabs, bars and side panels ("Also in this window").
    pub rest: String,
    /// The line History leads with.
    pub caption: String,
    /// Its screenshot.
    pub screen: Option<Screen>,
}

/// One window held in front for some minutes, one moment a minute.
#[derive(Debug, Clone, PartialEq)]
pub struct Hold {
    /// The window.
    pub win: Win,
    /// How long.
    pub minutes: u64,
}

/// What the understanding worker wrote about a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    /// Its title.
    pub title: String,
    /// What was on screen and what was done.
    pub surface: String,
    /// What lay beneath.
    pub beneath: String,
}

/// A run of work: windows held one after another.
#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    /// When it began.
    pub start_us: u64,
    /// Its windows, in order.
    pub holds: Vec<Hold>,
    /// Its note; none while it is still going.
    pub note: Option<Note>,
}

impl Session {
    /// When its last minute ends.
    #[must_use]
    pub fn end_us(&self) -> u64 {
        self.start_us + self.holds.iter().map(|h| h.minutes).sum::<u64>() * MIN
    }
}

/// One local day of the week.
#[derive(Debug, Clone, PartialEq)]
pub struct DayStory {
    /// Days before today.
    pub back: u64,
    /// Local midnight starting it.
    pub start_us: u64,
    /// Its sessions, oldest first.
    pub sessions: Vec<Session>,
    /// The day's summary: headline and narrative, written by the model.
    pub summary: Option<(String, String)>,
}

/// One event on the demo calendar. Only the title, the time, the
/// calendar's name and the location, as the window reads a real one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalendarEvent {
    /// Stable id.
    pub id: String,
    /// Its title.
    pub title: String,
    /// Start.
    pub start_us: u64,
    /// End.
    pub end_us: u64,
    /// The calendar it is on.
    pub calendar: String,
    /// Where.
    pub location: Option<String>,
}

/// Where a line about Ren comes from: moments of windows whose titles hold
/// one of these words, up to `limit`, newest first.
#[derive(Debug, Clone, PartialEq)]
pub struct Claim {
    /// The line.
    pub text: String,
    /// What it is about.
    pub kind: PropositionKind,
    /// The model's confidence.
    pub confidence: f64,
    /// How fast it goes stale.
    pub decay: f64,
    /// Ren said it is right.
    pub confirmed: bool,
    /// Words in the titles of the moments that show it.
    pub evidence: Vec<&'static str>,
    /// Only moments from these days back (none: any day).
    pub days: Vec<u64>,
    /// When it was learned, in minutes before now.
    pub minutes_ago: u64,
}

/// The whole week.
#[derive(Debug, Clone, PartialEq)]
pub struct World {
    /// Its clock.
    pub now_us: u64,
    /// Its time zone, seconds east of UTC.
    pub tz: i32,
    /// Its days, oldest first; the last is today.
    pub days: Vec<DayStory>,
    /// The calendar.
    pub calendar: Vec<CalendarEvent>,
    /// What was learned about Ren.
    pub claims: Vec<Claim>,
}

/// Make the week that ends at `now_us`, at `tz` seconds east of UTC.
#[must_use]
pub fn world(now_us: u64, tz: i32) -> World {
    story::week(now_us, tz)
}

impl World {
    /// Every moment the week writes, in time order: when, which window, and
    /// whether it keeps a screenshot.
    #[must_use]
    pub fn moments(&self) -> Vec<(u64, &Win, bool)> {
        let mut out = Vec::new();
        for day in &self.days {
            for session in &day.sessions {
                let mut at = session.start_us;
                for hold in &session.holds {
                    for minute in 0..hold.minutes {
                        let ts = at + minute * MIN;
                        if ts > self.now_us.saturating_sub(NEWEST_AGE_US) {
                            break;
                        }
                        out.push((ts, &hold.win, minute % SCREENSHOT_EVERY_MINUTES == 0));
                    }
                    at += hold.minutes * MIN;
                }
            }
        }
        out
    }

    /// The screenshots to draw, each once, in the order first used.
    #[must_use]
    pub fn screen_list(&self) -> Vec<(&Screen, &Win)> {
        let mut seen: Vec<&str> = Vec::new();
        let mut out = Vec::new();
        for (_, win, keeps) in self.moments() {
            let Some(screen) = win.screen.as_ref() else {
                continue;
            };
            if keeps && !seen.contains(&screen.id.as_str()) {
                seen.push(&screen.id);
                out.push((screen, win));
            }
        }
        out
    }

    /// The screen list for the drawing tool, as JSON.
    #[must_use]
    pub fn screens(&self) -> Value {
        let screens: Vec<Value> = self
            .screen_list()
            .into_iter()
            .map(|(screen, win)| {
                json!({
                    "id": screen.id,
                    "template": screen.template,
                    "app": win.app,
                    "title": win.title,
                    "url": win.url,
                    "main": win.main,
                    "rest": win.rest,
                    "meta": screen.meta,
                })
            })
            .collect();
        json!({
            "version": SCREENS_VERSION,
            "now_us": self.now_us,
            "tz_offset_secs": self.tz,
            "screens": screens,
        })
    }

    /// The demo calendar, as the window reads it.
    #[must_use]
    pub fn calendar_json(&self) -> Value {
        let events: Vec<Value> = self
            .calendar
            .iter()
            .map(|event| {
                json!({
                    "id": event.id,
                    "title": event.title,
                    "start_us": event.start_us,
                    "end_us": event.end_us,
                    "calendar": event.calendar,
                    "location": event.location,
                })
            })
            .collect();
        json!({ "version": CALENDAR_VERSION, "events": events })
    }
}

// ---------------------------------------------------------------------------
// Writing it
// ---------------------------------------------------------------------------

/// What [`seed`] wrote.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Written {
    /// Moments.
    pub moments: usize,
    /// Moments that keep a screenshot.
    pub screenshots: usize,
    /// Session notes.
    pub notes: usize,
    /// Lines about Ren.
    pub claims: usize,
}

/// The screenshots' sealed blobs, by screen id, from the drawing tool's
/// manifest: `{"version": 1, "screens": {"<id>": "<sha256 hex>"}}`.
///
/// # Errors
/// A manifest that is not that shape, or names a digest that is not 64
/// lowercase hexadecimal characters.
pub fn read_manifest(text: &str) -> Result<HashMap<String, String>, String> {
    let value: Value = serde_json::from_str(text).map_err(|e| format!("screens manifest: {e}"))?;
    if value.get("version").and_then(Value::as_u64) != Some(u64::from(SCREENS_VERSION)) {
        return Err("screens manifest: unknown version".into());
    }
    let screens = value
        .get("screens")
        .and_then(Value::as_object)
        .ok_or("screens manifest: no screens")?;
    let mut out = HashMap::new();
    for (id, digest) in screens {
        let digest = digest
            .as_str()
            .ok_or("screens manifest: a digest is not text")?;
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("screens manifest: a digest is not 64 lowercase hex characters".into());
        }
        out.insert(id.clone(), digest.to_owned());
    }
    Ok(out)
}

fn put_moment(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    win: &Win,
    keyframe: Option<&str>,
) -> Result<i64, String> {
    // The text as the reader stores it: its header line, the window's
    // chrome first (tabs and bars sit at the top), then what it said.
    let body = if win.rest.is_empty() {
        win.main.clone()
    } else {
        format!("{}\n{}", win.rest, win.main)
    };
    let text = format!(
        "{}{body}",
        mci_agent::brain_ingest::compose_context_header(
            Some(win.app),
            Some(&win.title),
            win.url.as_deref(),
            ts_us,
        )
    );
    let event = Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(win.app.to_owned()),
        window_title: Some(win.title.clone()),
        url: win.url.clone(),
        text,
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: keyframe.map(str::to_owned),
        tab_id: None,
        embedding: None,
    };
    let id = store
        .put_event_with_source(&event, EventSource::ScreenOcr)
        .map_err(|e| format!("put event: {e}"))?;
    // Its reading and caption, as the re-clean job keeps them: the window's
    // text with its chrome set apart, and a line about it.
    let moment = StoredMoment {
        id,
        ts_us,
        app_bundle_id: event.app_bundle_id.clone(),
        window_title: event.window_title.clone(),
        url: event.url.clone(),
        text: event.text.clone(),
        source: EventSource::ScreenOcr,
    };
    let reading = MomentReading {
        event_id: id,
        version: READING_VERSION,
        reading: Some(Reading {
            main: win.main.clone(),
            rest: win.rest.clone(),
        }),
        caption: Some(win.caption.clone()),
        caption_by: Some(MODEL.to_owned()),
        model_tried: true,
        updated_us: ts_us + 10 * MIN,
    };
    store
        .put_moment_reading(&reading, &moment)
        .map_err(|e| format!("reading: {e}"))?;
    i64::try_from(id.0).map_err(|_| "event id".to_owned())
}

/// Input in the window's app for each written minute, as the helper
/// measures it: five-second samples.
fn activity(
    store: &SqlCipherBrainStore,
    start_us: u64,
    end_us: u64,
    app: &str,
) -> Result<(), String> {
    let mut at = start_us;
    while at + 5_000_000 <= end_us {
        let interval = ActivityInterval {
            start_us: at,
            end_us: at + 5_000_000,
            state: ActivityState::InputActive,
            app_bundle_id: Some(app.to_owned()),
            capture_generation: "demo-week".into(),
        };
        store
            .append_activity_interval(&interval)
            .map_err(|e| format!("activity: {e}"))?;
        at += 5_000_000;
    }
    Ok(())
}

fn claim(item: &Claim) -> NewProposition {
    NewProposition {
        text: item.text.clone(),
        reasoning: "Made up for Demo Memory.".into(),
        kind: item.kind,
        confidence: item.confidence,
        decay: item.decay,
        model: MODEL.into(),
    }
}

/// One written moment, for evidence.
struct Kept {
    id: i64,
    back: u64,
    title: String,
}

/// One session's written moments, for its note.
struct Noted<'w> {
    session: &'w Session,
    events: Vec<ObservedEvent>,
}

/// Write `world` into `store`, with the screenshots `digests` names (by
/// screen id; a screen missing from it leaves its moments text only).
///
/// # Errors
/// The store refusing a write.
pub fn seed(
    store: &SqlCipherBrainStore,
    world: &World,
    digests: &HashMap<String, String>,
) -> Result<Written, String> {
    let mut written = Written::default();
    let mut kept: Vec<Kept> = Vec::new();
    let mut noted: Vec<Noted<'_>> = Vec::new();
    let cutoff = world.now_us.saturating_sub(NEWEST_AGE_US);
    for day in &world.days {
        for session in &day.sessions {
            let mut events = Vec::new();
            let mut at = session.start_us;
            for hold in &session.holds {
                if at <= cutoff {
                    let end = (at + hold.minutes * MIN).min(world.now_us);
                    activity(store, at, end, hold.win.app)?;
                }
                for minute in 0..hold.minutes {
                    let ts = at + minute * MIN;
                    if ts > cutoff {
                        break;
                    }
                    let keyframe = hold
                        .win
                        .screen
                        .as_ref()
                        .filter(|_| minute % SCREENSHOT_EVERY_MINUTES == 0)
                        .and_then(|screen| digests.get(&screen.id))
                        .map(String::as_str);
                    let id = put_moment(store, ts, &hold.win, keyframe)?;
                    written.moments += 1;
                    written.screenshots += usize::from(keyframe.is_some());
                    kept.push(Kept {
                        id,
                        back: day.back,
                        title: hold.win.title.clone(),
                    });
                    events.push(ObservedEvent {
                        id,
                        ts_us: ts,
                        app_bundle_id: Some(hold.win.app.into()),
                        window_title: Some(hold.win.title.clone()),
                        url: hold.win.url.clone(),
                        text: hold.win.main.clone(),
                        source: "screen_ocr".into(),
                    });
                }
                at += hold.minutes * MIN;
            }
            noted.push(Noted { session, events });
        }
    }
    // Searches come from the pages' addresses, as the agent reads them.
    let mut after = 0;
    loop {
        let (_, last) = store
            .backfill_search_queries(after, 1_000)
            .map_err(|e| format!("searches: {e}"))?;
        if last == after {
            break;
        }
        after = last;
    }
    let mut noted_through = 0;
    for Noted { session, events } in &noted {
        let (Some(note), Some(last)) = (session.note.as_ref(), events.last()) else {
            continue;
        };
        put_note(store, session, note, events, last.ts_us, world.now_us)?;
        written.notes += 1;
        noted_through = noted_through.max(last.ts_us + 1);
    }
    for day in &world.days {
        if let Some((headline, narrative)) = day.summary.as_ref() {
            put_summary(store, world, day, headline, narrative)?;
        }
    }
    for item in &world.claims {
        let evidence = evidence(&kept, item);
        if evidence.is_empty() {
            continue;
        }
        let learned = world.now_us.saturating_sub(item.minutes_ago * MIN);
        let id = store
            .insert_proposition(&claim(item), &evidence, learned)
            .map_err(|e| format!("item: {e}"))?;
        if item.confirmed {
            store
                .confirm_proposition(id, learned)
                .map_err(|e| format!("confirm: {e}"))?;
        }
        written.claims += 1;
    }
    ModelStatus {
        state: "available".into(),
        reason: None,
        checked_us: Some(world.now_us.saturating_sub(20 * MIN)),
    }
    .write(store)
    .map_err(|e| format!("model status: {e}"))?;
    mci_agent::understanding::mark_noted_through(store, noted_through)
        .map_err(|e| format!("state: {e}"))?;
    Ok(written)
}

/// A session's note, with the segments and signals the worker keeps.
fn put_note(
    store: &SqlCipherBrainStore,
    session: &Session,
    note: &Note,
    events: &[ObservedEvent],
    end: u64,
    now_us: u64,
) -> Result<(), String> {
    let segments = observe::segments(events, &[], end);
    let mut searches = store
        .search_queries_in_range(session.start_us, end + 1, 50)
        .map_err(|e| format!("searches: {e}"))?;
    searches.reverse();
    let signals = observe::signals(events, &segments, &searches);
    let signals_json = json!({
        "signals": &signals,
        "segments": segments.iter().map(|s| json!({
            "start_us": s.start_us, "end_us": s.end_us, "app": s.app,
            "name": mci_agent::understanding::apps::name(&s.app),
            "title": s.title,
            "host": s.url.as_deref().and_then(mci_agent::understanding::apps::host_of),
            "activity": s.activity(), "keys": s.keys, "events": s.event_ids,
        })).collect::<Vec<_>>(),
    });
    store
        .put_session_note(&SessionNote {
            start_us: session.start_us,
            end_us: end,
            title: note.title.clone(),
            surface: note.surface.clone(),
            beneath: note.beneath.clone(),
            signals: signals_json.to_string(),
            event_count: u32::try_from(events.len()).unwrap_or(u32::MAX),
            generated_us: (end + 5 * MIN).min(now_us),
            model: MODEL.into(),
        })
        .map_err(|e| format!("note: {e}"))
}

/// A day's summary, as the model writes it.
fn put_summary(
    store: &SqlCipherBrainStore,
    world: &World,
    day: &DayStory,
    headline: &str,
    narrative: &str,
) -> Result<(), String> {
    let date = Local::of(day.start_us + 12 * 60 * MIN, world.tz).date_string();
    store
        .put_day_report(&DayReport {
            date_local: date,
            start_us: day.start_us,
            end_us: day.start_us + DAY,
            generated_us: world.now_us.min(day.start_us + DAY - MIN),
            model: MODEL.into(),
            body: json!({ "narrative": {
                "headline": headline,
                "narrative": narrative,
                "insights": [],
                "suggestion": "",
            }})
            .to_string(),
        })
        .map_err(|e| format!("day report: {e}"))
}

/// The moments that show a line: of windows whose titles hold one of its
/// words, from its days, spread across the days they come from (the
/// newest of each window and day first), at most eight.
fn evidence(all: &[Kept], item: &Claim) -> Vec<i64> {
    let mut groups: BTreeMap<(u64, &str), Vec<i64>> = BTreeMap::new();
    for moment in all {
        let matches = item.evidence.iter().any(|word| moment.title.contains(word));
        let on_day = item.days.is_empty() || item.days.contains(&moment.back);
        if matches && on_day {
            groups
                .entry((moment.back, moment.title.as_str()))
                .or_default()
                .push(moment.id);
        }
    }
    let mut lists: Vec<Vec<i64>> = groups
        .into_values()
        .map(|mut ids| {
            ids.reverse();
            ids
        })
        .collect();
    let mut out = Vec::new();
    let mut round = 0;
    while out.len() < 8 && lists.iter().any(|ids| round < ids.len()) {
        for ids in &mut lists {
            if let Some(id) = ids.get(round) {
                if out.len() < 8 {
                    out.push(*id);
                }
            }
        }
        round += 1;
    }
    out
}

/// What [`seed`] needs to find in an empty store before it writes, so a
/// person's own memory is never written into.
///
/// # Errors
/// The store holding anything.
pub fn require_empty(store: &SqlCipherBrainStore) -> Result<(), String> {
    let existing = store
        .recent_events(1)
        .map_err(|e| format!("probe existing moments: {e}"))?;
    if existing.is_empty() {
        Ok(())
    } else {
        Err("the demo week is written only into an empty memory".into())
    }
}

#[cfg(test)]
#[path = "demo_week/tests.rs"]
mod tests;
