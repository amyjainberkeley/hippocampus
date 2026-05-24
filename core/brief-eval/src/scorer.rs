//! Scorer — graded the generated brief against the gold spec.
//!
//! See `docs/eval/brief-quality.md` for the metric definitions, the
//! proposed pass thresholds, and how a passing score relates to
//! ADR-0028 + cycle 9.0 dogfood readiness.

use std::collections::HashSet;

use mci_brief::model::Brief;

use crate::fixture::FixtureDay;
use crate::gold::GoldBrief;
use crate::report::{FixtureOutcome, MetricScore};

/// Pass/fail thresholds applied to a brief's metrics.
///
/// ADR-0028 §"Negative / tradeoff" cites ADR-0010 as the eval gate but
/// is silent on numeric thresholds for INT4 quality. The defaults here
/// are this PR's proposal; the CEO ratifies (or revises) when running
/// the eval against the real model after `OWNER_TASKS` #17.
#[derive(Debug, Clone, Copy)]
pub struct PassThresholds {
    /// Minimum fraction of `required_facts` substrings present
    /// in the body (case-insensitive). Default: 0.80.
    pub min_fact_coverage: f64,
    /// Maximum number of `forbidden_terms` allowed in the body.
    /// Default: 0 — any hallucinated app/product name fails.
    pub max_forbidden_hits: usize,
    /// Minimum fraction of unique cited event ids that resolve to
    /// a real fixture event. Default: 0.90 — mirrors ADR-0018 §4.8
    /// "every output bullet carries ≥1 source-event-ID."
    pub min_citation_validity: f64,
    /// If true, the brief MUST NOT contain the
    /// [`StubLlamaBackend`](mci_brief::llama_backend::StubLlamaBackend)
    /// signature phrase. Used when pointing the eval at a real model
    /// to prove the stub fallback didn't sneak in.
    pub require_real_model: bool,
}

impl Default for PassThresholds {
    fn default() -> Self {
        Self {
            min_fact_coverage: 0.80,
            max_forbidden_hits: 0,
            min_citation_validity: 0.90,
            require_real_model: false,
        }
    }
}

/// Score one brief against its fixture + gold spec.
#[must_use]
#[allow(clippy::too_many_lines)]
pub fn score_brief(
    brief: &Brief,
    fixture: &FixtureDay,
    gold: &GoldBrief,
    thresholds: PassThresholds,
) -> FixtureOutcome {
    let body_lower = brief.body.to_lowercase();
    let title_lower = brief.title.to_lowercase();

    // ── Factual coverage ────────────────────────────────────────────────
    let mut fact_hits = 0_usize;
    let mut missing_facts = Vec::new();
    for fact in &gold.required_facts {
        let needle = fact.to_lowercase();
        if body_lower.contains(&needle) || title_lower.contains(&needle) {
            fact_hits += 1;
        } else {
            missing_facts.push(fact.clone());
        }
    }
    let fact_coverage = if gold.required_facts.is_empty() {
        1.0
    } else {
        #[allow(clippy::cast_precision_loss)]
        let v = fact_hits as f64 / gold.required_facts.len() as f64;
        v
    };
    let fact_pass = fact_coverage >= thresholds.min_fact_coverage;

    // ── Forbidden / hallucinated terms ──────────────────────────────────
    let mut forbidden_hits = Vec::new();
    for term in &gold.forbidden_terms {
        let needle = term.to_lowercase();
        if body_lower.contains(&needle) || title_lower.contains(&needle) {
            forbidden_hits.push(term.clone());
        }
    }
    let forbidden_pass = forbidden_hits.len() <= thresholds.max_forbidden_hits;

    // ── Structure ───────────────────────────────────────────────────────
    let bullet_count = count_bullets(&brief.body);
    let citation_marker_count = count_citation_markers(&brief.body);
    let has_title = !brief.title.trim().is_empty();
    let structure_pass = has_title
        && bullet_count >= gold.min_section_bullets
        && citation_marker_count >= gold.min_citations;

    // ── Length ──────────────────────────────────────────────────────────
    let word_count = brief.body.split_whitespace().count();
    let length_pass = word_count >= gold.min_words && word_count <= gold.max_words;

    // ── Citation validity ───────────────────────────────────────────────
    let valid_ids: HashSet<u64> = fixture.event_ids().into_iter().collect();
    let cited_ids: HashSet<u64> = brief.citations.iter().map(|id| id.0).collect();
    let valid_cited = cited_ids
        .iter()
        .filter(|id| valid_ids.contains(id))
        .count();
    let citation_validity = if cited_ids.is_empty() {
        // No citations at all is a hard fail elsewhere (structure
        // and gold.min_citations); avoid a divide-by-zero here.
        0.0
    } else {
        #[allow(clippy::cast_precision_loss)]
        let v = valid_cited as f64 / cited_ids.len() as f64;
        v
    };
    let unresolved_citations: Vec<u64> = cited_ids
        .iter()
        .copied()
        .filter(|id| !valid_ids.contains(id))
        .collect();
    let citation_pass = !cited_ids.is_empty() && citation_validity >= thresholds.min_citation_validity;

    // ── Stub-fallback detection ─────────────────────────────────────────
    let stub_signature_count = brief
        .body
        .matches("Worked on task related to event")
        .count();
    let stub_pass = !thresholds.require_real_model || stub_signature_count == 0;

    let all_pass = fact_pass
        && forbidden_pass
        && structure_pass
        && length_pass
        && citation_pass
        && stub_pass;

    let forbidden_hits_count = forbidden_hits.len();
    let forbidden_hits_detail = if forbidden_hits.is_empty() {
        "none".to_owned()
    } else {
        format!("hits: {}", forbidden_hits.join(", "))
    };

    FixtureOutcome {
        fixture_name: fixture.name.clone(),
        title: brief.title.clone(),
        word_count,
        bullet_count,
        citation_marker_count,
        unique_citations: cited_ids.len(),
        unresolved_citations,
        missing_facts,
        forbidden_hits,
        stub_signature_count,
        metrics: vec![
            MetricScore {
                name: "fact_coverage".into(),
                value: fact_coverage,
                threshold: thresholds.min_fact_coverage,
                pass: fact_pass,
                detail: format!(
                    "{fact_hits}/{} required facts present",
                    gold.required_facts.len()
                ),
            },
            MetricScore {
                name: "forbidden_hits".into(),
                value: f64::from(u32::try_from(forbidden_hits_count).unwrap_or(u32::MAX)),
                #[allow(clippy::cast_precision_loss)]
                threshold: thresholds.max_forbidden_hits as f64,
                pass: forbidden_pass,
                detail: forbidden_hits_detail,
            },
            MetricScore {
                name: "structure".into(),
                value: f64::from(u8::from(structure_pass)),
                threshold: 1.0,
                pass: structure_pass,
                detail: format!(
                    "{bullet_count} bullets (need ≥{}), {citation_marker_count} citation markers (need ≥{}), title_present={has_title}",
                    gold.min_section_bullets, gold.min_citations
                ),
            },
            MetricScore {
                name: "length".into(),
                value: f64::from(u32::try_from(word_count).unwrap_or(u32::MAX)),
                threshold: f64::from(u32::try_from(gold.min_words).unwrap_or(u32::MAX)),
                pass: length_pass,
                detail: format!("{word_count} words (window: {}..{})", gold.min_words, gold.max_words),
            },
            MetricScore {
                name: "citation_validity".into(),
                value: citation_validity,
                threshold: thresholds.min_citation_validity,
                pass: citation_pass,
                detail: format!(
                    "{valid_cited}/{} cited ids resolve",
                    cited_ids.len()
                ),
            },
            MetricScore {
                name: "stub_fallback".into(),
                value: f64::from(u32::try_from(stub_signature_count).unwrap_or(u32::MAX)),
                threshold: 0.0,
                pass: stub_pass,
                detail: if thresholds.require_real_model {
                    format!("real model required; {stub_signature_count} stub-signature phrases")
                } else {
                    format!("informational; {stub_signature_count} stub-signature phrases")
                },
            },
        ],
        pass: all_pass,
    }
}

fn count_bullets(body: &str) -> usize {
    body.lines()
        .filter(|l| {
            let t = l.trim_start();
            t.starts_with("- ") || t.starts_with("* ") || t.starts_with("• ")
        })
        .count()
}

fn count_citation_markers(body: &str) -> usize {
    // Matches "[event:NUMBER]" — the same syntax LlamaBriefAuthor parses.
    let mut count = 0_usize;
    let mut rest = body;
    while let Some(start) = rest.find("[event:") {
        let after = &rest[start + 7..];
        if let Some(end) = after.find(']') {
            let inner = &after[..end];
            if inner.chars().all(|c| c.is_ascii_digit()) && !inner.is_empty() {
                count += 1;
            }
            rest = &after[end + 1..];
        } else {
            break;
        }
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::EventId;
    use mci_brief::model::{Brief, BriefId, BriefState};

    fn fixture(name: &str, ids: &[u64]) -> FixtureDay {
        FixtureDay {
            name: name.into(),
            source_path: "/dev/null".into(),
            events: ids
                .iter()
                .map(|&id| crate::fixture::FixtureEvent {
                    event_id: id,
                    ts_us: id * 1_000_000,
                    app_bundle_id: None,
                    window_title: None,
                    url: None,
                    text: format!("event {id}"),
                })
                .collect(),
        }
    }

    fn brief(title: &str, body: &str, cites: &[u64]) -> Brief {
        Brief {
            id: BriefId(0),
            title: title.into(),
            body: body.into(),
            citations: cites.iter().copied().map(EventId).collect(),
            state: BriefState::Draft,
            created_ts_us: 0,
            updated_ts_us: 0,
            human_approver_id: None,
        }
    }

    fn gold() -> GoldBrief {
        GoldBrief {
            notes: "test".into(),
            required_facts: vec!["pull request".into(), "merged".into()],
            forbidden_terms: vec!["zoom".into()],
            min_words: 5,
            max_words: 200,
            min_citations: 1,
            min_section_bullets: 1,
        }
    }

    #[test]
    fn passing_brief_passes_all_metrics() {
        let f = fixture("test", &[1, 2]);
        let g = gold();
        let body = "- Merged the pull request fixing the OCR pipeline [event:1]\n- Reviewed companion PR [event:2]";
        let b = brief("Daily summary", body, &[1, 2]);
        let outcome = score_brief(&b, &f, &g, PassThresholds::default());
        assert!(outcome.pass, "expected pass: {outcome:?}");
    }

    #[test]
    fn hallucinated_forbidden_term_fails() {
        let f = fixture("test", &[1]);
        let g = gold();
        let body = "- Joined a Zoom call about the pull request [event:1] and merged it";
        let b = brief("Bad day", body, &[1]);
        let outcome = score_brief(&b, &f, &g, PassThresholds::default());
        assert!(!outcome.pass);
        assert!(!outcome.forbidden_hits.is_empty());
    }

    #[test]
    fn hallucinated_citation_fails_validity() {
        let f = fixture("test", &[1]);
        let g = gold();
        let body = "- Merged the pull request [event:1] [event:99]";
        let mut b = brief("Bad cites", body, &[1, 99]);
        b.citations.push(EventId(99));
        let outcome = score_brief(&b, &f, &g, PassThresholds::default());
        // 99 is not a real fixture event → citation_validity < 1.0
        let citation_metric = outcome
            .metrics
            .iter()
            .find(|m| m.name == "citation_validity")
            .unwrap();
        assert!(citation_metric.value < 1.0);
    }

    #[test]
    fn require_real_model_fails_on_stub_signature() {
        let f = fixture("test", &[1, 2]);
        let g = gold();
        let body = "- Worked on task related to event deployment [event:1]\n- Merged the pull request [event:2]";
        let b = brief("Stubby", body, &[1, 2]);
        let th = PassThresholds {
            require_real_model: true,
            ..PassThresholds::default()
        };
        let outcome = score_brief(&b, &f, &g, th);
        assert!(!outcome.pass);
        let stub_metric = outcome
            .metrics
            .iter()
            .find(|m| m.name == "stub_fallback")
            .unwrap();
        assert!(!stub_metric.pass);
    }
}
