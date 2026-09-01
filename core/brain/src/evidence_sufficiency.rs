//! Independently calibrated evidence-sufficiency boundary.
//!
//! Retrieval rank answers "which candidate is closest?"; it does not answer
//! "does this candidate contain enough evidence to support an answer?" This
//! module keeps those decisions separate. The critic receives only a fixed
//! numeric feature vector, so it cannot branch on query wording, entities, or
//! answer categories. Its parameters are frozen from the disjoint fixture
//! named by [`EVIDENCE_SUFFICIENCY_POLICY`].

use std::collections::HashSet;

/// One candidate's text and raw semantic score before query-local ranking.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EvidenceCandidate<'a> {
    /// Stable candidate identity used as the final tie-break.
    pub stable_id: u64,
    /// Candidate evidence text.
    pub text: &'a str,
    /// Raw query-document cosine from the embedding model.
    pub raw_semantic_cosine: f32,
}

/// Versioned, cross-query-comparable features consumed by the local critic.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EvidenceFeatures {
    /// Raw query-document cosine from the embedding model.
    pub raw_semantic_cosine: f32,
    /// Raw top-1 minus top-2 cosine for the candidate set.
    pub semantic_margin: f32,
    /// Fraction of information-bearing query terms present in the document.
    pub query_coverage: f32,
    /// Fraction of information-bearing document terms present in the query.
    pub document_coverage: f32,
    /// `1.0` when lexical and semantic retrieval agree on top-1, else `0.0`.
    pub lexical_semantic_agreement: f32,
    /// Longest novel evidence term relative to the longest query term.
    /// This domain-neutral specificity signal distinguishes a concrete
    /// answer-bearing span from a placeholder that merely repeats the query.
    pub novel_specificity: f32,
}

impl EvidenceFeatures {
    const fn values(self) -> [f32; 6] {
        [
            self.raw_semantic_cosine,
            self.semantic_margin,
            self.query_coverage,
            self.document_coverage,
            self.lexical_semantic_agreement,
            self.novel_specificity,
        ]
    }

    fn valid(self) -> bool {
        let values = self.values();
        values.iter().all(|value| value.is_finite())
            && self.semantic_margin >= 0.0
            && (0.0..=1.0).contains(&self.query_coverage)
            && (0.0..=1.0).contains(&self.document_coverage)
            && matches!(self.lexical_semantic_agreement, 0.0 | 1.0)
            && (0.0..=1.0).contains(&self.novel_specificity)
    }
}

/// Extract the critic's fixed feature schema from a candidate set.
///
/// The semantic top-1 is selected directly from raw cosine with stable
/// candidate identity as the deterministic tie-break. Lexical top-1 is
/// selected by query coverage, then document coverage, then stable identity.
/// No score is normalized against
/// the current query's min/max, and no query words or answer categories are
/// interpreted.
#[must_use]
pub fn evidence_features_for_candidates(
    query: &str,
    candidates: &[EvidenceCandidate<'_>],
) -> Option<EvidenceFeatures> {
    if candidates.is_empty()
        || candidates
            .iter()
            .any(|candidate| !candidate.raw_semantic_cosine.is_finite())
    {
        return None;
    }

    let mut semantic_order: Vec<&EvidenceCandidate<'_>> = candidates.iter().collect();
    semantic_order.sort_by(|left, right| {
        right
            .raw_semantic_cosine
            .total_cmp(&left.raw_semantic_cosine)
            .then_with(|| left.stable_id.cmp(&right.stable_id))
    });
    let top = *semantic_order[0];
    let semantic_margin = semantic_order.get(1).map_or(0.0, |second| {
        (top.raw_semantic_cosine - second.raw_semantic_cosine).max(0.0)
    });

    let mut lexical_order: Vec<(&EvidenceCandidate<'_>, f32, f32)> = candidates
        .iter()
        .map(|candidate| {
            (
                candidate,
                lexical_coverage(query, candidate.text),
                lexical_coverage(candidate.text, query),
            )
        })
        .collect();
    lexical_order.sort_by(|left, right| {
        right
            .1
            .total_cmp(&left.1)
            .then_with(|| right.2.total_cmp(&left.2))
            .then_with(|| left.0.stable_id.cmp(&right.0.stable_id))
    });

    Some(EvidenceFeatures {
        raw_semantic_cosine: top.raw_semantic_cosine,
        semantic_margin,
        query_coverage: lexical_order[0].1,
        document_coverage: lexical_order[0].2,
        lexical_semantic_agreement: f32::from(lexical_order[0].0.stable_id == top.stable_id),
        novel_specificity: novel_specificity(query, lexical_order[0].0.text),
    })
}

fn novel_specificity(query: &str, evidence: &str) -> f32 {
    let query_terms = content_terms(query);
    let longest_query = query_terms
        .iter()
        .map(|term| term.chars().count())
        .max()
        .unwrap_or(1);
    let query_set: HashSet<&str> = query_terms.iter().map(String::as_str).collect();
    let longest_novel = content_terms(evidence)
        .iter()
        .filter(|term| !query_set.contains(term.as_str()))
        .map(|term| term.chars().count())
        .max()
        .unwrap_or(0);
    #[allow(clippy::cast_precision_loss)]
    let ratio = longest_novel as f32 / longest_query as f32;
    ratio.clamp(0.0, 1.0)
}

fn lexical_coverage(query: &str, evidence: &str) -> f32 {
    let query_terms = content_terms(query);
    if query_terms.is_empty() {
        return 0.0;
    }
    let evidence_terms: HashSet<String> = content_terms(evidence).into_iter().collect();
    let covered = query_terms
        .iter()
        .filter(|term| evidence_terms.contains(*term))
        .count();
    #[allow(clippy::cast_precision_loss)]
    let ratio = covered as f32 / query_terms.len() as f32;
    ratio
}

fn content_terms(text: &str) -> Vec<String> {
    const STOP: &[&str] = &[
        "a", "an", "and", "are", "as", "at", "be", "did", "do", "for", "from", "how", "i", "in",
        "is", "it", "of", "on", "or", "the", "to", "was", "we", "what", "where", "which", "who",
        "why", "with",
    ];
    let mut out = Vec::new();
    for raw in text.split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-') {
        let term = raw.trim().to_ascii_lowercase();
        if term.len() < 2 || STOP.contains(&term.as_str()) || out.contains(&term) {
            continue;
        }
        out.push(term);
    }
    out
}

/// Frozen linear evidence critic and its calibration provenance.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EvidenceSufficiencyPolicy {
    /// Feature-schema version used by both calibration and production.
    pub feature_schema_version: u32,
    /// Independent committed fixture identifier.
    pub calibration_dataset_id: &'static str,
    /// SHA-256 of the exact calibration fixture bytes.
    pub calibration_sha256: &'static str,
    /// Positive-coverage target used for conformal threshold selection.
    pub target_positive_coverage: f32,
    /// Mean of each feature on the fit split.
    pub means: [f32; 6],
    /// Standard deviation of each feature on the fit split.
    pub scales: [f32; 6],
    /// Logistic-regression weights fit only on the fit split.
    pub weights: [f32; 6],
    /// Logistic-regression intercept fit only on the fit split.
    pub intercept: f32,
    /// Frozen probability threshold selected only from positive calibration
    /// examples. Validation and Task 3 outcomes never alter it.
    pub threshold: f32,
    /// Whether the untouched validation split met its predeclared positive
    /// coverage and false-positive requirements. An unqualified critic may be
    /// inspected, but it cannot promote retrieval output to `Matched`.
    pub validation_qualified: bool,
}

impl EvidenceSufficiencyPolicy {
    /// Return the critic probability, or `None` for malformed features.
    #[must_use]
    pub fn score(self, features: EvidenceFeatures) -> Option<f32> {
        if !features.valid()
            || self
                .scales
                .iter()
                .any(|scale| !scale.is_finite() || *scale <= 0.0)
        {
            return None;
        }
        let mut logit = self.intercept;
        for (index, value) in features.values().into_iter().enumerate() {
            logit += self.weights[index] * ((value - self.means[index]) / self.scales[index]);
        }
        Some(1.0 / (1.0 + (-logit).exp()))
    }

    /// Decide whether the feature vector crosses the frozen boundary.
    #[must_use]
    pub fn is_sufficient(self, features: EvidenceFeatures) -> bool {
        self.validation_qualified
            && self
                .score(features)
                .is_some_and(|score| score >= self.threshold)
    }
}

/// Production policy. Values are replaced only by the independent calibration
/// procedure documented in `eval/relevance-calibration/README.md`.
pub const EVIDENCE_SUFFICIENCY_POLICY: EvidenceSufficiencyPolicy = EvidenceSufficiencyPolicy {
    feature_schema_version: 2,
    calibration_dataset_id: "hippocampus-evidence-sufficiency-calibration-v1",
    calibration_sha256: "e18aba01ab344da3a1ee4ab58003e28bb86c041e99107b223073bfa7830ead5d",
    target_positive_coverage: 0.90,
    means: [
        0.787_920_8,
        0.176_467_33,
        0.767_361_1,
        0.619_394_84,
        1.0,
        0.767_708_36,
    ],
    scales: [
        0.045_413_61,
        0.061_222_31,
        0.180_115_64,
        0.238_974_44,
        0.000_001,
        0.349_290_88,
    ],
    weights: [
        -0.208_845_88,
        -0.349_374_83,
        -0.431_204_68,
        0.479_562_28,
        0.0,
        0.999_120_7,
    ],
    intercept: -0.048_190_568,
    threshold: 0.313_164_4,
    validation_qualified: false,
};
