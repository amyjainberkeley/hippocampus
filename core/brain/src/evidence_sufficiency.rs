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

/// Conservative relation check for questions with an explicit answer shape.
///
/// This is a negative guard, not a general entailment model. A supported signal
/// requires a value of the requested type to occur locally with the query's
/// relation or subject. It can veto unsupported evidence but never promotes a
/// candidate to a match by itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExplicitEvidenceSignal {
    /// The query has no answer shape this guard can assess reliably.
    NotApplicable,
    /// At least one evidence candidate relates a requested value to the query.
    RelationSupported,
    /// No evidence candidate relates a requested value to the query.
    RelationUnsupported,
}

/// Frozen qualification record for the deterministic explicit-value veto.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExplicitEvidenceVetoQualification {
    /// Identifier of the committed synthetic fixture.
    pub fixture_dataset_id: &'static str,
    /// SHA-256 of the committed fixture bytes.
    pub fixture_sha256: &'static str,
    /// Number of simple calibration cases.
    pub calibration_cases: usize,
    /// Number of disjoint simple validation cases.
    pub validation_cases: usize,
    /// Number of held-out adversarial insufficient-evidence cases.
    pub adversarial_cases: usize,
    /// Adversarial cases where an unrelated value prevented the veto.
    pub adversarial_false_pass_throughs: usize,
    /// Whether held-out evidence establishes value-to-relation grounding.
    pub relation_grounded: bool,
}

/// Current qualification of the explicit-value veto.
pub const EXPLICIT_EVIDENCE_VETO_QUALIFICATION: ExplicitEvidenceVetoQualification =
    ExplicitEvidenceVetoQualification {
        fixture_dataset_id: "hippocampus-explicit-evidence-relation-v2",
        fixture_sha256: "9eb9b90d703a248a8526aebd723672a429f7eabbb4b1f278727c5181f8c2ae3d",
        calibration_cases: 6,
        validation_cases: 8,
        adversarial_cases: 8,
        adversarial_false_pass_throughs: 0,
        relation_grounded: true,
    };

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

/// Check whether retrieved evidence relates an explicitly requested answer
/// value to the query. The check is deliberately conservative and recognizes
/// only person, count, duration, and date requests.
#[must_use]
pub fn explicit_evidence_signal(
    query: &str,
    candidates: &[EvidenceCandidate<'_>],
) -> ExplicitEvidenceSignal {
    let query_tokens = normalized_tokens(query);
    let Some(answer_type) = explicit_answer_type(&query_tokens) else {
        return ExplicitEvidenceSignal::NotApplicable;
    };
    let query_terms: HashSet<String> = query_tokens.iter().cloned().collect();
    let query_anchors = relation_anchor_terms(&query_tokens);
    if candidates.iter().any(|candidate| {
        contains_related_value(
            answer_type,
            &query_tokens,
            evidence_body(candidate.text),
            &query_terms,
            &query_anchors,
        )
    }) {
        ExplicitEvidenceSignal::RelationSupported
    } else {
        ExplicitEvidenceSignal::RelationUnsupported
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExplicitAnswerType {
    Person,
    Count,
    Duration,
    Date,
}

fn explicit_answer_type(query_tokens: &[String]) -> Option<ExplicitAnswerType> {
    if contains_phrase(query_tokens, &["how", "long"])
        || query_tokens.iter().any(|token| token == "duration")
    {
        Some(ExplicitAnswerType::Duration)
    } else if contains_phrase(query_tokens, &["how", "many"])
        || query_tokens.iter().any(|token| token == "count")
    {
        Some(ExplicitAnswerType::Count)
    } else if contains_phrase(query_tokens, &["due", "date"])
        || query_tokens
            .iter()
            .any(|token| token == "deadline" || token == "date")
    {
        Some(ExplicitAnswerType::Date)
    } else if query_tokens
        .iter()
        .any(|token| token == "who" || token == "whom")
    {
        Some(ExplicitAnswerType::Person)
    } else {
        None
    }
}

fn contains_phrase(tokens: &[String], phrase: &[&str]) -> bool {
    tokens.windows(phrase.len()).any(|window| {
        window
            .iter()
            .zip(phrase.iter())
            .all(|(token, expected)| token == expected)
    })
}

fn contains_related_value(
    answer_type: ExplicitAnswerType,
    query_tokens: &[String],
    evidence: &str,
    query_terms: &HashSet<String>,
    query_anchors: &HashSet<String>,
) -> bool {
    match answer_type {
        ExplicitAnswerType::Person => {
            contains_related_person(query_tokens, evidence, query_terms, query_anchors)
        }
        ExplicitAnswerType::Count => contains_related_count(evidence, query_terms, query_anchors),
        ExplicitAnswerType::Duration => {
            contains_related_duration(evidence, query_terms, query_anchors)
        }
        ExplicitAnswerType::Date => {
            contains_related_date(query_tokens, evidence, query_terms, query_anchors)
        }
    }
}

fn contains_related_person(
    query_tokens: &[String],
    evidence: &str,
    query_terms: &HashSet<String>,
    query_anchors: &HashSet<String>,
) -> bool {
    let tokens = case_preserving_tokens(evidence);
    let relation_stems = person_relation_stems(query_tokens);
    let topic_anchors = query_anchors
        .iter()
        .filter(|anchor| !relation_stems.contains(&relation_stem(anchor)))
        .cloned()
        .collect::<HashSet<_>>();
    tokens.iter().enumerate().any(|(person_index, token)| {
        if !is_novel_person_token(token, query_terms) {
            return false;
        }
        let relation_nearby = tokens.iter().enumerate().any(|(index, candidate)| {
            candidate.segment == token.segment
                && index.abs_diff(person_index) <= 3
                && relation_stems.contains(&relation_stem(&candidate.normalized))
        });
        let attributed_near_topic = tokens.iter().enumerate().any(|(index, candidate)| {
            index.abs_diff(person_index) <= 3
                && matches!(
                    candidate.normalized.as_str(),
                    "by" | "from" | "name" | "named" | "names" | "owner" | "technician"
                )
        }) && has_anchor_near(&tokens, person_index, query_anchors, 5);
        (relation_nearby && has_anchor_near(&tokens, person_index, &topic_anchors, 5))
            || attributed_near_topic
    })
}

fn is_novel_person_token(token: &RelationToken, query_terms: &HashSet<String>) -> bool {
    token.starts_uppercase
        && token.has_lowercase
        && !query_terms.contains(&token.normalized)
        && !is_person_placeholder(&token.normalized)
        && !content_terms(&token.normalized).is_empty()
}

fn is_person_placeholder(token: &str) -> bool {
    is_month(token)
        || is_weekday(token)
        || matches!(
            token,
            "anybody"
                | "anyone"
                | "nobody"
                | "no-one"
                | "person"
                | "somebody"
                | "someone"
                | "today"
                | "tomorrow"
                | "tonight"
                | "unknown"
                | "yesterday"
        )
}

fn contains_related_count(
    evidence: &str,
    query_terms: &HashSet<String>,
    query_anchors: &HashSet<String>,
) -> bool {
    let tokens = case_preserving_tokens(evidence);
    tokens.iter().enumerate().any(|(index, token)| {
        !query_terms.contains(&token.normalized)
            && is_count_value(&tokens, index)
            && has_anchor_near(&tokens, index, query_anchors, 2)
    })
}

fn contains_related_duration(
    evidence: &str,
    query_terms: &HashSet<String>,
    query_anchors: &HashSet<String>,
) -> bool {
    let tokens = case_preserving_tokens(evidence);
    tokens.windows(2).enumerate().any(|(index, window)| {
        !query_terms.contains(&window[0].normalized)
            && (window[0]
                .normalized
                .chars()
                .all(|character| character.is_ascii_digit())
                || is_number_word(&window[0].normalized))
            && is_duration_unit(&window[1].normalized)
            && has_anchor_near(&tokens, index, query_anchors, 4)
    }) || tokens.iter().enumerate().any(|(index, token)| {
        let split = token
            .normalized
            .find(|character: char| !character.is_ascii_digit())
            .unwrap_or(token.normalized.len());
        split > 0
            && split < token.normalized.len()
            && !query_terms.contains(&token.normalized)
            && is_duration_unit(&token.normalized[split..])
            && has_anchor_near(&tokens, index, query_anchors, 4)
    }) || tokens.iter().enumerate().any(|(index, token)| {
        !query_terms.contains(&token.normalized)
            && matches!(
                token.normalized.as_str(),
                "overnight" | "all-day" | "daylong" | "weeklong"
            )
            && has_anchor_near(&tokens, index, query_anchors, 4)
    })
}

fn contains_related_date(
    query_tokens: &[String],
    evidence: &str,
    query_terms: &HashSet<String>,
    query_anchors: &HashSet<String>,
) -> bool {
    let tokens = case_preserving_tokens(evidence);
    let due_question = query_tokens
        .iter()
        .any(|token| matches!(token.as_str(), "due" | "deadline"));
    date_value_indexes(&tokens, query_terms)
        .into_iter()
        .any(|index| {
            if due_question {
                has_token_near(&tokens, index, 3, |token| {
                    matches!(token, "by" | "deadline" | "due")
                }) && has_anchor_near(&tokens, index, query_anchors, 5)
            } else {
                has_anchor_near(&tokens, index, query_anchors, 4)
                    && has_token_near(&tokens, index, 4, |token| {
                        matches!(token, "at" | "for" | "is" | "on" | "opens" | "scheduled")
                    })
            }
        })
}

fn date_value_indexes(tokens: &[RelationToken], query_terms: &HashSet<String>) -> Vec<usize> {
    let mut indexes = Vec::new();
    for (index, token) in tokens.iter().enumerate() {
        if !query_terms.contains(&token.normalized)
            && (is_weekday(&token.normalized)
                || matches!(token.normalized.as_str(), "today" | "tomorrow" | "tonight")
                || is_delimited_date(&token.normalized))
        {
            indexes.push(index);
        }
    }
    for (index, window) in tokens.windows(2).enumerate() {
        if is_month(&window[0].normalized)
            && !query_terms.contains(&window[0].normalized)
            && window[1]
                .normalized
                .chars()
                .all(|character| character.is_ascii_digit())
        {
            indexes.push(index);
        }
    }
    indexes
}

#[derive(Debug)]
struct RelationToken {
    normalized: String,
    starts_uppercase: bool,
    has_lowercase: bool,
    segment: usize,
}

fn case_preserving_tokens(text: &str) -> Vec<RelationToken> {
    text.split(['.', ';', '!', '?', '\n'])
        .enumerate()
        .flat_map(|(segment, clause)| {
            clause
                .split(|character: char| {
                    !character.is_alphanumeric()
                        && character != '_'
                        && character != '-'
                        && character != '/'
                        && character != ':'
                })
                .filter(|raw| !raw.is_empty())
                .map(move |raw| {
                    let mut letters = raw.chars().filter(|character| character.is_alphabetic());
                    let starts_uppercase = letters.next().is_some_and(char::is_uppercase);
                    let has_lowercase = letters.any(char::is_lowercase);
                    RelationToken {
                        normalized: raw.to_ascii_lowercase(),
                        starts_uppercase,
                        has_lowercase,
                        segment,
                    }
                })
        })
        .collect()
}

fn relation_anchor_terms(query_tokens: &[String]) -> HashSet<String> {
    const GENERIC: &[&str] = &[
        "count", "date", "deadline", "due", "duration", "long", "many", "number", "set", "total",
        "who", "whom",
    ];
    query_tokens
        .iter()
        .filter(|token| !GENERIC.contains(&token.as_str()))
        .filter(|token| !content_terms(token).is_empty())
        .cloned()
        .collect()
}

fn person_relation_stems(query_tokens: &[String]) -> HashSet<String> {
    const SKIP: &[&str] = &[
        "a", "an", "did", "does", "has", "have", "is", "the", "was", "were", "who", "whom",
    ];
    query_tokens
        .iter()
        .skip_while(|token| !matches!(token.as_str(), "who" | "whom"))
        .skip(1)
        .find(|token| !SKIP.contains(&token.as_str()))
        .map(|token| HashSet::from([relation_stem(token)]))
        .unwrap_or_default()
}

fn relation_stem(token: &str) -> String {
    for suffix in ["ing", "ed", "es", "s"] {
        if token.len() > suffix.len() + 3 {
            if let Some(stem) = token.strip_suffix(suffix) {
                return stem.to_owned();
            }
        }
    }
    token.to_owned()
}

fn has_anchor_near(
    tokens: &[RelationToken],
    index: usize,
    anchors: &HashSet<String>,
    radius: usize,
) -> bool {
    has_token_near(tokens, index, radius, |token| anchors.contains(token))
}

fn has_token_near(
    tokens: &[RelationToken],
    index: usize,
    radius: usize,
    predicate: impl Fn(&str) -> bool,
) -> bool {
    let start = index.saturating_sub(radius);
    let end = index
        .saturating_add(radius)
        .min(tokens.len().saturating_sub(1));
    tokens[start..=end]
        .iter()
        .any(|token| token.segment == tokens[index].segment && predicate(&token.normalized))
}

fn is_count_value(tokens: &[RelationToken], index: usize) -> bool {
    let token = &tokens[index].normalized;
    let value = token.chars().all(|character| character.is_ascii_digit()) || is_number_word(token);
    value
        && !tokens.get(index.wrapping_sub(1)).is_some_and(|previous| {
            matches!(
                previous.normalized.as_str(),
                "build" | "issue" | "pr" | "revision" | "version"
            )
        })
}

fn is_number_word(token: &str) -> bool {
    matches!(
        token,
        "zero"
            | "one"
            | "two"
            | "three"
            | "four"
            | "five"
            | "six"
            | "seven"
            | "eight"
            | "nine"
            | "ten"
            | "eleven"
            | "twelve"
            | "thirteen"
            | "fourteen"
            | "fifteen"
            | "sixteen"
            | "seventeen"
            | "eighteen"
            | "nineteen"
            | "twenty"
            | "thirty"
            | "forty"
            | "fifty"
            | "sixty"
            | "seventy"
            | "eighty"
            | "ninety"
            | "hundred"
            | "thousand"
    )
}

fn is_duration_unit(token: &str) -> bool {
    matches!(
        token,
        "ms" | "millisecond"
            | "milliseconds"
            | "second"
            | "seconds"
            | "sec"
            | "secs"
            | "minute"
            | "minutes"
            | "min"
            | "mins"
            | "hour"
            | "hours"
            | "hr"
            | "hrs"
            | "day"
            | "days"
            | "week"
            | "weeks"
    )
}

fn is_month(token: &str) -> bool {
    matches!(
        token,
        "january"
            | "february"
            | "march"
            | "april"
            | "may"
            | "june"
            | "july"
            | "august"
            | "september"
            | "october"
            | "november"
            | "december"
    )
}

fn is_weekday(token: &str) -> bool {
    matches!(
        token,
        "monday" | "tuesday" | "wednesday" | "thursday" | "friday" | "saturday" | "sunday"
    )
}

fn is_delimited_date(token: &str) -> bool {
    for delimiter in ['-', '/'] {
        let pieces = token.split(delimiter).collect::<Vec<_>>();
        if pieces.len() == 3
            && pieces.iter().all(|piece| {
                !piece.is_empty() && piece.chars().all(|character| character.is_ascii_digit())
            })
        {
            return true;
        }
    }
    false
}

fn evidence_body(text: &str) -> &str {
    text.strip_prefix("[app=")
        .and_then(|_| text.split_once("]\n"))
        .map_or(text, |(_, body)| body)
}

fn normalized_tokens(text: &str) -> Vec<String> {
    text.split(|character: char| {
        !character.is_alphanumeric() && character != '_' && character != '-'
    })
    .filter_map(|raw| {
        let token = raw.trim().to_ascii_lowercase();
        (!token.is_empty()).then_some(token)
    })
    .collect()
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
