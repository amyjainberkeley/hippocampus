//! Maintainer-only independent calibration for the local evidence critic.
//!
//! This binary never reads Task 3. It fits a fixed logistic critic on the
//! fixture's `fit` split, chooses a lower-tail threshold using only positive
//! `calibration` examples, and reports the untouched `validation` split.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{ExitCode, Stdio};

use mci_agent::bench_longmemeval::Embedders;
use mci_agent::child_command_environment::sanitized_command;
use mci_brain::{evidence_features_for_candidates, EvidenceCandidate, EvidenceFeatures};
use serde::{Deserialize, Serialize};

const FEATURE_SCHEMA_VERSION: u32 = 2;
const ITERATIONS: usize = 20_000;
const LEARNING_RATE: f64 = 0.02;
const L2_PENALTY: f64 = 0.01;
const MAX_VALIDATION_FALSE_POSITIVE_RATE: f64 = 0.10;

#[derive(Debug, Deserialize)]
struct Fixture {
    dataset_id: String,
    target_positive_coverage: f64,
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
struct Case {
    id: String,
    split: String,
    query: String,
    supporting_documents: Vec<String>,
    insufficient_documents: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct Observation {
    case_id: String,
    split: String,
    sufficient: bool,
    features: [f64; 6],
    score: f64,
    accepted: bool,
}

#[derive(Debug, Clone, Copy, Serialize)]
struct SplitMetrics {
    positives: usize,
    negatives: usize,
    positive_coverage: f64,
    negative_false_positive_rate: f64,
}

#[derive(Debug, Serialize)]
struct Report {
    dataset_id: String,
    fixture_sha256: String,
    model_path: String,
    feature_schema_version: u32,
    feature_names: [&'static str; 6],
    fit_procedure: &'static str,
    threshold_procedure: &'static str,
    target_positive_coverage: f64,
    means: [f64; 6],
    scales: [f64; 6],
    weights: [f64; 6],
    intercept: f64,
    threshold: f64,
    calibration: SplitMetrics,
    validation: SplitMetrics,
    validation_qualified: bool,
    observations: Vec<Observation>,
}

fn feature_array(features: EvidenceFeatures) -> [f64; 6] {
    [
        f64::from(features.raw_semantic_cosine),
        f64::from(features.semantic_margin),
        f64::from(features.query_coverage),
        f64::from(features.document_coverage),
        f64::from(features.lexical_semantic_agreement),
        f64::from(features.novel_specificity),
    ]
}

fn extract_features(
    embedders: &Embedders,
    query: &str,
    documents: &[String],
) -> Result<[f64; 6], String> {
    let query_vector = embedders
        .query
        .embed_one(query)
        .map_err(|error| format!("query embed: {error}"))?;
    let mut scores = Vec::with_capacity(documents.len());
    for document in documents {
        let document_vector = embedders
            .document
            .embed_one(document)
            .map_err(|error| format!("document embed: {error}"))?;
        if query_vector.len() != document_vector.len() {
            return Err("query/document embedding dimensions differ".into());
        }
        scores.push(
            query_vector
                .iter()
                .zip(document_vector.iter())
                .map(|(left, right)| left * right)
                .sum::<f32>(),
        );
    }
    let candidates: Vec<EvidenceCandidate<'_>> = documents
        .iter()
        .zip(scores)
        .enumerate()
        .map(|(index, (text, raw_semantic_cosine))| EvidenceCandidate {
            stable_id: index as u64,
            text,
            raw_semantic_cosine,
        })
        .collect();
    evidence_features_for_candidates(query, &candidates)
        .map(feature_array)
        .ok_or_else(|| "feature extraction returned no finite candidates".into())
}

fn standardization(rows: &[([f64; 6], f64)]) -> ([f64; 6], [f64; 6]) {
    let mut means = [0.0; 6];
    for (features, _) in rows {
        for index in 0..6 {
            means[index] += features[index];
        }
    }
    for mean in &mut means {
        *mean /= rows.len() as f64;
    }
    let mut scales = [0.0; 6];
    for (features, _) in rows {
        for index in 0..6 {
            scales[index] += (features[index] - means[index]).powi(2);
        }
    }
    for scale in &mut scales {
        *scale = (*scale / rows.len() as f64).sqrt().max(1e-6);
    }
    (means, scales)
}

fn standardized(features: [f64; 6], means: [f64; 6], scales: [f64; 6]) -> [f64; 6] {
    std::array::from_fn(|index| (features[index] - means[index]) / scales[index])
}

fn sigmoid(logit: f64) -> f64 {
    1.0 / (1.0 + (-logit).exp())
}

fn fit_logistic(rows: &[([f64; 6], f64)], means: [f64; 6], scales: [f64; 6]) -> ([f64; 6], f64) {
    let normalized: Vec<([f64; 6], f64)> = rows
        .iter()
        .map(|(features, label)| (standardized(*features, means, scales), *label))
        .collect();
    let mut weights = [0.0; 6];
    let mut intercept = 0.0;
    for _ in 0..ITERATIONS {
        let mut weight_gradient = [0.0; 6];
        let mut intercept_gradient = 0.0;
        for (features, label) in &normalized {
            let logit = weights
                .iter()
                .zip(features.iter())
                .fold(intercept, |sum, (weight, feature)| sum + weight * feature);
            let error = sigmoid(logit) - label;
            intercept_gradient += error;
            for index in 0..6 {
                weight_gradient[index] += error * features[index];
            }
        }
        let count = normalized.len() as f64;
        intercept -= LEARNING_RATE * intercept_gradient / count;
        for index in 0..6 {
            let gradient = weight_gradient[index] / count + L2_PENALTY * weights[index];
            weights[index] -= LEARNING_RATE * gradient;
        }
    }
    (weights, intercept)
}

fn critic_score(
    features: [f64; 6],
    means: [f64; 6],
    scales: [f64; 6],
    weights: [f64; 6],
    intercept: f64,
) -> f64 {
    let normalized = standardized(features, means, scales);
    sigmoid(
        weights
            .iter()
            .zip(normalized.iter())
            .fold(intercept, |sum, (weight, feature)| sum + weight * feature),
    )
}

fn lower_positive_threshold(scores: &mut [f64], target_coverage: f64) -> Result<f64, String> {
    if scores.is_empty() {
        return Err("calibration split has no positive examples".into());
    }
    if !target_coverage.is_finite()
        || !(0.0..=1.0).contains(&target_coverage)
        || target_coverage == 0.0
    {
        return Err("target positive coverage must be finite and inside (0, 1]".into());
    }
    scores.sort_by(f64::total_cmp);
    let alpha = 1.0 - target_coverage;
    let rank = (((scores.len() as f64 + 1.0) * alpha) + 1e-12).floor() as usize;
    if rank == 0 {
        return Err(format!(
            "requested {target_coverage:.3} one-sided coverage is unattainable with {} calibration positives",
            scores.len()
        ));
    }
    let index = rank.saturating_sub(1).min(scores.len() - 1);
    Ok(scores[index])
}

fn metrics(observations: &[Observation], split: &str) -> SplitMetrics {
    let selected: Vec<&Observation> = observations
        .iter()
        .filter(|observation| observation.split == split)
        .collect();
    let positives = selected.iter().filter(|row| row.sufficient).count();
    let negatives = selected.len() - positives;
    let accepted_positives = selected
        .iter()
        .filter(|row| row.sufficient && row.accepted)
        .count();
    let accepted_negatives = selected
        .iter()
        .filter(|row| !row.sufficient && row.accepted)
        .count();
    SplitMetrics {
        positives,
        negatives,
        positive_coverage: accepted_positives as f64 / positives as f64,
        negative_false_positive_rate: accepted_negatives as f64 / negatives as f64,
    }
}

fn policy_qualified(
    calibration: &SplitMetrics,
    validation: &SplitMetrics,
    target_positive_coverage: f64,
) -> bool {
    calibration.positive_coverage >= target_positive_coverage
        && calibration.negative_false_positive_rate <= MAX_VALIDATION_FALSE_POSITIVE_RATE
        && validation.positive_coverage >= target_positive_coverage
        && validation.negative_false_positive_rate <= MAX_VALIDATION_FALSE_POSITIVE_RATE
}

fn sha256(bytes: &[u8]) -> Result<String, String> {
    let mut child = sanitized_command("shasum")
        .args(["-a", "256"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|error| format!("spawn shasum: {error}"))?;
    child
        .stdin
        .as_mut()
        .ok_or_else(|| "shasum stdin unavailable".to_string())?
        .write_all(bytes)
        .map_err(|error| format!("write shasum input: {error}"))?;
    let output = child
        .wait_with_output()
        .map_err(|error| format!("wait shasum: {error}"))?;
    if !output.status.success() {
        return Err("shasum failed".into());
    }
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .map(str::to_owned)
        .ok_or_else(|| "shasum returned no digest".into())
}

fn run(fixture_path: &Path, output_path: &Path) -> Result<(), String> {
    let bytes = fs::read(fixture_path)
        .map_err(|error| format!("read {}: {error}", fixture_path.display()))?;
    let fixture: Fixture = serde_json::from_slice(&bytes)
        .map_err(|error| format!("parse {}: {error}", fixture_path.display()))?;
    let embedders = Embedders::load()?;

    let mut extracted = Vec::new();
    for case in &fixture.cases {
        for (sufficient, documents) in [
            (true, case.supporting_documents.as_slice()),
            (false, case.insufficient_documents.as_slice()),
        ] {
            extracted.push((
                case.id.clone(),
                case.split.clone(),
                sufficient,
                extract_features(&embedders, &case.query, documents)?,
            ));
        }
    }

    let fit_rows: Vec<([f64; 6], f64)> = extracted
        .iter()
        .filter(|(_, split, _, _)| split == "fit")
        .map(|(_, _, sufficient, features)| (*features, f64::from(*sufficient)))
        .collect();
    if fit_rows.is_empty() {
        return Err("fixture has no fit rows".into());
    }
    let (means, scales) = standardization(&fit_rows);
    let (weights, intercept) = fit_logistic(&fit_rows, means, scales);

    let mut positive_calibration_scores: Vec<f64> = extracted
        .iter()
        .filter(|(_, split, sufficient, _)| split == "calibration" && *sufficient)
        .map(|(_, _, _, features)| critic_score(*features, means, scales, weights, intercept))
        .collect();
    let threshold = lower_positive_threshold(
        &mut positive_calibration_scores,
        fixture.target_positive_coverage,
    )?;

    let observations: Vec<Observation> = extracted
        .into_iter()
        .map(|(case_id, split, sufficient, features)| {
            let score = critic_score(features, means, scales, weights, intercept);
            Observation {
                case_id,
                split,
                sufficient,
                features,
                score,
                accepted: score >= threshold,
            }
        })
        .collect();
    let calibration = metrics(&observations, "calibration");
    let validation = metrics(&observations, "validation");
    let validation_qualified =
        policy_qualified(&calibration, &validation, fixture.target_positive_coverage);
    let report = Report {
        dataset_id: fixture.dataset_id,
        fixture_sha256: sha256(&bytes)?,
        model_path: embedders.model_path.display().to_string(),
        feature_schema_version: FEATURE_SCHEMA_VERSION,
        feature_names: [
            "raw_semantic_cosine",
            "semantic_margin",
            "query_coverage",
            "document_coverage",
            "lexical_semantic_agreement",
            "novel_specificity",
        ],
        fit_procedure: "fixed logistic regression: 20000 full-batch iterations, learning_rate=0.02, l2=0.01",
        threshold_procedure: "lower positive split-conformal quantile; calibration negatives and validation labels do not select the threshold",
        target_positive_coverage: fixture.target_positive_coverage,
        means,
        scales,
        weights,
        intercept,
        threshold,
        calibration,
        validation,
        validation_qualified,
        observations,
    };
    let encoded = serde_json::to_vec_pretty(&report)
        .map_err(|error| format!("serialize calibration report: {error}"))?;
    fs::write(output_path, encoded)
        .map_err(|error| format!("write {}: {error}", output_path.display()))?;
    println!("calibration report: {}", output_path.display());
    println!("fixture sha256: {}", report.fixture_sha256);
    println!("means: {:?}", report.means);
    println!("scales: {:?}", report.scales);
    println!("weights: {:?}", report.weights);
    println!("intercept: {:.9}", report.intercept);
    println!("threshold: {:.9}", report.threshold);
    println!(
        "calibration coverage={:.3} fpr={:.3}; validation coverage={:.3} fpr={:.3}",
        report.calibration.positive_coverage,
        report.calibration.negative_false_positive_rate,
        report.validation.positive_coverage,
        report.validation.negative_false_positive_rate,
    );
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let fixture = args.get(1).map_or_else(
        || PathBuf::from("eval/relevance-calibration/v1.json"),
        PathBuf::from,
    );
    let output = args.get(2).map_or_else(
        || PathBuf::from("eval/relevance-calibration/v1-policy.json"),
        PathBuf::from,
    );
    match run(&fixture, &output) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("mci-calibrate-evidence: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{lower_positive_threshold, policy_qualified, SplitMetrics};

    #[test]
    fn split_conformal_rejects_sample_size_below_requested_coverage_limit() {
        let mut scores = vec![0.1; 8];
        let error = lower_positive_threshold(&mut scores, 0.90)
            .expect_err("eight calibration positives cannot certify 90% one-sided coverage");
        assert!(error.contains("unattainable"));
    }

    #[test]
    fn split_conformal_accepts_minimum_valid_sample_size_and_uses_first_order_statistic() {
        let mut scores = vec![0.9, 0.3, 0.8, 0.1, 0.7, 0.6, 0.5, 0.4, 0.2];
        let threshold = lower_positive_threshold(&mut scores, 0.90).unwrap();
        assert_eq!(threshold, 0.1);
    }

    #[test]
    fn split_conformal_uses_second_order_statistic_when_sample_size_supports_it() {
        let mut scores = (1..=19)
            .rev()
            .map(|value| f64::from(value) / 20.0)
            .collect::<Vec<_>>();
        let threshold = lower_positive_threshold(&mut scores, 0.90).unwrap();
        assert_eq!(threshold, 0.10);
    }

    #[test]
    fn split_conformal_rejects_invalid_coverage_targets() {
        for target in [0.0, -0.1, 1.1, f64::NAN] {
            assert!(lower_positive_threshold(&mut [0.5], target).is_err());
        }
    }

    #[test]
    fn qualification_requires_calibration_and_validation_false_positive_gates() {
        let good = SplitMetrics {
            positives: 10,
            negatives: 10,
            positive_coverage: 1.0,
            negative_false_positive_rate: 0.0,
        };
        let weak_calibration = SplitMetrics {
            negative_false_positive_rate: 0.2,
            ..good
        };
        assert!(!policy_qualified(&weak_calibration, &good, 0.90));
        assert!(policy_qualified(&good, &good, 0.90));
    }
}
