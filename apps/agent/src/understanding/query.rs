//! Read-only views of the understanding layer, shared by the CLI, MCP and the
//! app: a day, searches, the user model, sessions, answers and suggestions.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use mci_brain::reading::{self, ExcerptQuery, Reading};
use mci_brain::understanding::{
    ObservedEvent, Proposition, PropositionKind, PropositionStatus, SearchRecord, SessionNote,
};
use mci_brain::{EventRecord, EventSource, SqlCipherBrainStore, StoreError};

use super::mind::{MindCallError, MindClient};
use super::sending::{self, Gate, Sending};
use super::{apps, observe, Understanding};
use crate::brief_worker::local_date_string;

/// What to read.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "view", rename_all = "snake_case")]
pub enum UnderstandingQuery {
    /// A day's breakdown and account (`date` defaults to today).
    Day {
        /// `YYYY-MM-DD`.
        date: Option<String>,
    },
    /// Searches in the last `hours`.
    Searches {
        /// Hours back (default 24, at most 24 * 31).
        hours: Option<u64>,
        /// Most to return (default 50).
        limit: Option<usize>,
    },
    /// What Hippocampus understands about the user.
    UserModel {
        /// Optional topic to focus on.
        query: Option<String>,
        /// Most to return (default 20).
        limit: Option<usize>,
        /// The You page's shape ([`model_page`]) instead of a list. Only the
        /// CLI asks for it; the MCP server drops it.
        #[serde(default)]
        page: Option<bool>,
    },
    /// A day's sessions: surface and beneath.
    Sessions {
        /// `YYYY-MM-DD`.
        date: Option<String>,
    },
    /// The day overview the window draws ([`super::overview`]). CLI only.
    Overview {
        /// `YYYY-MM-DD`.
        date: Option<String>,
    },
}

fn today(tz: i32, now_us: u64) -> String {
    local_date_string(i64::try_from(now_us / 1_000_000).unwrap_or(0), tz)
}

/// `[local midnight, local midnight + 24 h)` of `date_local` in `tz`.
///
/// # Errors
/// A malformed date.
pub fn day_bounds(date_local: &str, tz: i32) -> Result<(u64, u64), StoreError> {
    let start_secs = crate::brief_worker::local_date_start_secs(date_local, tz)
        .ok_or_else(|| StoreError::InvalidInput("date must be YYYY-MM-DD".into()))?;
    let start_us = u64::try_from(start_secs)
        .unwrap_or(0)
        .saturating_mul(1_000_000);
    Ok((start_us, start_us + 86_400_000_000))
}

/// A proposition for display.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelItem {
    /// Id (for confirming or rejecting).
    pub id: i64,
    /// The statement.
    pub text: String,
    /// Why.
    pub reasoning: String,
    /// Kind.
    pub kind: String,
    /// 0–1.
    pub confidence: f64,
    /// When it last changed.
    pub updated_us: u64,
    /// Evidence event ids.
    pub evidence: Vec<i64>,
}

impl From<Proposition> for ModelItem {
    fn from(p: Proposition) -> Self {
        Self {
            id: p.id,
            text: p.text,
            reasoning: p.reasoning,
            kind: p.kind.as_str().into(),
            confidence: p.confidence,
            updated_us: p.updated_us,
            evidence: p.evidence,
        }
    }
}

/// Run a read-only query.
///
/// # Errors
/// Store failures and malformed dates.
pub fn run(
    store: &Arc<SqlCipherBrainStore>,
    tz: i32,
    now_us: u64,
    query: &UnderstandingQuery,
) -> Result<serde_json::Value, StoreError> {
    let reader = Understanding::new(
        Arc::clone(store),
        Arc::new(MindClient::new(None)),
        tz,
        String::new(),
        None,
    );
    Ok(match query {
        UnderstandingQuery::Day { date } => {
            let date = date.clone().unwrap_or_else(|| today(tz, now_us));
            let day = reader.day(&date, now_us)?;
            serde_json::json!({ "day": day, "facts": day.breakdown.facts(tz) })
        }
        UnderstandingQuery::Searches { hours, limit } => {
            let hours = hours.unwrap_or(24).clamp(1, 24 * 31);
            let searches = store.search_queries_in_range(
                now_us.saturating_sub(hours * 3_600_000_000),
                now_us + 1,
                limit.unwrap_or(50).clamp(1, 500),
            )?;
            serde_json::json!({ "searches": searches.iter().map(|s| search_json(s, tz)).collect::<Vec<_>>() })
        }
        UnderstandingQuery::UserModel {
            page: Some(true), ..
        } => model_page(store, tz, now_us)?,
        UnderstandingQuery::UserModel { query, limit, .. } => {
            let limit = limit.unwrap_or(20).clamp(1, 200);
            let candidates: Vec<Proposition> =
                if let Some(q) = query.as_deref().map(str::trim).filter(|q| !q.is_empty()) {
                    store
                        .search_propositions(q, limit)?
                        .into_iter()
                        .map(|(p, _)| p)
                        .collect()
                } else {
                    let mut all = store.propositions_with_status(PropositionStatus::Active, 500)?;
                    all.sort_by(|a, b| {
                        b.confidence
                            .total_cmp(&a.confidence)
                            .then(b.updated_us.cmp(&a.updated_us))
                    });
                    all
                };
            // Only what may go to AI tools: confirmed, or corroborated.
            let lens = ItemLens::read(store, &candidates, tz, now_us)?;
            let mut items: Vec<ModelItem> = Vec::new();
            for p in candidates {
                if items.len() == limit {
                    break;
                }
                if lens.served(store, &p)? {
                    items.push(ModelItem::from(p));
                }
            }
            serde_json::json!({ "propositions": items })
        }
        UnderstandingQuery::Sessions { date } => {
            let date = date.clone().unwrap_or_else(|| today(tz, now_us));
            let (start_us, end_us) = day_bounds(&date, tz)?;
            let notes = store.session_notes_in_range(start_us, end_us)?;
            serde_json::json!({ "date": date, "sessions": notes.iter().map(|n| session_json(n, tz)).collect::<Vec<_>>() })
        }
        UnderstandingQuery::Overview { date } => {
            let env = super::overview::OverviewEnv::default();
            serde_json::to_value(super::overview::overview(
                store,
                date.as_deref(),
                tz,
                now_us,
                &env,
            )?)
            .unwrap_or_default()
        }
    })
}

fn search_json(s: &SearchRecord, tz: i32) -> serde_json::Value {
    serde_json::json!({
        "query": s.query, "engine": s.engine, "ts_us": s.ts_us, "time": observe::clock(s.ts_us, tz),
        "app": s.app_bundle_id.as_deref().map(apps::name), "url": s.url, "event_id": s.event_id,
    })
}

fn session_json(n: &SessionNote, tz: i32) -> serde_json::Value {
    let signals: serde_json::Value = serde_json::from_str(&n.signals).unwrap_or_default();
    let kind = super::overview::stored_segments(n).map_or(apps::WorkKind::Other, |segments| {
        super::overview::kind_of_segments(&segments).0
    });
    serde_json::json!({
        "start_us": n.start_us, "end_us": n.end_us,
        "time": format!("{}–{}", observe::clock(n.start_us, tz), observe::clock(n.end_us, tz)),
        // Without any sentence about pauses, input counts or judgements
        // (RULINGS I14); notes written before the model stopped seeing input
        // still carry them.
        "title": n.title, "surface": super::overview::model_prose(&n.surface),
        "beneath": super::overview::model_prose(&n.beneath), "written_by": n.model,
        "kind": kind.as_str(), "kind_label": kind.label(),
        "segments": signals["segments"], "searches": signals["signals"]["searches"],
    })
}

// ---------------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------------

/// Number recalled hits as citable memories.
#[must_use]
pub fn sources_from_hits(hits: Vec<crate::mcp::McpHit>) -> Vec<Source> {
    hits.into_iter()
        .enumerate()
        .map(|(index, hit)| Source {
            n: index + 1,
            event_id: i64::try_from(hit.record.event_id.0).unwrap_or(0),
            ts_us: hit.record.ts_us,
            app: apps::name(hit.record.app_bundle_id.as_deref().unwrap_or("")),
            title: hit.record.window_title.clone(),
            url: hit.record.url.clone(),
            text: hit.record.text_snippet,
        })
        .collect()
}

/// Recalled hits from any outcome.
#[must_use]
pub fn hits_of(outcome: crate::mcp::McpRecallOutcome) -> Vec<crate::mcp::McpHit> {
    match outcome {
        crate::mcp::McpRecallOutcome::Matched { hits } => hits,
        crate::mcp::McpRecallOutcome::Degraded {
            related_context, ..
        } => related_context,
        crate::mcp::McpRecallOutcome::Contradicted { evidence } => evidence,
        crate::mcp::McpRecallOutcome::NothingMatched { .. } => Vec::new(),
    }
}

/// The command bar's assistant: answers and suggestions with a warm model.
pub struct Assistant {
    store: Arc<SqlCipherBrainStore>,
    mind: MindClient,
    tz: i32,
    user_name: String,
}

impl Assistant {
    /// Build over a store with the bundled model.
    #[must_use]
    pub fn new(store: Arc<SqlCipherBrainStore>, mind: MindClient) -> Self {
        Self {
            store,
            mind,
            tz: crate::brief_worker::current_tz_offset_secs(),
            user_name: super::Understanding::account_first_name(),
        }
    }

    fn now_us() -> u64 {
        u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_micros(),
        )
        .unwrap_or(u64::MAX)
    }

    /// Answer a question from recalled memories.
    ///
    /// # Errors
    /// Store failures.
    pub fn ask(
        &self,
        question: &str,
        now: Option<&str>,
        looking_at: &NowContext,
        memories: Vec<Source>,
    ) -> Result<Answer, StoreError> {
        let now_us = Self::now_us();
        let screen = on_screen(&self.store, now_us, looking_at)?;
        // A window was named but Hippocampus has not read it: say so, or the
        // model answers a question about the screen with the app's name.
        let unread =
            (screen.is_none() && looking_at.app.is_some()).then(|| unread_window_note(now));
        let now = unread.as_deref().or(now);
        answer(
            &self.store,
            &self.mind,
            &self.user_name,
            self.tz,
            now_us,
            question,
            now,
            screen.as_ref(),
            memories,
        )
    }

    /// Suggestions for the current moment.
    ///
    /// # Errors
    /// Store failures.
    pub fn suggest(
        &self,
        now: &NowContext,
        use_model: bool,
    ) -> Result<Vec<Suggestion>, StoreError> {
        suggest(
            &self.store,
            use_model.then_some(&self.mind),
            &self.user_name,
            self.tz,
            Self::now_us(),
            now,
        )
    }
}

/// A memory offered to the answerer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Source {
    /// Citation number.
    pub n: usize,
    /// Event id.
    pub event_id: i64,
    /// When.
    pub ts_us: u64,
    /// App name.
    pub app: String,
    /// Window title.
    pub title: Option<String>,
    /// URL.
    pub url: Option<String>,
    /// Excerpt.
    pub text: String,
}

/// An answer from memory.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Answer {
    /// The answer, or `None` when the model is unavailable.
    pub answer: Option<String>,
    /// The memories it cites (or, without a model, the best matches).
    pub sources: Vec<Source>,
    /// Why there is no answer, if there is none.
    pub unavailable: Option<String>,
}

#[derive(Deserialize)]
struct AnswerOut {
    answer: String,
    sources: Vec<usize>,
}

/// How recent a capture of the frontmost window must be to count as what is
/// on screen now.
const ON_SCREEN_WINDOW_US: u64 = 10 * 60 * 1_000_000;
/// With no matching title, only a capture this recent is taken for the
/// frontmost window.
const ON_SCREEN_UNTITLED_US: u64 = 2 * 60 * 1_000_000;
/// How much of the screen's text the on-device model is shown.
const ON_SCREEN_CHARS: usize = 2_400;

/// The newest capture of the window the user is looking at, if Hippocampus
/// read it recently. Only what capture already stored is used: an app it
/// never records has no capture, so nothing of it reaches an answer.
///
/// # Errors
/// Store failures.
pub fn on_screen(
    store: &SqlCipherBrainStore,
    now_us: u64,
    looking_at: &NowContext,
) -> Result<Option<ObservedEvent>, StoreError> {
    if looking_at.app.is_none() {
        return Ok(None);
    }
    let recent = store.observed_events_in_range(
        now_us.saturating_sub(ON_SCREEN_WINDOW_US),
        now_us + 1,
        2_000,
    )?;
    Ok(pick_on_screen(&recent, looking_at, now_us).cloned())
}

/// Of `recent` (oldest first), the capture that shows `looking_at`: the
/// newest with the same app and title, else the newest of that app within
/// two minutes (a title changes as a page loads or a file is edited).
#[must_use]
pub fn pick_on_screen<'a>(
    recent: &'a [ObservedEvent],
    looking_at: &NowContext,
    now_us: u64,
) -> Option<&'a ObservedEvent> {
    let app = looking_at.app.as_deref()?;
    let of_app = || {
        recent
            .iter()
            .rev()
            .filter(move |e| e.app_bundle_id.as_deref() == Some(app) && !e.text.trim().is_empty())
    };
    looking_at
        .title
        .as_deref()
        .and_then(|title| of_app().find(|e| e.window_title.as_deref() == Some(title)))
        .or_else(|| of_app().find(|e| now_us.saturating_sub(e.ts_us) <= ON_SCREEN_UNTITLED_US))
}

/// The start and the end of a long text: a window's heading and its newest
/// lines both matter, and the model cannot be shown everything.
#[must_use]
pub fn excerpt(text: &str, limit: usize) -> String {
    let count = text.chars().count();
    if count <= limit {
        return text.to_owned();
    }
    let head = limit * 5 / 8;
    let tail = limit - head;
    let start: String = text.chars().take(head).collect();
    let end: String = text.chars().skip(count - tail).collect();
    format!("{start}\n…\n{end}")
}

fn unread_window_note(now: Option<&str>) -> String {
    let unknown = "Hippocampus has not read the window in front, so what is in it is not known.";
    match now.map(str::trim).filter(|n| !n.is_empty()) {
        Some(now) => format!("{now}. {unknown}"),
        None => unknown.to_owned(),
    }
}

/// What an answer shows as its sources. The screen, when the model was shown
/// it, is always first: the person should see what was looked at whether or
/// not the model said it used it. Then the memories it cited; with no screen
/// and nothing cited, the three best matches.
fn answer_sources(screen: Option<Source>, memories: Vec<Source>, cited: &[usize]) -> Vec<Source> {
    let cited_memories: Vec<Source> = memories
        .iter()
        .filter(|m| cited.contains(&m.n))
        .cloned()
        .collect();
    match screen {
        Some(screen) => std::iter::once(screen).chain(cited_memories).collect(),
        None if cited_memories.is_empty() => memories.into_iter().take(3).collect(),
        None => cited_memories,
    }
}

/// What was on the screen in a capture: for a browser page read both ways,
/// the part read off the screen (T10), otherwise the reading. Never the
/// stored header.
fn screen_text(event: &ObservedEvent) -> Reading {
    reading::screen_reading(
        &event.text,
        EventSource::from_stored(&event.source),
        event.app_bundle_id.as_deref(),
        event.window_title.as_deref(),
    )
}

fn screen_source(event: &ObservedEvent) -> Source {
    let app = event.app_bundle_id.as_deref();
    let shown = reading::excerpt(
        &screen_text(event),
        app,
        &ExcerptQuery::default(),
        EventRecord::SNIPPET_MAX_CHARS,
    );
    Source {
        n: 1,
        event_id: event.id,
        ts_us: event.ts_us,
        app: apps::name(app.unwrap_or("")),
        title: event.window_title.clone(),
        url: event.url.clone(),
        text: shown,
    }
}

/// Answer `question` from what is on screen now (`screen`, cited as 1),
/// retrieved memories and the user model. `now` names the frontmost app when
/// there is no capture of its window.
///
/// # Errors
/// Store failures.
#[allow(clippy::too_many_arguments)]
pub fn answer(
    store: &SqlCipherBrainStore,
    mind: &MindClient,
    user_name: &str,
    tz: i32,
    now_us: u64,
    question: &str,
    now: Option<&str>,
    screen: Option<&ObservedEvent>,
    memories: Vec<Source>,
) -> Result<Answer, StoreError> {
    // The screen is source 1; recalled memories follow it, without the same
    // event twice.
    let on_screen = screen.map(screen_source);
    let memories: Vec<Source> = match &on_screen {
        Some(screen) => memories
            .into_iter()
            .filter(|m| m.event_id != screen.event_id)
            .enumerate()
            .map(|(index, m)| Source { n: index + 2, ..m })
            .collect(),
        None => memories,
    };
    let now_text = match (&screen, &on_screen) {
        (Some(event), Some(source)) => Some(format!(
            "[1] {}\n{}",
            match &source.title {
                Some(t) => format!("{} — {t}", source.app),
                None => source.app.clone(),
            },
            excerpt(&screen_text(event).main, ON_SCREEN_CHARS)
        )),
        _ => now.map(str::to_owned),
    };
    let now = now_text.as_deref();
    let confirmed = store.confirmed_proposition_ids()?;
    let propositions: Vec<String> = store
        .search_propositions(question, 6)?
        .into_iter()
        .filter(|(p, _)| {
            p.status == PropositionStatus::Active
                && !not_seen_lately(p, confirmed.contains(&p.id), now_us)
        })
        .map(|(p, _)| p.text)
        .collect();
    let input = serde_json::json!({
        "user_name": user_name,
        "question": question,
        "now": now,
        "memories": memories.iter().map(|m| serde_json::json!({
            "n": m.n,
            "when": format!("{} {}", local_date_string(i64::try_from(m.ts_us / 1_000_000).unwrap_or(0), tz), observe::clock(m.ts_us, tz)),
            "source": match &m.title { Some(t) => format!("{} — {t}", m.app), None => m.app.clone() },
            "text": m.text,
        })).collect::<Vec<_>>(),
        "propositions": propositions,
        "today": today(tz, now_us),
    });
    match mind.call::<_, AnswerOut>("answer", &input, Duration::from_secs(60)) {
        Ok(out) => Ok(Answer {
            answer: Some(out.answer),
            sources: answer_sources(on_screen, memories, &out.sources),
            unavailable: None,
        }),
        Err(error) => Ok(Answer {
            answer: None,
            sources: on_screen.into_iter().chain(memories).collect(),
            unavailable: Some(match error {
                MindCallError::Unavailable(reason) => reason,
                other => other.to_string(),
            }),
        }),
    }
}

// ---------------------------------------------------------------------------
// What an AI client is told: one decision, used by the context packet, the
// session hook, the Overview's "Your AI already knows" and the You page
// ---------------------------------------------------------------------------

/// Recent work lines sent at the start of a session.
pub const RECENT_WORK_LINES: usize = 4;
/// How far back recent work reaches.
pub const RECENT_WORK_WINDOW_US: u64 = 12 * 3_600_000_000;
/// Items about the person sent with each request.
pub const ABOUT_YOU_LINES: usize = 6;
/// Below this an item goes to no AI tool unless the person confirmed it;
/// above it, only once corroborated ([`super::sending`]).
pub const ABOUT_YOU_MIN_CONFIDENCE: f64 = 0.75;
/// The most recently updated items the six are chosen from.
pub const ABOUT_YOU_CANDIDATES: usize = 60;
/// Items matching the focus, tried first.
pub const ABOUT_YOU_FOCUS_MATCHES: usize = 4;
/// A recent work line's title is clipped to this.
pub const TITLE_CHARS: usize = 80;
/// A recent work line's detail is clipped to this.
pub const DETAIL_CHARS: usize = 180;
/// An item is sent clipped to this.
pub const STATEMENT_CHARS: usize = 220;
/// A confirmed project or goal unseen this long is not seen lately.
pub const NOT_SEEN_LATELY_DAYS: u64 = 45;

const DAY_US: u64 = 86_400_000_000;

/// The kinds of thing about the user that go into context sent without being
/// asked for. People they work with, what took them several tries and how
/// they are right now stay behind `person_model`, which a client has to
/// call.
const SHARED_UNASKED: [PropositionKind; 5] = [
    PropositionKind::Project,
    PropositionKind::Goal,
    PropositionKind::Habit,
    PropositionKind::Preference,
    PropositionKind::Skill,
];

/// Too old to use: stale by decay ([`super::gum::is_stale`]), or a confirmed
/// project or goal not seen for [`NOT_SEEN_LATELY_DAYS`].
#[must_use]
pub fn not_seen_lately(p: &Proposition, confirmed: bool, now_us: u64) -> bool {
    super::gum::is_stale(p.decay, p.updated_us, now_us)
        || (confirmed
            && matches!(p.kind, PropositionKind::Project | PropositionKind::Goal)
            && now_us.saturating_sub(p.updated_us) >= NOT_SEEN_LATELY_DAYS * DAY_US)
}

/// The You page shows it, so the person can confirm or forget it. How a
/// person is right now is never shown, and what took them several tries only
/// once it was seen on two days or confirmed. Whether an AI tool may be given
/// it is [`is_served`] and [`is_shared_unasked`].
#[must_use]
pub fn is_servable(p: &Proposition, confirmed: bool, days_seen: usize, now_us: u64) -> bool {
    p.status == PropositionStatus::Active
        && p.kind != PropositionKind::State
        && !not_seen_lately(p, confirmed, now_us)
        && (p.kind != PropositionKind::Struggle || confirmed || days_seen >= 2)
}

/// An AI tool is given it when it looks the person up (`person_model`):
/// shown on You, and cleared to go to AI tools ([`super::sending`]).
#[must_use]
pub fn is_served(p: &Proposition, sending: Sending, days_seen: usize, now_us: u64) -> bool {
    sending.allowed() && is_servable(p, sending.confirmed(), days_seen, now_us)
}

/// Sent with each request without being asked (the six are chosen from
/// these): a kind sent unasked, in use, seen lately, and cleared to go to AI
/// tools ([`super::sending`]).
#[must_use]
pub fn is_shared_unasked(p: &Proposition, sending: Sending, now_us: u64) -> bool {
    p.status == PropositionStatus::Active
        && SHARED_UNASKED.contains(&p.kind)
        && sending.allowed()
        && !not_seen_lately(p, sending.confirmed(), now_us)
}

/// What is known about a set of propositions besides themselves: which the
/// person confirmed or forgot, on how many local dates each was seen, and
/// whether each may go to AI tools.
pub(crate) struct ItemLens {
    gate: Gate,
    pub(crate) heads: std::collections::HashMap<i64, mci_brain::understanding::EventHead>,
    tz: i32,
    now_us: u64,
}

impl ItemLens {
    /// The person's verdicts and one batch of event heads for all evidence.
    pub(crate) fn read(
        store: &SqlCipherBrainStore,
        items: &[Proposition],
        tz: i32,
        now_us: u64,
    ) -> Result<Self, StoreError> {
        let ids: Vec<i64> = items
            .iter()
            .flat_map(|p| p.evidence.iter().copied())
            .collect();
        let heads = store
            .event_heads(&ids)?
            .into_iter()
            .map(|h| (h.id, h))
            .collect();
        Ok(Self {
            gate: Gate::read(store, tz)?,
            heads,
            tz,
            now_us,
        })
    }

    pub(crate) fn confirmed(&self, p: &Proposition) -> bool {
        self.gate.is_confirmed(p)
    }

    /// Whether `p` may go to AI tools ([`super::sending`]). Reads the moments
    /// it rests on only when its scores, words and days leave it open.
    pub(crate) fn sending(
        &self,
        store: &SqlCipherBrainStore,
        p: &Proposition,
    ) -> Result<Sending, StoreError> {
        let heads = p
            .evidence
            .iter()
            .filter_map(|id| self.heads.get(id))
            .cloned()
            .collect();
        self.gate.sending_from_heads(store, p, heads)
    }

    /// Whether an AI tool that looks the person up is given `p`.
    pub(crate) fn served(
        &self,
        store: &SqlCipherBrainStore,
        p: &Proposition,
    ) -> Result<bool, StoreError> {
        if !self.servable(p) {
            return Ok(false);
        }
        Ok(is_served(
            p,
            self.sending(store, p)?,
            self.days_seen(p),
            self.now_us,
        ))
    }

    /// Distinct local dates among the moments the item rests on.
    pub(crate) fn days_seen(&self, p: &Proposition) -> usize {
        p.evidence
            .iter()
            .filter_map(|id| self.heads.get(id))
            .map(|h| local_date_string(i64::try_from(h.ts_us / 1_000_000).unwrap_or(0), self.tz))
            .collect::<std::collections::BTreeSet<_>>()
            .len()
    }

    pub(crate) fn servable(&self, p: &Proposition) -> bool {
        is_servable(p, self.confirmed(p), self.days_seen(p), self.now_us)
    }
}

/// One "Recent work" line: a noted session, titled as the Overview titles it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RecentWork {
    /// The session's start.
    pub start_us: u64,
    /// The session's end.
    pub end_us: u64,
    /// The Overview's title for it, clipped to [`TITLE_CHARS`].
    pub title: String,
    /// What a model wrote about it, clipped to [`DETAIL_CHARS`]; none for a
    /// session noted from measurements.
    pub detail: Option<String>,
}

impl RecentWork {
    /// As the packet and the hook send it: `14:02–14:31 · {title}: {detail}`.
    #[must_use]
    pub fn packet_line(&self, tz: i32) -> String {
        let times = format!(
            "{}–{}",
            observe::clock(self.start_us, tz),
            observe::clock(self.end_us, tz)
        );
        match &self.detail {
            Some(detail) => format!("{times} · {}: {detail}", self.title),
            None => format!("{times} · {}", self.title),
        }
    }

    /// As the window shows it: the same line with the times left to Swift.
    #[must_use]
    pub fn template(&self) -> super::overview::Template {
        let escape = super::overview::escape_braces;
        let text = match &self.detail {
            Some(detail) => format!(
                "{{start}}–{{end}} · {}: {}",
                escape(&self.title),
                escape(detail)
            ),
            None => format!("{{start}}–{{end}} · {}", escape(&self.title)),
        };
        super::overview::Template::new(text)
            .time("start", self.start_us)
            .time("end", self.end_us)
    }
}

/// The sessions an AI client is told about at the start of a session: the
/// newest noted sessions of the last [`RECENT_WORK_WINDOW_US`], newest first.
/// A session still going has no note yet and is not sent. Best effort: a
/// store failure yields no lines.
#[must_use]
pub fn recent_work(store: &SqlCipherBrainStore, now_us: u64) -> Vec<RecentWork> {
    store
        .session_notes_in_range(now_us.saturating_sub(RECENT_WORK_WINDOW_US), now_us + 1)
        .unwrap_or_default()
        .iter()
        .rev()
        .take(RECENT_WORK_LINES)
        .map(|note| RecentWork {
            start_us: note.start_us,
            end_us: note.end_us,
            title: clip(&super::overview::note_title(note).0, TITLE_CHARS),
            detail: session_detail(note).map(|detail| clip(&detail, DETAIL_CHARS)),
        })
        .collect()
}

/// What a model wrote about a session, fit to send: `beneath` (what the
/// person was trying to do), else `surface`, without any sentence the word
/// check drops, and never "Nothing notable." A note written from
/// measurements has none, so input counts are never sent.
fn session_detail(note: &SessionNote) -> Option<String> {
    if note.model == "measured" {
        return None;
    }
    [&note.beneath, &note.surface].into_iter().find_map(|text| {
        let kept = super::overview::model_prose(text);
        (!kept.is_empty() && kept != "Nothing notable.").then_some(kept)
    })
}

/// What an AI client is told about the person, the surest first: up to
/// [`ABOUT_YOU_LINES`] items sent unasked ([`is_shared_unasked`]), those
/// matching `focus` first. Only a line the person confirmed, or one
/// corroborated ([`super::sending`]), is ever sent. The session hook and the
/// window pass no focus. Best effort: a store failure yields none.
#[must_use]
pub fn about_you(
    store: &SqlCipherBrainStore,
    tz: i32,
    now_us: u64,
    focus: Option<&str>,
) -> Vec<Proposition> {
    let Ok(gate) = Gate::read(store, tz) else {
        return Vec::new();
    };
    let focused: Vec<Proposition> = focus
        .map(str::trim)
        .filter(|f| !f.is_empty())
        .and_then(|f| store.search_propositions(f, ABOUT_YOU_FOCUS_MATCHES).ok())
        .unwrap_or_default()
        .into_iter()
        .map(|(p, _)| p)
        .collect();
    let recent = store
        .propositions_with_status(PropositionStatus::Active, ABOUT_YOU_CANDIDATES)
        .unwrap_or_default();
    shared_claims(focused, recent, now_us, |p| {
        gate.sending(store, p)
            .unwrap_or(Sending::Held(sending::Held::TooFewMoments))
    })
}

/// The items sent unasked, `focused` first, then the surest of `recent`.
/// `sending` decides whether each may go to AI tools; it is asked only about
/// items that could otherwise be sent, in the order they are tried.
fn shared_claims(
    focused: Vec<Proposition>,
    mut recent: Vec<Proposition>,
    now_us: u64,
    mut sending: impl FnMut(&Proposition) -> Sending,
) -> Vec<Proposition> {
    recent.sort_by(|a, b| {
        b.confidence
            .total_cmp(&a.confidence)
            .then(b.updated_us.cmp(&a.updated_us))
    });
    let mut out: Vec<Proposition> = Vec::new();
    for p in focused.into_iter().chain(recent) {
        if out.len() == ABOUT_YOU_LINES {
            break;
        }
        if out.iter().any(|kept| kept.id == p.id)
            || p.status != PropositionStatus::Active
            || !SHARED_UNASKED.contains(&p.kind)
        {
            continue;
        }
        if is_shared_unasked(&p, sending(&p), now_us) {
            out.push(p);
        }
    }
    out
}

/// What an AI client is told about the user's work: the recent work lines
/// and the items sent unasked, those matching `focus` first. `None` when
/// there is nothing to tell. The context packet and the session hook both
/// take it from here, and the Overview and the You page show the same two
/// lists.
#[must_use]
pub fn context_understanding(
    store: &SqlCipherBrainStore,
    tz: i32,
    now_us: u64,
    focus: Option<&str>,
) -> Option<crate::context_packet::ContextUnderstanding> {
    use crate::context_packet::{ContextUnderstanding, ContextUnderstandingClaim};
    let sessions = recent_work(store, now_us)
        .iter()
        .map(|line| line.packet_line(tz))
        .collect();
    let about = about_you(store, tz, now_us, focus)
        .into_iter()
        .map(|p| ContextUnderstandingClaim {
            text: clip(&p.text, STATEMENT_CHARS),
            confidence: p.confidence,
            event_ids: p.evidence,
        })
        .collect();
    let understanding = ContextUnderstanding { sessions, about };
    (!understanding.is_empty()).then_some(understanding)
}

// ---------------------------------------------------------------------------
// The You page
// ---------------------------------------------------------------------------

/// Most items in each list of the page.
const PAGE_LIST_LIMIT: usize = 200;
/// Dated session rows under one item.
const EVIDENCE_SESSIONS: usize = 5;

/// One item on the You page.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PageItem {
    /// The proposition id, the one a verdict names.
    pub id: i64,
    /// The statement, exactly as stored and sent.
    pub text: String,
    /// `project`, `goal`, `habit`, `preference`, `skill`, `relationship`, `struggle`.
    pub kind: String,
    /// `working_on`, `how_you_work`, `skills`, `people`, `struggles`.
    pub group: String,
    /// `confirmed`, `seen_on_days` or `seen_once`.
    pub basis: String,
    /// Distinct local dates among the moments it rests on.
    pub days_seen: usize,
    /// The model's reasoning, as stored.
    pub reasoning: String,
    /// When it was last written or seen again.
    pub updated_us: u64,
    /// One dated row per session it rests on, newest first.
    pub evidence_sessions: Vec<EvidenceSession>,
}

/// A session an item was learned in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EvidenceSession {
    /// The session's start.
    pub start_us: u64,
    /// The session's end.
    pub end_us: u64,
    /// One of the item's moments in it, to open.
    pub open_event_id: i64,
    /// That moment's app.
    pub app_name: String,
    /// That moment's window title, cleaned.
    pub window_title: Option<String>,
}

fn group_of(kind: PropositionKind) -> (usize, &'static str) {
    match kind {
        PropositionKind::Project | PropositionKind::Goal => (0, "working_on"),
        PropositionKind::Habit | PropositionKind::Preference => (1, "how_you_work"),
        PropositionKind::Skill => (2, "skills"),
        PropositionKind::Relationship => (3, "people"),
        PropositionKind::Struggle | PropositionKind::State => (4, "struggles"),
    }
}

/// The You page (`mci-agent model --page --json`): the recent work lines as
/// sent, what an AI can be told about the person (`shared`), what it gets
/// only when it looks it up (`kept_back`), what goes to no AI tool until it
/// is corroborated or the person confirms it (`not_sent`,
/// [`super::sending`]), and what has not been seen lately. No counts, no
/// scores.
///
/// # Errors
/// Store failures.
pub fn model_page(
    store: &SqlCipherBrainStore,
    tz: i32,
    now_us: u64,
) -> Result<serde_json::Value, StoreError> {
    let all = store.propositions_with_status(PropositionStatus::Active, 500)?;
    let lens = ItemLens::read(store, &all, tz, now_us)?;
    let notes = evidence_notes(store, &lens)?;
    let mut shared = Vec::new();
    let mut kept_back = Vec::new();
    let mut not_sent = Vec::new();
    let mut not_seen = Vec::new();
    for p in &all {
        let confirmed = lens.confirmed(p);
        let days_seen = lens.days_seen(p);
        let list = if is_servable(p, confirmed, days_seen, now_us) {
            let sending = lens.sending(store, p)?;
            if is_shared_unasked(p, sending, now_us) {
                &mut shared
            } else if is_served(p, sending, days_seen, now_us) {
                &mut kept_back
            } else {
                &mut not_sent
            }
        } else if p.kind != PropositionKind::State
            && (p.kind != PropositionKind::Struggle || confirmed || days_seen >= 2)
            && not_seen_lately(p, confirmed, now_us)
        {
            &mut not_seen
        } else {
            continue;
        };
        list.push((p, confirmed, days_seen));
    }
    let shape = |mut list: Vec<(&Proposition, bool, usize)>| -> Vec<PageItem> {
        list.sort_by(|a, b| {
            group_of(a.0.kind)
                .0
                .cmp(&group_of(b.0.kind).0)
                .then(b.1.cmp(&a.1))
                .then(b.2.cmp(&a.2))
                .then(b.0.updated_us.cmp(&a.0.updated_us))
                .then(b.0.id.cmp(&a.0.id))
        });
        list.into_iter()
            .take(PAGE_LIST_LIMIT)
            .map(|(p, confirmed, days_seen)| PageItem {
                id: p.id,
                text: clip(p.text.trim(), 1_000),
                kind: p.kind.as_str().into(),
                group: group_of(p.kind).1.into(),
                basis: if confirmed {
                    "confirmed"
                } else if days_seen >= 2 {
                    "seen_on_days"
                } else {
                    "seen_once"
                }
                .into(),
                days_seen,
                reasoning: clip(&p.reasoning, 4_000),
                updated_us: p.updated_us,
                evidence_sessions: evidence_sessions(p, &lens, &notes),
            })
            .collect()
    };
    let recent: Vec<_> = recent_work(store, now_us)
        .iter()
        .map(RecentWork::template)
        .collect();
    Ok(serde_json::json!({
        "version": 1,
        "now_us": now_us,
        "model_status": super::overview::ModelStatus::read(store),
        "recent_work": recent,
        "shared": shape(shared),
        "kept_back": shape(kept_back),
        "not_sent": shape(not_sent),
        "not_seen_lately": shape(not_seen),
    }))
}

/// The stored session notes covering any item's moments: one read over the
/// span the moments cover.
fn evidence_notes(
    store: &SqlCipherBrainStore,
    lens: &ItemLens,
) -> Result<Vec<SessionNote>, StoreError> {
    let first = lens.heads.values().map(|h| h.ts_us).min();
    let last = lens.heads.values().map(|h| h.ts_us).max();
    match (first, last) {
        (Some(first), Some(last)) => store.session_notes_in_range(first, last + 1),
        _ => Ok(Vec::new()),
    }
}

fn evidence_sessions(
    p: &Proposition,
    lens: &ItemLens,
    notes: &[SessionNote],
) -> Vec<EvidenceSession> {
    use mci_brain::understanding::EventHead;
    let mut moments: Vec<&EventHead> = p
        .evidence
        .iter()
        .filter_map(|id| lens.heads.get(id))
        .collect();
    moments.sort_by_key(|h| (h.ts_us, h.id));
    let mut rows: Vec<EvidenceSession> = Vec::new();
    let mut loose: Vec<&EventHead> = Vec::new();
    let mut by_note: Vec<(&SessionNote, Vec<&EventHead>)> = Vec::new();
    for head in moments {
        match notes
            .iter()
            .find(|n| n.start_us <= head.ts_us && head.ts_us <= n.end_us)
        {
            Some(note) => match by_note.iter_mut().find(|(n, _)| std::ptr::eq(*n, note)) {
                Some((_, heads)) => heads.push(head),
                None => by_note.push((note, vec![head])),
            },
            None => loose.push(head),
        }
    }
    let row = |start_us: u64, end_us: u64, open: &EventHead| {
        let app = open.app_bundle_id.as_deref().unwrap_or("");
        let app_name = if app.is_empty() {
            String::new()
        } else {
            apps::name(app)
        };
        EvidenceSession {
            start_us,
            end_us,
            open_event_id: open.id,
            window_title: open
                .window_title
                .as_deref()
                .map(|t| super::overview::clean_title(t, &app_name))
                .filter(|t| !t.is_empty()),
            app_name,
        }
    };
    for (note, heads) in by_note {
        let in_longest = super::overview::stored_segments(note).and_then(|segments| {
            let longest = super::overview::longest_window_events(&segments);
            heads
                .iter()
                .rev()
                .find(|h| longest.contains(&h.id))
                .copied()
        });
        let open = in_longest.unwrap_or_else(|| *heads.last().expect("a note row has a moment"));
        rows.push(row(note.start_us, note.end_us, open));
    }
    let mut group: Vec<&EventHead> = Vec::new();
    for head in loose {
        if group
            .last()
            .is_some_and(|last| head.ts_us.saturating_sub(last.ts_us) >= observe::SESSION_GAP_US)
        {
            rows.push(row(
                group[0].ts_us,
                group[group.len() - 1].ts_us,
                group[group.len() - 1],
            ));
            group.clear();
        }
        group.push(head);
    }
    if let (Some(first), Some(last)) = (group.first(), group.last()) {
        rows.push(row(first.ts_us, last.ts_us, last));
    }
    rows.sort_by_key(|r| std::cmp::Reverse(r.end_us));
    rows.truncate(EVIDENCE_SESSIONS);
    rows
}

// ---------------------------------------------------------------------------
// Suggestions
// ---------------------------------------------------------------------------

/// Something the user likely wants right now.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Suggestion {
    /// `resume`, `searched`, `related`, `day`, or `predicted`.
    pub kind: String,
    /// Title.
    pub title: String,
    /// Why it is offered.
    pub why: String,
    /// What to do: a query to run, an event to open, or a view.
    pub action: serde_json::Value,
    /// 1–10.
    pub score: u8,
    /// When it happened, for the app to show in the person's own clock
    /// format; no time is ever written into `why`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ts_us: Option<u64>,
}

#[derive(Deserialize)]
struct SuggestOut {
    suggestions: Vec<SuggestItem>,
}

#[derive(Deserialize)]
struct SuggestItem {
    title: String,
    why: String,
    usefulness: u8,
}

/// What the user is looking at.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct NowContext {
    /// Frontmost app.
    pub app: Option<String>,
    /// Its window title.
    pub title: Option<String>,
}

/// Suggestions before the user types. Measured ones are instant; with
/// `use_model`, the on-device model adds predictions that clear a
/// usefulness bar (GUM's mixed-initiative rule: offer only when the expected
/// benefit beats the cost of a wrong guess).
///
/// # Errors
/// Store failures.
#[allow(clippy::too_many_lines)] // one block per kind of suggestion
pub fn suggest(
    store: &SqlCipherBrainStore,
    mind: Option<&MindClient>,
    user_name: &str,
    tz: i32,
    now_us: u64,
    now: &NowContext,
) -> Result<Vec<Suggestion>, StoreError> {
    let mut out = Vec::new();
    let hour = 3_600_000_000u64;
    // What is on screen now, from the latest capture of the frontmost window.
    let recent = store.observed_events_in_range(
        now_us.saturating_sub(ON_SCREEN_WINDOW_US),
        now_us + 1,
        2_000,
    )?;
    let current = pick_on_screen(&recent, now, now_us);
    // Ask about what is in front of them: the one thing every screen offers.
    if let Some(event) = current {
        let app = apps::name(event.app_bundle_id.as_deref().unwrap_or(""));
        out.push(Suggestion {
            kind: "screen".into(),
            title: "What’s on this screen?".into(),
            why: match &event.window_title {
                Some(title) if !title.is_empty() => format!("{app} · {}", clip(title, 60)),
                _ => app,
            },
            action: serde_json::json!({ "ask": "What is on my screen right now, and what matters in it?" }),
            score: 8,
            ts_us: None,
        });
    }
    // Resume: the last session that was not in the current window.
    let notes = store.session_notes_in_range(now_us.saturating_sub(12 * hour), now_us + 1)?;
    if let Some(last) = notes
        .iter()
        .rev()
        .find(|n| !now.title.as_deref().is_some_and(|t| n.title.contains(t)))
    {
        let (title, _) = super::overview::note_title(last);
        // A note written from measurements has only input telemetry for a
        // surface, which is never shown: name its main app instead.
        let why = session_detail(last).map_or_else(
            || {
                super::overview::stored_segments(last)
                    .and_then(|segments| {
                        segments
                            .into_iter()
                            .max_by_key(|s| s.end_us.saturating_sub(s.start_us))
                    })
                    .map(|s| apps::name(&s.app))
                    .unwrap_or_default()
            },
            |detail| first_sentence(&detail),
        );
        out.push(Suggestion {
            kind: "resume".into(),
            title: format!("Resume: {title}"),
            why,
            action: serde_json::json!({ "open_session": last.start_us }),
            score: 7,
            ts_us: Some(last.start_us),
        });
    }
    // Searches in the last two hours.
    for search in store.search_queries_in_range(now_us.saturating_sub(2 * hour), now_us + 1, 3)? {
        out.push(Suggestion {
            kind: "searched".into(),
            title: format!("“{}”", search.query),
            why: "You searched for this".into(),
            action: serde_json::json!({ "query": search.query }),
            score: 6,
            ts_us: Some(search.ts_us),
        });
    }
    // Related to the current window: what else you saw about it. Only a
    // window Hippocampus itself captured counts; a title from an app it
    // never records (a password manager, a private window) is not used.
    if let Some(title) = current.and_then(|e| e.window_title.clone()) {
        let topic = title
            .split([' ', '—', '-', '|'])
            .filter(|w| w.len() > 2)
            .take(6)
            .collect::<Vec<_>>()
            .join(" ");
        if !topic.is_empty() {
            out.push(Suggestion {
                kind: "related".into(),
                title: format!("More about {}", clip(&title, 48)),
                why: "Everything else you saw about this".into(),
                action: serde_json::json!({ "query": topic }),
                score: 5,
                ts_us: None,
            });
        }
    }
    // Counted as the You page lists them: what can be shown, nothing else.
    let active = store.propositions_with_status(PropositionStatus::Active, 500)?;
    let lens = ItemLens::read(store, &active, tz, now_us)?;
    let learned = active.iter().filter(|p| lens.servable(p)).count();
    if learned > 0 {
        out.push(Suggestion {
            kind: "model".into(),
            title: "What Hippocampus understands about you".into(),
            why: if learned == 1 {
                "One thing, from your own work. Fix anything wrong.".to_owned()
            } else {
                format!("{learned} things, from your own work. Fix anything wrong.")
            },
            action: serde_json::json!({ "view": "model" }),
            score: 3,
            ts_us: None,
        });
    }
    out.push(Suggestion {
        kind: "day".into(),
        title: "Your day so far".into(),
        why: "What you worked on and looked up".into(),
        action: serde_json::json!({ "view": "day" }),
        score: 4,
        ts_us: None,
    });
    if let Some(mind) = mind {
        let confirmed = store.confirmed_proposition_ids()?;
        let propositions: Vec<String> = store
            .propositions_with_status(PropositionStatus::Active, 24)?
            .into_iter()
            .filter(|p| !not_seen_lately(p, confirmed.contains(&p.id), now_us))
            .take(6)
            .map(|p| p.text)
            .collect();
        let now_text = current.map_or_else(
            || now.app.as_deref().map(apps::name).unwrap_or_default(),
            |e| {
                format!(
                    "{} — {}\n{}",
                    apps::name(e.app_bundle_id.as_deref().unwrap_or("")),
                    e.window_title.clone().unwrap_or_default(),
                    clip(&screen_text(e).main, 1_000)
                )
            },
        );
        let recent_lines: Vec<String> = notes
            .iter()
            .rev()
            .take(6)
            .map(|n| {
                let (title, _) = super::overview::note_title(n);
                match session_detail(n) {
                    Some(detail) => format!("{} {title}: {detail}", observe::clock(n.start_us, tz)),
                    None => format!("{} {title}", observe::clock(n.start_us, tz)),
                }
            })
            .collect();
        if let Ok(predicted) = mind.call::<_, SuggestOut>(
            "suggest",
            &serde_json::json!({ "user_name": user_name, "now": now_text, "recent": recent_lines, "propositions": propositions }),
            Duration::from_secs(30),
        ) {
            for item in predicted.suggestions.into_iter().filter(|s| s.usefulness >= 6) {
                out.push(Suggestion {
                    kind: "predicted".into(),
                    title: item.title.clone(),
                    why: item.why,
                    action: serde_json::json!({ "ask": item.title }),
                    score: item.usefulness.min(10),
                    ts_us: None,
                });
            }
        }
    }
    out.sort_by_key(|s| std::cmp::Reverse(s.score));
    out.truncate(7);
    Ok(out)
}

fn first_sentence(text: &str) -> String {
    clip(text.split(". ").next().unwrap_or(text), 120)
}

fn clip(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        text.to_owned()
    } else {
        text.chars().take(limit).collect::<String>() + "…"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seen(id: i64, ts_us: u64, app: &str, title: Option<&str>, text: &str) -> ObservedEvent {
        ObservedEvent {
            id,
            ts_us,
            app_bundle_id: Some(app.to_owned()),
            window_title: title.map(str::to_owned),
            url: None,
            text: text.to_owned(),
            source: "screen_ocr".to_owned(),
        }
    }

    fn looking_at(app: &str, title: Option<&str>) -> NowContext {
        NowContext {
            app: Some(app.to_owned()),
            title: title.map(str::to_owned),
        }
    }

    const MINUTE: u64 = 60 * 1_000_000;

    #[test]
    fn the_screen_is_the_newest_capture_of_the_window_in_front() {
        let recent = vec![
            seen(
                1,
                10 * MINUTE,
                "com.apple.Safari",
                Some("Pricing"),
                "old pricing text",
            ),
            seen(
                2,
                11 * MINUTE,
                "com.apple.Notes",
                Some("Launch plan"),
                "notes text",
            ),
            seen(
                3,
                12 * MINUTE,
                "com.apple.Safari",
                Some("Pricing"),
                "new pricing text",
            ),
            seen(
                4,
                13 * MINUTE,
                "com.apple.Safari",
                Some("Another tab"),
                "another tab",
            ),
        ];
        let picked = pick_on_screen(
            &recent,
            &looking_at("com.apple.Safari", Some("Pricing")),
            14 * MINUTE,
        );
        assert_eq!(picked.map(|e| e.id), Some(3));
    }

    #[test]
    fn a_changed_title_falls_back_to_a_capture_of_that_app_from_the_last_two_minutes() {
        let recent = vec![
            seen(
                1,
                5 * MINUTE,
                "com.microsoft.VSCode",
                Some("query.rs"),
                "old file",
            ),
            seen(
                2,
                13 * MINUTE,
                "com.microsoft.VSCode",
                Some("● query.rs"),
                "edited file",
            ),
        ];
        let now = 14 * MINUTE;
        assert_eq!(
            pick_on_screen(
                &recent,
                &looking_at("com.microsoft.VSCode", Some("server.rs")),
                now
            )
            .map(|e| e.id),
            Some(2)
        );
        assert_eq!(
            pick_on_screen(&recent, &looking_at("com.microsoft.VSCode", None), now).map(|e| e.id),
            Some(2)
        );
        // Nothing recent enough: an old window is not passed off as the screen.
        assert_eq!(
            pick_on_screen(
                &recent[..1],
                &looking_at("com.microsoft.VSCode", Some("server.rs")),
                now
            ),
            None
        );
    }

    #[test]
    fn an_app_that_was_never_captured_has_no_screen() {
        let recent = vec![seen(
            1,
            13 * MINUTE,
            "com.apple.Notes",
            Some("Launch plan"),
            "notes text",
        )];
        assert_eq!(
            pick_on_screen(
                &recent,
                &looking_at("com.1password.1password", Some("Vault")),
                14 * MINUTE
            ),
            None
        );
        assert_eq!(
            pick_on_screen(&recent, &NowContext::default(), 14 * MINUTE),
            None
        );
        // A capture with no text is not a screen to answer from.
        let blank = vec![seen(
            2,
            13 * MINUTE,
            "com.apple.Safari",
            Some("Pricing"),
            "  ",
        )];
        assert_eq!(
            pick_on_screen(
                &blank,
                &looking_at("com.apple.Safari", Some("Pricing")),
                14 * MINUTE
            ),
            None
        );
    }

    fn held(
        id: i64,
        kind: PropositionKind,
        confidence: f64,
        status: PropositionStatus,
    ) -> Proposition {
        Proposition {
            id,
            text: format!("Sam drafts the launch checklist number {id}"),
            reasoning: String::new(),
            kind,
            confidence,
            decay: 0.1,
            status,
            created_us: 0,
            updated_us: u64::try_from(id).unwrap_or(0),
            revised_from: None,
            model: "test".into(),
            evidence: vec![id, id + 100, id + 200],
        }
    }

    /// The gate's verdict on lines whose moments show them on two days: what
    /// the line alone decides, otherwise corroborated.
    fn verdicts(confirmed: &[i64]) -> impl FnMut(&Proposition) -> Sending {
        let gate = Gate::new(confirmed.iter().copied().collect(), Vec::new(), 0);
        move |p| gate.without_moments(p).unwrap_or(Sending::Corroborated)
    }

    fn ids(lines: Vec<Proposition>) -> Vec<i64> {
        lines.into_iter().map(|p| p.id).collect()
    }

    #[test]
    fn context_sent_unasked_leaves_out_people_struggles_and_guesses() {
        use PropositionKind::{Goal, Habit, Project, Relationship, State, Struggle};
        let recent = vec![
            held(1, Project, 0.9, PropositionStatus::Active),
            held(2, Relationship, 0.95, PropositionStatus::Active),
            held(3, Struggle, 0.9, PropositionStatus::Active),
            held(4, State, 0.9, PropositionStatus::Active),
            held(5, Habit, 0.4, PropositionStatus::Active),
            held(6, Goal, 0.7, PropositionStatus::Active),
        ];
        assert_eq!(
            ids(shared_claims(
                Vec::new(),
                recent.clone(),
                NOW,
                verdicts(&[])
            )),
            vec![1],
            "a goal at 0.7 is still a guess"
        );
        // A guess the person confirmed is no longer a guess.
        assert_eq!(
            ids(shared_claims(
                Vec::new(),
                recent.clone(),
                NOW,
                verdicts(&[5])
            )),
            vec![1, 5]
        );
        let mut fresh = recent;
        fresh[5].updated_us = NOW - DAY_US;
        assert_eq!(
            ids(shared_claims(Vec::new(), fresh, NOW, verdicts(&[6]))),
            vec![1, 6]
        );
    }

    #[test]
    fn only_lines_cleared_to_go_are_sent_and_the_gate_is_asked_only_about_them() {
        use PropositionKind::{Project, Relationship, State};
        let recent = vec![
            held(1, Project, 0.9, PropositionStatus::Active),
            held(2, Project, 0.9, PropositionStatus::Active),
            held(3, Relationship, 0.9, PropositionStatus::Active),
            held(4, State, 0.9, PropositionStatus::Active),
        ];
        let mut asked = Vec::new();
        let shared = shared_claims(Vec::new(), recent, NOW, |p| {
            asked.push(p.id);
            if p.id == 2 {
                Sending::Held(sending::Held::OneDay)
            } else {
                Sending::Corroborated
            }
        });
        assert_eq!(ids(shared), vec![1]);
        asked.sort_unstable();
        assert_eq!(
            asked,
            vec![1, 2],
            "people and states are never sent unasked"
        );
    }

    #[test]
    fn what_matches_the_project_comes_first_and_nothing_is_listed_twice() {
        use PropositionKind::{Habit, Project};
        let focused = vec![held(7, Project, 0.8, PropositionStatus::Active)];
        let recent: Vec<Proposition> = (1..=9)
            .map(|id| {
                held(
                    id,
                    if id == 7 { Project } else { Habit },
                    if id == 7 { 0.8 } else { 0.9 },
                    PropositionStatus::Active,
                )
            })
            .collect();
        let shared = ids(shared_claims(focused, recent, NOW, verdicts(&[])));
        assert_eq!(shared.len(), ABOUT_YOU_LINES);
        assert_eq!(shared[0], 7);
        assert_eq!(shared.iter().filter(|id| **id == 7).count(), 1);
    }

    #[test]
    fn stale_claims_leave_the_page_and_the_context_packet() {
        use PropositionKind::{Habit, Project, Skill};
        let mut fast = held(1, Habit, 0.9, PropositionStatus::Active);
        fast.decay = 0.9;
        fast.updated_us = NOW - 2 * DAY_US;
        let mut slow = held(2, Skill, 0.9, PropositionStatus::Active);
        slow.decay = 0.3;
        slow.updated_us = NOW - 400 * DAY_US;
        let mut finished = held(3, Project, 0.9, PropositionStatus::Active);
        finished.updated_us = NOW - 46 * DAY_US;
        assert!(not_seen_lately(&fast, false, NOW));
        assert!(
            !is_shared_unasked(&fast, Sending::Corroborated, NOW)
                && !is_servable(&fast, false, 2, NOW)
        );
        assert!(
            is_shared_unasked(&slow, Sending::Corroborated, NOW),
            "a slow claim never goes stale"
        );
        assert!(
            !not_seen_lately(&finished, false, NOW),
            "an unconfirmed project ages by its decay only"
        );
        assert!(
            not_seen_lately(&finished, true, NOW),
            "a confirmed project unseen for 45 days is not seen lately"
        );
        let all = vec![fast, slow, finished];
        assert_eq!(
            ids(shared_claims(Vec::new(), all.clone(), NOW, verdicts(&[3]))),
            vec![2]
        );
        assert_eq!(
            ids(shared_claims(Vec::new(), all, NOW, verdicts(&[]))),
            vec![3, 2],
            "equally sure: the newer first"
        );
    }

    #[test]
    fn a_struggle_seen_once_is_neither_shown_nor_sent() {
        let struggle = held(1, PropositionKind::Struggle, 0.9, PropositionStatus::Active);
        assert!(!is_servable(&struggle, false, 1, NOW));
        assert!(is_servable(&struggle, false, 2, NOW), "seen on two days");
        assert!(is_servable(&struggle, true, 1, NOW), "confirmed");
        assert!(
            !is_shared_unasked(&struggle, Sending::Confirmed, NOW),
            "never sent unasked"
        );
        assert!(is_served(&struggle, Sending::Confirmed, 1, NOW));
        assert!(is_served(&struggle, Sending::Corroborated, 2, NOW));
        assert!(
            !is_served(&struggle, Sending::Held(sending::Held::NotSure), 2, NOW),
            "shown on You, but no AI tool is given it"
        );
        let state = held(2, PropositionKind::State, 0.9, PropositionStatus::Active);
        assert!(
            !is_servable(&state, true, 5, NOW),
            "how they are right now is never shown"
        );
        assert!(!is_served(&state, Sending::Confirmed, 5, NOW));
        let rejected = held(
            3,
            PropositionKind::Project,
            0.9,
            PropositionStatus::Rejected,
        );
        assert!(
            !is_servable(&rejected, false, 3, NOW)
                && !is_shared_unasked(&rejected, Sending::Corroborated, NOW)
                && !is_served(&rejected, Sending::Corroborated, 3, NOW)
        );
    }

    const NOW: u64 = 1_800_000_000_000_000;

    fn source(n: usize) -> Source {
        Source {
            n,
            event_id: i64::try_from(n).unwrap_or(0),
            ts_us: 0,
            app: "App".into(),
            title: None,
            url: None,
            text: String::new(),
        }
    }

    #[test]
    fn the_screen_is_always_shown_as_a_source_when_the_model_saw_it() {
        let memories = vec![source(2), source(3), source(4), source(5)];
        let n = |sources: Vec<Source>| sources.into_iter().map(|s| s.n).collect::<Vec<_>>();
        // The model rarely cites the screen itself; it is listed regardless.
        assert_eq!(
            n(answer_sources(Some(source(1)), memories.clone(), &[3])),
            vec![1, 3]
        );
        assert_eq!(
            n(answer_sources(Some(source(1)), memories.clone(), &[])),
            vec![1]
        );
        // Without a screen: what was cited, or the best three when nothing was.
        assert_eq!(n(answer_sources(None, memories.clone(), &[4])), vec![4]);
        assert_eq!(n(answer_sources(None, memories, &[])), vec![2, 3, 4]);
    }

    #[test]
    fn a_window_that_was_never_read_is_said_to_be_unknown() {
        assert_eq!(
            unread_window_note(Some("Using Preview")),
            "Using Preview. Hippocampus has not read the window in front, so what is in it is not known."
        );
        assert!(unread_window_note(None).starts_with("Hippocampus has not read"));
    }

    const NOTES_HEADER: &str =
        "[app=com.apple.Notes | title=Launch plan | url=? | ts=2026-10-12T14:02:00.000Z]\n";

    #[test]
    fn the_screen_is_shown_and_read_without_its_header_or_chrome() {
        let stored = format!(
            "{NOTES_HEADER}\u{4e09} The beta opens on October 21.\n\n\u{1e}\nRecently Deleted 3"
        );
        let event = seen(1, 0, "com.apple.Notes", Some("Launch plan"), &stored);
        assert_eq!(screen_text(&event).main, "The beta opens on October 21.");
        assert_eq!(screen_source(&event).text, "The beta opens on October 21.");
    }

    #[test]
    fn a_page_read_both_ways_is_on_screen_as_the_part_that_was_visible() {
        let stored = format!("{NOTES_HEADER}The whole page, top to bottom\n\n[VISIBLE-OCR]\nWhat was visible\n\n\u{1e}\nTabs");
        let mut event = seen(1, 0, "com.google.Chrome", Some("Pricing"), &stored);
        event.source = "browser_page_with_ocr".into();
        assert_eq!(screen_text(&event).main, "What was visible");
        assert_eq!(screen_source(&event).text, "What was visible");
    }

    #[test]
    fn a_terminal_on_screen_is_shown_by_its_last_lines() {
        let lines: Vec<String> = (1..=100).map(|n| format!("step {n} ok")).collect();
        let stored = format!("{NOTES_HEADER}{}\nerror: build failed", lines.join("\n"));
        let event = seen(1, 0, "com.apple.Terminal", Some("zsh"), &stored);
        let text = screen_source(&event).text;
        assert!(text.ends_with("error: build failed"), "{text:?}");
        assert!(text.len() <= 512);
    }

    #[test]
    #[allow(clippy::format_collect)] // 500 short lines, built once
    fn a_long_screen_keeps_its_start_and_its_newest_lines() {
        let text: String = (0..500).map(|i| format!("line {i}\n")).collect();
        let shown = excerpt(&text, 400);
        assert!(shown.starts_with("line 0\n"));
        assert!(shown.ends_with("line 499\n"));
        assert!(shown.contains("\n…\n"));
        assert!(shown.chars().count() <= 400 + 3);
        assert_eq!(excerpt("short", 400), "short");
    }
}
