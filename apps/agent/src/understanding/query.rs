//! Read-only views of the understanding layer, shared by the CLI, MCP and the
//! app: a day, searches, the user model, sessions, answers and suggestions.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use mci_brain::understanding::{Proposition, PropositionStatus, SearchRecord, SessionNote};
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
    pub fn ask(&self, question: &str, now: Option<&str>, memories: Vec<Source>) -> Result<Answer, StoreError> {
        answer(&self.store, &self.mind, &self.user_name, self.tz, Self::now_us(), question, now, memories)
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

/// Answer `question` from retrieved memories, the user model and what is on
/// screen now (`now`).
///
/// # Errors
/// Store failures.
pub fn answer(
    store: &SqlCipherBrainStore,
    mind: &MindClient,
    user_name: &str,
    tz: i32,
    now_us: u64,
    question: &str,
    now: Option<&str>,
    memories: Vec<Source>,
) -> Result<Answer, StoreError> {
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
        Ok(out) => {
            let cited: Vec<Source> = memories.iter().filter(|m| out.sources.contains(&m.n)).cloned().collect();
            Ok(Answer {
                answer: Some(out.answer),
                sources: if cited.is_empty() { memories.into_iter().take(3).collect() } else { cited },
                unavailable: None,
            })
        }
        Err(error) => Ok(Answer {
            answer: None,
            sources: memories,
            unavailable: Some(match error {
                MindCallError::Unavailable(reason) => reason,
                other => other.to_string(),
            }),
        }),
    }
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
    let recent = store.observed_events_in_range(now_us.saturating_sub(hour), now_us + 1, 2_000)?;
    let current = now.app.as_deref().and_then(|app| {
        recent.iter().rev().find(|e| {
            e.app_bundle_id.as_deref() == Some(app)
                && now.title.as_deref().map_or(true, |t| e.window_title.as_deref() == Some(t))
        })
    });
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
    out.truncate(6);
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
