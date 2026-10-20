//! Re-cleaning memories: the chrome rules and captions, applied to moments
//! already stored, including those read before windows were classified.
//!
//! Each batch takes the newest moments without a reading of the current
//! version ([`READING_VERSION`]) from the days before today: a day still
//! being lived gains frames, so its moments are read once it is over. For
//! each, it learns the chrome of its app from that app's other moments the
//! same local day, sampled across the whole day ([`RepeatedChrome`]), and
//! writes its reading: the cleaned text when the learned lines moved
//! something, and a caption made from its title ([`caption::fallback`]).
//! Then, when an on-device model is there, it offers the newest captions made
//! from titles to it, a few at a time, and keeps a line only when
//! [`caption::accept`] does: grounded in that moment, naming something the
//! title does not, nothing about the person, no secret pattern. A moment in
//! a sensitive area (work, health, money, relationships, beliefs or the law)
//! is never offered to the model.
//!
//! - Non-destructive: only `moment_readings` is written. `events.text` keeps
//!   what was read, byte for byte, and stays what search indexes.
//! - Resumable: a row of the current version marks a moment done, so an
//!   interrupted batch loses nothing and no moment is made twice; a moment
//!   offered to the model is marked so, and not offered again, also when a
//!   new version changes only the reading's rules ([`CAPTION_RULES_SINCE`]).
//! - Bounded: a batch does at most its limits and stops at its deadline; a
//!   model request is given only the time left. When and how often batches
//!   run is the caller's choice; the agent runs them only plugged in and
//!   idle, and rests between them.
//! - Tied to the moment it read: a row is written only while the event with
//!   that id is still the moment that was read
//!   ([`SqlCipherBrainStore::put_moment_reading`]).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::caption::{self, Moment};
use crate::chrome::{title_key, Frame, RepeatedChrome};
use crate::moment_readings::{
    MomentReading, StoredMoment, CAPTION_BY_TITLE, CAPTION_RULES_SINCE, READING_VERSION,
};
use crate::reading::{body, reading, reading_with, Reading, TERMINAL_APPS, VISIBLE_OCR_SEPARATOR};
use crate::redaction::ocr_secrets::contains_secret;
use crate::{apps, EventId, EventSource, SqlCipherBrainStore, StoreError};

/// The span of one app's moments the many-frame rule learns from: a local
/// day.
pub const LEARNING_SPAN_US: u64 = 24 * 3_600 * 1_000_000;

/// The most moments of one app the many-frame rule reads for one span.
pub const LEARNING_FRAMES: usize = 400;

/// Moments offered to the model in one request.
pub const CAPTIONS_PER_REQUEST: usize = 6;

/// The most characters of a moment's text a model request carries.
pub const CAPTION_TEXT_CHARS: usize = 600;

/// What one batch may do.
#[derive(Debug, Clone, Copy)]
pub struct BatchLimits {
    /// Moments read and written.
    pub moments: usize,
    /// Moments offered to the model.
    pub captions: usize,
    /// Stop when this passes, between moments and between requests; a
    /// request is given only the time left.
    pub deadline: Option<Instant>,
    /// This Mac's offset from UTC, in seconds, for its local days.
    pub utc_offset_s: i32,
}

/// The start of the local day that holds `ts_us`, in microseconds since the
/// epoch.
#[must_use]
pub fn local_day_start(ts_us: u64, utc_offset_s: i32) -> u64 {
    let offset_us = i128::from(utc_offset_s) * 1_000_000;
    let local = i128::from(ts_us) + offset_us;
    let day = i128::from(LEARNING_SPAN_US);
    let start = local.div_euclid(day) * day - offset_us;
    u64::try_from(start.max(0)).unwrap_or(0)
}

/// One moment, as a caption request carries it to the on-device model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptionRequest {
    /// The app's name ("Chrome").
    pub app: String,
    /// The window title.
    pub title: String,
    /// The start of the moment's cleaned text.
    pub text: String,
}

/// The model cannot be used now (not there, or work waits for mains power).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelUnavailable(pub String);

/// Writes caption lines on this Mac. The agent's is `hippocampus-mind`.
pub trait Captioner {
    /// Who writes, as stored with what it wrote ("apple-foundation-models",
    /// "local:<model>").
    fn label(&self) -> String;

    /// One line per request, in order; `None` where the model gave none.
    /// `within` is the time the batch has left: a request that would take
    /// longer stops then.
    ///
    /// # Errors
    /// [`ModelUnavailable`] when the model cannot be used now (not there, the
    /// Mac is in use or on battery again, or the time ran out); the moments
    /// keep their captions and are offered again later.
    fn captions(
        &self,
        requests: &[CaptionRequest],
        within: Option<Duration>,
    ) -> Result<Vec<Option<String>>, ModelUnavailable>;
}

/// What a batch did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BatchStats {
    /// Moments given a reading of the current version.
    pub read: usize,
    /// …of which the learned chrome changed the text.
    pub cleaned: usize,
    /// Captions made from titles.
    pub captions_by_title: usize,
    /// Captions the model wrote that were used.
    pub captions_by_model: usize,
    /// Lines the model wrote that were not used.
    pub model_lines_not_used: usize,
    /// Why the model could not be used, when it could not.
    pub model_unavailable: Option<String>,
    /// The deadline passed before the batch was done.
    pub deadline_hit: bool,
    /// Nothing was left to do: every moment has a current reading and no
    /// caption waits for the model (or there is no model).
    pub caught_up: bool,
}

/// Run one batch. `now_us` stamps what it writes.
///
/// # Errors
/// Store failures. A moment deleted while the batch runs is skipped.
pub fn run_batch(
    store: &SqlCipherBrainStore,
    captioner: Option<&dyn Captioner>,
    limits: BatchLimits,
    now_us: u64,
) -> Result<BatchStats, StoreError> {
    let mut stats = BatchStats::default();
    let past = |deadline: Option<Instant>| deadline.is_some_and(|d| Instant::now() >= d);
    let today = local_day_start(now_us, limits.utc_offset_s);
    let moments = store.moments_to_read(READING_VERSION, limits.moments, today)?;
    let fewer_than_asked = moments.len() < limits.moments;
    let mut learned: HashMap<(String, u64), RepeatedChrome> = HashMap::new();
    // Rows an earlier version made, whose model captions may carry over.
    let ids: Vec<EventId> = moments.iter().map(|moment| moment.id).collect();
    let earlier = store.moment_readings(&ids)?;
    for moment in &moments {
        if past(limits.deadline) {
            stats.deadline_hit = true;
            return Ok(stats);
        }
        let before = earlier.get(&moment.id.0);
        let row = read_moment(
            store,
            moment,
            before,
            &mut learned,
            limits.utc_offset_s,
            now_us,
        )?;
        let cleaned = row.reading.is_some();
        let by_title = row.caption.is_some();
        if store.put_moment_reading(&row, moment)? {
            stats.read += 1;
            stats.cleaned += usize::from(cleaned);
            stats.captions_by_title += usize::from(by_title);
        }
    }
    let mut waiting = false;
    if let Some(captioner) = captioner.filter(|_| limits.captions > 0) {
        waiting = caption_with_model(store, captioner, limits, now_us, &mut stats)?;
    }
    stats.caught_up = fewer_than_asked && !waiting && !stats.deadline_hit;
    Ok(stats)
}

/// The screen text of a stored moment, for learning: the body, or for a
/// browser page read both ways the part read off the screen. `None` for text
/// that was not read off a screen.
fn screen_text(moment: &StoredMoment) -> Option<&str> {
    match moment.source {
        EventSource::ScreenOcr | EventSource::ScreenContext => Some(body(&moment.text)),
        EventSource::BrowserPageWithOcr => body(&moment.text)
            .split_once(VISIBLE_OCR_SEPARATOR)
            .map(|(_, seen)| seen),
        _ => None,
    }
}

fn learned_for<'a>(
    store: &SqlCipherBrainStore,
    moment: &StoredMoment,
    learned: &'a mut HashMap<(String, u64), RepeatedChrome>,
    utc_offset_s: i32,
) -> Result<Option<&'a RepeatedChrome>, StoreError> {
    let Some(app) = moment.app_bundle_id.as_deref() else {
        return Ok(None);
    };
    if screen_text(moment).is_none() || TERMINAL_APPS.contains(&app) {
        return Ok(None);
    }
    let day = local_day_start(moment.ts_us, utc_offset_s);
    let key = (app.to_owned(), day);
    if !learned.contains_key(&key) {
        let frames = store.moments_of_app(
            app,
            day,
            day.saturating_add(LEARNING_SPAN_US),
            LEARNING_FRAMES,
        )?;
        let chrome = RepeatedChrome::learn(
            frames.iter().filter_map(|frame| {
                Some(Frame {
                    title: frame.window_title.as_deref(),
                    text: screen_text(frame)?,
                })
            }),
            Some(app),
        );
        learned.insert(key.clone(), chrome);
    }
    Ok(learned.get(&key).filter(|chrome| !chrome.is_empty()))
}

/// The row for `moment` by the current rules. `before` is the row an
/// earlier version made, when there is one.
fn read_moment(
    store: &SqlCipherBrainStore,
    moment: &StoredMoment,
    before: Option<&MomentReading>,
    learned: &mut HashMap<(String, u64), RepeatedChrome>,
    utc_offset_s: i32,
    now_us: u64,
) -> Result<MomentReading, StoreError> {
    let app = moment.app_bundle_id.as_deref();
    let title = moment.window_title.as_deref();
    let live = reading(&moment.text, moment.source, app, title);
    let learned = learned_for(store, moment, learned, utc_offset_s)?;
    let cleaned = learned
        .map(|chrome| reading_with(&moment.text, moment.source, app, title, Some(chrome)))
        .filter(|cleaned| *cleaned != live)
        .filter(|cleaned| !contains_secret(&cleaned.main) && !contains_secret(&cleaned.rest));
    let main = cleaned
        .as_ref()
        .map_or(live.main.as_str(), |r| r.main.as_str());
    let shown = Moment {
        app,
        title,
        url: moment.url.as_deref(),
        text: main,
        beside: moment.source == EventSource::ScreenContext,
    };
    let caption = caption::fallback(&shown);
    // Surfaces that are not work get no caption, and the model is not asked;
    // nor is it asked about a moment in a sensitive area, or a window beside
    // the one in use.
    let not_work = app.is_none_or(|app| app.is_empty() || apps::is_noise(app));
    let not_for_the_model = not_work || shown.beside || caption::is_sensitive(&shown);
    let mut row = MomentReading {
        event_id: moment.id,
        version: READING_VERSION,
        caption_by: caption.as_ref().map(|_| CAPTION_BY_TITLE.to_owned()),
        caption,
        reading: None,
        model_tried: not_for_the_model,
        updated_us: now_us,
    };
    if let Some(before) = before {
        keep_model_caption(&mut row, before, &shown);
    }
    row.reading = cleaned;
    Ok(row)
}

/// When only the reading's rules changed since `before` was made (it is of
/// [`CAPTION_RULES_SINCE`] or later), `row` keeps what the model gave it:
/// that the model was asked, so it is not asked again, and the model's line,
/// when it wrote one that is still grounded in the moment as it now reads
/// (`shown`). A line that no longer is goes, and the moment is offered again.
/// A moment that is now not for the model keeps its caption from the title.
fn keep_model_caption(row: &mut MomentReading, before: &MomentReading, shown: &Moment<'_>) {
    if before.version < CAPTION_RULES_SINCE
        || before.version >= READING_VERSION
        || !before.model_tried
        || row.model_tried
    {
        return;
    }
    let by_model = before
        .caption_by
        .as_deref()
        .filter(|by| *by != CAPTION_BY_TITLE);
    let Some((line, by)) = before.caption.as_deref().zip(by_model) else {
        // Asked, and no line of the model's was used.
        row.model_tried = true;
        return;
    };
    if let Some(line) = caption::accept(line, shown) {
        row.caption = Some(line);
        row.caption_by = Some(by.to_owned());
        row.model_tried = true;
    }
}

/// Offer the newest captions made from titles to the model. Returns whether
/// some are still waiting for it.
fn caption_with_model(
    store: &SqlCipherBrainStore,
    captioner: &dyn Captioner,
    limits: BatchLimits,
    now_us: u64,
    stats: &mut BatchStats,
) -> Result<bool, StoreError> {
    let pending = store.moments_awaiting_model_caption(limits.captions)?;
    if pending.is_empty() {
        return Ok(false);
    }
    // A full page of them: more may wait behind it.
    let more_behind = pending.len() >= limits.captions;
    // Moments of one window (one app, one title) are asked about once, with
    // the newest one's text: a run of moments gets one caption. The line is
    // still checked against each moment's own text, and kept only where it
    // is grounded there.
    let mut groups: Vec<(CaptionRequest, Vec<(StoredMoment, Reading)>)> = Vec::new();
    let mut by_key: HashMap<(String, String), usize> = HashMap::new();
    for (moment, row) in pending {
        let shown = row.reading.clone().unwrap_or_else(|| {
            reading(
                &moment.text,
                moment.source,
                moment.app_bundle_id.as_deref(),
                moment.window_title.as_deref(),
            )
        });
        let text: String = shown.main.chars().take(CAPTION_TEXT_CHARS).collect();
        let app = moment
            .app_bundle_id
            .as_deref()
            .map(apps::name)
            .unwrap_or_default();
        let title = moment.window_title.clone().unwrap_or_default();
        let key = (app.clone(), title_key(&title));
        if let Some(&at) = by_key.get(&key) {
            groups[at].1.push((moment, shown));
        } else {
            by_key.insert(key, groups.len());
            groups.push((CaptionRequest { app, title, text }, vec![(moment, shown)]));
        }
    }
    let mut asked = 0usize;
    for chunk in groups.chunks(CAPTIONS_PER_REQUEST) {
        let within = limits
            .deadline
            .map(|deadline| deadline.saturating_duration_since(Instant::now()));
        if within.is_some_and(|left| left.is_zero()) {
            stats.deadline_hit = true;
            return Ok(true);
        }
        let requests: Vec<CaptionRequest> =
            chunk.iter().map(|(request, _)| request.clone()).collect();
        let answered = captioner.captions(&requests, within);
        if limits.deadline.is_some_and(|d| Instant::now() > d) {
            // The request ran past the batch's time: say so, so the worker
            // rests as long as the batch really took.
            stats.deadline_hit = true;
        }
        let lines = match answered {
            Ok(lines) => lines,
            Err(ModelUnavailable(reason)) => {
                stats.model_unavailable = Some(reason);
                return Ok(true);
            }
        };
        // Who wrote: known once the model has answered.
        let label = captioner.label();
        for (index, (_, moments)) in chunk.iter().enumerate() {
            let line = lines.get(index).cloned().flatten();
            for (moment, shown) in moments {
                let accepted = line.as_deref().and_then(|line| {
                    caption::accept(
                        line,
                        &Moment {
                            app: moment.app_bundle_id.as_deref(),
                            title: moment.window_title.as_deref(),
                            url: moment.url.as_deref(),
                            text: &shown.main,
                            beside: moment.source == EventSource::ScreenContext,
                        },
                    )
                });
                match &accepted {
                    Some(_) => stats.captions_by_model += 1,
                    None if line.is_some() => stats.model_lines_not_used += 1,
                    None => {}
                }
                store.set_model_caption(
                    moment,
                    accepted.as_deref().map(|line| (line, label.as_str())),
                    now_us,
                )?;
            }
        }
        asked += chunk.len();
    }
    Ok(more_behind || asked < groups.len())
}
