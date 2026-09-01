//! LongMemEval retrieval benchmark, run against the real brain.
//!
//! # Why this exists
//!
//! Hippocampus has never had a number attached to it. Competing products
//! publish benchmark charts; practitioners in the local-memory community
//! complain, correctly, that no shared benchmark exists and so nobody can
//! tell which of these systems actually work. Without a measurement there
//! is no honest way to claim recall is good, and no way to tell whether a
//! change to fusion weights helped or hurt.
//!
//! # What is measured, and what is not
//!
//! This measures **retrieval**, not question answering. LongMemEval's full
//! task is: read a long chat history, then answer a question about it.
//! That end-to-end score is dominated by whichever LLM writes the answer,
//! which is not the part Hippocampus supplies. Hippocampus supplies the
//! step before it: given the question, find the sessions that contain the
//! answer.
//!
//! So the metric is session-level retrieval over the labelled
//! `answer_session_ids`. A number produced this way is **not comparable**
//! to a published QA-accuracy number, and any writeup that puts the two on
//! one axis is wrong. It is comparable across runs of this harness, which
//! is what makes it useful for deciding whether a change was an
//! improvement.
//!
//! # Why it runs the production path
//!
//! Every instance gets a real `SqlCipherBrainStore`, the real
//! `HybridRetriever`, and the real ArcticEmbedS Core ML embedder loaded
//! through the same resolver `mcp-serve` uses. A benchmark that
//! reimplements retrieval measures the reimplementation. The cost is that
//! a run is slow, roughly 250,000 events embedded across 500 instances.
//! That is the right trade.
//!
//! # Arms
//!
//! Both arms run over the identical corpus so the comparison is internal
//! and fair:
//!
//! - `lexical` — FTS5 only, the embedder withheld. This is what
//!   `mci-brain search` gives you today.
//! - `hybrid` — FTS5 + semantic under ADR-0010 min-max fusion, which is
//!   what `mci_recall` gives Claude Code.
//!
//! If hybrid does not beat lexical here, the embedder is not earning the
//! 64 MB it costs, and that is a finding worth having either way.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use mci_brain::{
    BrainStore, Event, EventId, HybridRetriever, RetrievalQuery, Retriever, SqlCipherBrainStore,
};
use mci_core::crypto::DbKey;

use crate::idle_batch::backfill_until_drained;

/// One LongMemEval instance: a question plus the haystack it hides in.
#[derive(serde::Deserialize)]
pub struct Instance {
    /// Dataset-assigned identifier, unique across the 500 instances.
    pub question_id: String,
    /// One of the six LongMemEval categories, e.g. `multi-session`.
    pub question_type: String,
    /// The question asked of the history.
    pub question: String,
    /// When the question is asked. Used as "now" so the recency term in
    /// fusion sees the same clock the scenario implies.
    pub question_date: String,
    /// Sessions that actually contain the answer. The ground truth.
    #[serde(default)]
    pub answer_session_ids: Vec<String>,
    /// One timestamp per haystack session, same order.
    pub haystack_dates: Vec<String>,
    /// One id per haystack session, same order.
    pub haystack_session_ids: Vec<String>,
    /// The haystack: every session, each a list of turns.
    pub haystack_sessions: Vec<Vec<Turn>>,
}

/// One message in a session.
#[derive(serde::Deserialize)]
pub struct Turn {
    /// `user` or `assistant`.
    pub role: String,
    /// The message text.
    pub content: String,
}

/// Which retrieval arm to run.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Arm {
    /// FTS5 only. What `mci-brain search` gives you.
    Lexical,
    /// FTS5 + semantic under ADR-0010 fusion. What `mci_recall` gives.
    Hybrid,
}

impl Arm {
    /// Short name used in output and in the JSON report.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Lexical => "lexical",
            Self::Hybrid => "hybrid",
        }
    }
}

/// Per-instance outcome. Kept per-instance rather than only aggregated so
/// a bad category can be traced back to the questions that caused it.
#[derive(serde::Serialize, Clone)]
pub struct InstanceResult {
    /// Which instance this scores.
    pub question_id: String,
    /// Its LongMemEval category.
    pub question_type: String,
    /// Rank (1-based) of the first answer session in the ranked session
    /// list, or `None` if no answer session was retrieved at all.
    pub first_hit_rank: Option<usize>,
    /// Fraction of this instance's answer sessions found within each k.
    pub recall_at: BTreeMap<usize, f64>,
    /// How many sessions held the answer, for this question.
    pub answer_sessions: usize,
    /// Haystack size, so a score can be read against its difficulty.
    pub sessions_in_haystack: usize,
    /// Turns actually written to the brain, after empty ones are skipped.
    pub events_indexed: usize,
}

/// Aggregate over a set of instances.
#[derive(serde::Serialize, Clone)]
pub struct Summary {
    /// Which arm produced these numbers.
    pub arm: String,
    /// How many instances are behind the averages.
    pub instances: usize,
    /// Proportion of questions where at least one answer session appeared
    /// in the top k. This is the number a user feels: did it find it.
    pub hit_rate_at: BTreeMap<usize, f64>,
    /// Mean proportion of answer sessions recovered within top k. Stricter
    /// than hit rate, because most questions have more than one.
    pub recall_at: BTreeMap<usize, f64>,
    /// Mean reciprocal rank of the first answer session.
    pub mrr: f64,
    /// Questions where no answer session was retrieved at any depth.
    pub complete_misses: usize,
}

/// Everything one run produced, written with `--out`.
#[derive(serde::Serialize)]
pub struct Report {
    /// Path of the dataset this run read, recorded so a published number
    /// can be traced to the exact file that produced it.
    pub dataset: String,
    /// One summary per arm, over every instance.
    pub overall: Vec<Summary>,
    /// question_type -> one summary per arm.
    pub by_type: BTreeMap<String, Vec<Summary>>,
    /// Every per-instance result, so a category can be traced to cases.
    pub results: Vec<InstanceResult>,
}

/// Parse `2023/05/20 (Sat) 02:21` into microseconds since the epoch.
///
/// The weekday is ignored: it is redundant with the date and the dataset
/// is internally consistent, so trusting it would only add a way to be
/// wrong. A date that will not parse is an error rather than a guess,
/// because a silently wrong timestamp corrupts the recency term in fusion
/// and would show up as an unexplained score change.
///
/// # Errors
/// Returns the offending string when it does not match the expected shape.
pub fn parse_dataset_ts(s: &str) -> Result<u64, String> {
    let bad = || format!("unparseable timestamp: {s:?}");
    // "2023/05/20 (Sat) 02:21" -> ["2023/05/20", "(Sat)", "02:21"].
    let mut parts = s.split_whitespace();
    let date = parts.next().ok_or_else(bad)?;
    let time = parts.next_back().ok_or_else(bad)?;
    if date == time {
        return Err(bad());
    }

    let mut d = date.split('/');
    let y: i64 = d.next().ok_or_else(bad)?.parse().map_err(|_| bad())?;
    let mo: i64 = d.next().ok_or_else(bad)?.parse().map_err(|_| bad())?;
    let da: i64 = d.next().ok_or_else(bad)?.parse().map_err(|_| bad())?;
    if d.next().is_some() || !(1..=12).contains(&mo) || !(1..=31).contains(&da) {
        return Err(bad());
    }

    let (hh, mm) = time.split_once(':').ok_or_else(bad)?;
    let hh: i64 = hh.parse().map_err(|_| bad())?;
    let mm: i64 = mm.parse().map_err(|_| bad())?;
    if hh > 23 || mm > 59 {
        return Err(bad());
    }

    // Howard Hinnant's days_from_civil.
    let y_adj = if mo <= 2 { y - 1 } else { y };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = y_adj - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + da - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;

    let secs = days * 86_400 + hh * 3_600 + mm * 60;
    u64::try_from(secs)
        .map(|s| s * 1_000_000)
        .map_err(|_| bad())
}

/// Build one instance's brain, then run the question against it.
///
/// # Errors
/// Any store, embed or retrieval failure, with the instance id attached.
pub fn run_instance(
    inst: &Instance,
    arm: Arm,
    ks: &[usize],
    dir: &Path,
) -> Result<InstanceResult, String> {
    let db_path = dir.join(format!("{}.sqlite", inst.question_id));
    // A throwaway key: the corpus is a public dataset and the database is
    // deleted at the end of the instance. It still goes through SQLCipher
    // so the benchmark exercises the same write path users do.
    let key = DbKey::from_bytes([0x5a; 32]);
    let store = SqlCipherBrainStore::new(&db_path, &key)
        .map_err(|e| format!("{}: open store: {e}", inst.question_id))?;

    // event id -> session id, so a hit can be attributed back.
    let mut owner: BTreeMap<u64, String> = BTreeMap::new();
    let mut events_indexed = 0usize;

    for (si, session) in inst.haystack_sessions.iter().enumerate() {
        let sid = inst
            .haystack_session_ids
            .get(si)
            .ok_or_else(|| format!("{}: session {si} has no id", inst.question_id))?;
        let base_ts = parse_dataset_ts(
            inst.haystack_dates
                .get(si)
                .ok_or_else(|| format!("{}: session {si} has no date", inst.question_id))?,
        )
        .map_err(|e| format!("{}: {e}", inst.question_id))?;

        for (ti, turn) in session.iter().enumerate() {
            let text = turn.content.trim();
            if text.is_empty() {
                continue;
            }
            // Turns inside a session share a date, so spread them a second
            // apart. Without this the recency term cannot order them and
            // ties resolve arbitrarily.
            let ts_us = base_ts + (ti as u64) * 1_000_000;
            // Same context-header shape the real ingest path writes, so
            // the embedder sees the same kind of string it sees in
            // production rather than a bare turn.
            let header = format!(
                "[app=longmemeval | title={} | url={sid} | ts={ts_us}]\n",
                turn.role
            );
            let event = Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: Some("longmemeval".to_string()),
                window_title: Some(turn.role.clone()),
                url: Some(sid.clone()),
                text: format!("{header}{text}"),
                embedding: None,
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: None,
                tab_id: None,
            };
            let id = store
                .put_event(&event)
                .map_err(|e| format!("{}: put_event: {e}", inst.question_id))?;
            owner.insert(id.0, sid.clone());
            events_indexed += 1;
        }
    }

    let store = Arc::new(store);
    let now_us =
        parse_dataset_ts(&inst.question_date).map_err(|e| format!("{}: {e}", inst.question_id))?;

    let max_k = ks.iter().copied().max().unwrap_or(10);
    // Ask for more events than sessions wanted: several events collapse
    // into one session, so a top-k of events is a shorter list of
    // sessions. Over-fetching keeps the session list long enough to score
    // the deepest k honestly.
    let query = RetrievalQuery {
        text: inst.question.clone(),
        limit: max_k * 10,
        time_filter: None,
        app_filter: None,
    };

    let hits: Vec<u64> = match arm {
        // No embedder at all, rather than a zero-vector stub fed into
        // fusion: against a zero query every document scores an identical
        // cosine, which would add uniform noise on top of the lexical
        // signal and make this arm measure something that is neither
        // lexical nor hybrid.
        Arm::Lexical => store
            .fts5_search(&query.text, query.limit)
            .map_err(|e| format!("{}: fts5: {e}", inst.question_id))?
            .into_iter()
            .map(|(id, _score)| id.0)
            .collect(),
        Arm::Hybrid => {
            let (doc_emb, is_real) = crate::embedder_load::load_embedder_backend();
            if !is_real {
                return Err(format!(
                    "{}: hybrid arm needs the real ArcticEmbedS model and none loaded;                      refusing to report a number for an arm that did not run",
                    inst.question_id
                ));
            }
            backfill_until_drained(store.as_ref(), doc_emb.as_ref(), 64, |_| {})
                .map_err(|e| format!("{}: embed: {e}", inst.question_id))?;
            // Query flavour, not document flavour: ADR-0011 §3 prefix.
            let (q_emb, _) = crate::embedder_load::load_query_embedder_backend();
            // Both wrappers are the ones `mcp-serve` uses. `DynEmbedder`
            // because `HybridRetriever<S, E>` needs `E: Sized`, and
            // `FtsSanitizingStore` because the retriever hands raw query
            // text to FTS5 — without it a question containing an
            // apostrophe or a hyphen would error out of the lexical half
            // and the hybrid arm would quietly score as semantic-only.
            let sanitizing = crate::mcp::live::FtsSanitizingStore {
                inner: Arc::clone(&store),
            };
            HybridRetriever::new(
                Arc::new(sanitizing),
                Arc::new(crate::mcp::live::DynEmbedder(q_emb)),
                now_us,
            )
            .retrieve(&query)
            .map_err(|e| format!("{}: retrieve: {e}", inst.question_id))?
            .into_iter()
            .map(|h| h.event_id.0)
            .collect()
        }
    };

    // Collapse the event ranking into a session ranking, first occurrence
    // wins. This is the granularity the labels are at.
    let mut ranked: Vec<String> = Vec::new();
    for id in hits {
        if let Some(sid) = owner.get(&id) {
            if !ranked.iter().any(|s| s == sid) {
                ranked.push(sid.clone());
            }
        }
    }

    let answers: Vec<&String> = inst.answer_session_ids.iter().collect();
    let first_hit_rank = ranked
        .iter()
        .position(|s| answers.iter().any(|a| *a == s))
        .map(|p| p + 1);

    let mut recall_at = BTreeMap::new();
    for &k in ks {
        let found = ranked
            .iter()
            .take(k)
            .filter(|s| answers.iter().any(|a| a == s))
            .count();
        let denom = answers.len().max(1);
        recall_at.insert(k, found as f64 / denom as f64);
    }

    drop(store);
    let _ = std::fs::remove_file(&db_path);

    Ok(InstanceResult {
        question_id: inst.question_id.clone(),
        question_type: inst.question_type.clone(),
        first_hit_rank,
        recall_at,
        answer_sessions: answers.len(),
        sessions_in_haystack: inst.haystack_sessions.len(),
        events_indexed,
    })
}

/// Aggregate a set of per-instance results into one summary.
#[must_use]
pub fn summarize(results: &[InstanceResult], arm: Arm, ks: &[usize]) -> Summary {
    let n = results.len();
    let denom = if n == 0 { 1.0 } else { n as f64 };

    let mut hit_rate_at = BTreeMap::new();
    let mut recall_at = BTreeMap::new();
    for &k in ks {
        let hits = results
            .iter()
            .filter(|r| r.first_hit_rank.is_some_and(|rank| rank <= k))
            .count();
        hit_rate_at.insert(k, hits as f64 / denom);
        let rec: f64 = results
            .iter()
            .map(|r| r.recall_at.get(&k).copied().unwrap_or(0.0))
            .sum();
        recall_at.insert(k, rec / denom);
    }

    let mrr = results
        .iter()
        .map(|r| r.first_hit_rank.map_or(0.0, |rank| 1.0 / rank as f64))
        .sum::<f64>()
        / denom;

    Summary {
        arm: arm.label().to_string(),
        instances: n,
        hit_rate_at,
        recall_at,
        mrr,
        complete_misses: results
            .iter()
            .filter(|r| r.first_hit_rank.is_none())
            .count(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_dataset_timestamp() {
        // 2023-05-20 02:21 UTC = 1684549260
        assert_eq!(
            parse_dataset_ts("2023/05/20 (Sat) 02:21").unwrap(),
            1_684_549_260_000_000
        );
    }

    #[test]
    fn parses_the_epoch_and_a_leap_day() {
        assert_eq!(parse_dataset_ts("1970/01/01 (Thu) 00:00").unwrap(), 0);
        // 2024-02-29 exists; 2023-02-29 does not, but the dataset never
        // contains it and rejecting real dates would be worse than
        // accepting an impossible one here.
        assert_eq!(
            parse_dataset_ts("2024/02/29 (Thu) 12:00").unwrap(),
            1_709_208_000_000_000
        );
    }

    #[test]
    fn rejects_rather_than_guesses() {
        for bad in [
            "2023/13/01 (Sat) 02:21", // month 13
            "2023/05/32 (Sat) 02:21", // day 32
            "2023/05/20 (Sat) 25:00", // hour 25
            "2023/05/20 (Sat) 02:61", // minute 61
            "not a date",
            "2023/05/20",
        ] {
            assert!(
                parse_dataset_ts(bad).is_err(),
                "{bad:?} should not parse, a wrong timestamp corrupts the recency term silently"
            );
        }
    }

    #[test]
    fn summary_scores_a_known_ranking() {
        let mk = |rank: Option<usize>, rec: f64| InstanceResult {
            question_id: "q".into(),
            question_type: "t".into(),
            first_hit_rank: rank,
            recall_at: [(5usize, rec)].into_iter().collect(),
            answer_sessions: 2,
            sessions_in_haystack: 50,
            events_indexed: 100,
        };
        // ranks 1 and 3 -> MRR = (1.0 + 0.3333)/3, one complete miss.
        let s = summarize(
            &[mk(Some(1), 1.0), mk(Some(3), 0.5), mk(None, 0.0)],
            Arm::Hybrid,
            &[5],
        );
        assert_eq!(s.instances, 3);
        assert_eq!(s.complete_misses, 1);
        assert!((s.hit_rate_at[&5] - 2.0 / 3.0).abs() < 1e-9);
        assert!((s.recall_at[&5] - 0.5).abs() < 1e-9);
        assert!((s.mrr - (1.0 + 1.0 / 3.0) / 3.0).abs() < 1e-9);
    }

    #[test]
    fn hit_rate_respects_the_k_cutoff() {
        let r = InstanceResult {
            question_id: "q".into(),
            question_type: "t".into(),
            first_hit_rank: Some(7),
            recall_at: BTreeMap::new(),
            answer_sessions: 1,
            sessions_in_haystack: 50,
            events_indexed: 10,
        };
        let s = summarize(std::slice::from_ref(&r), Arm::Hybrid, &[1, 5, 10]);
        assert!(
            (s.hit_rate_at[&1] - 0.0).abs() < 1e-9,
            "rank 7 is not in top 1"
        );
        assert!(
            (s.hit_rate_at[&5] - 0.0).abs() < 1e-9,
            "rank 7 is not in top 5"
        );
        assert!(
            (s.hit_rate_at[&10] - 1.0).abs() < 1e-9,
            "rank 7 is in top 10"
        );
    }
}
