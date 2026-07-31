//! ADR-0030 §3(a) corpus runner.
//!
//! Reads `docs/research/sms-2fa-test-corpus-shapes.md`, applies the
//! [`mci_brain::redaction::sms_otp::redact_sms_shapes`] regex set + the
//! Mail-header check to each labelled entry, and emits a markdown
//! audit report to stdout.
//!
//! The committed artifact at
//! `docs/audit/2026-05-28-messages-mail-redaction-corpus.md` is the
//! output of this binary. Per ADR-0030 §1 gate-condition (4) the
//! catch rate on `S-` (sensitive) entries MUST be ≥99% and the
//! false-positive rate on `H-` (honey) entries MUST be ≤5% before
//! `com.apple.MobileSMS` or `com.apple.mail` may be added to
//! `known-safe-apps.toml`.
//!
//! # Usage
//!
//! ```bash
//! cargo run -p mci-brain --bin redaction_corpus --release \
//!   > docs/audit/2026-05-28-messages-mail-redaction-corpus.md
//! ```
//!
//! The runner is deterministic — same corpus + same regex set →
//! identical output bytes. The post-build sanity check is `git diff
//! docs/audit/2026-05-28-messages-mail-redaction-corpus.md` after a
//! second invocation; an empty diff is the §1 gate-condition (4)
//! determinism witness.

use std::fmt::Write;

use mci_brain::redaction::sms_otp::{redact_sms_shapes, TOKEN_BANK_NOTIFICATION, TOKEN_SMS_OTP};

const CORPUS_MD: &str = include_str!("../../fixtures/sms-2fa-test-corpus-shapes.md");

#[derive(Debug, Clone)]
struct Entry {
    id: String,
    class: char,
    text: String,
    must_redact: bool,
}

#[derive(Debug, Default, Clone, Copy)]
struct Tally {
    total: u32,
    caught: u32,
    missed: u32,
    false_positive: u32,
    true_negative: u32,
}

impl Tally {
    fn record(&mut self, entry: &Entry, matched: bool) {
        self.total += 1;
        match (entry.must_redact, matched) {
            (true, true) => self.caught += 1,
            (true, false) => self.missed += 1,
            (false, true) => self.false_positive += 1,
            (false, false) => self.true_negative += 1,
        }
    }
}

#[allow(clippy::too_many_lines)]
fn main() {
    let entries = parse_corpus(CORPUS_MD);

    let mut overall = Tally::default();
    let mut by_class: std::collections::BTreeMap<char, Tally> = std::collections::BTreeMap::new();

    // Build the per-entry table + tally.
    let mut rows = String::new();
    for e in &entries {
        let r = redact_sms_shapes(&e.text);
        let matched = r.matched();

        overall.record(e, matched);
        by_class.entry(e.class).or_default().record(e, matched);

        let outcome = match (e.must_redact, matched) {
            (true, true) => "✅ caught",
            (true, false) => "❌ missed",
            (false, true) => "⚠️ false-positive",
            (false, false) => "✅ true-negative",
        };
        let rules = if r.fired_rules.is_empty() {
            "—".to_string()
        } else {
            r.fired_rules.join(", ")
        };
        let _ = writeln!(
            rows,
            "| `{id}` | {outcome} | `{rules}` | {text} |",
            id = e.id,
            outcome = outcome,
            rules = rules,
            text = md_escape(&e.text),
        );
    }

    let total_sensitive = overall.caught + overall.missed;
    let total_honey = overall.false_positive + overall.true_negative;
    let catch_pct = if total_sensitive == 0 {
        0.0
    } else {
        (f64::from(overall.caught) / f64::from(total_sensitive)) * 100.0
    };
    let fp_pct = if total_honey == 0 {
        0.0
    } else {
        (f64::from(overall.false_positive) / f64::from(total_honey)) * 100.0
    };

    let gate_catch = catch_pct >= 99.0;
    let gate_fp = fp_pct <= 5.0;
    let gate_overall = gate_catch && gate_fp;

    // --------------------------------------------------------------------
    // Print the artifact.
    // --------------------------------------------------------------------

    println!("# ADR-0030 §3(a) Messages + Mail redaction corpus-run artifact");
    println!();
    println!("- **Date:** 2026-05-28");
    println!("- **Generator:** `cargo run -p mci-brain --bin redaction_corpus --release`");
    println!(
        "- **Corpus source:** `docs/research/sms-2fa-test-corpus-shapes.md` ({total} entries)",
        total = entries.len()
    );
    println!("- **Code under test:** `core/brain/src/redaction/sms_otp.rs` (Tier 1–4 + sentinel + password-reset prose)");
    println!("- **Replacement tokens:** `{TOKEN_SMS_OTP}` and `{TOKEN_BANK_NOTIFICATION}`");
    println!();
    println!("## Gate (ADR-0030 §1 condition (4))");
    println!();
    println!(
        "- **Catch rate on `S-` (sensitive) entries:** **{catch_pct:.2}%** ({caught}/{total_sensitive})  → gate ≥99%: **{gate_catch_str}**",
        catch_pct = catch_pct,
        caught = overall.caught,
        total_sensitive = total_sensitive,
        gate_catch_str = if gate_catch { "PASS ✅" } else { "FAIL ❌" },
    );
    println!(
        "- **False-positive rate on `H-` (honey) entries:** **{fp_pct:.2}%** ({fp}/{total_honey})  → gate ≤5%: **{gate_fp_str}**",
        fp_pct = fp_pct,
        fp = overall.false_positive,
        total_honey = total_honey,
        gate_fp_str = if gate_fp { "PASS ✅" } else { "FAIL ❌" },
    );
    println!(
        "- **Overall gate:** **{gate_overall_str}**",
        gate_overall_str = if gate_overall { "PASS ✅" } else { "FAIL ❌" },
    );
    println!();
    println!("## Per-class breakdown");
    println!();
    println!("| Class | Description | Total | Caught | Missed | FP | TN | Catch % | FP % |");
    println!("|---|---|---:|---:|---:|---:|---:|---:|---:|");
    for (class, t) in &by_class {
        let class_total_sensitive = t.caught + t.missed;
        let class_total_honey = t.false_positive + t.true_negative;
        let c_catch_pct = if class_total_sensitive == 0 {
            None
        } else {
            Some((f64::from(t.caught) / f64::from(class_total_sensitive)) * 100.0)
        };
        let c_fp_pct = if class_total_honey == 0 {
            None
        } else {
            Some((f64::from(t.false_positive) / f64::from(class_total_honey)) * 100.0)
        };
        println!(
            "| **{class}** | {desc} | {total} | {caught} | {missed} | {fp} | {tn} | {catch_pct} | {fp_pct} |",
            class = class,
            desc = class_description(*class),
            total = t.total,
            caught = t.caught,
            missed = t.missed,
            fp = t.false_positive,
            tn = t.true_negative,
            catch_pct = c_catch_pct
                .map_or_else(|| "—".to_string(), |p| format!("{p:.2}%")),
            fp_pct = c_fp_pct
                .map_or_else(|| "—".to_string(), |p| format!("{p:.2}%")),
        );
    }
    println!();
    println!("## Per-entry outcomes");
    println!();
    println!("| id | outcome | fired rules | text |");
    println!("|---|---|---|---|");
    print!("{rows}");
    println!();
    println!("## Notes");
    println!();
    println!("- The `outcome` column is `✅ caught` (S- correctly redacted), `❌ missed` (S- not redacted — counted in the missed total), `⚠️ false-positive` (H- incorrectly redacted — counted in the FP total), or `✅ true-negative` (H- correctly preserved).");
    println!("- The `fired rules` column lists the stable rule ids that fired in `core/brain/src/redaction/sms_otp.rs`. Empty (`—`) when no rule fired.");
    println!("- Replacement is performed by `redact_sms_shapes(text) -> RedactionResult`; no source bytes from a matched span survive in the returned text.");
    println!("- Determinism: this artifact is byte-identical across invocations on the same code + corpus. The §1 gate-condition (4) witness is `git diff` against the committed file.");
    println!();
    println!("## ADR references");
    println!();
    println!("- ADR-0030 §3(a) — SMS-OTP / banking-notification regex set (this corpus's gate)");
    println!(
        "- ADR-0030 §1 condition (4) — committed corpus-run artifact with catch ≥99% / FP ≤5%"
    );
    println!("- ADR-0013 Amendment 1 §3 — fail-safe-default-redact (the rule that motivates redacting on partial matches)");
    println!(
        "- ADR-0016 §4.2 — cascade-twice-for-OCR (the integration point this layer mounts at)"
    );
    println!("- ADR-0029 §5 — corpus-then-flip discipline (this PR's structure mirrors that)");

    // Exit code is 0 even on gate failure — the orchestrator reads
    // the artifact to decide whether to open the next PR; failing
    // hard here would obscure the report. The implementer (a human)
    // checks the gate line above. Tests (`cargo test -p mci-brain`)
    // are the hard fail.
}

fn class_description(c: char) -> &'static str {
    match c {
        'A' => "Apple-issued (Apple ID / Pay / iCloud)",
        'B' => "US bank / financial institution",
        'C' => "Generic carrier / short-code OTP",
        'D' => "Developer / SaaS account verification",
        'E' => "Auth-app / TOTP-display notification",
        'R' => "Password-reset / account-recovery",
        'H' => "Honey / adversarial (must NOT redact)",
        _ => "(unknown)",
    }
}

/// Escape a corpus text fragment for inclusion in a markdown table cell.
///
/// Pipe characters break the column count; backslashes break the
/// closing backtick. Replace both with their HTML entity forms so
/// the table renders correctly.
fn md_escape(s: &str) -> String {
    s.replace('|', "\\|").replace('\n', " ")
}

/// Parse the corpus markdown into a flat list of [`Entry`].
///
/// The corpus tables look like:
///
/// ```markdown
/// | id | text | must_redact | source_shape |
/// |---|---|---|---|
/// | A-01 | `483921 is your Apple ID Verification Code.` | true | … |
/// ```
///
/// The parser scans every line for the `| <id> | …` shape where
/// `<id>` matches `[A-Z]-[0-9]+`. The `text` column is unwrapped
/// from its surrounding backticks. The `must_redact` column is
/// parsed as `true` / `false`.
fn parse_corpus(md: &str) -> Vec<Entry> {
    let mut out = Vec::new();
    for line in md.lines() {
        let line = line.trim();
        if !line.starts_with('|') {
            continue;
        }
        // Split into columns. `|` may appear escaped in regex
        // sources inside the corpus, but the corpus tables here
        // use plain pipes; the four-column table shape is
        // structural.
        let cols: Vec<&str> = line.split('|').map(str::trim).collect();
        // First and last elements are empty strings from the
        // leading/trailing pipes. We want indices 1..=4.
        if cols.len() < 5 {
            continue;
        }
        let id_field = cols[1];
        let text_field = cols[2];
        let must_redact_field = cols[3];

        let Some(id) = parse_id(id_field) else {
            continue;
        };
        let class = id.chars().next().expect("id is non-empty after parse_id");

        let text = unwrap_backticks(text_field);
        if text.is_empty() {
            // Header rows (`| id | text | must_redact | source_shape |`)
            // would otherwise survive; the text column is empty after
            // backtick stripping.
            continue;
        }

        let must_redact = match must_redact_field.to_ascii_lowercase().as_str() {
            "true" => true,
            "false" => false,
            _ => continue, // separator row (`|---|---|`), header row, etc.
        };

        out.push(Entry {
            id,
            class,
            text,
            must_redact,
        });
    }
    out
}

/// Match `A-01` / `B-30` / `H-10` / etc. Returns the trimmed id or
/// `None` for non-matching cells (header rows, separators, free
/// prose).
fn parse_id(s: &str) -> Option<String> {
    let s = s.trim();
    if s.len() < 3 {
        return None;
    }
    let mut chars = s.chars();
    let class = chars.next()?;
    if !class.is_ascii_uppercase() {
        return None;
    }
    let dash = chars.next()?;
    if dash != '-' {
        return None;
    }
    if !chars.all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some(s.to_owned())
}

/// Strip a surrounding pair of backticks from a corpus text cell.
/// Cells without backticks (header / separator rows) return an
/// empty string so the caller can skip them.
fn unwrap_backticks(s: &str) -> String {
    let s = s.trim();
    if let Some(inner) = s.strip_prefix('`').and_then(|x| x.strip_suffix('`')) {
        inner.to_owned()
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_canonical_id_shapes() {
        assert_eq!(parse_id("A-01"), Some("A-01".into()));
        assert_eq!(parse_id("B-30"), Some("B-30".into()));
        assert_eq!(parse_id("H-10"), Some("H-10".into()));
        assert_eq!(parse_id(" R-03 "), Some("R-03".into()));
    }

    #[test]
    fn rejects_non_id_cells() {
        assert_eq!(parse_id(""), None);
        assert_eq!(parse_id("id"), None);
        assert_eq!(parse_id("---"), None);
        assert_eq!(parse_id("not an id"), None);
        // Mixed-case is rejected (corpus ids are always upper-case +
        // dash + digits).
        assert_eq!(parse_id("a-01"), None);
        assert_eq!(parse_id("A1"), None);
    }

    #[test]
    fn corpus_parses_to_non_empty_set() {
        let entries = parse_corpus(CORPUS_MD);
        // Cycle-8.14 seed corpus has 60+ entries.
        assert!(
            entries.len() >= 60,
            "expected ≥60 corpus entries, got {}",
            entries.len()
        );
        // At least one H- (honey) entry.
        assert!(entries.iter().any(|e| e.class == 'H'));
        // At least one B- (bank) entry.
        assert!(entries.iter().any(|e| e.class == 'B'));
        // All H- entries are must_redact=false; everything else is true.
        for e in &entries {
            if e.class == 'H' {
                assert!(!e.must_redact, "H-{} should be must_redact=false", e.id);
            } else {
                assert!(
                    e.must_redact,
                    "{}-{} should be must_redact=true",
                    e.class, e.id
                );
            }
        }
    }
}
