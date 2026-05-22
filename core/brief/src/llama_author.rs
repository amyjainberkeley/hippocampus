//! `LlamaBriefAuthor` — LLM-backed brief generator conforming to
//! [`BriefAuthor`].
//!
//! Takes `&[EventRecord]` + topic string → renders a prompt → calls
//! [`LlamaBackend`] → parses output into a [`Brief`] with citations.
//!
//! # Prompt template
//!
//! The prompt instructs the model to:
//! 1. Summarize the events under the given topic.
//! 2. Cite each claim with `[event:N]` markers where N is the event ID.
//! 3. End with a `###CITATIONS:` section listing all cited event IDs.
//!
//! The `###CITATIONS:` marker also serves as a stop sequence for greedy
//! decode — the Core ML backend stops generating when it sees this marker.
//!
//! # Citation parsing
//!
//! The parser extracts `[event:N]` from the body text. Malformed markers
//! (non-numeric N, missing brackets) are silently skipped. Only citations
//! that reference event IDs present in the input `EventRecord` slice are
//! kept — hallucinated IDs are dropped and counted by the tripwire.
//!
//! # ADR-0018 §4 invariants
//!
//! - Output is always `BriefState::Draft` — no auto-approve.
//! - Citations are drawn from input event IDs only.
//! - Hallucination tripwire runs AFTER this author, in the lifecycle
//!   chokepoint — this author does not bypass it.

use std::collections::HashSet;
use std::sync::Arc;

use mci_brain::{EventId, EventRecord};

use crate::author::{AuthorError, BriefAuthor};
use crate::llama_backend::LlamaBackend;
use crate::model::{Brief, BriefId, BriefState};

/// LLM-backed brief author using a [`LlamaBackend`] for generation.
pub struct LlamaBriefAuthor {
    backend: Arc<dyn LlamaBackend>,
}

impl LlamaBriefAuthor {
    /// Create a new author with the given backend.
    #[must_use]
    pub fn new(backend: Arc<dyn LlamaBackend>) -> Self {
        Self { backend }
    }

    /// Render the prompt for the given events and topic.
    ///
    /// Public for test pinning.
    #[must_use]
    pub fn render_prompt(retrieval: &[EventRecord], topic: &str) -> String {
        use std::fmt::Write;
        let mut event_block = String::new();
        for r in retrieval {
            let _ = writeln!(
                event_block,
                "EVENT_ID={} APP={} WINDOW={} TEXT={}",
                r.event_id.0,
                r.app_bundle_id.as_deref().unwrap_or("unknown"),
                r.window_title.as_deref().unwrap_or("unknown"),
                r.text_snippet,
            );
        }

        PROMPT_TEMPLATE
            .replace("{topic}", topic)
            .replace("{event_count}", &retrieval.len().to_string())
            .replace("{events}", &event_block)
    }
}

/// Prompt template for daily brief generation.
///
/// Placeholders: `{topic}`, `{event_count}`, `{events}`.
///
/// Qwen3 ChatML format per ADR-0028 §3. Direct mode (no thinking
/// tokens) — the system prompt instructs concise structured output.
///
/// The `###CITATIONS:` line doubles as the stop marker in the
/// Core ML backend.
const PROMPT_TEMPLATE: &str = "\
<|im_start|>system
You are a concise daily brief generator for a knowledge worker. Follow these rules exactly:
1. First line is the brief title (≤10 words).
2. Then bullet points summarizing what happened, grouped by activity.
3. Every bullet MUST cite at least one source event using [event:N] where N is the EVENT_ID.
4. Do NOT invent or reference any EVENT_ID not listed below.
5. End with a line: ###CITATIONS: [event:X], [event:Y], ...
/no_think<|im_end|>
<|im_start|>user
Summarize the following {event_count} screen events under the topic \"{topic}\".

EVENTS:
{events}<|im_end|>
<|im_start|>assistant
";

impl BriefAuthor for LlamaBriefAuthor {
    fn author(&self, retrieval: &[EventRecord], topic: &str) -> Result<Brief, AuthorError> {
        if retrieval.is_empty() {
            return Err(AuthorError::NoEvents);
        }

        let valid_ids: HashSet<u64> = retrieval.iter().map(|r| r.event_id.0).collect();

        let prompt = Self::render_prompt(retrieval, topic);
        let raw_output = self
            .backend
            .generate(&prompt)
            .map_err(|e| AuthorError::Backend(e.to_string()))?;

        let (title, body) = parse_title_body(&raw_output);
        let cited_ids = parse_citations(&body, &valid_ids);

        let now_us = retrieval.iter().map(|r| r.ts_us).max().unwrap_or(0);

        Ok(Brief {
            id: BriefId(0),
            title,
            body,
            citations: cited_ids.into_iter().map(EventId).collect(),
            state: BriefState::Draft,
            created_ts_us: now_us,
            updated_ts_us: now_us,
            human_approver_id: None,
        })
    }
}

/// Parse the first non-empty line as title, rest (up to `###CITATIONS:`) as body.
fn parse_title_body(raw: &str) -> (String, String) {
    let lines: Vec<&str> = raw.lines().collect();

    let title = lines
        .iter()
        .find(|l| !l.trim().is_empty())
        .map_or_else(|| "Untitled Brief".to_owned(), |l| l.trim().to_owned());

    let mut body_lines = Vec::new();
    let mut past_title = false;
    for line in &lines {
        let trimmed = line.trim();
        if !past_title {
            if trimmed == title {
                past_title = true;
            }
            continue;
        }
        if trimmed.starts_with("###CITATIONS:") {
            break;
        }
        body_lines.push(*line);
    }

    let body = body_lines.join("\n").trim().to_owned();

    (title, body)
}

/// Extract `[event:N]` markers from text, keeping only IDs in `valid_ids`.
///
/// Silently skips malformed markers (non-numeric, missing brackets).
#[must_use]
#[allow(clippy::implicit_hasher)]
pub fn parse_citations(text: &str, valid_ids: &HashSet<u64>) -> Vec<u64> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();

    let mut remaining = text;
    while let Some(start) = remaining.find("[event:") {
        let after_marker = &remaining[start + 7..];
        if let Some(end) = after_marker.find(']') {
            let id_str = &after_marker[..end];
            if let Ok(id) = id_str.parse::<u64>() {
                if valid_ids.contains(&id) && seen.insert(id) {
                    result.push(id);
                }
            }
            remaining = &after_marker[end + 1..];
        } else {
            break;
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llama_backend::StubLlamaBackend;
    use std::sync::Arc;

    fn make_records(ids: &[u64]) -> Vec<EventRecord> {
        ids.iter()
            .map(|&id| EventRecord {
                event_id: EventId(id),
                ts_us: id * 1_000_000,
                app_bundle_id: Some("com.test.app".into()),
                window_title: Some("Test Window".into()),
                url: None,
                text_snippet: format!("Event text for id {id}"),
            })
            .collect()
    }

    #[test]
    fn llama_author_produces_draft_with_citations() {
        let ids = vec![10, 20, 30];
        let backend = Arc::new(StubLlamaBackend::with_event_ids(ids.clone()));
        let author = LlamaBriefAuthor::new(backend);
        let records = make_records(&ids);

        let brief = author.author(&records, "End of day").unwrap();

        assert_eq!(brief.state, BriefState::Draft);
        assert!(brief.human_approver_id.is_none());
        assert!(!brief.citations.is_empty());
        for id in &ids {
            assert!(
                brief.citations.contains(&EventId(*id)),
                "missing citation for event:{id}"
            );
        }
    }

    #[test]
    fn llama_author_rejects_empty_events() {
        let backend = Arc::new(StubLlamaBackend::default());
        let author = LlamaBriefAuthor::new(backend);
        assert!(author.author(&[], "topic").is_err());
    }

    #[test]
    fn prompt_rendering_contains_all_event_ids() {
        let records = make_records(&[5, 10]);
        let prompt = LlamaBriefAuthor::render_prompt(&records, "Weekly sync");
        assert!(prompt.contains("EVENT_ID=5"));
        assert!(prompt.contains("EVENT_ID=10"));
        assert!(prompt.contains("Weekly sync"));
        assert!(prompt.contains("2 screen events"));
    }

    #[test]
    fn prompt_rendering_includes_template_rules() {
        let records = make_records(&[1]);
        let prompt = LlamaBriefAuthor::render_prompt(&records, "test");
        assert!(prompt.contains("[event:N]"));
        assert!(prompt.contains("###CITATIONS:"));
        assert!(prompt.contains("Do NOT invent"));
    }

    #[test]
    fn prompt_uses_chatml_format() {
        let records = make_records(&[1]);
        let prompt = LlamaBriefAuthor::render_prompt(&records, "test");
        assert!(
            prompt.contains("<|im_start|>system"),
            "must use Qwen3 ChatML system tag"
        );
        assert!(
            prompt.contains("<|im_end|>"),
            "must use Qwen3 ChatML end tag"
        );
        assert!(
            prompt.contains("<|im_start|>user"),
            "must use Qwen3 ChatML user tag"
        );
        assert!(
            prompt.contains("<|im_start|>assistant"),
            "must use Qwen3 ChatML assistant tag"
        );
        assert!(
            prompt.contains("/no_think"),
            "must use direct mode (no thinking tokens)"
        );
    }

    #[test]
    fn citation_parser_extracts_valid_ids() {
        let valid: HashSet<u64> = [1, 2, 3].into_iter().collect();
        let text = "Did thing [event:1] and [event:2] also [event:99]";
        let ids = parse_citations(text, &valid);
        assert_eq!(ids, vec![1, 2]);
    }

    #[test]
    fn citation_parser_skips_malformed() {
        let valid: HashSet<u64> = [1].into_iter().collect();
        let text = "[event:abc] [event:1] [event: [event:1]";
        let ids = parse_citations(text, &valid);
        // Only one unique valid citation
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn citation_parser_deduplicates() {
        let valid: HashSet<u64> = [5].into_iter().collect();
        let text = "[event:5] repeated [event:5] again [event:5]";
        let ids = parse_citations(text, &valid);
        assert_eq!(ids, vec![5]);
    }

    #[test]
    fn citation_parser_empty_input() {
        let valid: HashSet<u64> = [1].into_iter().collect();
        assert!(parse_citations("", &valid).is_empty());
        assert!(parse_citations("no citations here", &valid).is_empty());
    }

    #[test]
    fn parse_title_body_splits_correctly() {
        let raw = "My Title\n\n- bullet one [event:1]\n- bullet two [event:2]\n\n###CITATIONS: [event:1], [event:2]";
        let (title, body) = parse_title_body(raw);
        assert_eq!(title, "My Title");
        assert!(body.contains("bullet one"));
        assert!(body.contains("bullet two"));
        assert!(!body.contains("###CITATIONS:"));
    }

    #[test]
    fn parse_title_body_handles_empty() {
        let (title, body) = parse_title_body("");
        assert_eq!(title, "Untitled Brief");
        assert!(body.is_empty());
    }

    #[test]
    fn llama_author_filters_hallucinated_citations() {
        // Backend claims ids 10,20,30 but records only have 10,20
        let backend = Arc::new(StubLlamaBackend::with_event_ids(vec![10, 20, 30]));
        let author = LlamaBriefAuthor::new(backend);
        let records = make_records(&[10, 20]); // no event 30

        let brief = author.author(&records, "test").unwrap();
        assert!(!brief.citations.contains(&EventId(30)));
        assert!(brief.citations.contains(&EventId(10)));
        assert!(brief.citations.contains(&EventId(20)));
    }
}
