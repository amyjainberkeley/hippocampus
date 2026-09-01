use std::fs;
use std::path::Path;
use std::process::Command;

use serde_json::Value;
use tempfile::tempdir;

fn run_bench(dataset_json: &str, extra_args: &[&str]) -> (std::process::Output, Value) {
    let dir = tempdir().expect("tempdir");
    let dataset_path = dir.path().join("dataset.json");
    let report_path = dir.path().join("report.json");
    fs::write(&dataset_path, dataset_json).expect("write dataset");

    let output = Command::new(env!("CARGO_BIN_EXE_mci-bench"))
        .arg("--dataset")
        .arg(&dataset_path)
        .arg("--arm")
        .arg("lexical")
        .arg("--out")
        .arg(&report_path)
        .args(extra_args)
        .output()
        .expect("run mci-bench");

    let report = fs::read_to_string(&report_path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or(Value::Null);
    (output, report)
}

#[test]
fn synthetic_work_memory_dataset_reports_extended_metrics() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-test",
      "instances": [
        {
          "question_id": "exact-1",
          "question_type": "exact_recall",
          "question": "wires complete false partial runs",
          "question_date": "2026/08/31 (Mon) 11:30",
          "answer_session_ids": ["github://hippocampus/pull/431"],
          "haystack_dates": [
            "2026/08/31 (Mon) 09:00",
            "2026/08/31 (Mon) 10:30"
          ],
          "haystack_session_ids": [
            "github://hippocampus/pull/431",
            "terminal://zsh/session-14"
          ],
          "haystack_sessions": [
            [
              {
                "role": "assistant",
                "content": "GitHub PR #431 wires complete=false on partial runs and exits nonzero when hybrid cannot finish."
              }
            ],
            [
              {
                "role": "assistant",
                "content": "cargo test -p mci-agent --test work_memory_bench"
              }
            ]
          ],
          "tags": ["github", "provenance"]
        },
        {
          "question_id": "none-1",
          "question_type": "unanswerable",
          "question": "Who approved PR 431 after the rollback discussion?",
          "question_date": "2026/08/31 (Mon) 11:30",
          "answer_session_ids": [],
          "haystack_dates": [
            "2026/08/31 (Mon) 09:00"
          ],
          "haystack_session_ids": [
            "slack://war-room/thread-991"
          ],
          "haystack_sessions": [
            [
              {
                "role": "assistant",
                "content": "Slack war room noted the deploy rollback and linked PR #431."
              }
            ]
          ],
          "tags": ["slack", "unanswerable"],
          "unanswerable": true
        }
      ]
    }"#;

    let (output, report) = run_bench(dataset, &[]);
    assert!(
        output.status.success(),
        "expected success, got status={} stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(report["complete"], Value::Bool(true));
    assert_eq!(report["publishable"], Value::Bool(false));
    assert_eq!(
        report["dataset_id"],
        Value::String("synthetic-v1-test".into())
    );
    assert_eq!(
        report["overall"][0]["provenance_coverage_at"]["1"],
        Value::from(1.0)
    );
    assert_eq!(
        report["overall"][0]["false_positive_rate_at"]["1"],
        Value::from(0.0)
    );
    assert_eq!(report["overall"][0]["outcomes"]["matched"], Value::from(1));
    assert_eq!(
        report["overall"][0]["outcomes"]["abstained"],
        Value::from(1)
    );
    assert!(
        report["absolute_quality_targets"]["hybrid"].is_object(),
        "absolute launch targets must be separate from measured regression thresholds"
    );
    assert_eq!(report["launch_qualified"], Value::Bool(false));
    assert_eq!(
        report["by_type"]["exact_recall"][0]["false_positive_rate_at"]["1"],
        Value::Null,
        "unanswerable-only metrics are undefined on an answerable-only slice"
    );
    assert_eq!(
        report["by_type"]["exact_recall"][0]["abstention_separation_at"]["1"],
        Value::Null
    );
    assert_eq!(
        report["by_type"]["unanswerable"][0]["hit_rate_at"]["1"],
        Value::Null,
        "answerable-only metrics are undefined on an unanswerable-only slice"
    );
    assert_eq!(report["by_type"]["unanswerable"][0]["mrr"], Value::Null);
}

#[test]
fn partial_runs_write_incomplete_report_and_exit_nonzero() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-partial",
      "instances": [
        {
          "question_id": "good-1",
          "question_type": "exact_recall",
          "question": "Which file added the new benchmark report fields?",
          "question_date": "2026/08/31 (Mon) 12:00",
          "answer_session_ids": ["files:///docs/eval/README.md"],
          "haystack_dates": ["2026/08/31 (Mon) 11:00"],
          "haystack_session_ids": ["files:///docs/eval/README.md"],
          "haystack_sessions": [
            [
              {
                "role": "assistant",
                "content": "docs/eval/README.md now explains the new work-memory benchmark."
              }
            ]
          ]
        },
        {
          "question_id": "bad-1",
          "question_type": "temporal",
          "question": "What changed right before the rollback?",
          "question_date": "not a timestamp",
          "answer_session_ids": ["terminal://zsh/session-19"],
          "haystack_dates": ["2026/08/31 (Mon) 11:55"],
          "haystack_session_ids": ["terminal://zsh/session-19"],
          "haystack_sessions": [
            [
              {
                "role": "assistant",
                "content": "Terminal session reverted the rollout and tailed the agent logs."
              }
            ]
          ]
        }
      ]
    }"#;

    let (output, report) = run_bench(dataset, &[]);
    assert!(
        !output.status.success(),
        "partial runs must exit nonzero; stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(report["complete"], Value::Bool(false));
    assert_eq!(report["publishable"], Value::Bool(false));
    assert_eq!(report["failures"].as_array().map(Vec::len), Some(1));
}

#[test]
fn limited_runs_are_explicit_nonpublishable_smoke_reports() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-limited",
      "instances": [
        {
          "question_id": "first",
          "question_type": "exact_recall",
          "question": "Which PR introduced complete false?",
          "question_date": "2026/08/31 (Mon) 12:00",
          "answer_session_ids": ["github://hippocampus/pull/431"],
          "haystack_dates": ["2026/08/31 (Mon) 11:00"],
          "haystack_session_ids": ["github://hippocampus/pull/431"],
          "haystack_sessions": [[{"role": "assistant", "content": "PR 431 introduced complete false."}]]
        },
        {
          "question_id": "second",
          "question_type": "exact_recall",
          "question": "Which PR moved retrieval to production?",
          "question_date": "2026/08/31 (Mon) 12:00",
          "answer_session_ids": ["github://hippocampus/pull/440"],
          "haystack_dates": ["2026/08/31 (Mon) 11:15"],
          "haystack_session_ids": ["github://hippocampus/pull/440"],
          "haystack_sessions": [[{"role": "assistant", "content": "PR 440 moved retrieval to production."}]]
        }
      ]
    }"#;

    let (output, report) = run_bench(dataset, &["--limit", "1"]);
    assert!(
        !output.status.success(),
        "limited benchmark runs must be nonzero by default"
    );
    assert_eq!(report["complete"], Value::Bool(false));
    assert_eq!(report["publishable"], Value::Bool(false));
    assert_eq!(report["run"]["original_instances"], Value::from(2));
    assert_eq!(report["run"]["evaluated_instances"], Value::from(1));
}

#[test]
fn path_traversal_question_ids_are_rejected_before_scratch_creation() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-path-safety",
      "instances": [{
        "question_id": "../escaped",
        "question_type": "exact_recall",
        "question": "Which PR introduced complete false?",
        "question_date": "2026/08/31 (Mon) 12:00",
        "answer_session_ids": ["github://hippocampus/pull/431"],
        "haystack_dates": ["2026/08/31 (Mon) 11:00"],
        "haystack_session_ids": ["github://hippocampus/pull/431"],
        "haystack_sessions": [[{"role": "assistant", "content": "PR 431 introduced complete false."}]]
      }]
    }"#;
    let dir = tempdir().expect("tempdir");
    let workdir = dir.path().join("scratch");
    let workdir_arg = workdir.to_str().expect("utf-8 workdir");
    let (output, report) = run_bench(dataset, &["--workdir", workdir_arg]);

    assert!(!output.status.success(), "unsafe question ids must fail");
    assert_eq!(report["complete"], Value::Bool(false));
    let failures = report["failures"].as_array().expect("failure list");
    assert!(
        failures.iter().any(|failure| failure["error"]
            .as_str()
            .is_some_and(|error| error.contains("invalid question_id"))),
        "failure should identify the rejected dataset id: {failures:?}"
    );
    assert!(
        !dir.path().join("escaped.sqlite").exists(),
        "dataset ids must never select a path outside the scratch directory"
    );
}

#[test]
fn baseline_thresholds_allow_small_noise_but_fail_material_regressions() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-baseline-check",
      "instances": [
        {
          "question_id": "git-1",
          "question_type": "exact_recall",
          "question": "Which PR moved the benchmark to the production retriever?",
          "question_date": "2026/08/31 (Mon) 10:00",
          "answer_session_ids": ["github://hippocampus/pull/440"],
          "haystack_dates": ["2026/08/31 (Mon) 09:15"],
          "haystack_session_ids": ["github://hippocampus/pull/440"],
          "haystack_sessions": [
            [
              {
                "role": "assistant",
                "content": "GitHub PR #440 switched the benchmark onto the production hybrid retriever."
              }
            ]
          ]
        }
      ],
      "regression_thresholds": {
        "lexical": {
          "hit_rate_at_1_min": 0.0,
          "mrr_min": 0.0,
          "false_positive_rate_at_1_max": 1.0
        }
      }
    }"#;
    let dir = tempdir().expect("tempdir");
    let baseline_path = dir.path().join("baseline.json");
    let (seed_output, mut baseline) = run_bench(dataset, &[]);
    assert!(seed_output.status.success(), "seed report must run");
    baseline["complete"] = Value::Bool(true);
    baseline["publishable"] = Value::Bool(true);
    baseline["run"]["git_dirty_at_start"] = Value::Bool(false);
    baseline["regression_thresholds"]["lexical"]["hit_rate_at_1_min"] = Value::from(0.95);
    baseline["regression_thresholds"]["lexical"]["mrr_min"] = Value::from(0.95);
    fs::write(
        &baseline_path,
        serde_json::to_vec_pretty(&baseline).expect("serialize baseline"),
    )
    .expect("write baseline");

    let (output, _) = run_bench(
        dataset,
        &[
            "--baseline",
            baseline_path.to_str().expect("utf-8 baseline path"),
        ],
    );
    assert!(
        !output.status.success(),
        "material regression against baseline must fail; stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn baseline_comparison_rejects_a_missing_requested_arm() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-missing-arm",
      "instances": [{
        "question_id": "git-1",
        "question_type": "exact_recall",
        "question": "Which PR moved the benchmark to the production retriever?",
        "question_date": "2026/08/31 (Mon) 10:00",
        "answer_session_ids": ["github://hippocampus/pull/440"],
        "haystack_dates": ["2026/08/31 (Mon) 09:15"],
        "haystack_session_ids": ["github://hippocampus/pull/440"],
        "haystack_sessions": [[{"role": "assistant", "content": "GitHub PR 440 moved the benchmark to the production retriever."}]]
      }]
    }"#;

    let (seed_output, mut baseline) = run_bench(dataset, &[]);
    assert!(seed_output.status.success(), "seed report must run");
    baseline["complete"] = Value::Bool(true);
    baseline["publishable"] = Value::Bool(true);
    baseline["run"]["git_dirty_at_start"] = Value::Bool(false);
    baseline["overall"] = Value::Array(Vec::new());
    baseline["regression_thresholds"] = serde_json::json!({});

    let dir = tempdir().expect("tempdir");
    let baseline_path = dir.path().join("baseline.json");
    fs::write(
        &baseline_path,
        serde_json::to_vec_pretty(&baseline).expect("serialize baseline"),
    )
    .expect("write baseline");

    let (output, report) = run_bench(
        dataset,
        &[
            "--baseline",
            baseline_path.to_str().expect("utf-8 baseline path"),
        ],
    );
    assert!(
        !output.status.success(),
        "a baseline without the requested arm must be rejected"
    );
    let regression_failures = report["regression"]["failures"]
        .as_array()
        .expect("regression failures");
    assert!(
        regression_failures.iter().any(|failure| failure
            .as_str()
            .is_some_and(|text| text.contains("missing requested arm lexical"))),
        "missing arm must be explicit: {regression_failures:?}"
    );
}

#[test]
fn baseline_comparison_rejects_incompatible_identity() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-identity",
      "instances": [{
        "question_id": "git-identity",
        "question_type": "exact_recall",
        "question": "Which PR moved the benchmark to the production retriever?",
        "question_date": "2026/08/31 (Mon) 10:00",
        "answer_session_ids": ["github://hippocampus/pull/440"],
        "haystack_dates": ["2026/08/31 (Mon) 09:15"],
        "haystack_session_ids": ["github://hippocampus/pull/440"],
        "haystack_sessions": [[{"role": "assistant", "content": "GitHub PR 440 moved the benchmark to the production retriever."}]]
      }]
    }"#;
    let (seed_output, mut valid_baseline) = run_bench(dataset, &[]);
    assert!(seed_output.status.success(), "seed report must run");
    valid_baseline["complete"] = Value::Bool(true);
    valid_baseline["publishable"] = Value::Bool(true);
    valid_baseline["run"]["git_dirty_at_start"] = Value::Bool(false);

    let cases = [
        ("incomplete baseline", "/complete", Value::Bool(false)),
        (
            "nonpublishable baseline",
            "/publishable",
            Value::Bool(false),
        ),
        (
            "dataset id mismatch",
            "/dataset_id",
            Value::String("different-dataset".into()),
        ),
        (
            "dataset checksum mismatch",
            "/dataset_checksum_sha256",
            Value::String("00".repeat(32)),
        ),
        ("k-set mismatch", "/run/ks", serde_json::json!([1, 3, 5])),
        (
            "dirty baseline code",
            "/run/git_dirty_at_start",
            Value::Bool(true),
        ),
    ];

    for (label, pointer, replacement) in cases {
        let mut baseline = valid_baseline.clone();
        *baseline.pointer_mut(pointer).expect("fixture field") = replacement;
        let dir = tempdir().expect("tempdir");
        let baseline_path = dir.path().join("baseline.json");
        fs::write(
            &baseline_path,
            serde_json::to_vec_pretty(&baseline).expect("serialize baseline"),
        )
        .expect("write baseline");

        let (output, _) = run_bench(
            dataset,
            &[
                "--baseline",
                baseline_path.to_str().expect("utf-8 baseline path"),
            ],
        );
        assert!(
            !output.status.success(),
            "{label} must be rejected by baseline comparison"
        );
    }
}

#[test]
fn work_memory_runner_is_cwd_independent() {
    let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root");
    let script = repo_root.join("scripts/eval/work-memory/run.sh");
    let dir = tempdir().expect("tempdir");
    let report_path = dir.path().join("runner-report.json");

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", env!("CARGO_BIN_EXE_mci-bench"))
        .arg("--no-baseline")
        .arg("--out")
        .arg(&report_path)
        .arg("--allow-smoke")
        .arg("--limit")
        .arg("1")
        .arg("--arm")
        .arg("lexical")
        .output()
        .expect("run work-memory runner from outside the repository");

    assert!(
        output.status.success(),
        "runner must work outside the repo; stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value =
        serde_json::from_slice(&fs::read(&report_path).expect("runner writes requested report"))
            .expect("valid runner report");
    assert_eq!(report["complete"], Value::Bool(false));
    assert_eq!(report["publishable"], Value::Bool(false));
    assert_eq!(
        report["dataset"],
        Value::String("eval/work-memory/synthetic-v1.json".into())
    );
}

#[test]
fn report_metadata_redacts_outside_repository_paths() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-path-redaction",
      "instances": [{
        "question_id": "path-redaction",
        "question_type": "exact_recall",
        "question": "Which PR introduced complete false?",
        "question_date": "2026/08/31 (Mon) 12:00",
        "answer_session_ids": ["github://hippocampus/pull/431"],
        "haystack_dates": ["2026/08/31 (Mon) 11:00"],
        "haystack_session_ids": ["github://hippocampus/pull/431"],
        "haystack_sessions": [[{"role": "assistant", "content": "PR 431 introduced complete false."}]]
      }]
    }"#;
    let (output, report) = run_bench(dataset, &[]);
    assert!(output.status.success(), "redaction fixture must run");

    let serialized = serde_json::to_string(&report).expect("serialize report value");
    assert!(
        !serialized.contains("/Users/") && !serialized.contains("/var/folders/"),
        "report metadata must not serialize user-home or temporary absolute paths: {serialized}"
    );
    assert_eq!(
        report["dataset"],
        Value::String("external-dataset://dataset.json".into())
    );
    let arguments = report["run"]["arguments"]
        .as_array()
        .expect("normalized arguments");
    assert!(
        arguments.iter().any(|argument| {
            argument == &Value::String("external-dataset://dataset.json".into())
        }),
        "dataset argument keeps a reproducible logical identity"
    );
    assert!(
        arguments
            .iter()
            .any(|argument| { argument == &Value::String("external-report://report.json".into()) }),
        "report argument keeps a reproducible logical identity"
    );
}
