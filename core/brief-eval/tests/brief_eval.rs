//! Integration test for the brief-quality eval framework.
//!
//! Two passes per fixture:
//!
//! 1. **Scripted backend (CI default)** — proves the full
//!    `LlamaBriefAuthor + ScriptedLlamaBackend` path produces a brief
//!    that passes every metric. This is the deterministic green that
//!    CI relies on.
//! 2. **Stub backend (regression check)** — proves that
//!    [`StubBriefAuthor`] does NOT pass. This is intentional: the stub
//!    is supposed to fail the eval so that "still on the stub" is a
//!    loud, visible signal in any future CEO run.
//!
//! The Core ML backend (`Qwen3CoreMLBackend`) is opt-in via the
//! `coreml` feature; integration tests do not invoke it because
//! running the real model takes ~10-20 s per fixture and requires the
//! ~950 MB `.mlmodelc` artifact, which `OWNER_TASKS` #17 produces.

use std::sync::Arc;

use mci_brief::author::{BriefAuthor, StubBriefAuthor};
use mci_brief::llama_author::LlamaBriefAuthor;
use mci_brief::llama_backend::LlamaBackend;

use mci_brief_eval::{
    bundled_fixtures_dir, list_fixture_names, score_brief, FixtureDay, GoldBrief, PassThresholds,
    ScriptedLlamaBackend,
};

fn load_scripted(name: &str) -> String {
    let path = bundled_fixtures_dir()
        .join("scripted")
        .join(name)
        .with_extension("md");
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("missing scripted output {}: {e}", path.display()))
}

#[test]
fn every_fixture_passes_with_scripted_backend() {
    let dir = bundled_fixtures_dir();
    let names = list_fixture_names(&dir).expect("list fixtures");
    assert!(
        names.len() >= 5,
        "expected ≥5 fixtures in the corpus, got {}",
        names.len()
    );

    let thresholds = PassThresholds::default();
    let mut failures = Vec::new();

    for name in &names {
        let fixture = FixtureDay::load(&dir, name)
            .unwrap_or_else(|e| panic!("load fixture {name}: {e}"));
        let gold =
            GoldBrief::load(&dir, name).unwrap_or_else(|e| panic!("load gold {name}: {e}"));

        let scripted = load_scripted(name);
        let backend: Arc<dyn LlamaBackend> = Arc::new(ScriptedLlamaBackend::new(scripted));
        let author = LlamaBriefAuthor::new(backend);

        let records = fixture.to_event_records();
        let brief = author
            .author(&records, "Daily brief")
            .unwrap_or_else(|e| panic!("scripted author failed on {name}: {e}"));

        let outcome = score_brief(&brief, &fixture, &gold, thresholds);
        if !outcome.pass {
            failures.push(format!(
                "fixture {name} failed; missing_facts={:?} forbidden_hits={:?} unresolved_citations={:?} word_count={} bullets={} unique_citations={}",
                outcome.missing_facts,
                outcome.forbidden_hits,
                outcome.unresolved_citations,
                outcome.word_count,
                outcome.bullet_count,
                outcome.unique_citations,
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "expected all fixtures to pass; failures:\n{}",
        failures.join("\n")
    );
}

#[test]
fn stub_brief_author_intentionally_fails_eval() {
    let dir = bundled_fixtures_dir();
    let names = list_fixture_names(&dir).expect("list fixtures");
    let thresholds = PassThresholds::default();
    let author = StubBriefAuthor;

    let mut any_passed = false;
    for name in &names {
        let fixture = FixtureDay::load(&dir, name).expect("load fixture");
        let gold = GoldBrief::load(&dir, name).expect("load gold");
        let records = fixture.to_event_records();
        let brief = author.author(&records, "Daily brief").expect("stub author");
        let outcome = score_brief(&brief, &fixture, &gold, thresholds);
        if outcome.pass {
            any_passed = true;
        }
    }
    // StubBriefAuthor concatenates raw event-text snippets with no
    // structure or citations — it can't satisfy the gold spec for any
    // of the fixtures. If this assertion ever flips, the eval has
    // softened to the point where the dev stub passes — almost
    // certainly an unintentional regression in the scorer thresholds.
    assert!(
        !any_passed,
        "StubBriefAuthor unexpectedly passed at least one fixture — the eval is too lenient"
    );
}

#[test]
fn require_real_model_threshold_rejects_stub_signature() {
    let dir = bundled_fixtures_dir();
    let fixture = FixtureDay::load(&dir, "day_light").expect("load fixture");
    let gold = GoldBrief::load(&dir, "day_light").expect("load gold");

    // Use the LlamaBriefAuthor with the *stub* LlamaBackend (which
    // produces "Worked on task related to event N" output). The eval
    // with --require-real-model must catch this.
    let backend: Arc<dyn LlamaBackend> = Arc::new(
        mci_brief::llama_backend::StubLlamaBackend::with_event_ids(fixture.event_ids()),
    );
    let author = LlamaBriefAuthor::new(backend);
    let records = fixture.to_event_records();
    let brief = author.author(&records, "Daily brief").unwrap();

    let thresholds = PassThresholds {
        require_real_model: true,
        ..PassThresholds::default()
    };
    let outcome = score_brief(&brief, &fixture, &gold, thresholds);

    assert!(
        !outcome.pass,
        "expected --require-real-model to reject stub LLM output"
    );
    let stub_metric = outcome
        .metrics
        .iter()
        .find(|m| m.name == "stub_fallback")
        .expect("stub_fallback metric present");
    assert!(!stub_metric.pass);
    assert!(outcome.stub_signature_count > 0);
}
