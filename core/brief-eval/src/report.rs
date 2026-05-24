//! Report types for the eval driver.
//!
//! Two layers:
//!
//! - [`MetricScore`] — one row in the per-fixture report. Carries the
//!   metric name, the observed value, the threshold, and a pass flag.
//! - [`FixtureOutcome`] — the full result for one fixture day, including
//!   structural counts (word count, bullet count, citation count) and
//!   the per-metric breakdown.
//! - [`EvalReport`] — aggregate across every fixture run in this
//!   invocation.

use std::time::Duration;

/// Per-metric pass/fail row.
#[derive(Debug, Clone)]
pub struct MetricScore {
    /// Metric identifier (e.g. `"fact_coverage"`).
    pub name: String,
    /// Observed numeric value (interpretation depends on the metric —
    /// fractions for coverage/validity, counts for hits/length/stub).
    pub value: f64,
    /// Threshold used for the pass decision (interpretation matches
    /// `value`).
    pub threshold: f64,
    /// Did this metric pass?
    pub pass: bool,
    /// Short human-readable explanation.
    pub detail: String,
}

/// Full outcome for one fixture day.
#[derive(Debug, Clone)]
pub struct FixtureOutcome {
    /// Fixture name (e.g. `"day_light"`).
    pub fixture_name: String,
    /// Generated brief title.
    pub title: String,
    /// Word count of the brief body.
    pub word_count: usize,
    /// Number of bullet lines in the body.
    pub bullet_count: usize,
    /// Number of `[event:N]` markers in the body.
    pub citation_marker_count: usize,
    /// Number of distinct event ids cited.
    pub unique_citations: usize,
    /// Cited event ids that don't resolve to a fixture event.
    pub unresolved_citations: Vec<u64>,
    /// Required facts from the gold spec that were absent.
    pub missing_facts: Vec<String>,
    /// Forbidden terms that appeared in the brief.
    pub forbidden_hits: Vec<String>,
    /// How many times the `StubLlamaBackend` signature phrase
    /// "Worked on task related to event" appears.
    pub stub_signature_count: usize,
    /// Per-metric breakdown.
    pub metrics: Vec<MetricScore>,
    /// Did every metric pass?
    pub pass: bool,
}

/// Aggregate report across every fixture in this run.
#[derive(Debug, Clone, Default)]
pub struct EvalReport {
    /// One entry per fixture (preserves input order).
    pub fixtures: Vec<FixtureOutcome>,
    /// Backend label echoed in the report header (e.g. `"scripted"`,
    /// `"stub"`, `"coreml"`).
    pub backend_label: String,
    /// Total wall-clock spent in `BriefAuthor::author` across all
    /// fixtures.
    pub author_time_total: Duration,
}

impl EvalReport {
    /// `true` when every fixture passed.
    #[must_use]
    pub fn all_passed(&self) -> bool {
        !self.fixtures.is_empty() && self.fixtures.iter().all(|f| f.pass)
    }

    /// Number of fixtures that passed.
    #[must_use]
    pub fn pass_count(&self) -> usize {
        self.fixtures.iter().filter(|f| f.pass).count()
    }

    /// Render a human-readable text report to stdout-style.
    #[must_use]
    pub fn render_text(&self) -> String {
        use std::fmt::Write;
        let mut out = String::new();
        let _ = writeln!(out, "MCI brief-author eval — backend: {}", self.backend_label);
        let _ = writeln!(
            out,
            "Fixtures: {} | Passed: {} | Author time: {:.2?}",
            self.fixtures.len(),
            self.pass_count(),
            self.author_time_total
        );
        let _ = writeln!(out, "{}", "-".repeat(72));

        for f in &self.fixtures {
            let status = if f.pass { "PASS" } else { "FAIL" };
            let _ = writeln!(
                out,
                "[{status}] {name:<24} words={words:<4} bullets={bullets:<3} cites={cites:<3} unresolved={unres}",
                status = status,
                name = f.fixture_name,
                words = f.word_count,
                bullets = f.bullet_count,
                cites = f.unique_citations,
                unres = f.unresolved_citations.len(),
            );
            for m in &f.metrics {
                let mark = if m.pass { "  ✓" } else { "  ✗" };
                let _ = writeln!(
                    out,
                    "{mark} {name:<20} value={value:<8.3} threshold={threshold:<8.3}  {detail}",
                    mark = mark,
                    name = m.name,
                    value = m.value,
                    threshold = m.threshold,
                    detail = m.detail,
                );
            }
            if !f.missing_facts.is_empty() {
                let _ = writeln!(out, "    missing facts: {}", f.missing_facts.join(", "));
            }
            if !f.unresolved_citations.is_empty() {
                let ids: Vec<String> = f
                    .unresolved_citations
                    .iter()
                    .map(std::string::ToString::to_string)
                    .collect();
                let _ = writeln!(out, "    unresolved citations: {}", ids.join(", "));
            }
            let _ = writeln!(out);
        }

        let _ = writeln!(
            out,
            "Overall: {} ({}/{} passed)",
            if self.all_passed() { "PASS" } else { "FAIL" },
            self.pass_count(),
            self.fixtures.len(),
        );
        out
    }
}
