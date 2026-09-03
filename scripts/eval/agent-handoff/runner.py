#!/usr/bin/env python3
"""Score raw production-path observations for agent-handoff-v1."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import platform
import re
import subprocess
from collections import defaultdict
from typing import Any, Iterable


QUALITY_TARGETS = {
    "semantic_relevance_at_3_min": 0.90,
    "temporal_current_accuracy_min": 0.90,
    "superseded_exclusion_rate_min": 0.90,
    "contradiction_visibility_min": 0.80,
    "duplicate_ocr_suppression_min": 0.80,
    "exact_provenance_validity_min": 1.0,
    "abstention_accuracy_min": 0.80,
    "handoff_task_success_min": 0.75,
    "bounded_packet_rate_min": 1.0,
}
REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
CANONICAL_DATASET = "eval/agent-handoff/agent-handoff-v1.json"


def ratio(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def mean(values: Iterable[float]) -> float | None:
    materialized = list(values)
    return sum(materialized) / len(materialized) if materialized else None


def normalized(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip().lower()


def timestamp_us(value: str) -> int:
    parsed = datetime.datetime.strptime(value, "%Y/%m/%d (%a) %H:%M")
    return int(parsed.replace(tzinfo=datetime.timezone.utc).timestamp() * 1_000_000)


def expected_sources(case: dict[str, Any]) -> dict[str, dict[str, Any]]:
    sources: dict[str, dict[str, Any]] = {}
    for index, session_id in enumerate(case["haystack_session_ids"]):
        sources[session_id] = {
            "session_id": session_id,
            "ts_us": timestamp_us(case["haystack_dates"][index]),
            "app_bundle_id": case["haystack_app_ids"][index],
            "window_title": case["haystack_window_titles"][index],
            "url": case["haystack_urls"][index],
        }
    return sources


def citation_is_exact(citation: dict[str, Any], expected: dict[str, Any]) -> bool:
    return (
        isinstance(citation.get("event_id"), int)
        and citation["event_id"] > 0
        and citation.get("session_id") == expected["session_id"]
        and citation.get("ts_us") == expected["ts_us"]
        and citation.get("app_bundle_id") == expected["app_bundle_id"]
        and citation.get("window_title") == expected["window_title"]
        and citation.get("url") == expected["url"]
    )


def rank_of_any(ranked: list[str], expected: set[str]) -> int | None:
    for index, session_id in enumerate(ranked, start=1):
        if session_id in expected:
            return index
    return None


def score_case(case: dict[str, Any], raw: dict[str, Any]) -> dict[str, Any]:
    expectation = case["handoff_expectation"]
    packet = raw["packet"]
    ranked = raw["ranked_session_ids"]
    answer_sources = set(case["answer_session_ids"])
    required_sources = set(expectation["required_session_ids"])
    forbidden_sources = set(expectation["forbidden_session_ids"])
    contradiction_sources = set(expectation["contradiction_session_ids"])
    duplicate_sources = set(expectation["duplicate_session_ids"])
    citations = packet["citations"]
    cited_sources = {citation["session_id"] for citation in citations}
    packet_text = normalized(packet["text"])
    required_facts = expectation["required_facts"]
    present_facts = [fact for fact in required_facts if normalized(fact) in packet_text]
    source_map = expected_sources(case)

    provenance_checks = []
    for citation in citations:
        expected = source_map.get(citation.get("session_id"))
        provenance_checks.append(expected is not None and citation_is_exact(citation, expected))
    required_sources_present = required_sources.issubset(cited_sources)
    provenance_exact = required_sources_present and all(provenance_checks)
    first_hit_rank = rank_of_any(ranked, answer_sources)
    recall_at = {
        str(k): (
            None
            if case.get("unanswerable", False)
            else ratio(len(answer_sources.intersection(ranked[:k])), len(answer_sources))
        )
        for k in (1, 3, 5)
    }
    bounded = (
        packet["token_estimate"] <= expectation["max_tokens"]
        and len(citations) <= expectation["max_evidence"]
    )
    current_source_present = required_sources_present
    superseded_sources_excluded = current_source_present and not bool(
        forbidden_sources.intersection(cited_sources)
    )
    contradiction_visible = contradiction_sources.issubset(cited_sources)
    duplicate_citations = len(duplicate_sources.intersection(cited_sources))
    duplicate_suppressed = (
        duplicate_citations > 0
        and duplicate_citations <= expectation["max_duplicate_citations"]
    )
    facts_complete = len(present_facts) == len(required_facts)
    abstained = (
        raw["recall_disposition"] == "nothing_matched"
        and packet["focus_retrieval_status"] == "nothing_matched"
        and packet["outcome"] == "nothing_available"
        and not citations
    )
    handoff_complete = required_sources_present and facts_complete and bounded

    capability = case["capability"]
    capability_passed = {
        "semantic_relevance": (first_hit_rank is not None and first_hit_rank <= 3 and handoff_complete),
        "temporal_supersession": current_source_present and superseded_sources_excluded and facts_complete,
        "contradiction": contradiction_visible and facts_complete and bounded,
        "duplicate_ocr": duplicate_suppressed and facts_complete and bounded,
        "exact_provenance": required_sources_present and provenance_exact and facts_complete,
        "abstention": abstained,
        "handoff_utility": handoff_complete,
    }[capability]

    return {
        **raw,
        "capability": capability,
        "unanswerable": case.get("unanswerable", False),
        "answer_session_ids": case["answer_session_ids"],
        "first_hit_rank": first_hit_rank,
        "recall_at": recall_at,
        "required_sources_present": required_sources_present,
        "current_source_present": current_source_present,
        "superseded_sources_excluded": superseded_sources_excluded,
        "contradiction_visible": contradiction_visible,
        "duplicate_citations": duplicate_citations,
        "duplicate_ocr_suppressed": duplicate_suppressed,
        "facts_present": len(present_facts),
        "facts_required": len(required_facts),
        "facts_complete": facts_complete,
        "provenance_exact": provenance_exact,
        "abstained": abstained,
        "packet_bounded": bounded,
        "handoff_complete": handoff_complete,
        "capability_passed": capability_passed,
    }


def metric_for_capability(
    results: list[dict[str, Any]], capability: str, field: str
) -> float | None:
    eligible = [result for result in results if result["capability"] == capability]
    return ratio(sum(bool(result[field]) for result in eligible), len(eligible))


def score_arm(arm: str, results: list[dict[str, Any]]) -> dict[str, Any]:
    answerable = [result for result in results if not result["unanswerable"]]
    ranked_recall = {
        str(k): mean(
            value
            for result in answerable
            if (value := result["recall_at"][str(k)]) is not None
        )
        for k in (1, 3, 5)
    }
    hit_rate = {
        str(k): ratio(
            sum(
                result["first_hit_rank"] is not None and result["first_hit_rank"] <= k
                for result in answerable
            ),
            len(answerable),
        )
        for k in (1, 3, 5)
    }
    reciprocal_ranks = [
        0.0 if result["first_hit_rank"] is None else 1.0 / result["first_hit_rank"]
        for result in answerable
    ]
    fact_count = sum(result["facts_required"] for result in answerable)
    facts_present = sum(result["facts_present"] for result in answerable)

    metrics = {
        "hit_rate_at": hit_rate,
        "recall_at": ranked_recall,
        "mrr": mean(reciprocal_ranks),
        "semantic_relevance_at_3": metric_for_capability(
            results, "semantic_relevance", "capability_passed"
        ),
        "temporal_current_accuracy": metric_for_capability(
            results, "temporal_supersession", "current_source_present"
        ),
        "superseded_exclusion_rate": metric_for_capability(
            results, "temporal_supersession", "superseded_sources_excluded"
        ),
        "contradiction_visibility": metric_for_capability(
            results, "contradiction", "contradiction_visible"
        ),
        "duplicate_ocr_suppression": metric_for_capability(
            results, "duplicate_ocr", "duplicate_ocr_suppressed"
        ),
        "exact_provenance_validity": metric_for_capability(
            results, "exact_provenance", "provenance_exact"
        ),
        "abstention_accuracy": metric_for_capability(
            results, "abstention", "abstained"
        ),
        "handoff_task_success": metric_for_capability(
            results, "handoff_utility", "handoff_complete"
        ),
        "handoff_fact_coverage": ratio(facts_present, fact_count),
        "bounded_packet_rate": ratio(
            sum(result["packet_bounded"] for result in results), len(results)
        ),
        "capability_pass_rate": ratio(
            sum(result["capability_passed"] for result in results), len(results)
        ),
    }
    failures = []
    for target_name, threshold in QUALITY_TARGETS.items():
        metric_name = target_name.removesuffix("_min")
        value = metrics[metric_name]
        if value is not None and value < threshold:
            failures.append(f"{metric_name} {value:.4f} is below {threshold:.4f}")
    return {
        "arm": arm,
        "tasks": len(results),
        "answerable_tasks": len(answerable),
        "unanswerable_tasks": len(results) - len(answerable),
        "metrics": metrics,
        "quality_gate": {"passed": not failures, "failures": failures},
    }


def build_report(
    corpus: dict[str, Any], raw_report: dict[str, Any], run_metadata: dict[str, Any]
) -> dict[str, Any]:
    cases = {case["question_id"]: case for case in corpus["instances"]}
    scored = []
    failures = []
    for row in raw_report["cases"]:
        case = cases.get(row["question_id"])
        if case is None:
            failures.append(f"unknown raw case {row['question_id']}")
            continue
        try:
            scored.append(score_case(case, row))
        except (KeyError, TypeError, ValueError) as error:
            failures.append(f"{row['question_id']} ({row.get('arm', 'unknown')}): {error}")

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for result in scored:
        grouped[result["arm"]].append(result)
    arms = [score_arm(arm, grouped[arm]) for arm in sorted(grouped)]
    expected_rows = corpus["task_count"] * len(grouped)
    complete = not failures and len(scored) == expected_rows
    handoff_gate = complete and all(arm["quality_gate"]["passed"] for arm in arms)
    return {
        "schema_version": 1,
        "dataset": run_metadata.get("dataset", CANONICAL_DATASET),
        "dataset_id": corpus["dataset_id"],
        "task_count": corpus["task_count"],
        "surface": raw_report["surface"],
        "measurement_boundary": "retrieval_and_context_handoff_not_answer_generation",
        "trusted_answer_qualified": False,
        "retrieval_and_handoff_qualified": handoff_gate,
        "complete": complete,
        "publishable": (
            complete
            and run_metadata.get("dataset") == CANONICAL_DATASET
            and run_metadata.get("benchmark_scope_dirty_at_start") is False
            and isinstance(run_metadata.get("dataset_checksum_sha256"), str)
            and (
                all(arm["arm"] == "lexical" for arm in arms)
                or isinstance(run_metadata.get("model_checksum_sha256"), str)
            )
        ),
        "run": run_metadata,
        "quality_targets": QUALITY_TARGETS,
        "arms": arms,
        "failures": failures,
        "results": scored,
    }


def write_report(path: pathlib.Path, report: dict[str, Any]) -> None:
    path.write_text(json.dumps(report, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_path(path: pathlib.Path) -> str:
    if path.is_file():
        return sha256_file(path)
    digest = hashlib.sha256()
    for child in sorted(value for value in path.rglob("*") if value.is_file()):
        digest.update(str(child.relative_to(path)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(child).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def command_value(arguments: list[str]) -> str:
    completed = subprocess.run(
        arguments,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    return completed.stdout.strip() if completed.returncode == 0 else "unknown"


def git_dirty(paths: list[str] | None = None) -> bool:
    arguments = ["git", "status", "--porcelain", "--untracked-files=all"]
    if paths:
        arguments.extend(["--", *paths])
    completed = subprocess.run(
        arguments,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    return completed.returncode != 0 or bool(completed.stdout)


def logical_path(path: pathlib.Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        if str(resolved).startswith("/Applications/Hippocampus.app/"):
            return f"installed-model://{resolved.name}"
        return f"external-dataset://{resolved.name}"


def collect_metadata(
    dataset_path: pathlib.Path,
    command: str,
    model_path: pathlib.Path | None,
) -> dict[str, Any]:
    scope_paths = [
        "apps/agent",
        "core/brain",
        "core/src",
        "adapters/macos/mci-embed-coreml",
        "eval/agent-handoff",
        "scripts/eval/agent-handoff",
        "Cargo.toml",
    ]
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    metadata: dict[str, Any] = {
        "captured_at_utc": now.isoformat().replace("+00:00", "Z"),
        "git_commit": command_value(["git", "rev-parse", "HEAD"]),
        "branch": command_value(["git", "branch", "--show-current"]),
        "repository_dirty_at_start": git_dirty(),
        "benchmark_scope_dirty_at_start": git_dirty(scope_paths),
        "command": command,
        "dataset": logical_path(dataset_path),
        "dataset_checksum_sha256": sha256_file(dataset_path),
        "python_version": platform.python_version(),
        "os": platform.platform(),
        "architecture": platform.machine(),
        "model_path": None,
        "model_checksum_sha256": None,
    }
    if model_path is not None:
        metadata["model_path"] = logical_path(model_path)
        metadata["model_checksum_sha256"] = sha256_path(model_path)
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, type=pathlib.Path)
    parser.add_argument("--raw", required=True, type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--command", required=True)
    parser.add_argument("--model-path", type=pathlib.Path)
    arguments = parser.parse_args()
    corpus = json.loads(arguments.dataset.read_text(encoding="utf-8"))
    raw_report = json.loads(arguments.raw.read_text(encoding="utf-8"))
    metadata = collect_metadata(arguments.dataset, arguments.command, arguments.model_path)
    report = build_report(corpus, raw_report, metadata)
    write_report(arguments.out, report)
    return 0 if report["complete"] else 5


if __name__ == "__main__":
    raise SystemExit(main())
