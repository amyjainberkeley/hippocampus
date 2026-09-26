#!/usr/bin/env python3

import json
import importlib.util
import datetime
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import unittest
from types import ModuleType


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
CORPUS_PATH = REPO_ROOT / "eval/agent-handoff/agent-handoff-v1.json"
RUNNER_PATH = REPO_ROOT / "scripts/eval/agent-handoff/runner.py"
RESULT_PATH = REPO_ROOT / "docs/eval/agent-handoff-v1-result.json"
RESULT_SHA_PATH = REPO_ROOT / "docs/eval/agent-handoff-v1-result.sha256"


def load_runner() -> ModuleType:
    if not RUNNER_PATH.is_file():
        raise AssertionError("agent-handoff scorer is missing")
    spec = importlib.util.spec_from_file_location("agent_handoff_runner", RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("agent-handoff scorer cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_case(capability: str, *, unanswerable: bool = False) -> dict:
    sources = [
        {
            "session_id": "source://current",
            "date": "2026/09/02 (Wed) 12:00",
            "app_bundle_id": "com.example.source",
            "window_title": "Current source",
            "url": "source://current",
            "text": "Current fact is green.",
        },
        {
            "session_id": "source://old",
            "date": "2026/09/01 (Tue) 12:00",
            "app_bundle_id": "com.example.source",
            "window_title": "Old source",
            "url": "source://old",
            "text": "Old fact is red.",
        },
    ]
    answer_ids = [] if unanswerable else ["source://current"]
    return {
        "question_id": f"fixture-{capability}",
        "question_type": capability,
        "capability": capability,
        "question": "What is current?",
        "question_date": "2026/09/02 (Wed) 18:00",
        "answer_session_ids": answer_ids,
        "haystack_dates": [source["date"] for source in sources],
        "haystack_session_ids": [source["session_id"] for source in sources],
        "haystack_app_ids": [source["app_bundle_id"] for source in sources],
        "haystack_window_titles": [source["window_title"] for source in sources],
        "haystack_urls": [source["url"] for source in sources],
        "haystack_sessions": [[{"role": "assistant", "content": source["text"]}] for source in sources],
        "tags": [capability],
        "unanswerable": unanswerable,
        "handoff_expectation": {
            "required_facts": [] if unanswerable else ["Current fact is green"],
            "required_session_ids": answer_ids,
            "forbidden_session_ids": ["source://old"] if capability == "temporal_supersession" else [],
            "contradiction_session_ids": ["source://current", "source://old"] if capability == "contradiction" else [],
            "duplicate_session_ids": ["source://current", "source://old"] if capability == "duplicate_ocr" else [],
            "max_duplicate_citations": 1 if capability == "duplicate_ocr" else 0,
            "expect_abstention": unanswerable,
            "max_tokens": 128,
            "max_evidence": 4,
        },
    }


def fixture_row(case: dict, *, include_old: bool = False) -> dict:
    cited = [] if case.get("unanswerable") else ["source://current"]
    if include_old:
        cited.append("source://old")
    citations = []
    for session_id in cited:
        index = case["haystack_session_ids"].index(session_id)
        citations.append(
            {
                "event_id": index + 1,
                "session_id": session_id,
                "ts_us": int(
                    datetime.datetime.strptime(
                        case["haystack_dates"][index], "%Y/%m/%d (%a) %H:%M"
                    )
                    .replace(tzinfo=datetime.timezone.utc)
                    .timestamp()
                    * 1_000_000
                ),
                "app_bundle_id": case["haystack_app_ids"][index],
                "window_title": case["haystack_window_titles"][index],
                "url": case["haystack_urls"][index],
            }
        )
    text = "" if case.get("unanswerable") else "Current fact is green."
    if include_old:
        text += " Old fact is red."
    return {
        "question_id": case["question_id"],
        "arm": "hybrid",
        "recall_disposition": "nothing_matched" if case.get("unanswerable") else "degraded",
        "recall_reason": "evidence_floor" if case.get("unanswerable") else "evidence_sufficiency_unqualified",
        "ranked_session_ids": [] if case.get("unanswerable") else cited,
        "packet": {
            "outcome": "nothing_available" if case.get("unanswerable") else "observations_only",
            "focus_retrieval_status": "nothing_matched" if case.get("unanswerable") else "degraded",
            "focus_retrieval_reason": "evidence_floor" if case.get("unanswerable") else "evidence_sufficiency_unqualified",
            "token_estimate": 12,
            "byte_estimate": len(text),
            "truncated": False,
            "text": text,
            "citations": citations,
        },
    }


class CorpusContractTests(unittest.TestCase):
    def test_corpus_has_36_tasks_across_the_locked_capability_axes(self) -> None:
        self.assertTrue(CORPUS_PATH.is_file(), "agent-handoff-v1 corpus is missing")
        corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))

        self.assertEqual(corpus["dataset_id"], "synthetic-agent-handoff-v1")
        self.assertEqual(corpus["task_count"], 36)
        self.assertFalse(corpus["trusted_answer_qualified"])
        self.assertEqual(len(corpus["instances"]), 36)
        self.assertEqual(
            corpus["capabilities"],
            [
                "semantic_relevance",
                "temporal_supersession",
                "contradiction",
                "duplicate_ocr",
                "exact_provenance",
                "abstention",
                "handoff_utility",
            ],
        )

        expected_counts = {
            "semantic_relevance": 6,
            "temporal_supersession": 6,
            "contradiction": 5,
            "duplicate_ocr": 5,
            "exact_provenance": 5,
            "abstention": 5,
            "handoff_utility": 4,
        }
        actual_counts = {capability: 0 for capability in expected_counts}
        seen_ids: set[str] = set()
        for instance in corpus["instances"]:
            task_id = instance["question_id"]
            self.assertNotIn(task_id, seen_ids)
            seen_ids.add(task_id)
            actual_counts[instance["capability"]] += 1
            self.assertEqual(len(instance["haystack_sessions"]), len(instance["haystack_session_ids"]))
            self.assertEqual(len(instance["haystack_sessions"]), len(instance["haystack_dates"]))
            self.assertEqual(len(instance["haystack_sessions"]), len(instance["haystack_app_ids"]))
            self.assertEqual(len(instance["haystack_sessions"]), len(instance["haystack_window_titles"]))
            self.assertEqual(len(instance["haystack_sessions"]), len(instance["haystack_urls"]))
            self.assertIn("handoff_expectation", instance)

        self.assertEqual(actual_counts, expected_counts)

    def test_unanswerable_tasks_carry_no_answer_sources_or_required_facts(self) -> None:
        self.assertTrue(CORPUS_PATH.is_file(), "agent-handoff-v1 corpus is missing")
        corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))

        unanswerable = [case for case in corpus["instances"] if case.get("unanswerable", False)]
        self.assertEqual(len(unanswerable), 5)
        for case in unanswerable:
            self.assertEqual(case["capability"], "abstention")
            self.assertEqual(case["answer_session_ids"], [])
            self.assertEqual(case["handoff_expectation"]["required_facts"], [])
            self.assertTrue(case["handoff_expectation"]["expect_abstention"])

    def test_accepted_result_is_complete_pinned_and_never_answer_qualified(self) -> None:
        self.assertTrue(RESULT_PATH.is_file())
        self.assertTrue(RESULT_SHA_PATH.is_file())
        expected_digest = RESULT_SHA_PATH.read_text(encoding="utf-8").strip()
        actual_digest = hashlib.sha256(RESULT_PATH.read_bytes()).hexdigest()
        self.assertEqual(actual_digest, expected_digest)

        result = json.loads(RESULT_PATH.read_text(encoding="utf-8"))
        self.assertTrue(result["complete"])
        self.assertTrue(result["publishable"])
        self.assertFalse(result["trusted_answer_qualified"])
        all_arm_gates_pass = all(arm["quality_gate"]["passed"] for arm in result["arms"])
        self.assertEqual(result["retrieval_and_handoff_qualified"], all_arm_gates_pass)
        self.assertEqual(result["task_count"], 36)
        self.assertEqual(len(result["results"]), 72)
        self.assertEqual([arm["arm"] for arm in result["arms"]], ["hybrid", "lexical"])
        self.assertFalse(result["run"]["benchmark_scope_dirty_at_start"])


class ScoringContractTests(unittest.TestCase):
    def test_report_scores_all_axes_without_claiming_trusted_answers(self) -> None:
        runner = load_runner()
        capabilities = [
            "semantic_relevance",
            "temporal_supersession",
            "contradiction",
            "duplicate_ocr",
            "exact_provenance",
            "abstention",
            "handoff_utility",
        ]
        cases = [fixture_case(value, unanswerable=value == "abstention") for value in capabilities]
        rows = []
        for case in cases:
            include_old = case["capability"] == "contradiction"
            rows.append(fixture_row(case, include_old=include_old))
        corpus = {
            "dataset_id": "synthetic-agent-handoff-v1",
            "task_count": len(cases),
            "capabilities": capabilities,
            "trusted_answer_qualified": False,
            "instances": cases,
        }

        report = runner.build_report(corpus, {"surface": "fixture", "cases": rows}, {"fixture": True})

        self.assertFalse(report["trusted_answer_qualified"])
        self.assertEqual(report["measurement_boundary"], "retrieval_and_context_handoff_not_answer_generation")
        metrics = report["arms"][0]["metrics"]
        self.assertEqual(metrics["semantic_relevance_at_3"], 1.0)
        self.assertEqual(metrics["temporal_current_accuracy"], 1.0)
        self.assertEqual(metrics["superseded_exclusion_rate"], 1.0)
        self.assertEqual(metrics["contradiction_visibility"], 1.0)
        self.assertEqual(metrics["duplicate_ocr_suppression"], 1.0)
        self.assertEqual(metrics["exact_provenance_validity"], 1.0)
        self.assertEqual(metrics["abstention_accuracy"], 1.0)
        self.assertEqual(metrics["handoff_task_success"], 1.0)

    def test_temporal_metric_fails_when_superseded_source_leaks_into_packet(self) -> None:
        runner = load_runner()
        case = fixture_case("temporal_supersession")
        report = runner.build_report(
            {
                "dataset_id": "synthetic-agent-handoff-v1",
                "task_count": 1,
                "capabilities": ["temporal_supersession"],
                "trusted_answer_qualified": False,
                "instances": [case],
            },
            {"surface": "fixture", "cases": [fixture_row(case, include_old=True)]},
            {"fixture": True},
        )

        result = report["results"][0]
        self.assertTrue(result["current_source_present"])
        self.assertFalse(result["superseded_sources_excluded"])
        self.assertFalse(result["capability_passed"])

    def test_provenance_metric_compares_exact_source_metadata(self) -> None:
        runner = load_runner()
        case = fixture_case("exact_provenance")
        row = fixture_row(case)
        row["packet"]["citations"][0]["url"] = "source://invented"
        report = runner.build_report(
            {
                "dataset_id": "synthetic-agent-handoff-v1",
                "task_count": 1,
                "capabilities": ["exact_provenance"],
                "trusted_answer_qualified": False,
                "instances": [case],
            },
            {"surface": "fixture", "cases": [row]},
            {"fixture": True},
        )

        self.assertEqual(report["arms"][0]["metrics"]["exact_provenance_validity"], 0.0)
        self.assertFalse(report["results"][0]["provenance_exact"])

    def test_cli_writes_a_checksummed_report_with_locked_trust_boundary(self) -> None:
        case = fixture_case("abstention", unanswerable=True)
        corpus = {
            "dataset_id": "synthetic-agent-handoff-v1",
            "task_count": 1,
            "capabilities": ["abstention"],
            "trusted_answer_qualified": False,
            "instances": [case],
        }
        raw = {"surface": "fixture", "cases": [fixture_row(case)]}
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            corpus_path = root / "corpus.json"
            raw_path = root / "raw.json"
            out_path = root / "report.json"
            corpus_path.write_text(json.dumps(corpus), encoding="utf-8")
            raw_path.write_text(json.dumps(raw), encoding="utf-8")

            completed = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--dataset",
                    str(corpus_path),
                    "--raw",
                    str(raw_path),
                    "--out",
                    str(out_path),
                    "--command",
                    "fixture command",
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(out_path.is_file())
            report = json.loads(out_path.read_text(encoding="utf-8"))
            self.assertFalse(report["trusted_answer_qualified"])
            self.assertEqual(len(report["run"]["dataset_checksum_sha256"]), 64)
            self.assertEqual(report["run"]["command"], "fixture command")


if __name__ == "__main__":
    unittest.main()
