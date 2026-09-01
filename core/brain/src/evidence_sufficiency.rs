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
}

impl EvidenceFeatures {
    const fn values(self) -> [f32; 5] {
        [
            self.raw_semantic_cosine,
            self.semantic_margin,
            self.query_coverage,
            self.document_coverage,
            self.lexical_semantic_agreement,
        ]
    }

    fn valid(self) -> bool {
        let values = self.values();
        values.iter().all(|value| value.is_finite())
            && self.semantic_margin >= 0.0
            && (0.0..=1.0).contains(&self.query_coverage)
            && (0.0..=1.0).contains(&self.document_coverage)
            && matches!(self.lexical_semantic_agreement, 0.0 | 1.0)
    }
}

/// Extract the critic's fixed feature schema from a candidate set.
///
/// The semantic top-1 is selected directly from raw cosine with input order as
/// the deterministic tie-break. Lexical top-1 is selected by query coverage,
/// then document coverage, then input order. No score is normalized against
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

    let mut semantic_order: Vec<usize> = (0..candidates.len()).collect();
    semantic_order.sort_by(|left, right| {
        candidates[*right]
            .raw_semantic_cosine
            .total_cmp(&candidates[*left].raw_semantic_cosine)
            .then_with(|| left.cmp(right))
    });
    let top_index = semantic_order[0];
    let top = candidates[top_index];
    let semantic_margin = semantic_order.get(1).map_or(0.0, |second| {
        (top.raw_semantic_cosine - candidates[*second].raw_semantic_cosine).max(0.0)
    });

    let mut lexical_order: Vec<(usize, f32, f32)> = candidates
        .iter()
        .enumerate()
        .map(|(index, candidate)| {
            (
                index,
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
            .then_with(|| left.0.cmp(&right.0))
    });

    Some(EvidenceFeatures {
        raw_semantic_cosine: top.raw_semantic_cosine,
        semantic_margin,
        query_coverage: lexical_coverage(query, top.text),
        document_coverage: lexical_coverage(top.text, query),
        lexical_semantic_agreement: f32::from(lexical_order[0].0 == top_index),
    })
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
    pub means: [f32; 5],
    /// Standard deviation of each feature on the fit split.
    pub scales: [f32; 5],
    /// Logistic-regression weights fit only on the fit split.
    pub weights: [f32; 5],
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
    feature_schema_version: 1,
    calibration_dataset_id: "hippocampus-evidence-sufficiency-calibration-v1",
    calibration_sha256: "4767463f1ca003c8f018aa6b375e4241db71ff982187b898bd2774f8adba2fbf",
    target_positive_coverage: 0.90,
    means: [0.787_043_6, 0.170_410_74, 0.619_444_43, 0.400_892_85, 1.0],
    scales: [
        0.038_208_46,
        0.057_695_847,
        0.103_823_51,
        0.086_070_59,
        0.000_001,
    ],
    weights: [0.868_549_6, 0.571_916_9, 0.266_064_58, -2.951_581_5, 0.0],
    intercept: -0.085_427_48,
    threshold: 0.000_002_363_062_6,
    validation_qualified: false,
};
