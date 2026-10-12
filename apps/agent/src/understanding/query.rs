//! Read-only views of the understanding layer, shared by the CLI, MCP and the
//! app: a day, searches, the user model, sessions, answers and suggestions.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use mci_brain::understanding::{
    ObservedEvent, Proposition, PropositionKind, PropositionStatus, SearchRecord, SessionNote,
};
use mci_brain::{SqlCipherBrainStore, StoreError};

use super::mind::{MindCallError, MindClient};
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
    },
    /// A day's sessions: surface and beneath.
    Sessions {
        /// `YYYY-MM-DD`.
        date: Option<String>,
    },
}

fn today(tz: i32, now_us: u64) -> String {
    local_date_string(i64::try_from(now_us / 1_000_000).unwrap_or(0), tz)
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
pub fn run(store: &Arc<SqlCipherBrainStore>, tz: i32, now_us: u64, query: &UnderstandingQuery) -> Result<serde_json::Value, StoreError> {
    let reader = Understanding::new(Arc::clone(store), Arc::new(MindClient::new(None)), tz, String::new());
    Ok(match query {
        UnderstandingQuery::Day { date } => {
            let date = date.clone().unwrap_or_else(|| today(tz, now_us));
            let day = reader.day(&date, now_us)?;
            serde_json::json!({ "day": day, "facts": day.breakdown.facts(tz) })
        }
        UnderstandingQuery::Searches { hours, limit } => {
            let hours = hours.unwrap_or(24).clamp(1, 24 * 31);
            let searches = store.search_queries_in_range(now_us.saturating_sub(hours * 3_600_000_000), now_us + 1, limit.unwrap_or(50).clamp(1, 500))?;
            serde_json::json!({ "searches": searches.iter().map(|s| search_json(s, tz)).collect::<Vec<_>>() })
        }
        UnderstandingQuery::UserModel { query, limit } => {
            let limit = limit.unwrap_or(20).clamp(1, 200);
            let items: Vec<ModelItem> = match query.as_deref().map(str::trim).filter(|q| !q.is_empty()) {
                Some(q) => store
                    .search_propositions(q, limit)?
                    .into_iter()
                    .map(|(p, _)| p)
                    .filter(|p| p.status == PropositionStatus::Active)
                    .map(ModelItem::from)
                    .collect(),
                None => {
                    let mut all = store.propositions_with_status(PropositionStatus::Active, 500)?;
                    all.sort_by(|a, b| b.confidence.total_cmp(&a.confidence).then(b.updated_us.cmp(&a.updated_us)));
                    all.into_iter().take(limit).map(ModelItem::from).collect()
                }
            };
            serde_json::json!({ "propositions": items })
        }
        UnderstandingQuery::Sessions { date } => {
            let date = date.clone().unwrap_or_else(|| today(tz, now_us));
            let day = reader.day(&date, now_us)?;
            let notes = store.session_notes_in_range(day.breakdown.start_us, day.breakdown.end_us)?;
            serde_json::json!({ "date": date, "sessions": notes.iter().map(|n| session_json(n, tz)).collect::<Vec<_>>() })
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
    serde_json::json!({
        "start_us": n.start_us, "end_us": n.end_us,
        "time": format!("{}–{}", observe::clock(n.start_us, tz), observe::clock(n.end_us, tz)),
        "title": n.title, "surface": n.surface, "beneath": n.beneath, "written_by": n.model,
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
        crate::mcp::McpRecallOutcome::Degraded { related_context, .. } => related_context,
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
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_micros(),
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
        let unread = (screen.is_none() && looking_at.app.is_some()).then(|| unread_window_note(now));
        let now = unread.as_deref().or(now);
        answer(&self.store, &self.mind, &self.user_name, self.tz, now_us, question, now, screen, memories)
    }

    /// Suggestions for the current moment.
    ///
    /// # Errors
    /// Store failures.
    pub fn suggest(&self, now: &NowContext, use_model: bool) -> Result<Vec<Suggestion>, StoreError> {
        suggest(&self.store, use_model.then_some(&self.mind), &self.user_name, self.tz, Self::now_us(), now)
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
    let recent = store.observed_events_in_range(now_us.saturating_sub(ON_SCREEN_WINDOW_US), now_us + 1, 2_000)?;
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
    let of_app = || recent.iter().rev().filter(move |e| e.app_bundle_id.as_deref() == Some(app) && !e.text.trim().is_empty());
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
    let cited_memories: Vec<Source> = memories.iter().filter(|m| cited.contains(&m.n)).cloned().collect();
    match screen {
        Some(screen) => std::iter::once(screen).chain(cited_memories).collect(),
        None if cited_memories.is_empty() => memories.into_iter().take(3).collect(),
        None => cited_memories,
    }
}

fn screen_source(event: &ObservedEvent) -> Source {
    Source {
        n: 1,
        event_id: event.id,
        ts_us: event.ts_us,
        app: apps::name(event.app_bundle_id.as_deref().unwrap_or("")),
        title: event.window_title.clone(),
        url: event.url.clone(),
        text: clip(&event.text, 512),
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
    screen: Option<ObservedEvent>,
    memories: Vec<Source>,
) -> Result<Answer, StoreError> {
    // The screen is source 1; recalled memories follow it, without the same
    // event twice.
    let on_screen = screen.as_ref().map(screen_source);
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
            match &source.title { Some(t) => format!("{} — {t}", source.app), None => source.app.clone() },
            excerpt(&event.text, ON_SCREEN_CHARS)
        )),
        _ => now.map(str::to_owned),
    };
    let now = now_text.as_deref();
    let propositions: Vec<String> = store
        .search_propositions(question, 6)?
        .into_iter()
        .filter(|(p, _)| p.status == PropositionStatus::Active)
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
// Context for an AI client
// ---------------------------------------------------------------------------

/// The kinds of thing about the user that go into context sent without being
/// asked for. People they work with, where they get stuck and how they are
/// right now stay behind `mci_user_model`, which a client has to call.
const SHARED_UNASKED: [PropositionKind; 5] = [
    PropositionKind::Project,
    PropositionKind::Goal,
    PropositionKind::Habit,
    PropositionKind::Preference,
    PropositionKind::Skill,
];

/// What an AI client is told about the user's work when a session starts:
/// the last few work sessions and the surest things in the user model,
/// those matching `focus` first. `None` when nothing has been learned yet.
/// Best effort: a store failure yields no block, never a failed packet.
#[must_use]
pub fn context_understanding(
    store: &SqlCipherBrainStore,
    tz: i32,
    now_us: u64,
    focus: Option<&str>,
) -> Option<crate::context_packet::ContextUnderstanding> {
    use crate::context_packet::{ContextUnderstanding, ContextUnderstandingClaim};
    let half_day = 12 * 3_600_000_000u64;
    let sessions = store
        .session_notes_in_range(now_us.saturating_sub(half_day), now_us + 1)
        .unwrap_or_default()
        .iter()
        .rev()
        .take(4)
        .map(|note| session_line(note, tz))
        .collect();
    let focused = focus
        .map(str::trim)
        .filter(|f| !f.is_empty())
        .and_then(|f| store.search_propositions(f, 4).ok())
        .unwrap_or_default()
        .into_iter()
        .map(|(p, _)| p);
    let recent = store.propositions_with_status(PropositionStatus::Active, 60).unwrap_or_default();
    let about = shared_claims(focused.collect(), recent)
        .into_iter()
        .map(|p| ContextUnderstandingClaim { text: clip(&p.text, 220), confidence: p.confidence, event_ids: p.evidence })
        .collect();
    let understanding = ContextUnderstanding { sessions, about };
    (!understanding.is_empty()).then_some(understanding)
}

fn session_line(note: &SessionNote, tz: i32) -> String {
    let detail = if note.beneath.trim().is_empty() { &note.surface } else { &note.beneath };
    format!(
        "{}–{} · {}: {}",
        observe::clock(note.start_us, tz),
        observe::clock(note.end_us, tz),
        clip(note.title.trim(), 80),
        clip(detail.trim(), 180)
    )
}

/// Up to six active propositions of the kinds shared unasked: those matching
/// the focus first, then the surest of the rest.
fn shared_claims(focused: Vec<Proposition>, mut recent: Vec<Proposition>) -> Vec<Proposition> {
    recent.sort_by(|a, b| b.confidence.total_cmp(&a.confidence).then(b.updated_us.cmp(&a.updated_us)));
    let mut out: Vec<Proposition> = Vec::new();
    for p in focused.into_iter().chain(recent) {
        if out.len() == 6 {
            break;
        }
        if p.status == PropositionStatus::Active
            && p.confidence >= 0.5
            && SHARED_UNASKED.contains(&p.kind)
            && !out.iter().any(|kept| kept.id == p.id)
        {
            out.push(p);
        }
    }
    out
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
    let recent = store.observed_events_in_range(now_us.saturating_sub(ON_SCREEN_WINDOW_US), now_us + 1, 2_000)?;
    let current = pick_on_screen(&recent, now, now_us);
    // Ask about what is in front of them: the one thing every screen offers.
    if let Some(event) = current {
        let app = apps::name(event.app_bundle_id.as_deref().unwrap_or(""));
        out.push(Suggestion {
            kind: "screen".into(),
            title: "What’s on this screen?".into(),
            why: match &event.window_title {
                Some(title) if !title.is_empty() => format!("{app} — {}", clip(title, 60)),
                _ => app,
            },
            action: serde_json::json!({ "ask": "What is on my screen right now, and what matters in it?" }),
            score: 8,
        });
    }
    // Resume: the last session that was not in the current window.
    let notes = store.session_notes_in_range(now_us.saturating_sub(12 * hour), now_us + 1)?;
    if let Some(last) = notes.iter().rev().find(|n| !now.title.as_deref().is_some_and(|t| n.title.contains(t))) {
        out.push(Suggestion {
            kind: "resume".into(),
            title: format!("Resume: {}", last.title),
            why: format!("{} · {}", observe::clock(last.start_us, tz), first_sentence(&last.surface)),
            action: serde_json::json!({ "open_session": last.start_us }),
            score: 7,
        });
    }
    // Searches in the last two hours.
    for search in store.search_queries_in_range(now_us.saturating_sub(2 * hour), now_us + 1, 3)? {
        out.push(Suggestion {
            kind: "searched".into(),
            title: format!("“{}”", search.query),
            why: format!("You searched this at {}", observe::clock(search.ts_us, tz)),
            action: serde_json::json!({ "query": search.query }),
            score: 6,
        });
    }
    // Related to the current window: what else you saw about it. Only a
    // window Hippocampus itself captured counts; a title from an app it
    // never records (a password manager, a private window) is not used.
    if let Some(title) = current.and_then(|e| e.window_title.clone()) {
        let topic = title.split([' ', '—', '-', '|']).filter(|w| w.len() > 2).take(6).collect::<Vec<_>>().join(" ");
        if !topic.is_empty() {
            out.push(Suggestion {
                kind: "related".into(),
                title: format!("More about {}", clip(&title, 48)),
                why: "Everything you saw on this, across apps".into(),
                action: serde_json::json!({ "query": topic }),
                score: 5,
            });
        }
    }
    let learned = store.propositions_with_status(PropositionStatus::Active, 500)?.len();
    if learned > 0 {
        out.push(Suggestion {
            kind: "model".into(),
            title: "What Hippocampus has learned about you".into(),
            why: format!("{learned} things from your work; correct anything wrong"),
            action: serde_json::json!({ "view": "model" }),
            score: 3,
        });
    }
    out.push(Suggestion {
        kind: "day".into(),
        title: "Your day so far".into(),
        why: "Time, focus, searches and where you got stuck".into(),
        action: serde_json::json!({ "view": "day" }),
        score: 4,
    });
    if let Some(mind) = mind {
        let propositions: Vec<String> = store
            .propositions_with_status(PropositionStatus::Active, 6)?
            .into_iter()
            .map(|p| p.text)
            .collect();
        let now_text = current.map_or_else(
            || now.app.as_deref().map(apps::name).unwrap_or_default(),
            |e| format!("{} — {}\n{}", apps::name(e.app_bundle_id.as_deref().unwrap_or("")), e.window_title.clone().unwrap_or_default(), clip(&e.text, 1_000)),
        );
        let recent_lines: Vec<String> = notes.iter().rev().take(6).map(|n| format!("{} {}: {}", observe::clock(n.start_us, tz), n.title, n.beneath)).collect();
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
                });
            }
        }
    }
    out.sort_by(|a, b| b.score.cmp(&a.score));
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
        NowContext { app: Some(app.to_owned()), title: title.map(str::to_owned) }
    }

    const MINUTE: u64 = 60 * 1_000_000;

    #[test]
    fn the_screen_is_the_newest_capture_of_the_window_in_front() {
        let recent = vec![
            seen(1, 10 * MINUTE, "com.apple.Safari", Some("Pricing"), "old pricing text"),
            seen(2, 11 * MINUTE, "com.apple.Notes", Some("Launch plan"), "notes text"),
            seen(3, 12 * MINUTE, "com.apple.Safari", Some("Pricing"), "new pricing text"),
            seen(4, 13 * MINUTE, "com.apple.Safari", Some("Another tab"), "another tab"),
        ];
        let picked = pick_on_screen(&recent, &looking_at("com.apple.Safari", Some("Pricing")), 14 * MINUTE);
        assert_eq!(picked.map(|e| e.id), Some(3));
    }

    #[test]
    fn a_changed_title_falls_back_to_a_capture_of_that_app_from_the_last_two_minutes() {
        let recent = vec![
            seen(1, 5 * MINUTE, "com.microsoft.VSCode", Some("query.rs"), "old file"),
            seen(2, 13 * MINUTE, "com.microsoft.VSCode", Some("● query.rs"), "edited file"),
        ];
        let now = 14 * MINUTE;
        assert_eq!(pick_on_screen(&recent, &looking_at("com.microsoft.VSCode", Some("server.rs")), now).map(|e| e.id), Some(2));
        assert_eq!(pick_on_screen(&recent, &looking_at("com.microsoft.VSCode", None), now).map(|e| e.id), Some(2));
        // Nothing recent enough: an old window is not passed off as the screen.
        assert_eq!(pick_on_screen(&recent[..1], &looking_at("com.microsoft.VSCode", Some("server.rs")), now), None);
    }

    #[test]
    fn an_app_that_was_never_captured_has_no_screen() {
        let recent = vec![seen(1, 13 * MINUTE, "com.apple.Notes", Some("Launch plan"), "notes text")];
        assert_eq!(pick_on_screen(&recent, &looking_at("com.1password.1password", Some("Vault")), 14 * MINUTE), None);
        assert_eq!(pick_on_screen(&recent, &NowContext::default(), 14 * MINUTE), None);
        // A capture with no text is not a screen to answer from.
        let blank = vec![seen(2, 13 * MINUTE, "com.apple.Safari", Some("Pricing"), "  ")];
        assert_eq!(pick_on_screen(&blank, &looking_at("com.apple.Safari", Some("Pricing")), 14 * MINUTE), None);
    }

    fn held(id: i64, kind: PropositionKind, confidence: f64, status: PropositionStatus) -> Proposition {
        Proposition {
            id,
            text: format!("claim {id}"),
            reasoning: String::new(),
            kind,
            confidence,
            decay: 0.1,
            status,
            created_us: 0,
            updated_us: u64::try_from(id).unwrap_or(0),
            revised_from: None,
            model: "test".into(),
            evidence: vec![id],
        }
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
        let shared: Vec<i64> = shared_claims(Vec::new(), recent).into_iter().map(|p| p.id).collect();
        assert_eq!(shared, vec![1, 6]);
    }

    #[test]
    fn what_matches_the_project_comes_first_and_nothing_is_listed_twice() {
        use PropositionKind::{Habit, Project};
        let focused = vec![held(7, Project, 0.6, PropositionStatus::Active)];
        let recent: Vec<Proposition> = (1..=9)
            .map(|id| held(id, if id == 7 { Project } else { Habit }, if id == 7 { 0.6 } else { 0.9 }, PropositionStatus::Active))
            .collect();
        let shared: Vec<i64> = shared_claims(focused, recent).into_iter().map(|p| p.id).collect();
        assert_eq!(shared.len(), 6);
        assert_eq!(shared[0], 7);
        assert_eq!(shared.iter().filter(|id| **id == 7).count(), 1);
    }

    fn source(n: usize) -> Source {
        Source { n, event_id: i64::try_from(n).unwrap_or(0), ts_us: 0, app: "App".into(), title: None, url: None, text: String::new() }
    }

    #[test]
    fn the_screen_is_always_shown_as_a_source_when_the_model_saw_it() {
        let memories = vec![source(2), source(3), source(4), source(5)];
        let n = |sources: Vec<Source>| sources.into_iter().map(|s| s.n).collect::<Vec<_>>();
        // The model rarely cites the screen itself; it is listed regardless.
        assert_eq!(n(answer_sources(Some(source(1)), memories.clone(), &[3])), vec![1, 3]);
        assert_eq!(n(answer_sources(Some(source(1)), memories.clone(), &[])), vec![1]);
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

    #[test]
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
