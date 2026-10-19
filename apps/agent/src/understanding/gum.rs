//! A general user model, after GUM (Shaikh et al., 2025, arXiv 2505.10831).
//!
//! **Propose** writes candidate propositions from an observation. **Retrieve**
//! finds stored propositions that might be the same claim: BM25 over text and
//! reasoning, adjusted for staleness (`exp(-decay · k · age_days)`, k = 2) and
//! diversified with maximal marginal relevance (λ = 0.5). **Revise** asks the
//! model whether each candidate is identical, similar or unrelated; identical
//! and similar ones are merged into one revised proposition carrying all the
//! evidence, and the originals are retired. A proposition the user rejected
//! is never proposed again, and one the user confirmed keeps the words they
//! agreed to: a draft that restates it only adds its evidence.

use std::collections::BTreeSet;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use mci_brain::understanding::{NewProposition, Proposition, PropositionKind, PropositionStatus};
use mci_brain::{SqlCipherBrainStore, StoreError};

use super::mind::{MindCallError, MindClient};

const RECENCY_K: f64 = 2.0;
const MMR_LAMBDA: f64 = 0.5;
const CANDIDATES: usize = 5;
const CALL_TIMEOUT: Duration = Duration::from_secs(60);
/// The label stored with a proposition when the ready line named no engine.
pub const MODEL: &str = super::mind::DEFAULT_ENGINE;

/// A proposition as the mind writes it (scores 1–10).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Draft {
    /// The statement.
    pub text: String,
    /// Why.
    pub reasoning: String,
    /// Kind name.
    pub kind: String,
    /// 1–10.
    pub confidence: i64,
    /// 1–10.
    pub decay: i64,
}

impl Draft {
    /// `model` is who wrote it, as [`MindClient::engine_label`] names it.
    #[allow(clippy::cast_precision_loss)] // both are clamped to 1–10
    fn to_new(&self, model: &str) -> NewProposition {
        NewProposition {
            text: self.text.trim().to_owned(),
            reasoning: self.reasoning.trim().to_owned(),
            kind: PropositionKind::parse(&self.kind).unwrap_or(PropositionKind::State),
            confidence: (self.confidence.clamp(1, 10) as f64) / 10.0,
            decay: (self.decay.clamp(1, 10) as f64) / 10.0,
            model: model.into(),
        }
    }

    #[allow(clippy::cast_possible_truncation)] // stored scores are 0–1, so these are 0–10
    fn from_stored(p: &Proposition) -> Self {
        Self {
            text: p.text.clone(),
            reasoning: p.reasoning.clone(),
            kind: p.kind.as_str().into(),
            confidence: (p.confidence * 10.0).round() as i64,
            decay: (p.decay * 10.0).round() as i64,
        }
    }
}

#[derive(Deserialize)]
struct ProposeOut {
    propositions: Vec<Draft>,
}

#[derive(Deserialize)]
struct Relation {
    id: i64,
    relation: String,
}

#[derive(Deserialize)]
struct RelateOut {
    relations: Vec<Relation>,
}

/// What one integration did.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize)]
pub struct Integration {
    /// New propositions stored.
    pub added: u32,
    /// Existing ones revised.
    pub revised: u32,
    /// Drafts dropped (rejected before, trivial, a model failure, or a
    /// restatement of a confirmed claim, which gains the draft's evidence).
    pub skipped: u32,
}

/// Errors that stop an integration.
#[derive(Debug, thiserror::Error)]
pub enum GumError {
    /// The store failed.
    #[error(transparent)]
    Store(#[from] StoreError),
    /// The model failed.
    #[error(transparent)]
    Mind(#[from] MindCallError),
}

fn words(text: &str) -> BTreeSet<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.len() >= 3)
        .map(str::to_owned)
        .collect()
}

const DAY_US: u64 = 86_400_000_000;

/// Whether a proposition is too old to use: one that goes stale fast (decay
/// 0.9 or more) after a day without being seen again, 0.7 or more after a
/// week, 0.4 or more after 45 days; below 0.4 it never goes stale.
#[must_use]
pub fn is_stale(decay: f64, updated_us: u64, now_us: u64) -> bool {
    let age = now_us.saturating_sub(updated_us);
    let after_days = if decay >= 0.9 {
        1
    } else if decay >= 0.7 {
        7
    } else if decay >= 0.4 {
        45
    } else {
        return false;
    };
    age >= after_days * DAY_US
}

/// Jaccard similarity of word sets, 0..=1.
#[must_use]
#[allow(clippy::cast_precision_loss)] // word counts of one proposition
pub fn similarity(a: &str, b: &str) -> f64 {
    let (a, b) = (words(a), words(b));
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    a.intersection(&b).count() as f64 / a.union(&b).count() as f64
}

/// Recency-adjusted relevance: BM25 (`SQLite` ranks lower-is-better, so the
/// relevance is its negation) scaled by `exp(-decay · k · age_days)`.
#[must_use]
#[allow(clippy::cast_precision_loss)] // 2^52 microseconds is 142 years
pub fn adjusted_relevance(bm25: f64, decay: f64, age_us: u64) -> f64 {
    let age_days = age_us as f64 / 86_400_000_000.0;
    (-bm25).max(0.0) * (-decay * RECENCY_K * age_days).exp()
}

/// Pick up to `n` candidates by maximal marginal relevance.
#[must_use]
pub fn mmr(candidates: &[(Proposition, f64)], n: usize) -> Vec<Proposition> {
    let mut chosen: Vec<Proposition> = Vec::new();
    let mut pool: Vec<&(Proposition, f64)> = candidates.iter().collect();
    let top = pool
        .iter()
        .map(|(_, r)| *r)
        .fold(0.0_f64, f64::max)
        .max(f64::EPSILON);
    while chosen.len() < n && !pool.is_empty() {
        let (index, _) = pool
            .iter()
            .enumerate()
            .map(|(i, (p, relevance))| {
                let redundancy = chosen
                    .iter()
                    .map(|c| similarity(&c.text, &p.text))
                    .fold(0.0, f64::max);
                (
                    i,
                    MMR_LAMBDA * (relevance / top) - (1.0 - MMR_LAMBDA) * redundancy,
                )
            })
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .expect("pool is not empty");
        chosen.push(pool.remove(index).0.clone());
    }
    chosen
}

/// Words that fit any claim about anyone, so they say nothing about this one.
pub(crate) const GENERIC: &[&str] = &[
    "user",
    "users",
    "project",
    "projects",
    "work",
    "working",
    "works",
    "task",
    "tasks",
    "computer",
    "screen",
    "app",
    "apps",
    "application",
    "window",
    "windows",
    "document",
    "documents",
    "file",
    "files",
    "something",
    "things",
    "thing",
    "information",
    "content",
    "various",
    "different",
    "multiple",
    "several",
    "some",
    "their",
    "they",
    "this",
    "that",
    "with",
    "about",
    "using",
    "used",
    "uses",
    "related",
    "currently",
    "actively",
    "trying",
    "likely",
    "seems",
    "appears",
    "interested",
    "interest",
    "involved",
    "engaged",
    "activity",
    "activities",
    "time",
    "while",
];

/// Keep only propositions specific enough to help: each must share at least
/// two meaningful words with the observation (names, products, topics),
/// beyond the user's name and generic words like "project" or "work".
#[must_use]
pub fn specific(drafts: Vec<Draft>, observation: &str, user_name: &str) -> Vec<Draft> {
    let seen = words(observation);
    let name = user_name.to_lowercase();
    // One claim per batch: a draft that mostly repeats an earlier one adds nothing.
    let mut distinct: Vec<Draft> = Vec::new();
    for draft in drafts {
        if !distinct
            .iter()
            .any(|kept| similarity(&kept.text, &draft.text) >= 0.45)
        {
            distinct.push(draft);
        }
    }
    distinct
        .into_iter()
        .filter(|draft| {
            words(&draft.text)
                .into_iter()
                .filter(|w| {
                    w.len() >= 4 && *w != name && !GENERIC.contains(&w.as_str()) && seen.contains(w)
                })
                .count()
                >= 2
        })
        .collect()
}

/// Ceilings for a claim seen once. A habit, preference or skill is a
/// pattern, and one session cannot show a pattern; only a revision that
/// confirms the claim can raise it further. The small on-device model is
/// otherwise confident about everything.
fn first_sighting_ceiling(kind: &str) -> i64 {
    match kind {
        "habit" | "preference" | "skill" => 6,
        _ => 8,
    }
}

/// Refer to the user by name, never by a gendered pronoun the model chose.
#[must_use]
pub fn ungender(text: &str, user_name: &str) -> String {
    let name = if user_name.trim().is_empty() {
        "They"
    } else {
        user_name.trim()
    };
    let mut out = Vec::new();
    for word in text.split(' ') {
        let trimmed = word.trim_end_matches(|c: char| !c.is_alphanumeric());
        let tail = &word[trimmed.len()..];
        let replacement = match trimmed {
            "she" | "he" | "She" | "He" => Some(name.to_owned()),
            "her" | "his" => Some("their".to_owned()),
            "Her" | "His" => Some("Their".to_owned()),
            "him" => Some("them".to_owned()),
            "herself" | "himself" => Some("themself".to_owned()),
            _ => None,
        };
        match replacement {
            Some(r) => out.push(format!("{r}{tail}")),
            None => out.push(word.to_owned()),
        }
    }
    out.join(" ")
}

/// Calibrate and clean a draft before it is stored.
#[must_use]
pub fn prepare(mut draft: Draft, user_name: &str, first_sighting: bool) -> Draft {
    draft.text = ungender(&draft.text, user_name);
    draft.reasoning = ungender(&draft.reasoning, user_name);
    if first_sighting {
        draft.confidence = draft.confidence.min(first_sighting_ceiling(&draft.kind));
    }
    draft
}

/// Retrieve stored, active propositions that might restate `text`.
///
/// # Errors
/// Store failures.
pub fn retrieve(
    store: &SqlCipherBrainStore,
    text: &str,
    now_us: u64,
) -> Result<Vec<Proposition>, StoreError> {
    let scored: Vec<(Proposition, f64)> = store
        .search_propositions(text, 24)?
        .into_iter()
        .filter(|(p, _)| p.status == PropositionStatus::Active)
        .map(|(p, bm25)| {
            let relevance = adjusted_relevance(bm25, p.decay, now_us.saturating_sub(p.updated_us));
            (p, relevance)
        })
        .collect();
    Ok(mmr(&scored, CANDIDATES))
}

/// Ask the mind for propositions about an observation.
///
/// # Errors
/// Model failures.
pub fn propose(
    mind: &MindClient,
    user_name: &str,
    observation: &str,
    known: &[String],
) -> Result<Vec<Draft>, MindCallError> {
    let out: ProposeOut = mind.call(
        "propose",
        &serde_json::json!({ "user_name": user_name, "observation": observation, "known": known }),
        CALL_TIMEOUT,
    )?;
    Ok(out.propositions)
}

/// Fold drafts into the stored model. A confirmed proposition is never
/// revised or retired: when a draft restates one, the draft's evidence is
/// attached to it, nothing else changes, and the draft counts as skipped.
///
/// # Errors
/// Store failures. Model failures on one draft skip that draft.
pub fn integrate(
    store: &SqlCipherBrainStore,
    mind: &MindClient,
    user_name: &str,
    drafts: &[Draft],
    evidence: &[i64],
    now_us: u64,
) -> Result<Integration, GumError> {
    let rejected = store.propositions_with_status(PropositionStatus::Rejected, 500)?;
    let forgotten: Vec<BTreeSet<String>> = rejected
        .iter()
        .map(|r| super::sending::keywords(&r.text))
        .collect();
    // What the person forgot never comes back, in its words or others.
    let says_forgotten = |text: &str| {
        let words = super::sending::keywords(text);
        rejected.iter().any(|r| similarity(&r.text, text) >= 0.6)
            || forgotten
                .iter()
                .any(|f| super::sending::restates(&words, f))
    };
    let confirmed = store.confirmed_proposition_ids()?;
    let mut outcome = Integration::default();
    for draft in drafts {
        let text = draft.text.trim();
        if text.split_whitespace().count() < 4 || says_forgotten(text) {
            outcome.skipped += 1;
            continue;
        }
        let candidates = retrieve(store, text, now_us)?;
        let related: Vec<Proposition> = if candidates.is_empty() {
            Vec::new()
        } else {
            let input = serde_json::json!({
                "proposition": text,
                "candidates": candidates.iter().map(|c| serde_json::json!({"id": c.id, "text": c.text})).collect::<Vec<_>>(),
            });
            match mind.call::<_, RelateOut>("relate", &input, CALL_TIMEOUT) {
                Ok(out) => {
                    // Merge only the same claim. A small model calls too much
                    // "similar", and merging different claims blurs both.
                    let ids: Vec<i64> = out
                        .relations
                        .into_iter()
                        .filter(|r| r.relation == "identical")
                        .map(|r| r.id)
                        .collect();
                    candidates
                        .into_iter()
                        .filter(|c| ids.contains(&c.id) && similarity(&c.text, text) >= 0.3)
                        .collect()
                }
                Err(MindCallError::Unavailable(reason)) => {
                    return Err(MindCallError::Unavailable(reason).into())
                }
                Err(_) => {
                    // Without a judgement, fall back to near-identical wording.
                    candidates
                        .into_iter()
                        .filter(|c| similarity(&c.text, text) >= 0.7)
                        .collect()
                }
            }
        };
        if related.is_empty() {
            let draft = prepare(draft.clone(), user_name, true);
            store.insert_proposition(&draft.to_new(&mind.engine_label()), evidence, now_us)?;
            outcome.added += 1;
            continue;
        }
        if let Some(kept) = related.iter().find(|p| confirmed.contains(&p.id)) {
            // Seen again: more evidence, the same words. The other related
            // claims are left as they are too.
            store.add_proposition_evidence(kept.id, evidence, now_us)?;
            outcome.skipped += 1;
            continue;
        }
        let revised = match mind.call::<_, Draft>(
            "revise",
            &serde_json::json!({
                "user_name": user_name,
                "new": draft,
                "old": related.iter().map(Draft::from_stored).collect::<Vec<_>>(),
            }),
            CALL_TIMEOUT,
        ) {
            Ok(revised) => revised,
            Err(MindCallError::Unavailable(reason)) => {
                return Err(MindCallError::Unavailable(reason).into())
            }
            Err(_) => {
                outcome.skipped += 1;
                continue;
            }
        };
        let revised = prepare(revised, user_name, false);
        if says_forgotten(revised.text.trim()) {
            // A merge that would bring a forgotten line back leaves the
            // stored claims as they are.
            outcome.skipped += 1;
            continue;
        }
        let mut all_evidence: Vec<i64> = evidence.to_vec();
        for old in &related[1..] {
            all_evidence.extend(old.evidence.iter().copied());
            store.set_proposition_status(old.id, PropositionStatus::Retired, now_us)?;
        }
        store.revise_proposition(
            related[0].id,
            &revised.to_new(&mind.engine_label()),
            &all_evidence,
            now_us,
        )?;
        outcome.revised += 1;
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_claims_age_by_their_decay() {
        let day = 86_400_000_000u64;
        let now = 400 * day;
        assert!(!is_stale(0.9, now - day + 1, now));
        assert!(is_stale(0.9, now - day, now));
        assert!(!is_stale(0.7, now - 6 * day, now));
        assert!(is_stale(0.7, now - 7 * day, now));
        assert!(!is_stale(0.4, now - 44 * day, now));
        assert!(is_stale(0.5, now - 45 * day, now));
        assert!(!is_stale(0.3, 0, now), "slow claims never go stale");
        assert!(
            is_stale(9.0 / 10.0, now - 2 * day, now),
            "a stored score of 9 is 0.9"
        );
        assert!(
            !is_stale(0.9, now + day, now),
            "a clock that went back is not age"
        );
    }

    fn prop(id: i64, text: &str) -> Proposition {
        Proposition {
            id,
            text: text.into(),
            reasoning: String::new(),
            kind: PropositionKind::Project,
            confidence: 0.5,
            decay: 0.5,
            status: PropositionStatus::Active,
            created_us: 0,
            updated_us: 0,
            revised_from: None,
            model: "t".into(),
            evidence: vec![],
        }
    }

    #[test]
    fn staleness_discounts_relevance_by_decay() {
        let day = 86_400_000_000;
        let fresh = adjusted_relevance(-3.0, 0.9, 0);
        let lasting = adjusted_relevance(-3.0, 0.1, 2 * day);
        let fleeting = adjusted_relevance(-3.0, 0.9, 2 * day);
        assert!((fresh - 3.0).abs() < 1e-9);
        assert!(
            lasting > fleeting,
            "a fast-decaying proposition loses relevance sooner"
        );
    }

    #[test]
    fn mmr_prefers_diverse_candidates() {
        let candidates = vec![
            (prop(1, "Sam is pricing the team plan"), 3.0),
            (prop(2, "Sam is pricing the team plan for beta"), 2.9),
            (prop(3, "Sam drafts launch notes in Notes"), 2.0),
        ];
        let picked: Vec<i64> = mmr(&candidates, 2).into_iter().map(|p| p.id).collect();
        assert_eq!(
            picked,
            vec![1, 3],
            "the near-duplicate gives way to a different claim"
        );
    }

    #[test]
    fn a_first_sighting_cannot_be_a_confident_habit_and_pronouns_become_the_name() {
        let draft = Draft {
            text: "Sam watches YouTube often, so she takes breaks.".into(),
            reasoning: "her typing pauses".into(),
            kind: "habit".into(),
            confidence: 9,
            decay: 3,
        };
        let prepared = prepare(draft, "Sam", true);
        assert_eq!(prepared.confidence, 6);
        assert_eq!(
            prepared.text,
            "Sam watches YouTube often, so Sam takes breaks."
        );
        assert_eq!(prepared.reasoning, "their typing pauses");
        let project = Draft {
            text: "Sam is pricing Team".into(),
            reasoning: String::new(),
            kind: "project".into(),
            confidence: 10,
            decay: 4,
        };
        assert_eq!(prepare(project.clone(), "Sam", true).confidence, 8);
        assert_eq!(
            prepare(project, "Sam", false).confidence,
            10,
            "confirmed claims may rise"
        );
    }

    #[test]
    fn a_batch_keeps_one_version_of_each_claim() {
        let draft = |text: &str| Draft {
            text: text.into(),
            reasoning: String::new(),
            kind: "state".into(),
            confidence: 5,
            decay: 5,
        };
        let observation =
            "YouTube search: sourdough starter for beginners. Notes: Launch plan for Team pricing.";
        let kept = specific(
            vec![
                draft("Sam is looking for sourdough starter videos on YouTube."),
                draft("Sam is searching YouTube for sourdough starter videos."),
                draft("Sam is drafting the Team pricing launch plan in Notes."),
            ],
            observation,
            "Sam",
        );
        assert_eq!(
            kept.len(),
            2,
            "{:?}",
            kept.iter().map(|d| &d.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn generic_propositions_are_dropped() {
        let draft = |text: &str| Draft {
            text: text.into(),
            reasoning: String::new(),
            kind: "project".into(),
            confidence: 7,
            decay: 4,
        };
        let observation = "Chrome — Pricing | Stripe: per-seat pricing. Notes — Launch plan: Team: $18/seat annual. Slack — #pricing Ravi";
        let kept = specific(
            vec![
                draft("Sam is working on a project."),
                draft("Sam is setting per-seat pricing for the Team plan with Ravi."),
                draft("Sam is interested in various things."),
            ],
            observation,
            "Sam",
        );
        assert_eq!(kept.len(), 1);
        assert!(kept[0].text.contains("per-seat"));
    }

    #[test]
    fn similarity_is_word_overlap() {
        assert!(similarity("Sam is pricing the team plan", "sam pricing team plan") > 0.6);
        assert!(similarity("Sam writes Rust", "Sam cooks pasta") < 0.3);
    }

    #[test]
    fn drafts_map_scores_to_unit_range() {
        let d = Draft {
            text: "Sam ships".into(),
            reasoning: "r".into(),
            kind: "goal".into(),
            confidence: 14,
            decay: 0,
        };
        let n = d.to_new(MODEL);
        assert!((n.confidence - 1.0).abs() < 1e-9 && (n.decay - 0.1).abs() < 1e-9);
        assert_eq!(n.kind, PropositionKind::Goal);
    }

    /// A model that judges both stored claims identical to the draft and
    /// then, if asked, writes one merged revision of them.
    fn merging_mind(dir: &std::path::Path, a: i64, b: i64) -> MindClient {
        merging_mind_writing(dir, a, b, "Sam is pricing the Team plan")
    }

    /// [`merging_mind`], with the merged revision saying `merged`.
    fn merging_mind_writing(dir: &std::path::Path, a: i64, b: i64, merged: &str) -> MindClient {
        use std::os::unix::fs::PermissionsExt;
        let relate = serde_json::json!({"id": 1, "ok": true, "output": {"relations": [
            {"id": a, "relation": "identical"}, {"id": b, "relation": "identical"},
        ]}});
        let revise = serde_json::json!({"id": 2, "ok": true, "output": {
            "text": merged, "reasoning": "merged", "kind": "project", "confidence": 7, "decay": 3,
        }});
        let path = dir.join("fake-mind");
        std::fs::write(
            &path,
            format!(
                "#!/bin/sh\necho '{{\"ready\":true,\"available\":true}}'\nread line; echo '{relate}'\nread line; echo '{revise}'\ncat >/dev/null\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        MindClient::new(Some(path))
    }

    struct Merge {
        dir: tempfile::TempDir,
        store: SqlCipherBrainStore,
        a: i64,
        b: i64,
        old: i64,
        new: i64,
    }

    /// Two stored claims (`a`, `b`) resting on `old`, and a session (`new`).
    fn two_claims() -> Merge {
        use mci_brain::{BrainStore, Event, EventId, EventSource};
        let dir = tempfile::tempdir().unwrap();
        let store = SqlCipherBrainStore::new(
            &dir.path().join("b.sqlite"),
            &mci_core::crypto::DbKey::from_bytes([9; 32]),
        )
        .unwrap();
        let put = |ts_us| {
            let event = Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: Some("com.apple.Notes".into()),
                window_title: Some("Launch plan".into()),
                url: None,
                text: "Team: $18 a seat".into(),
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: None,
                tab_id: None,
                embedding: None,
            };
            i64::try_from(
                store
                    .put_event_with_source(&event, EventSource::ScreenOcr)
                    .unwrap()
                    .0,
            )
            .unwrap()
        };
        let (old, new) = (put(1), put(2));
        let claim = |text: &str| NewProposition {
            text: text.into(),
            reasoning: "seen".into(),
            kind: PropositionKind::Project,
            confidence: 0.6,
            decay: 0.3,
            model: "t".into(),
        };
        let a = store
            .insert_proposition(
                &claim("Sam is pricing the Team plan for the beta launch"),
                &[old],
                10,
            )
            .unwrap();
        let b = store
            .insert_proposition(
                &claim("Sam is pricing the Team plan for the launch in Notes"),
                &[old],
                10,
            )
            .unwrap();
        Merge {
            dir,
            store,
            a,
            b,
            old,
            new,
        }
    }

    fn restatement() -> Draft {
        Draft {
            text: "Sam is pricing the Team plan for the beta launch in Notes".into(),
            reasoning: "seen again".into(),
            kind: "project".into(),
            confidence: 7,
            decay: 3,
        }
    }

    #[test]
    fn a_confirmed_claim_is_never_rewritten_or_retired_by_a_merge() {
        let m = two_claims();
        assert!(m.store.confirm_proposition(m.a, 20).unwrap());
        let mind = merging_mind(m.dir.path(), m.a, m.b);

        let outcome = integrate(&m.store, &mind, "Sam", &[restatement()], &[m.new], 30).unwrap();

        assert_eq!(
            outcome,
            Integration {
                added: 0,
                revised: 0,
                skipped: 1
            }
        );
        let active = m
            .store
            .propositions_with_status(PropositionStatus::Active, 10)
            .unwrap();
        assert_eq!(active.len(), 2, "nothing retired, nothing new");
        let a = active
            .iter()
            .find(|p| p.id == m.a)
            .expect("the confirmed claim stays in use");
        assert_eq!(
            a.text, "Sam is pricing the Team plan for the beta launch",
            "in the words that were confirmed"
        );
        assert_eq!(
            a.evidence,
            vec![m.old, m.new],
            "it gains the session as evidence"
        );
        assert_eq!(a.updated_us, 30, "and is marked seen");
        let b = active
            .iter()
            .find(|p| p.id == m.b)
            .expect("the other related claim is untouched");
        assert_eq!((b.evidence.clone(), b.updated_us), (vec![m.old], 10));
        assert!(m
            .store
            .propositions_with_status(PropositionStatus::Retired, 10)
            .unwrap()
            .is_empty());
        assert!(m.store.confirmed_proposition_ids().unwrap().contains(&m.a));
    }

    #[test]
    fn unconfirmed_restatements_are_still_merged() {
        let m = two_claims();
        let mind = merging_mind(m.dir.path(), m.a, m.b);

        let outcome = integrate(&m.store, &mind, "Sam", &[restatement()], &[m.new], 30).unwrap();

        assert_eq!(
            outcome,
            Integration {
                added: 0,
                revised: 1,
                skipped: 0
            }
        );
        let active = m
            .store
            .propositions_with_status(PropositionStatus::Active, 10)
            .unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].text, "Sam is pricing the Team plan");
        assert_eq!(active[0].evidence, vec![m.old, m.new]);
        assert_eq!(
            m.store
                .propositions_with_status(PropositionStatus::Retired, 10)
                .unwrap()
                .len(),
            2
        );
    }

    /// A line the person forgot, made from a mailbox's name as in the audit
    /// (product-4).
    const FORGOTTEN: &str = "Sam is planning a trip through the Northwind Travel account";

    fn forget(m: &Merge, text: &str) -> i64 {
        let id = m
            .store
            .insert_proposition(
                &NewProposition {
                    text: text.into(),
                    reasoning: "seen".into(),
                    kind: PropositionKind::Goal,
                    confidence: 0.8,
                    decay: 0.3,
                    model: "t".into(),
                },
                &[m.old],
                5,
            )
            .unwrap();
        m.store
            .set_proposition_status(id, PropositionStatus::Rejected, 6)
            .unwrap();
        id
    }

    #[test]
    fn a_forgotten_line_is_not_stored_again_in_other_words() {
        let m = two_claims();
        forget(&m, FORGOTTEN);
        let reworded = Draft {
            text: "Sam is booking trips with the Northwind Travel account".into(),
            reasoning: "inbox".into(),
            kind: "goal".into(),
            confidence: 8,
            decay: 3,
        };
        assert!(
            similarity(FORGOTTEN, &reworded.text) < 0.6,
            "the old word-overlap check alone let this through"
        );

        let outcome = integrate(
            &m.store,
            &MindClient::new(None),
            "Sam",
            &[reworded],
            &[m.new],
            30,
        )
        .unwrap();

        assert_eq!(
            outcome,
            Integration {
                added: 0,
                revised: 0,
                skipped: 1
            }
        );
        let active: Vec<i64> = m
            .store
            .propositions_with_status(PropositionStatus::Active, 10)
            .unwrap()
            .into_iter()
            .map(|p| p.id)
            .collect();
        assert_eq!(active.len(), 2, "only the two pricing claims: {active:?}");
    }

    #[test]
    fn a_merge_never_writes_a_forgotten_line_back() {
        let m = two_claims();
        forget(&m, FORGOTTEN);
        let mind = merging_mind_writing(
            m.dir.path(),
            m.a,
            m.b,
            "Sam is planning a trip with Northwind Travel",
        );

        let outcome = integrate(&m.store, &mind, "Sam", &[restatement()], &[m.new], 30).unwrap();

        assert_eq!(
            outcome,
            Integration {
                added: 0,
                revised: 0,
                skipped: 1
            }
        );
        let mut active: Vec<i64> = m
            .store
            .propositions_with_status(PropositionStatus::Active, 10)
            .unwrap()
            .into_iter()
            .map(|p| p.id)
            .collect();
        active.sort_unstable();
        assert_eq!(
            active,
            vec![m.a, m.b],
            "the stored claims stay as they were"
        );
        assert!(m
            .store
            .propositions_with_status(PropositionStatus::Retired, 10)
            .unwrap()
            .is_empty());
    }
}
