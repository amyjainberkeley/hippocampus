//! ADR-0030 §3(f) / ADR-0032 §4 V2-P7 corpus runner.
//!
//! Reads `docs/research/messages-plugin-test-corpus.md`, applies the
//! [`mci_brain::redaction::messages_plugin::redact_messages_plugin_event`]
//! cascade-equivalent to each labelled entry, and emits a markdown audit
//! report to stdout.
//!
//! The committed artifact at `docs/audit/2026-05-30-messages-plugin-corpus.md`
//! is the output of this binary. Per ADR-0032 §4 the catch rate on the
//! `MS-`/`MB-`/`MU-`/`MP-` classes MUST be ≥99% and the false-positive
//! rate on the `MH-` honey class MUST be ≤5% before V2-P10 may flip
//! `MessagesPluginConfig::DEFAULT::plugin_enabled = true`.
//!
//! # Usage
//!
//! ```bash
//! cargo run -p mci-brain --bin messages_plugin_corpus --release \
//!   > docs/audit/2026-05-30-messages-plugin-corpus.md
//! ```
//!
//! The runner is deterministic — same corpus + same code → identical
//! output bytes. The post-build sanity check is `git diff
//! docs/audit/2026-05-30-messages-plugin-corpus.md` after a second
//! invocation; an empty diff is the determinism witness.

use std::fmt::Write;

use mci_brain::redaction::messages_plugin::{
    redact_messages_plugin_event, MessagesPluginConfig, MessagesPluginEvent,
};

const CORPUS_MD: &str = include_str!("../../fixtures/messages-plugin-test-corpus.md");

#[derive(Debug, Clone)]
struct Entry {
    id: String,
    class: String,
    body: String,
    participants: Vec<String>,
    expect: Expect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Expect {
    /// MS / MB: §3(a) regex must fire in place (`drop_event = false`,
    /// `fired_rules` non-empty, body carries replacement tokens).
    Redact,
    /// MU / MP: cascade-equivalent must drop the event.
    Drop,
    /// MH: honey — neither dropped nor redacted.
    Pass,
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
    fn record(&mut self, expect: Expect, observed_drop: bool, observed_redact: bool) {
        self.total += 1;
        match expect {
            Expect::Redact => {
                if observed_redact {
                    self.caught += 1;
                } else {
                    self.missed += 1;
                }
            }
            Expect::Drop => {
                if observed_drop {
                    self.caught += 1;
                } else {
                    self.missed += 1;
                }
            }
            Expect::Pass => {
                if observed_drop || observed_redact {
                    self.false_positive += 1;
                } else {
                    self.true_negative += 1;
                }
            }
        }
    }
}

#[allow(clippy::too_many_lines)]
fn main() {
    let entries = parse_corpus(CORPUS_MD);

    let mut overall_sensitive = Tally::default();
    let mut overall_honey = Tally::default();
    let mut by_class: std::collections::BTreeMap<String, Tally> = std::collections::BTreeMap::new();

    // The cascade-equivalent runs with plugin_enabled=true so the runner
    // exercises the actual redaction logic. (DEFAULT is plugin_enabled=
    // false, which would drop every event with reason PluginDisabled —
    // that's the live deployment posture, not the corpus posture.)
    let cfg = MessagesPluginConfig {
        plugin_enabled: true,
        ..MessagesPluginConfig::DEFAULT
    };

    let mut rows = String::new();
    for e in &entries {
        let evt = MessagesPluginEvent {
            participants: e.participants.clone(),
            body: Some(e.body.clone()),
            service: "iMessage".to_owned(),
            is_from_me: false,
        };
        let d = redact_messages_plugin_event(&evt, &cfg);
        let observed_drop = d.drop_event;
        let observed_redact = !d.drop_event && !d.fired_rules.is_empty();

        if e.expect == Expect::Pass {
            overall_honey.record(e.expect, observed_drop, observed_redact);
        } else {
            overall_sensitive.record(e.expect, observed_drop, observed_redact);
        }
        by_class.entry(e.class.clone()).or_default().record(
            e.expect,
            observed_drop,
            observed_redact,
        );

        let outcome = match (e.expect, observed_drop, observed_redact) {
            (Expect::Drop, true, _) => "drop_caught",
            (Expect::Drop, false, _) => "drop_missed",
            (Expect::Redact, false, true) => "redact_caught",
            (Expect::Redact, true, _) => "redact_overdropped",
            (Expect::Redact, false, false) => "redact_missed",
            (Expect::Pass, false, false) => "pass_ok",
            (Expect::Pass, true, _) => "false_positive_drop",
            (Expect::Pass, false, true) => "false_positive_redact",
        };
        let detail = if observed_drop {
            d.drop_reason
                .map_or_else(|| "—".to_string(), |r| format!("drop:{r:?}"))
        } else if observed_redact {
            format!("rules:{}", d.fired_rules.join(","))
        } else {
            "—".to_string()
        };
        let _ = writeln!(
            rows,
            "| `{id}` | {outcome} | `{detail}` | {body} |",
            id = e.id,
            outcome = outcome,
            detail = detail,
            body = md_escape(&e.body),
        );
    }

    let sens_total = overall_sensitive.caught + overall_sensitive.missed;
    let honey_total = overall_honey.false_positive + overall_honey.true_negative;
    let catch_pct = if sens_total == 0 {
        0.0
    } else {
        (f64::from(overall_sensitive.caught) / f64::from(sens_total)) * 100.0
    };
    let fp_pct = if honey_total == 0 {
        0.0
    } else {
        (f64::from(overall_honey.false_positive) / f64::from(honey_total)) * 100.0
    };

    let gate_catch = catch_pct >= 99.0;
    let gate_fp = fp_pct <= 5.0;
    let gate_overall = gate_catch && gate_fp;

    println!("# ADR-0030 §3(f) / ADR-0032 §4 V2-P7 Messages plugin corpus-run artifact");
    println!();
    println!("- **Date:** 2026-05-30");
    println!("- **Generator:** `cargo run -p mci-brain --bin messages_plugin_corpus --release`");
    println!(
        "- **Corpus source:** `docs/research/messages-plugin-test-corpus.md` ({total} entries)",
        total = entries.len()
    );
    println!("- **Code under test:** `core/brain/src/redaction/messages_plugin.rs`");
    println!("- **Adapter crate:** `adapters/macos/mci-messages-reader/` (READ-ONLY)");
    println!();
    println!("## Per-class gate (ADR-0032 §4)");
    println!();
    println!("Per ADR-0032 §4 the gate is `(catch ≥99% on MS+MB+MU+MP) AND (FP ≤5% on MH)`.");
    println!();
    println!(
        "- **Catch rate on `MS-`+`MB-`+`MU-`+`MP-` entries:** **{catch_pct:.2}%** ({caught}/{sens_total})  → gate ≥99%: **{gate_catch_str}**",
        catch_pct = catch_pct,
        caught = overall_sensitive.caught,
        sens_total = sens_total,
        gate_catch_str = if gate_catch { "PASS" } else { "FAIL" },
    );
    println!(
        "- **False-positive rate on `MH-` (honey) entries:** **{fp_pct:.2}%** ({fp}/{honey_total})  → gate ≤5%: **{gate_fp_str}**",
        fp_pct = fp_pct,
        fp = overall_honey.false_positive,
        honey_total = honey_total,
        gate_fp_str = if gate_fp { "PASS" } else { "FAIL" },
    );
    println!(
        "- **Overall gate:** **{gate_overall_str}**",
        gate_overall_str = if gate_overall { "PASS" } else { "FAIL" },
    );
    println!();
    println!("## Per-class breakdown");
    println!();
    println!("| Class | Description | Total | Caught | Missed | FP | TN | Catch % | FP % |");
    println!("|---|---|---:|---:|---:|---:|---:|---:|---:|");
    for (class, t) in &by_class {
        let c_sens_total = t.caught + t.missed;
        let c_honey_total = t.false_positive + t.true_negative;
        let c_catch_pct = if c_sens_total == 0 {
            None
        } else {
            Some((f64::from(t.caught) / f64::from(c_sens_total)) * 100.0)
        };
        let c_fp_pct = if c_honey_total == 0 {
            None
        } else {
            Some((f64::from(t.false_positive) / f64::from(c_honey_total)) * 100.0)
        };
        println!(
            "| **{class}** | {desc} | {total} | {caught} | {missed} | {fp} | {tn} | {catch_pct} | {fp_pct} |",
            class = class,
            desc = class_description(class),
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
    println!("| id | outcome | detail | body |");
    println!("|---|---|---|---|");
    print!("{rows}");
    println!();
    println!("## Notes");
    println!();
    println!("- `outcome` is `drop_caught` / `redact_caught` (sensitive entry handled correctly), `drop_missed` / `redact_missed` (sensitive entry slipped through), `pass_ok` (honey entry handled correctly), `false_positive_drop` / `false_positive_redact` (honey entry incorrectly dropped / redacted), `redact_overdropped` (sensitive entry was dropped instead of redacted — counts as caught for the gate but may indicate an over-eager drop predicate).");
    println!("- `detail` carries either the cascade-equivalent's `drop_reason` (when dropped) or the rules that fired in the §3(a) `redact_sms_shapes` pass.");
    println!("- The cascade-equivalent runs with `MessagesPluginConfig {{ plugin_enabled: true, ..DEFAULT }}` — the master switch is forced ON so the runner exercises the redaction logic. In a shipped V2-P7 binary `plugin_enabled = false` and every event is dropped with reason `PluginDisabled`; V2-P10 is the user-driven flip.");
    println!("- Determinism: this artifact is byte-identical across invocations on the same code + corpus. The §4 gate witness is `git diff` against the committed file.");
    println!();
    println!("## ADR references");
    println!();
    println!("- ADR-0030 §3(f) — per-plugin redaction arm extension.");
    println!("- ADR-0032 §3(b) — default-OFF master switch (`MessagesPluginConfig::DEFAULT::plugin_enabled = false`).");
    println!("- ADR-0032 §4 — per-class gate (≥99% catch / ≤5% FP).");
    println!("- ADR-0013 Amendment 1 §3 — fail-safe-default-redact (the rule that motivates dropping/redacting on partial matches).");
    println!("- ADR-0029 §5 — corpus-then-flip discipline (this PR's structure mirrors that).");
}

fn class_description(class: &str) -> &'static str {
    match class {
        "MS" => "SMS-OTP shapes carried over a Messages row",
        "MB" => "Banking notification shapes (fraud / transaction confirmations)",
        "MU" => "Sensitive URL / host inside the body",
        "MP" => "Sensitive participant (e.g. alerts@chase.com)",
        "MH" => "Honey / adversarial (must NOT drop or redact)",
        _ => "(unknown)",
    }
}

/// Escape a corpus text fragment for inclusion in a markdown table cell.
fn md_escape(s: &str) -> String {
    s.replace('|', "\\|").replace('\n', " ")
}

/// Parse the corpus markdown into a flat list of [`Entry`].
///
/// The corpus tables look like:
///
/// ```markdown
/// | id | body | participants | expect | source_shape |
/// |---|---|---|---|---|
/// | MS-01 | `483921 is your Apple ID Verification Code.` | `+18001234567` | redact | … |
/// ```
///
/// The parser scans every line for the `| <id> | <body> | <parts> | <expect> | …` shape
/// where `<id>` matches `(MS|MB|MU|MP|MH)-[0-9]+`. The body and participants
/// columns are unwrapped from their surrounding backticks; participants are
/// split on `|` (escaped inside the table cell) — but the corpus uses
/// space-separation inside one backticked cell to avoid the pipe-conflict,
/// so we split on `,` instead.
fn parse_corpus(md: &str) -> Vec<Entry> {
    let mut out = Vec::new();
    for line in md.lines() {
        let line = line.trim();
        if !line.starts_with('|') {
            continue;
        }
        let cols: Vec<&str> = line.split('|').map(str::trim).collect();
        // First / last elements are empty (leading/trailing pipes).
        // We want indices 1..=5 → id, body, participants, expect, source.
        if cols.len() < 6 {
            continue;
        }
        let id_field = cols[1];
        let body_field = cols[2];
        let participants_field = cols[3];
        let expect_field = cols[4];

        // Allow the id to be wrapped in backticks (the corpus uses
        // `MS-01` style for visual alignment) — strip them before the
        // shape probe.
        let id_unwrapped = id_field
            .trim()
            .trim_start_matches('`')
            .trim_end_matches('`');
        let Some(id) = parse_id(id_unwrapped) else {
            continue;
        };
        let class = id
            .split_once('-')
            .map_or_else(|| id.clone(), |(c, _)| c.to_owned());

        let body = unwrap_backticks(body_field);
        if body.is_empty() {
            continue;
        }
        let participants_raw = unwrap_backticks(participants_field);
        let participants: Vec<String> = participants_raw
            .split(',')
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
            .collect();

        let expect = match expect_field.to_ascii_lowercase().as_str() {
            "drop" => Expect::Drop,
            "redact" => Expect::Redact,
            "pass" => Expect::Pass,
            _ => continue,
        };

        out.push(Entry {
            id,
            class,
            body,
            participants,
            expect,
        });
    }
    out
}

/// Match `MS-01`, `MB-05`, `MU-10`, `MP-03`, `MH-12`. Returns the trimmed
/// id or `None` for non-matching cells.
fn parse_id(s: &str) -> Option<String> {
    let s = s.trim();
    if s.len() < 4 {
        return None;
    }
    let (prefix, rest) = s.split_once('-')?;
    if !matches!(prefix, "MS" | "MB" | "MU" | "MP" | "MH") {
        return None;
    }
    if rest.is_empty() || !rest.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(s.to_owned())
}

/// Strip a surrounding pair of backticks from a corpus text cell.
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
    fn parses_canonical_ids() {
        assert_eq!(parse_id("MS-01"), Some("MS-01".into()));
        assert_eq!(parse_id("MB-05"), Some("MB-05".into()));
        assert_eq!(parse_id("MU-10"), Some("MU-10".into()));
        assert_eq!(parse_id("MP-03"), Some("MP-03".into()));
        assert_eq!(parse_id("MH-12"), Some("MH-12".into()));
        assert_eq!(parse_id(" MS-01 "), Some("MS-01".into()));
    }

    #[test]
    fn rejects_non_corpus_ids() {
        assert_eq!(parse_id(""), None);
        assert_eq!(parse_id("id"), None);
        assert_eq!(parse_id("A-01"), None); // upstream sms corpus class
        assert_eq!(parse_id("---"), None);
        assert_eq!(parse_id("MS-"), None);
        assert_eq!(parse_id("MSX-01"), None);
    }

    #[test]
    fn corpus_parses_to_non_empty_set() {
        let entries = parse_corpus(CORPUS_MD);
        // V2-P7 seed corpus has 57 entries (25 MS + 5 MB + 10 MU + 5 MP + 12 MH).
        assert!(
            entries.len() >= 50,
            "expected ≥50 corpus entries, got {}",
            entries.len()
        );
        assert!(entries.iter().any(|e| e.class == "MS"));
        assert!(entries.iter().any(|e| e.class == "MB"));
        assert!(entries.iter().any(|e| e.class == "MU"));
        assert!(entries.iter().any(|e| e.class == "MP"));
        assert!(entries.iter().any(|e| e.class == "MH"));
        // All MH entries must be `pass`; everything else must be `drop` or `redact`.
        for e in &entries {
            if e.class == "MH" {
                assert_eq!(e.expect, Expect::Pass, "MH entry {} should be pass", e.id);
            } else {
                assert_ne!(e.expect, Expect::Pass, "{} should not be pass", e.id);
            }
        }
    }
}
