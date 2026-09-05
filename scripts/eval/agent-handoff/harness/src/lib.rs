use std::collections::BTreeMap;
use std::sync::Arc;

use mci_agent::context_packet::ContextBudget;
use mci_agent::mcp::{BrainReader, LiveBrainReader, McpHit, McpRecallOutcome};
use mci_brain::{
    BrainStore, Embedder, Event, EventId, EventSource, NothingMatchedReason, RetrievalDegradation,
    SqlCipherBrainStore,
};
use mci_core::crypto::DbKey;
use serde::Deserialize;
use serde_json::{json, Value};

#[cfg(test)]
mod seed_tests;

#[derive(Clone, Copy)]
pub enum Arm {
    Lexical,
    Hybrid,
}

impl Arm {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Lexical => "lexical",
            Self::Hybrid => "hybrid",
        }
    }
}

#[derive(Deserialize)]
struct Corpus {
    dataset_id: String,
    task_count: usize,
    instances: Vec<Instance>,
}

#[derive(Deserialize)]
struct Instance {
    question_id: String,
    question: String,
    haystack_dates: Vec<String>,
    haystack_session_ids: Vec<String>,
    haystack_app_ids: Vec<String>,
    haystack_window_titles: Vec<String>,
    haystack_urls: Vec<String>,
    haystack_sessions: Vec<Vec<Turn>>,
    handoff_expectation: HandoffExpectation,
}

#[derive(Deserialize)]
struct Turn {
    content: String,
}

#[derive(Deserialize)]
struct HandoffExpectation {
    max_tokens: usize,
    max_evidence: usize,
}

#[derive(Clone)]
struct SessionMeta {
    session_id: String,
}

struct EvalEmbedders {
    document: Arc<dyn Embedder>,
    query: Arc<dyn Embedder>,
}

impl EvalEmbedders {
    fn load() -> Result<Self, String> {
        let (document, document_is_real) = mci_agent::embedder_load::load_embedder_backend();
        if !document_is_real {
            return Err("hybrid arm requires the real Arctic Embed S Core ML model".to_owned());
        }
        let (query, query_is_real) = mci_agent::embedder_load::load_query_embedder_backend();
        if !query_is_real {
            return Err("hybrid arm requires the real Arctic Embed S query model".to_owned());
        }
        Ok(Self { document, query })
    }
}

pub fn evaluate_raw(corpus_json: &str, arms: &[Arm]) -> Result<Value, String> {
    let corpus: Corpus =
        serde_json::from_str(corpus_json).map_err(|error| format!("parse corpus: {error}"))?;
    if corpus.instances.len() != corpus.task_count {
        return Err(format!(
            "task_count {} does not match {} instances",
            corpus.task_count,
            corpus.instances.len()
        ));
    }
    let embedders = if arms.iter().any(|arm| matches!(arm, Arm::Hybrid)) {
        Some(EvalEmbedders::load()?)
    } else {
        None
    };
    let mut cases = Vec::with_capacity(corpus.instances.len() * arms.len());
    for arm in arms {
        for instance in &corpus.instances {
            cases.push(run_case(instance, *arm, embedders.as_ref())?);
        }
    }
    Ok(json!({
        "dataset_id": corpus.dataset_id,
        "surface": "LiveBrainReader::recall + LiveBrainReader::context (mci_context backend)",
        "cases": cases,
    }))
}

fn run_case(
    instance: &Instance,
    arm: Arm,
    embedders: Option<&EvalEmbedders>,
) -> Result<Value, String> {
    validate_instance(instance)?;
    let scratch = tempfile::tempdir().map_err(|error| format!("create scratch: {error}"))?;
    let db_path = scratch.path().join("brain.sqlite");
    let key = DbKey::from_bytes([0x6b; 32]);
    let store = SqlCipherBrainStore::new(&db_path, &key)
        .map_err(|error| format!("{}: open store: {error}", instance.question_id))?;
    let mut owners = BTreeMap::new();
    for session_index in 0..instance.haystack_sessions.len() {
        seed_session(instance, session_index, arm, embedders, &store, &mut owners)?;
    }
    let store = Arc::new(store);
    let query_embedder = match arm {
        Arm::Lexical => None,
        Arm::Hybrid => Some(Arc::clone(
            &embedders
                .ok_or_else(|| "hybrid embedder was not loaded".to_owned())?
                .query,
        )),
    };
    let reader = LiveBrainReader::from_store_with_embedder(store, query_embedder);
    let recall = reader
        .recall(&instance.question, 10)
        .map_err(|error| format!("{}: recall: {error}", instance.question_id))?;
    let (recall_disposition, recall_reason, hits) = flatten_recall(recall);
    let ranked_event_ids = hits
        .iter()
        .map(|hit| hit.record.event_id.0)
        .collect::<Vec<_>>();
    let owner_ids = owners
        .iter()
        .map(|(event_id, meta)| (*event_id, meta.session_id.clone()))
        .collect::<BTreeMap<_, _>>();
    let ranked_session_ids = collapse_ranked_sessions(&ranked_event_ids, &owner_ids);

    let packet = reader
        .context(
            Some(&instance.question),
            ContextBudget::new(
                instance.handoff_expectation.max_tokens,
                instance.handoff_expectation.max_evidence,
            ),
        )
        .map_err(|error| format!("{}: context: {error}", instance.question_id))?;
    let packet_json = serde_json::to_value(&packet)
        .map_err(|error| format!("{}: serialize packet: {error}", instance.question_id))?;
    let packet_text = packet
        .sections
        .iter()
        .flat_map(|section| section.items.iter())
        .map(|item| item.text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let citations = packet
        .citations
        .iter()
        .map(|citation| {
            let session_id = owners
                .get(&citation.event_id)
                .map(|meta| meta.session_id.clone())
                .unwrap_or_default();
            json!({
                "event_id": citation.event_id,
                "session_id": session_id,
                "ts_us": citation.ts_us,
                "app_bundle_id": citation.app_bundle_id,
                "window_title": citation.window_title,
                "url": citation.url,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "question_id": instance.question_id,
        "arm": arm.label(),
        "recall_disposition": recall_disposition,
        "recall_reason": recall_reason,
        "ranked_session_ids": ranked_session_ids,
        "packet": {
            "outcome": packet_json["outcome"],
            "focus_retrieval_status": packet_json["focus_retrieval"]["status"],
            "focus_retrieval_reason": packet_json["focus_retrieval"].get("reason"),
            "token_estimate": packet.token_estimate,
            "byte_estimate": packet.byte_estimate,
            "truncated": packet.truncated,
            "text": packet_text,
            "citations": citations,
        },
    }))
}

fn validate_instance(instance: &Instance) -> Result<(), String> {
    let count = instance.haystack_sessions.len();
    for (name, actual) in [
        ("haystack_dates", instance.haystack_dates.len()),
        ("haystack_session_ids", instance.haystack_session_ids.len()),
        ("haystack_app_ids", instance.haystack_app_ids.len()),
        (
            "haystack_window_titles",
            instance.haystack_window_titles.len(),
        ),
        ("haystack_urls", instance.haystack_urls.len()),
    ] {
        if actual != count {
            return Err(format!(
                "{}: {name} has {actual} entries, expected {count}",
                instance.question_id
            ));
        }
    }
    Ok(())
}

fn seed_session(
    instance: &Instance,
    session_index: usize,
    arm: Arm,
    embedders: Option<&EvalEmbedders>,
    store: &SqlCipherBrainStore,
    owners: &mut BTreeMap<u64, SessionMeta>,
) -> Result<(), String> {
    let base_ts = parse_dataset_timestamp(&instance.haystack_dates[session_index])?;
    // Only explicit screen locators assert acquisition; app IDs and other URLs do not.
    let source = if instance.haystack_session_ids[session_index].starts_with("screen://")
        || instance.haystack_urls[session_index].starts_with("screen://")
    {
        EventSource::ScreenOcr
    } else {
        EventSource::Unknown
    };
    for (turn_index, turn) in instance.haystack_sessions[session_index].iter().enumerate() {
        let text = turn.content.trim();
        if text.is_empty() {
            continue;
        }
        let ts_us = base_ts + u64::try_from(turn_index).unwrap_or(u64::MAX);
        let prepared = mci_agent::brain_ingest::prepare_event_content(
            &mci_brain::event_chunker::EventChunker::default(),
            Some(&instance.haystack_app_ids[session_index]),
            Some(&instance.haystack_window_titles[session_index]),
            Some(&instance.haystack_urls[session_index]),
            ts_us,
            text,
        )
        .map_err(|error| format!("{}: prepare event: {error}", instance.question_id))?;
        let embedding = match arm {
            Arm::Lexical => None,
            Arm::Hybrid => prepared
                .embedding_input
                .as_deref()
                .filter(|value| !value.is_empty())
                .map(|value| {
                    embedders
                        .ok_or_else(|| "hybrid embedder was not loaded".to_owned())?
                        .document
                        .embed_one(value)
                        .map_err(|error| format!("{}: embed: {error}", instance.question_id))
                })
                .transpose()?,
        };
        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(instance.haystack_app_ids[session_index].clone()),
            window_title: Some(instance.haystack_window_titles[session_index].clone()),
            url: Some(instance.haystack_urls[session_index].clone()),
            text: prepared.stored_text,
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding,
        };
        let event_id = store
            .put_event_with_source(&event, source)
            .map_err(|error| format!("{}: store event: {error}", instance.question_id))?;
        owners.insert(
            event_id.0,
            SessionMeta {
                session_id: instance.haystack_session_ids[session_index].clone(),
            },
        );
    }
    Ok(())
}

fn flatten_recall(outcome: McpRecallOutcome) -> (&'static str, Option<&'static str>, Vec<McpHit>) {
    match outcome {
        McpRecallOutcome::Matched { hits } => ("matched", None, hits),
        McpRecallOutcome::Contradicted { evidence } => ("contradicted", None, evidence),
        McpRecallOutcome::NothingMatched { reason } => {
            ("nothing_matched", Some(nothing_reason(reason)), Vec::new())
        }
        McpRecallOutcome::Degraded {
            degradation,
            related_context,
        } => (
            "degraded",
            Some(degradation_reason(degradation)),
            related_context,
        ),
    }
}

const fn nothing_reason(reason: NothingMatchedReason) -> &'static str {
    match reason {
        NothingMatchedReason::NoCandidates => "no_candidates",
        NothingMatchedReason::EvidenceFloor => "evidence_floor",
        NothingMatchedReason::ZeroLimit => "zero_limit",
    }
}

const fn degradation_reason(reason: RetrievalDegradation) -> &'static str {
    match reason {
        RetrievalDegradation::EmbeddingsUnavailable => "embeddings_unavailable",
        RetrievalDegradation::LexicalUnavailable => "lexical_unavailable",
        RetrievalDegradation::LexicalAndEmbeddingsUnavailable => {
            "lexical_and_embeddings_unavailable"
        }
        RetrievalDegradation::EvidenceSufficiencyUnqualified => "evidence_sufficiency_unqualified",
        RetrievalDegradation::EvidenceVerifierUnavailable => "evidence_verifier_unavailable",
    }
}

pub fn parse_dataset_timestamp(value: &str) -> Result<u64, String> {
    let fields = value.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 3 {
        return Err(format!("invalid dataset timestamp {value:?}"));
    }
    let date = parse_numbers(fields[0], '/', 3, value)?;
    let time = parse_numbers(fields[2], ':', 2, value)?;
    let (year, month, day) = (date[0], date[1], date[2]);
    let (hour, minute) = (time[0], time[1]);
    if !(1..=12).contains(&month)
        || day == 0
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
    {
        return Err(format!("out-of-range dataset timestamp {value:?}"));
    }
    let days = days_from_civil(year, month, day);
    if days < 0 {
        return Err("dataset timestamp predates Unix epoch".to_owned());
    }
    let expected_weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
        [usize::try_from(days.rem_euclid(7)).unwrap()];
    let supplied_weekday = fields[1].trim_matches(['(', ')']);
    if supplied_weekday != expected_weekday {
        return Err(format!(
            "dataset timestamp weekday {supplied_weekday:?} does not match {expected_weekday:?}"
        ));
    }
    let seconds = u64::try_from(days)
        .map_err(|_| "dataset timestamp day overflow".to_owned())?
        .checked_mul(86_400)
        .and_then(|value| value.checked_add(u64::from(hour) * 3_600))
        .and_then(|value| value.checked_add(u64::from(minute) * 60))
        .ok_or_else(|| "dataset timestamp overflow".to_owned())?;
    seconds
        .checked_mul(1_000_000)
        .ok_or_else(|| "dataset timestamp microsecond overflow".to_owned())
}

pub fn collapse_ranked_sessions(
    ranked_events: &[u64],
    owners: &BTreeMap<u64, String>,
) -> Vec<String> {
    let mut sessions = Vec::new();
    for event_id in ranked_events {
        let Some(session_id) = owners.get(event_id) else {
            continue;
        };
        if !sessions.contains(session_id) {
            sessions.push(session_id.clone());
        }
    }
    sessions
}

fn parse_numbers(
    value: &str,
    separator: char,
    expected: usize,
    original: &str,
) -> Result<Vec<u32>, String> {
    let values = value
        .split(separator)
        .map(|part| part.parse::<u32>())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| format!("invalid numeric field in dataset timestamp {original:?}"))?;
    if values.len() != expected {
        return Err(format!("invalid dataset timestamp {original:?}"));
    }
    Ok(values)
}

const fn is_leap_year(year: u32) -> bool {
    year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
}

const fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

const fn days_from_civil(year: u32, month: u32, day: u32) -> i64 {
    let mut year = year as i64;
    let month = month as i64;
    let day = day as i64;
    if month <= 2 {
        year -= 1;
    }
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let adjusted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}
