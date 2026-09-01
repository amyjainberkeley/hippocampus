use std::fs;
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
          "question": "Which nebula codename unlocked the vinyl koala?",
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
    assert_eq!(report["failures"].as_array().map(Vec::len), Some(1));
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
    let baseline = r#"{
      "dataset_id": "synthetic-v1-baseline-check",
      "regression_thresholds": {
        "lexical": {
          "hit_rate_at_1_min": 0.95,
          "mrr_min": 0.95,
          "false_positive_rate_at_1_max": 0.05
        }
      }
    }"#;

    let dir = tempdir().expect("tempdir");
    let baseline_path = dir.path().join("baseline.json");
    fs::write(&baseline_path, baseline).expect("write baseline");

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
