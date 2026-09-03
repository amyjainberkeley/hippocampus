use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

use serde_json::Value;
use tempfile::tempdir;

use mci_agent::bench_longmemeval::ScratchRun;

fn run_bench_for_arm(
    dataset_json: &str,
    arm: &str,
    extra_args: &[&str],
) -> (std::process::Output, Value) {
    let dir = tempdir().expect("tempdir");
    let dataset_path = dir.path().join("dataset.json");
    let report_path = dir.path().join("report.json");
    fs::write(&dataset_path, dataset_json).expect("write dataset");

    let output = Command::new(env!("CARGO_BIN_EXE_mci-bench"))
        .arg("--dataset")
        .arg(&dataset_path)
        .arg("--arm")
        .arg(arm)
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

fn run_bench(dataset_json: &str, extra_args: &[&str]) -> (std::process::Output, Value) {
    run_bench_for_arm(dataset_json, "lexical", extra_args)
}

fn stage_runner_fixture(
    root: &Path,
    fake_report: &Value,
) -> (std::path::PathBuf, std::path::PathBuf) {
    let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root");
    let script = root.join("scripts/eval/work-memory/run.sh");
    fs::create_dir_all(script.parent().expect("runner parent")).expect("runner directory");
    fs::copy(repo_root.join("scripts/eval/work-memory/run.sh"), &script).expect("copy runner");

    let dataset = root.join("eval/work-memory/synthetic-v1.json");
    fs::create_dir_all(dataset.parent().expect("dataset parent")).expect("dataset directory");
    fs::copy(
        repo_root.join("eval/work-memory/synthetic-v1.json"),
        &dataset,
    )
    .expect("copy canonical dataset");
    fs::create_dir_all(root.join("docs/eval")).expect("baseline directory");
    fs::copy(
        repo_root.join("docs/eval/work-memory-baseline.json"),
        root.join("docs/eval/work-memory-baseline.json"),
    )
    .expect("copy accepted baseline");
    fs::copy(
        repo_root.join("docs/eval/work-memory-baseline.sha256"),
        root.join("docs/eval/work-memory-baseline.sha256"),
    )
    .expect("copy accepted baseline digest");

    let fake_report_path = root.join("fake-report.json");
    fs::write(
        &fake_report_path,
        serde_json::to_vec_pretty(fake_report).expect("serialize fake report"),
    )
    .expect("write fake report");
    let fake_args_path = root.join("fake-args.txt");
    let fake_bin = root.join("fake-mci-bench");
    fs::write(
        &fake_bin,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$@" > "$MCI_FAKE_ARGS"
out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out)
            out=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cp "$MCI_FAKE_REPORT" "$out"
"#,
    )
    .expect("write fake benchmark");
    let mut permissions = fs::metadata(&fake_bin)
        .expect("fake benchmark metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&fake_bin, permissions).expect("make fake benchmark executable");

    (script, fake_args_path)
}

fn eligible_fake_baseline() -> Value {
    serde_json::json!({
        "complete": true,
        "publishable": true,
        "launch_qualified": true,
        "dataset": "eval/work-memory/synthetic-v1.json",
        "dataset_id": "synthetic-work-memory-v1",
        "dataset_checksum_sha256": "f56ec3a13733343b6819edd86782d28c4ec9f6c5ee9fbb3a2d0b19c03282ae4d",
        "failures": [],
        "regression": {"passed": true, "failures": []},
        "quality_gate": {"passed": true, "failures": []},
        "run": {
            "git_dirty_at_start": false,
            "limit": null,
            "requested_arms": ["lexical", "hybrid"],
            "ks": [1, 3, 5, 10],
            "original_instances": 24,
            "evaluated_instances": 24,
            "model_checksum_sha256": "f782f7f4a13c69a4399345f1d6a4b8de8f4327c131e537a1ea6bf9fdeaeaeef8",
            "arguments": [
                "--dataset", "eval/work-memory/synthetic-v1.json",
                "--arm", "both",
                "--out", "external-report://fake-report.json",
                "--baseline", "docs/eval/work-memory-baseline.json"
            ]
        }
    })
}

#[test]
#[allow(clippy::too_many_lines)] // Keep the complete benchmark contract visible in one trace.
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
    assert_eq!(
        report["results"][0]["retrieval_disposition"],
        Value::String("matched".into()),
        "per-case results must preserve the production retrieval outcome"
    );
    assert_eq!(
        report["results"][1]["retrieval_disposition"],
        Value::String("nothingMatchedEvidenceFloor".into()),
        "an abstention must retain its production reason"
    );
}

#[test]
fn direct_binary_never_publishes_an_unrelated_empty_corpus() {
    let dataset = r#"{
      "dataset_id": "not-the-work-memory-corpus",
      "instances": []
    }"#;

    let (_output, report) = run_bench_for_arm(dataset, "lexical", &[]);

    assert_eq!(
        report["complete"],
        Value::Bool(true),
        "the empty generic run executed without an instance failure"
    );
    assert_eq!(
        report["publishable"],
        Value::Bool(false),
        "direct binary reports must enforce canonical work-memory publication scope"
    );
    assert_eq!(report["launch_qualified"], Value::Bool(false));
    assert_eq!(
        report["dataset_id"],
        Value::String("not-the-work-memory-corpus".into())
    );
    assert_eq!(report["run"]["original_instances"], Value::from(0));
    assert_eq!(report["run"]["evaluated_instances"], Value::from(0));
    assert_eq!(
        report["run"]["requested_arms"],
        serde_json::json!(["lexical"])
    );
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

    let (output, report) = run_bench(
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
    assert_eq!(report["regression"]["passed"], Value::Bool(false));
    assert_eq!(report["complete"], Value::Bool(false));
    assert_eq!(report["publishable"], Value::Bool(false));
    assert_eq!(report["launch_qualified"], Value::Bool(false));
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
        !output.status.success(),
        "a one-case canonical smoke cannot satisfy the accepted baseline; stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value =
        serde_json::from_slice(&fs::read(&report_path).expect("runner writes requested report"))
            .expect("valid runner report");
    assert_eq!(report["complete"], Value::Bool(false));
    assert_eq!(report["publishable"], Value::Bool(false));
    assert_eq!(report["regression"]["passed"], Value::Bool(false));
    assert_eq!(
        report["dataset"],
        Value::String("eval/work-memory/synthetic-v1.json".into())
    );
}

#[test]
fn work_memory_runner_rejects_baseline_bypass_before_invoking_benchmark() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .arg("--no-baseline")
        .output()
        .expect("run forbidden baseline bypass");

    assert!(!output.status.success());
    assert!(
        !fake_args_path.exists(),
        "baseline bypass must be rejected before benchmark execution"
    );
}

#[test]
fn work_memory_runner_rejects_every_caller_baseline_override_before_execution() {
    for (label, arguments) in [
        ("ordinary override", vec!["--baseline", "attacker.json"]),
        ("equals override", vec!["--baseline=attacker.json"]),
        (
            "update override",
            vec!["--update-baseline", "--baseline", "attacker.json"],
        ),
    ] {
        let dir = tempdir().expect("tempdir");
        let report = eligible_fake_baseline();
        let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);
        let output = Command::new(&script)
            .current_dir(dir.path())
            .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
            .env("MCI_ARCTIC_MODEL_PATH", dir.path())
            .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
            .env("MCI_FAKE_ARGS", &fake_args_path)
            .args(arguments)
            .output()
            .expect("run forbidden baseline override");

        assert!(!output.status.success(), "{label} must be rejected");
        assert!(
            !fake_args_path.exists(),
            "{label} must fail before benchmark execution"
        );
    }
}

#[test]
fn direct_binary_rejects_duplicate_baseline_arguments_before_writing_a_report() {
    let dataset = r#"{
      "dataset_id":"duplicate-baseline-fixture",
      "instances":[{
        "question_id":"q1",
        "question_type":"exact_recall",
        "question":"What moved?",
        "answer":"The benchmark moved.",
        "question_date":"2023/05/20 (Sat) 03:00",
        "haystack_dates":["2023/05/20 (Sat) 02:00"],
        "haystack_session_ids":["s1"],
        "haystack_sessions":[[{"role":"assistant","content":"The benchmark moved."}]]
      }]
    }"#;
    let (output, report) = run_bench(
        dataset,
        &[
            "--baseline",
            "first-baseline.json",
            "--baseline",
            "second-baseline.json",
        ],
    );

    assert_eq!(output.status.code(), Some(2));
    assert_eq!(
        report,
        Value::Null,
        "argument rejection must precede report output"
    );
}

#[test]
fn canonical_binary_rejects_an_exact_baseline_copy_and_clears_authority_booleans() {
    let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root");
    let dir = tempdir().expect("tempdir");
    let copied_baseline = dir.path().join("copied-accepted-baseline.json");
    fs::copy(
        repo_root.join("docs/eval/work-memory-baseline.json"),
        &copied_baseline,
    )
    .expect("copy accepted baseline");
    let report_path = dir.path().join("report.json");

    let output = Command::new(env!("CARGO_BIN_EXE_mci-bench"))
        .current_dir(&repo_root)
        .arg("--dataset")
        .arg("eval/work-memory/synthetic-v1.json")
        .arg("--arm")
        .arg("lexical")
        .arg("--baseline")
        .arg(&copied_baseline)
        .arg("--out")
        .arg(&report_path)
        .output()
        .expect("run canonical binary with copied baseline");

    assert_eq!(output.status.code(), Some(5));
    let report: Value =
        serde_json::from_slice(&fs::read(report_path).expect("report")).expect("valid report");
    assert_eq!(report["regression"]["passed"], Value::Bool(false));
    assert_eq!(report["complete"], Value::Bool(false));
    assert_eq!(report["publishable"], Value::Bool(false));
    assert_eq!(report["launch_qualified"], Value::Bool(false));
    assert!(report["regression"]["failures"]
        .as_array()
        .expect("failures")
        .iter()
        .any(|failure| failure
            .as_str()
            .is_some_and(|value| value.contains("accepted baseline path"))));
}

#[test]
fn work_memory_runner_requires_the_accepted_baseline_file() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);
    fs::remove_file(dir.path().join("docs/eval/work-memory-baseline.json"))
        .expect("remove accepted baseline fixture");

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .output()
        .expect("run without accepted baseline");

    assert!(!output.status.success());
    assert!(
        !fake_args_path.exists(),
        "missing baseline must fail before benchmark execution"
    );
}

#[test]
fn work_memory_runner_always_forwards_the_accepted_baseline() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);
    let output_path = dir.path().join("report.json");

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .arg("--out")
        .arg(&output_path)
        .output()
        .expect("run canonical runner");

    assert!(output.status.success());
    let args = fs::read_to_string(&fake_args_path).expect("captured benchmark arguments");
    let arguments = args.lines().collect::<Vec<_>>();
    assert_eq!(
        arguments
            .iter()
            .filter(|argument| **argument == "--baseline")
            .count(),
        1,
        "runner must forward exactly one baseline flag"
    );
    let baseline_index = arguments
        .iter()
        .position(|argument| *argument == "--baseline")
        .expect("baseline flag");
    assert_eq!(
        arguments.get(baseline_index + 1).copied(),
        Some("docs/eval/work-memory-baseline.json")
    );
}

#[test]
fn work_memory_runner_rejects_a_successful_override_that_produces_no_report() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, _) = stage_runner_fixture(dir.path(), &report);
    let output_path = dir.path().join("report.json");

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", "/usr/bin/true")
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .arg("--out")
        .arg(&output_path)
        .output()
        .expect("run canonical runner with a no-op benchmark override");

    assert!(
        !output.status.success(),
        "a zero exit without a canonical report must never pass"
    );
    assert!(
        !output_path.exists(),
        "the runner must not leave an absent or unvalidated report"
    );
}

#[test]
fn work_memory_runner_rejects_semantically_forged_override_reports() {
    let cases = [
        (
            "dataset digest",
            "/dataset_checksum_sha256",
            Value::String("00".repeat(32)),
        ),
        (
            "baseline provenance",
            "/run/arguments",
            serde_json::json!([
                "--dataset",
                "eval/work-memory/synthetic-v1.json",
                "--arm",
                "both",
                "--out",
                "external-report://fake-report.json"
            ]),
        ),
        (
            "completion truthfulness",
            "/regression/passed",
            Value::Bool(false),
        ),
        (
            "qualification truthfulness",
            "/quality_gate/passed",
            Value::Bool(false),
        ),
    ];

    for (label, pointer, replacement) in cases {
        let dir = tempdir().expect("tempdir");
        let mut report = eligible_fake_baseline();
        *report.pointer_mut(pointer).expect("fixture field") = replacement;
        let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);
        let output_path = dir.path().join("report.json");

        let output = Command::new(&script)
            .current_dir(dir.path())
            .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
            .env("MCI_ARCTIC_MODEL_PATH", dir.path())
            .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
            .env("MCI_FAKE_ARGS", &fake_args_path)
            .arg("--out")
            .arg(&output_path)
            .output()
            .expect("run canonical runner with forged report");

        assert!(!output.status.success(), "forged {label} must be rejected");
        assert!(
            !output_path.exists(),
            "forged {label} must not be installed as the canonical report"
        );
    }
}

#[test]
fn baseline_update_rejects_forwarded_dataset_overrides() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);
    let external_dataset = dir.path().join("external-empty.json");
    fs::write(
        &external_dataset,
        r#"{"dataset_id":"not-the-work-memory-corpus","instances":[]}"#,
    )
    .expect("write external dataset");
    let output_path = dir.path().join("published.json");

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .arg("--update-baseline")
        .arg("--out")
        .arg(&output_path)
        .arg("--dataset")
        .arg(&external_dataset)
        .output()
        .expect("run update mode with dataset override");

    assert!(
        !output.status.success(),
        "update mode must reject a forwarded dataset override"
    );
    assert!(
        !output_path.exists(),
        "a rejected override must not install a baseline"
    );
    assert!(
        !fake_args_path.exists(),
        "dataset overrides must be rejected before invoking the benchmark"
    );
}

#[test]
fn baseline_update_never_installs_an_invalid_corpus_report() {
    let dir = tempdir().expect("tempdir");
    let mut report = eligible_fake_baseline();
    report["dataset"] = Value::String("external-dataset://empty.json".into());
    report["dataset_id"] = Value::String("not-the-work-memory-corpus".into());
    report["run"]["original_instances"] = Value::from(0);
    report["run"]["evaluated_instances"] = Value::from(0);
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);
    let output_path = dir.path().join("published.json");
    fs::write(&output_path, "existing-baseline").expect("write protected output");

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .arg("--update-baseline")
        .arg("--out")
        .arg(&output_path)
        .output()
        .expect("run update mode with invalid report");

    assert!(
        !output.status.success(),
        "an invalid corpus report must fail baseline promotion"
    );
    assert_eq!(
        fs::read_to_string(&output_path).expect("protected output remains"),
        "existing-baseline",
        "invalid output must never replace an existing baseline"
    );
    assert!(
        !dir.path()
            .join("docs/eval/work-memory-baseline.next.json")
            .exists(),
        "invalid candidate artifacts must be cleaned up"
    );
}

#[test]
fn baseline_update_refreshes_the_single_pinned_digest() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);
    let baseline = dir.path().join("docs/eval/work-memory-baseline.json");
    let digest = dir.path().join("docs/eval/work-memory-baseline.sha256");

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .arg("--update-baseline")
        .output()
        .expect("update canonical baseline");

    assert!(
        output.status.success(),
        "eligible update must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let expected = Command::new("shasum")
        .args(["-a", "256"])
        .arg(&baseline)
        .output()
        .expect("hash installed baseline");
    assert!(expected.status.success());
    let expected = String::from_utf8(expected.stdout)
        .expect("utf-8 shasum")
        .split_whitespace()
        .next()
        .expect("digest")
        .to_owned();
    assert_eq!(
        fs::read_to_string(digest).expect("updated digest").trim(),
        expected,
        "baseline bytes and their single pinned authority must move together"
    );
}

#[test]
fn identity_change_is_allowed_only_during_explicit_baseline_update() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .arg("--accept-identity-change")
        .arg("--out")
        .arg(dir.path().join("report.json"))
        .output()
        .expect("run identity change outside update mode");

    assert!(!output.status.success());
    assert!(
        !fake_args_path.exists(),
        "identity migration must be rejected before benchmark execution"
    );
}

#[test]
fn explicit_baseline_identity_change_forwards_the_narrow_binary_policy() {
    let dir = tempdir().expect("tempdir");
    let report = eligible_fake_baseline();
    let (script, fake_args_path) = stage_runner_fixture(dir.path(), &report);

    let output = Command::new(&script)
        .current_dir(dir.path())
        .env("MCI_BENCH_BIN", dir.path().join("fake-mci-bench"))
        .env("MCI_ARCTIC_MODEL_PATH", dir.path())
        .env("MCI_FAKE_REPORT", dir.path().join("fake-report.json"))
        .env("MCI_FAKE_ARGS", &fake_args_path)
        .arg("--update-baseline")
        .arg("--accept-identity-change")
        .output()
        .expect("run explicit identity-changing baseline update");

    assert!(
        output.status.success(),
        "explicit identity update must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let args = fs::read_to_string(fake_args_path).expect("captured benchmark arguments");
    assert!(
        args.lines()
            .any(|argument| argument == "--allow-baseline-identity-migration"),
        "runner must forward only the binary's narrow migration policy"
    );
    assert!(!args
        .lines()
        .any(|argument| argument == "--accept-identity-change"));
}

#[test]
fn concurrent_scratch_runs_are_isolated_and_cleaned_on_drop() {
    let dir = tempdir().expect("tempdir");
    let base = dir.path().join("scratch");
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));

    let handles = ["first", "second"].map(|marker| {
        let base = base.clone();
        let barrier = std::sync::Arc::clone(&barrier);
        std::thread::spawn(move || {
            let run = ScratchRun::create(&base).expect("create unique scratch run");
            let path = run.path().to_path_buf();
            let db = path.join("same.sqlite");
            for suffix in ["", "-wal", "-shm"] {
                fs::write(path.join(format!("same.sqlite{suffix}")), marker)
                    .expect("write isolated database artifact");
            }
            barrier.wait();
            assert_eq!(
                fs::read_to_string(&db).expect("read own database marker"),
                marker,
                "concurrent runs must never share an instance database"
            );
            barrier.wait();
            path
        })
    });

    let first = handles[0].thread().id();
    let paths = handles
        .into_iter()
        .map(|handle| handle.join().expect("scratch thread"))
        .collect::<Vec<_>>();
    assert_ne!(paths[0], paths[1], "every run needs a unique directory");
    assert_ne!(
        first,
        std::thread::current().id(),
        "threads actually ran concurrently"
    );
    assert!(
        fs::read_dir(&base)
            .expect("scratch base remains")
            .next()
            .is_none(),
        "run directories must be removed when their guards drop"
    );
}

#[test]
fn failed_instances_leave_no_database_or_wal_artifacts() {
    let dataset = r#"{
      "dataset_id": "synthetic-v1-cleanup",
      "instances": [{
        "question_id": "failure-cleanup",
        "question_type": "temporal",
        "question": "What happened before the rollback?",
        "question_date": "not a timestamp",
        "answer_session_ids": ["terminal://zsh/session-19"],
        "haystack_dates": ["2026/08/31 (Mon) 11:55"],
        "haystack_session_ids": ["terminal://zsh/session-19"],
        "haystack_sessions": [[{
          "role": "assistant",
          "content": "The terminal session reverted the rollout and tailed agent logs."
        }]]
      }]
    }"#;
    let dir = tempdir().expect("tempdir");
    let scratch = dir.path().join("scratch");
    let scratch_arg = scratch.to_str().expect("utf-8 scratch path");

    let (output, report) = run_bench(dataset, &["--workdir", scratch_arg]);

    assert!(!output.status.success(), "the malformed date must fail");
    assert_eq!(report["complete"], Value::Bool(false));
    assert!(
        fs::read_dir(&scratch)
            .expect("scratch base remains")
            .next()
            .is_none(),
        "error returns must clean the database, WAL, SHM, and run directory"
    );
}

#[test]
fn reported_index_footprint_grows_with_indexed_content() {
    let large_body = format!("large-anchor {}", "distinct-index-payload ".repeat(40_000));
    let dataset = serde_json::json!({
        "dataset_id": "synthetic-v1-index-footprint",
        "instances": [
            {
                "question_id": "small-index",
                "question_type": "exact_recall",
                "question": "small-anchor",
                "question_date": "2026/08/31 (Mon) 12:00",
                "answer_session_ids": ["files:///small.txt"],
                "haystack_dates": ["2026/08/31 (Mon) 11:00"],
                "haystack_session_ids": ["files:///small.txt"],
                "haystack_sessions": [[{
                    "role": "assistant",
                    "content": "small-anchor"
                }]]
            },
            {
                "question_id": "large-index",
                "question_type": "exact_recall",
                "question": "large-anchor",
                "question_date": "2026/08/31 (Mon) 12:00",
                "answer_session_ids": ["files:///large.txt"],
                "haystack_dates": ["2026/08/31 (Mon) 11:00"],
                "haystack_session_ids": ["files:///large.txt"],
                "haystack_sessions": [[{
                    "role": "assistant",
                    "content": large_body
                }]]
            }
        ]
    });
    let serialized = serde_json::to_string(&dataset).expect("serialize size fixture");

    let (output, report) = run_bench(&serialized, &[]);

    assert!(
        output.status.success(),
        "size fixture must run; stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
    let results = report["results"].as_array().expect("instance results");
    let size_for = |question_id: &str| {
        results
            .iter()
            .find(|result| result["question_id"] == question_id)
            .and_then(|result| result["index_size_bytes"].as_u64())
            .expect("reported index size")
    };
    let small = size_for("small-index");
    let large = size_for("large-index");
    assert!(
        large > small,
        "real index footprint must grow with indexed content: small={small} large={large}"
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
