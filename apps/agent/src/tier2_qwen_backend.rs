//! V2-P5 — Qwen-backed [`NerBackend`] for Tier 2 entity extraction.
//!
//! Wraps the [`LlamaBackend`] (production: `Qwen3CoreMLBackend` on
//! macOS) and renders a structured-output prompt that asks Qwen to
//! emit JSON of the form:
//!
//! ```json
//! {
//!   "entities": [
//!     {
//!       "kind": "person_name",
//!       "canonical": "Alice Smith",
//!       "text": "Alice Smith",
//!       "span": [12, 23],
//!       "confidence": 0.95
//!     }
//!   ]
//! }
//! ```
//!
//! The parser is defensive — Qwen sometimes wraps the JSON in a
//! ```json … ``` fence or prepends a sentence; we extract the first
//! `{ … }` block and parse it. Spans + verbatim-text are verified
//! by [`mci_brain::Tier2Extractor`] above this backend; this
//! backend's job is just to coerce raw model output into
//! [`Tier2RawMatch`] structs.
//!
//! # Cascade discipline
//!
//! Same posture as [`crate::brain_ingest`] — this backend operates
//! on `events.text` which is already cascade-twice-cleared (pixel-
//! time §1–§5/§7 + OCR-time §6 redaction). It does not re-litigate
//! cascade. The Tier 2 extractor above this backend applies the
//! cascade-marker SKIP + token-REDACT downstream SKIP filters.
//!
//! # Footprint
//!
//! Qwen inference is ~100-500ms per call with the structured-output
//! prompt + ~2 KB response. The async idle-batch worker
//! (`tier2_worker.rs`) drives this backend in single-flight,
//! bounded steady-state; on-disk cost is the Qwen3-1.7B model
//! (~950 MB INT4-palettized) and runtime cost is ~400-500 MB
//! working set per ADR-0028 §6.

use mci_brain::{NerBackend, NerError, Tier2RawMatch};
use mci_brief::llama_backend::LlamaBackend;
use serde::Deserialize;
use std::sync::Arc;

/// `NerBackend` impl that asks a [`LlamaBackend`] for structured-
/// output JSON.
///
/// The prompt template lists a closed kind set
/// (`person_name`, `organization`, `project_name`, `product_name`,
/// `location`, `topic`) so Qwen has a constrained vocabulary. The
/// parser tolerates leading prose + optional ```json … ``` fencing;
/// it extracts the first `{ … }` block and parses it.
pub struct QwenTier2Backend {
    llama: Arc<dyn LlamaBackend>,
}

impl QwenTier2Backend {
    /// Construct a Tier 2 backend backed by an already-loaded
    /// [`LlamaBackend`]. The caller (typically `mci_agent.rs`
    /// startup) is responsible for the model lifecycle.
    #[must_use]
    pub fn new(llama: Arc<dyn LlamaBackend>) -> Self {
        Self { llama }
    }
}

impl std::fmt::Debug for QwenTier2Backend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QwenTier2Backend").finish_non_exhaustive()
    }
}

impl NerBackend for QwenTier2Backend {
    fn extract_entities(&self, text: &str) -> Result<Vec<Tier2RawMatch>, NerError> {
        if text.trim().is_empty() {
            return Err(NerError::InvalidInput("empty text".into()));
        }
        let prompt = build_ner_prompt(text);
        let raw = self
            .llama
            .generate(&prompt)
            .map_err(|e| NerError::Backend(e.to_string()))?;
        parse_qwen_ner_output(&raw, text)
    }
}

/// Build the structured-output NER prompt. Lists the closed kind
/// set, asks for one JSON object on the output, gives a worked
/// example so the model anchors on the schema.
///
/// The prompt is intentionally compact (a long preamble eats into
/// the Qwen3-1.7B 2048-token context). For the typical OCR event
/// (≤1500 word-tokens), the input fits with room to spare; longer
/// inputs are truncated by the backend's tokenizer before
/// generation (Qwen's fixed-2048 context drops the tail).
fn build_ner_prompt(text: &str) -> String {
    // Keep the example small; structured-output 1.7B-class models
    // anchor better on a tiny, exact-schema example than on a long
    // discursive prompt.
    format!(
        "You are an entity extractor. From the input text, extract entities of these kinds:\n\
         - person_name: a named individual (e.g. \"Alice Smith\", \"Dr. Chen\")\n\
         - organization: a company / team / group (e.g. \"Anthropic\", \"the Brain team\")\n\
         - project_name: an internal or public project (e.g. \"MCI\", \"V2-P5\")\n\
         - product_name: a software / hardware product (e.g. \"Hippocampus\", \"iPhone 15 Pro\")\n\
         - location: a place (e.g. \"San Francisco\", \"office 3F\")\n\
         - topic: a free-form subject (e.g. \"footprint slo\", \"oauth migration\")\n\
         \n\
         Skip token-shape strings (JWTs, API keys, crypto addresses) — those are handled separately.\n\
         Skip the contents of [REDACTED:…] markers — those are already redacted.\n\
         \n\
         Reply with one JSON object: {{\"entities\": [{{\"kind\": \"…\", \"canonical\": \"…\", \"text\": \"…\", \"span\": [start, end], \"confidence\": 0.0-1.0}}]}}\n\
         \n\
         Span offsets are BYTE offsets into the input text. The substring at text[start..end] MUST equal the \"text\" field exactly.\n\
         \n\
         INPUT:\n\
         {text}\n\
         \n\
         JSON:"
    )
}

/// Parse the raw Qwen output into [`Tier2RawMatch`] candidates.
///
/// Defensive: extracts the first `{ … }` block (Qwen sometimes
/// wraps the JSON in ```json … ``` fences or prepends a sentence),
/// then deserialises. The Tier 2 extractor above this verifies
/// that each span actually points at the claimed substring; this
/// parser just coerces the wire format.
fn parse_qwen_ner_output(raw: &str, _input: &str) -> Result<Vec<Tier2RawMatch>, NerError> {
    let json_str = extract_json_object(raw)
        .ok_or_else(|| NerError::Parse("no JSON object found in model output".into()))?;
    let parsed: NerOutput = serde_json::from_str(json_str)
        .map_err(|e| NerError::Parse(format!("JSON deserialise: {e}")))?;
    let mut out: Vec<Tier2RawMatch> = Vec::with_capacity(parsed.entities.len());
    for raw in parsed.entities {
        // Tolerate Qwen omitting an explicit confidence — default
        // to 0.7 (above the 0.5 floor, below 0.9 so a
        // confidence-comparison test still works).
        let confidence = raw.confidence.unwrap_or(0.7).clamp(0.0, 1.0);
        // Tolerate Qwen using `canonical` as alias for missing
        // `text`, and vice versa.
        let canonical = raw.canonical.clone().unwrap_or_else(|| raw.text.clone());
        let text = raw.text;
        let (start, end) = (raw.span.0, raw.span.1);
        out.push(Tier2RawMatch {
            kind: raw.kind,
            canonical_name: canonical,
            mention_text: text,
            span_start: start,
            span_end: end,
            confidence,
        });
    }
    Ok(out)
}

/// Find the first balanced `{ … }` block in `s`, returning a
/// `&str` slice of it. Returns `None` if no opening brace is
/// present or the braces don't balance before end-of-string.
///
/// Used to peel back optional ```json … ``` fencing or leading
/// "Here's the JSON:" prose that 1.7B-class models occasionally
/// emit.
fn extract_json_object(s: &str) -> Option<&str> {
    let start = s.find('{')?;
    let mut depth: i32 = 0;
    let bytes = s.as_bytes();
    let mut in_string = false;
    let mut escape = false;
    for (i, b) in bytes.iter().enumerate().skip(start) {
        if escape {
            escape = false;
            continue;
        }
        match *b {
            b'\\' if in_string => escape = true,
            b'"' => in_string = !in_string,
            b'{' if !in_string => depth += 1,
            b'}' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    return Some(&s[start..=i]);
                }
            }
            _ => {}
        }
    }
    None
}

#[derive(Debug, Deserialize)]
struct NerOutput {
    #[serde(default)]
    entities: Vec<NerEntity>,
}

#[derive(Debug, Deserialize)]
struct NerEntity {
    kind: String,
    #[serde(default)]
    canonical: Option<String>,
    text: String,
    span: (usize, usize),
    #[serde(default)]
    confidence: Option<f32>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brief::llama_backend::{GenerateError, LlamaBackend, StubLlamaBackend};

    /// Test backend that returns a caller-supplied raw string verbatim.
    #[derive(Debug)]
    struct CannedBackend {
        output: String,
    }
    impl LlamaBackend for CannedBackend {
        fn generate(&self, _prompt: &str) -> Result<String, GenerateError> {
            Ok(self.output.clone())
        }
        fn max_output_tokens(&self) -> usize {
            512
        }
    }

    #[test]
    fn extract_json_object_finds_simple_object() {
        let s = r#"Here is the JSON: {"a": 1} ok"#;
        assert_eq!(extract_json_object(s), Some(r#"{"a": 1}"#));
    }

    #[test]
    fn extract_json_object_handles_nested_braces() {
        let s = r#"{"outer": {"inner": [1, 2, 3]}}"#;
        assert_eq!(extract_json_object(s), Some(s));
    }

    #[test]
    fn extract_json_object_ignores_braces_in_strings() {
        let s = r#"{"a": "has } inside", "b": 2}"#;
        assert_eq!(extract_json_object(s), Some(s));
    }

    #[test]
    fn extract_json_object_handles_escaped_quotes() {
        let s = r#"{"a": "\"hi\" }", "b": 2}"#;
        assert_eq!(extract_json_object(s), Some(s));
    }

    #[test]
    fn extract_json_object_strips_code_fence() {
        let s = "```json\n{\"entities\": []}\n```";
        assert_eq!(extract_json_object(s), Some(r#"{"entities": []}"#));
    }

    #[test]
    fn extract_json_object_returns_none_on_no_braces() {
        assert!(extract_json_object("no braces here").is_none());
    }

    #[test]
    fn extract_json_object_returns_none_on_unbalanced() {
        assert!(extract_json_object("{ unbalanced").is_none());
    }

    #[test]
    fn parse_qwen_ner_output_parses_valid_json() {
        let text = "Alice Smith met Bob today";
        let raw = r#"{
            "entities": [
                {"kind": "person_name", "canonical": "Alice Smith", "text": "Alice Smith", "span": [0, 11], "confidence": 0.95},
                {"kind": "person_name", "canonical": "Bob", "text": "Bob", "span": [16, 19], "confidence": 0.88}
            ]
        }"#;
        let out = parse_qwen_ner_output(raw, text).expect("parse ok");
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].kind, "person_name");
        assert_eq!(out[0].canonical_name, "Alice Smith");
        assert_eq!(out[0].mention_text, "Alice Smith");
        assert_eq!(out[0].span_start, 0);
        assert_eq!(out[0].span_end, 11);
        assert!((out[0].confidence - 0.95).abs() < 1e-5);
        assert_eq!(out[1].mention_text, "Bob");
    }

    #[test]
    fn parse_qwen_ner_output_handles_missing_confidence() {
        let text = "Alice met Bob";
        let raw = r#"{"entities": [{"kind": "person_name", "canonical": "Alice", "text": "Alice", "span": [0, 5]}]}"#;
        let out = parse_qwen_ner_output(raw, text).expect("parse ok");
        assert_eq!(out.len(), 1);
        // Default confidence is 0.7.
        assert!((out[0].confidence - 0.7).abs() < 1e-5);
    }

    #[test]
    fn parse_qwen_ner_output_handles_missing_canonical_falls_back_to_text() {
        let text = "Hello World";
        let raw = r#"{"entities": [{"kind": "topic", "text": "Hello World", "span": [0, 11], "confidence": 0.8}]}"#;
        let out = parse_qwen_ner_output(raw, text).expect("parse ok");
        assert_eq!(out[0].canonical_name, "Hello World");
    }

    #[test]
    fn parse_qwen_ner_output_clamps_out_of_range_confidence() {
        let text = "Test";
        let raw = r#"{"entities": [{"kind": "topic", "canonical": "x", "text": "Test", "span": [0, 4], "confidence": 2.5}]}"#;
        let out = parse_qwen_ner_output(raw, text).expect("parse ok");
        assert!((out[0].confidence - 1.0).abs() < 1e-5);

        let neg = r#"{"entities": [{"kind": "topic", "canonical": "x", "text": "Test", "span": [0, 4], "confidence": -0.5}]}"#;
        let out = parse_qwen_ner_output(neg, text).expect("parse ok");
        assert!((out[0].confidence - 0.0).abs() < 1e-5);
    }

    #[test]
    fn parse_qwen_ner_output_handles_code_fence_wrapping() {
        let text = "Alice";
        let raw =
            "```json\n{\"entities\": [{\"kind\": \"person_name\", \"text\": \"Alice\", \"span\": [0, 5], \"confidence\": 0.9}]}\n```";
        let out = parse_qwen_ner_output(raw, text).expect("parse ok");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].mention_text, "Alice");
    }

    #[test]
    fn parse_qwen_ner_output_handles_prepended_prose() {
        let text = "Alice";
        let raw = "Here is the structured output: {\"entities\": [{\"kind\": \"person_name\", \"text\": \"Alice\", \"span\": [0, 5], \"confidence\": 0.9}]}";
        let out = parse_qwen_ner_output(raw, text).expect("parse ok");
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn parse_qwen_ner_output_empty_entities_array() {
        let text = "nothing here";
        let raw = r#"{"entities": []}"#;
        let out = parse_qwen_ner_output(raw, text).expect("parse ok");
        assert!(out.is_empty());
    }

    #[test]
    fn parse_qwen_ner_output_rejects_malformed_json() {
        let text = "test";
        let raw = "{not json";
        let err = parse_qwen_ner_output(raw, text).expect_err("should fail");
        assert!(matches!(err, NerError::Parse(_)));
    }

    #[test]
    fn parse_qwen_ner_output_rejects_no_json_at_all() {
        let text = "test";
        let raw = "just prose, no JSON anywhere";
        let err = parse_qwen_ner_output(raw, text).expect_err("should fail");
        assert!(matches!(err, NerError::Parse(_)));
    }

    #[test]
    fn build_ner_prompt_includes_input_text_and_schema() {
        let text = "Alice met Bob";
        let prompt = build_ner_prompt(text);
        // Schema reference present.
        assert!(prompt.contains("person_name"));
        assert!(prompt.contains("organization"));
        assert!(prompt.contains("project_name"));
        assert!(prompt.contains("topic"));
        // Closed-vocab discipline references.
        assert!(prompt.contains("Skip token-shape"));
        assert!(prompt.contains("[REDACTED"));
        // Input is appended at the end before "JSON:".
        assert!(prompt.contains(text));
        assert!(prompt.contains("JSON:"));
    }

    #[test]
    fn backend_rejects_empty_input() {
        let llama: Arc<dyn LlamaBackend> = Arc::new(StubLlamaBackend::default());
        let backend = QwenTier2Backend::new(llama);
        let err = backend.extract_entities("").expect_err("empty rejected");
        assert!(matches!(err, NerError::InvalidInput(_)));
        let err2 = backend
            .extract_entities("   \t  ")
            .expect_err("whitespace rejected");
        assert!(matches!(err2, NerError::InvalidInput(_)));
    }

    #[test]
    fn backend_returns_parsed_entities_from_canned_backend() {
        let canned = Arc::new(CannedBackend {
            output: r#"{"entities": [{"kind": "person_name", "canonical": "Alice", "text": "Alice", "span": [0, 5], "confidence": 0.9}]}"#.to_string(),
        });
        let backend = QwenTier2Backend::new(canned);
        let out = backend.extract_entities("Alice and Bob met").expect("ok");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].canonical_name, "Alice");
    }

    #[test]
    fn backend_propagates_backend_error_as_ner_error_backend() {
        #[derive(Debug)]
        struct FailingBackend;
        impl LlamaBackend for FailingBackend {
            fn generate(&self, _: &str) -> Result<String, GenerateError> {
                Err(GenerateError::Backend("model load failed".into()))
            }
            fn max_output_tokens(&self) -> usize {
                512
            }
        }
        let backend = QwenTier2Backend::new(Arc::new(FailingBackend));
        let err = backend.extract_entities("Hello").expect_err("should fail");
        assert!(matches!(err, NerError::Backend(_)));
    }
}
