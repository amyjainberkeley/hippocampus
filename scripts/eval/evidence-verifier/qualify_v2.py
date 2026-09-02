#!/usr/bin/env python3
"""Validate and score evidence-verifier v2 verdicts without loading a model."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SPLITS = ("fit", "calibration", "validation")
VERDICTS = ("supported", "contradicted", "insufficient")
REQUIRED_CATEGORIES = (
    "direct_answer",
    "paraphrase_coreference",
    "temporal_update",
    "contradiction",
    "cross_document_synthesis",
    "provenance_enforcement",
    "absent_answer",
    "concrete_distractor",
)
REQUIRED_METRICS = {
    "minimum_validation_support_coverage",
    "minimum_validation_contradiction_coverage",
    "maximum_validation_insufficient_false_positive_rate",
    "minimum_validation_provenance_validity",
    "minimum_validation_metamorphic_consistency",
}


class ContractError(ValueError):
    """Raised when input cannot be interpreted safely."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def require_object(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_array(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and bool(value.strip()), f"{label} must be a non-empty string")
    return value


def require_unique_strings(value: Any, label: str, *, allow_empty: bool = False) -> list[str]:
    items = require_array(value, label)
    if not allow_empty:
        require(bool(items), f"{label} must not be empty")
    for index, item in enumerate(items):
        require_string(item, f"{label}[{index}]")
    require(len(items) == len(set(items)), f"{label} must not contain duplicates")
    return items


def normalized_text(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip()).casefold()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ContractError(f"file not found: {path}") from error
    except json.JSONDecodeError as error:
        raise ContractError(f"invalid JSON in {path}: {error}") from error
    return require_object(value, str(path))


def corpus_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_lock(corpus_path: Path, lock_path: Path | None) -> str:
    digest = corpus_sha256(corpus_path)
    resolved = lock_path or corpus_path.with_suffix(corpus_path.suffix + ".sha256")
    try:
        fields = resolved.read_text(encoding="ascii").strip().split()
    except FileNotFoundError as error:
        raise ContractError(f"corpus lock not found: {resolved}") from error
    require(len(fields) in {1, 2}, f"invalid corpus lock format: {resolved}")
    require(re.fullmatch(r"[0-9a-f]{64}", fields[0]) is not None, f"invalid SHA-256 in {resolved}")
    if len(fields) == 2:
        require(fields[1].lstrip("*") == corpus_path.name, f"lock filename does not match {corpus_path.name}")
    require(fields[0] == digest, f"corpus lock mismatch for {corpus_path}")
    return digest


def validate_corpus(data: dict[str, Any]) -> dict[str, Any]:
    require(data.get("schema_version") == 2, "corpus schema_version must be 2")
    dataset_id = require_string(data.get("dataset_id"), "corpus.dataset_id")

    thresholds = require_object(data.get("qualification_thresholds"), "corpus.qualification_thresholds")
    require(set(thresholds) == REQUIRED_METRICS, "qualification_thresholds has missing or unknown metrics")
    for name, value in thresholds.items():
        require(isinstance(value, (int, float)) and not isinstance(value, bool), f"threshold {name} must be numeric")
        require(0.0 <= float(value) <= 1.0, f"threshold {name} must be between 0 and 1")

    categories = require_unique_strings(data.get("required_categories"), "corpus.required_categories")
    require(
        set(categories) == set(REQUIRED_CATEGORIES) and len(categories) == len(REQUIRED_CATEGORIES),
        "corpus.required_categories must contain the complete v2 category contract",
    )
    evidence_rows = require_array(data.get("evidence"), "corpus.evidence")
    case_rows = require_array(data.get("cases"), "corpus.cases")
    pair_rows = require_array(data.get("metamorphic_pairs"), "corpus.metamorphic_pairs")
    require(bool(evidence_rows), "corpus.evidence must not be empty")
    require(bool(case_rows), "corpus.cases must not be empty")

    evidence: dict[str, dict[str, Any]] = {}
    normalized_evidence_by_split: dict[str, set[str]] = defaultdict(set)
    for index, raw in enumerate(evidence_rows):
        row = require_object(raw, f"corpus.evidence[{index}]")
        evidence_id = require_string(row.get("id"), f"corpus.evidence[{index}].id")
        require(evidence_id not in evidence, f"duplicate evidence ID: {evidence_id}")
        require_string(row.get("scenario_id"), f"evidence {evidence_id}.scenario_id")
        require_string(row.get("source_id"), f"evidence {evidence_id}.source_id")
        text = require_string(row.get("text"), f"evidence {evidence_id}.text")
        require(text == text.strip(), f"evidence {evidence_id}.text must preserve exact trimmed source text")
        evidence[evidence_id] = row

    cases: dict[str, dict[str, Any]] = {}
    scenario_splits: dict[str, str] = {}
    split_categories: dict[str, set[str]] = defaultdict(set)
    split_counts: Counter[str] = Counter()
    scenario_evidence: dict[str, set[str]] = defaultdict(set)
    query_occurrences: dict[str, list[str]] = defaultdict(list)
    case_to_split: dict[str, str] = {}
    for index, raw in enumerate(case_rows):
        case = require_object(raw, f"corpus.cases[{index}]")
        case_id = require_string(case.get("id"), f"corpus.cases[{index}].id")
        require(case_id not in cases, f"duplicate case ID: {case_id}")
        scenario_id = require_string(case.get("scenario_id"), f"case {case_id}.scenario_id")
        split = require_string(case.get("split"), f"case {case_id}.split")
        require(split in SPLITS, f"case {case_id} has unknown split: {split}")
        previous_split = scenario_splits.setdefault(scenario_id, split)
        require(previous_split == split, f"scenario {scenario_id} crosses {previous_split} and {split}")
        category = require_string(case.get("category"), f"case {case_id}.category")
        require(category in categories, f"case {case_id} has unknown category: {category}")
        query = require_string(case.get("query"), f"case {case_id}.query")
        candidate_ids = require_unique_strings(case.get("candidate_ids"), f"case {case_id}.candidate_ids")
        for evidence_id in candidate_ids:
            require(evidence_id in evidence, f"case {case_id} cites missing candidate {evidence_id}")
            evidence_scenario = evidence[evidence_id]["scenario_id"]
            require(
                evidence_scenario == scenario_id,
                f"case {case_id} leaks evidence from scenario {evidence_scenario}",
            )
            scenario_evidence[scenario_id].add(evidence_id)

        expected = require_object(case.get("expected"), f"case {case_id}.expected")
        expected_verdict = require_string(expected.get("verdict"), f"case {case_id}.expected.verdict")
        require(expected_verdict in VERDICTS, f"case {case_id} has unknown expected verdict")
        required_sets = require_array(
            expected.get("required_citation_sets"),
            f"case {case_id}.expected.required_citation_sets",
        )
        if expected_verdict == "insufficient":
            require(not required_sets, f"insufficient case {case_id} must not require citations")
        else:
            require(bool(required_sets), f"{expected_verdict} case {case_id} requires evidence citations")
            canonical_sets: set[tuple[str, ...]] = set()
            for set_index, raw_set in enumerate(required_sets):
                citation_set = require_unique_strings(
                    raw_set,
                    f"case {case_id}.required_citation_sets[{set_index}]",
                )
                require(set(citation_set) <= set(candidate_ids), f"case {case_id} requires a non-candidate citation")
                canonical = tuple(sorted(citation_set))
                require(canonical not in canonical_sets, f"case {case_id} repeats a required citation set")
                canonical_sets.add(canonical)

        cases[case_id] = case
        case_to_split[case_id] = split
        split_categories[split].add(category)
        split_counts[split] += 1
        query_occurrences[normalized_text(query)].append(case_id)

    require(set(split_counts) == set(SPLITS), "corpus must contain fit, calibration, and validation cases")
    for split in SPLITS:
        missing = sorted(set(categories) - split_categories[split])
        require(not missing, f"split {split} is missing categories: {', '.join(missing)}")

    evidence_splits: dict[str, str] = {}
    referenced_evidence: set[str] = set()
    for case in cases.values():
        split = case["split"]
        for evidence_id in case["candidate_ids"]:
            referenced_evidence.add(evidence_id)
            prior = evidence_splits.setdefault(evidence_id, split)
            require(prior == split, f"evidence {evidence_id} crosses {prior} and {split}")
            normalized_evidence_by_split[split].add(normalized_text(evidence[evidence_id]["text"]))
    unreferenced = sorted(set(evidence) - referenced_evidence)
    require(not unreferenced, f"unreferenced evidence IDs: {', '.join(unreferenced)}")
    for first_index, first in enumerate(SPLITS):
        for second in SPLITS[first_index + 1 :]:
            overlap = normalized_evidence_by_split[first] & normalized_evidence_by_split[second]
            require(not overlap, f"evidence text is duplicated across {first} and {second}")

    pairs: dict[str, dict[str, Any]] = {}
    paired_case_sets: set[frozenset[str]] = set()
    for index, raw in enumerate(pair_rows):
        pair = require_object(raw, f"corpus.metamorphic_pairs[{index}]")
        pair_id = require_string(pair.get("id"), f"corpus.metamorphic_pairs[{index}].id")
        require(pair_id not in pairs, f"duplicate metamorphic pair ID: {pair_id}")
        require(pair.get("relation") == "candidate_order_invariant", f"pair {pair_id} has unknown relation")
        base_id = require_string(pair.get("base_case_id"), f"pair {pair_id}.base_case_id")
        variant_id = require_string(pair.get("variant_case_id"), f"pair {pair_id}.variant_case_id")
        require(base_id in cases and variant_id in cases, f"pair {pair_id} references an unknown case")
        require(base_id != variant_id, f"pair {pair_id} must reference two cases")
        base = cases[base_id]
        variant = cases[variant_id]
        for field in ("scenario_id", "split", "category", "query", "expected"):
            require(base[field] == variant[field], f"pair {pair_id} differs in {field}")
        require(set(base["candidate_ids"]) == set(variant["candidate_ids"]), f"pair {pair_id} changes candidates")
        require(base["candidate_ids"] != variant["candidate_ids"], f"pair {pair_id} does not reorder candidates")
        case_set = frozenset((base_id, variant_id))
        require(case_set not in paired_case_sets, f"duplicate metamorphic case pair: {pair_id}")
        paired_case_sets.add(case_set)
        pairs[pair_id] = pair

    for split in SPLITS:
        pair_verdicts = {
            cases[pair["base_case_id"]]["expected"]["verdict"]
            for pair in pairs.values()
            if cases[pair["base_case_id"]]["split"] == split
        }
        require(
            {"supported", "insufficient"} <= pair_verdicts,
            f"split {split} must have supported and insufficient candidate-order metamorphic pairs",
        )
    for query, duplicate_ids in query_occurrences.items():
        if len(duplicate_ids) == 1:
            continue
        require(
            frozenset(duplicate_ids) in paired_case_sets,
            f"duplicate query is not one declared metamorphic pair: {query}",
        )

    return {
        "dataset_id": dataset_id,
        "thresholds": {name: float(value) for name, value in thresholds.items()},
        "categories": categories,
        "evidence": evidence,
        "cases": cases,
        "pairs": pairs,
        "split_counts": dict(split_counts),
        "scenario_counts": dict(Counter(scenario_splits.values())),
    }


def validate_verdicts(data: dict[str, Any], corpus: dict[str, Any]) -> dict[str, dict[str, Any]]:
    require(data.get("schema_version") == 1, "verdict schema_version must be 1")
    require(data.get("dataset_id") == corpus["dataset_id"], "verdict dataset_id does not match corpus")
    system = require_object(data.get("system"), "verdicts.system")
    require_string(system.get("name"), "verdicts.system.name")
    require_string(system.get("version"), "verdicts.system.version")
    rows = require_array(data.get("verdicts"), "verdicts.verdicts")
    indexed: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(rows):
        row = require_object(raw, f"verdicts.verdicts[{index}]")
        case_id = require_string(row.get("case_id"), f"verdicts.verdicts[{index}].case_id")
        require(case_id in corpus["cases"], f"verdict file contains unknown case: {case_id}")
        require(case_id not in indexed, f"verdict file repeats case: {case_id}")
        verdict = require_string(row.get("verdict"), f"verdict {case_id}.verdict")
        require(verdict in VERDICTS, f"verdict {case_id} has unknown verdict: {verdict}")
        citations = require_unique_strings(
            row.get("citations"),
            f"verdict {case_id}.citations",
            allow_empty=True,
        )
        indexed[case_id] = {"case_id": case_id, "verdict": verdict, "citations": citations}
    missing = sorted(set(corpus["cases"]) - set(indexed))
    require(not missing, f"verdict file is missing cases: {', '.join(missing)}")
    return indexed


def exact_required_citation_match(case: dict[str, Any], citations: list[str]) -> bool:
    required = case["expected"]["required_citation_sets"]
    return any(set(citations) == set(allowed) for allowed in required)


def provenance_failure(case: dict[str, Any], row: dict[str, Any], known_evidence: set[str]) -> str | None:
    citations = row["citations"]
    invented = sorted(set(citations) - known_evidence)
    if invented:
        return f"case {case['id']} used invented citation(s): {', '.join(invented)}"
    outside_candidates = sorted(set(citations) - set(case["candidate_ids"]))
    if outside_candidates:
        return f"case {case['id']} cited non-candidate evidence: {', '.join(outside_candidates)}"
    if row["verdict"] == "insufficient":
        if citations:
            return f"case {case['id']} returned insufficient with citations"
        return None
    if row["verdict"] != case["expected"]["verdict"]:
        return f"case {case['id']} cannot substantiate incorrect verdict {row['verdict']}"
    if not exact_required_citation_match(case, citations):
        return f"case {case['id']} did not cite one exact required evidence set"
    return None


def ratio(numerator: int, denominator: int, label: str) -> float:
    require(denominator > 0, f"cannot compute {label}: denominator is zero")
    return numerator / denominator


def score_split(
    split: str,
    corpus: dict[str, Any],
    verdicts: dict[str, dict[str, Any]],
    provenance: dict[str, str | None],
) -> dict[str, Any]:
    cases = [case for case in corpus["cases"].values() if case["split"] == split]
    support = [case for case in cases if case["expected"]["verdict"] == "supported"]
    contradiction = [case for case in cases if case["expected"]["verdict"] == "contradicted"]
    insufficient = [case for case in cases if case["expected"]["verdict"] == "insufficient"]
    pairs = [
        pair
        for pair in corpus["pairs"].values()
        if corpus["cases"][pair["base_case_id"]]["split"] == split
    ]

    support_hits = sum(
        verdicts[case["id"]]["verdict"] == "supported" and provenance[case["id"]] is None
        for case in support
    )
    contradiction_hits = sum(
        verdicts[case["id"]]["verdict"] == "contradicted" and provenance[case["id"]] is None
        for case in contradiction
    )
    insufficient_false_positives = sum(
        verdicts[case["id"]]["verdict"] != "insufficient" for case in insufficient
    )
    provenance_hits = sum(provenance[case["id"]] is None for case in cases)
    consistent_pairs = 0
    for pair in pairs:
        base = verdicts[pair["base_case_id"]]
        variant = verdicts[pair["variant_case_id"]]
        if base["verdict"] == variant["verdict"] and set(base["citations"]) == set(variant["citations"]):
            consistent_pairs += 1

    return {
        "cases": len(cases),
        "expected_supported": len(support),
        "expected_contradicted": len(contradiction),
        "expected_insufficient": len(insufficient),
        "metamorphic_pairs": len(pairs),
        "positive_support_coverage": ratio(support_hits, len(support), "positive support coverage"),
        "contradiction_coverage": ratio(contradiction_hits, len(contradiction), "contradiction coverage"),
        "insufficient_false_positive_rate": ratio(
            insufficient_false_positives,
            len(insufficient),
            "insufficient false-positive rate",
        ),
        "provenance_validity": ratio(provenance_hits, len(cases), "provenance validity"),
        "metamorphic_consistency": ratio(consistent_pairs, len(pairs), "metamorphic consistency"),
    }


def score_verdicts(corpus: dict[str, Any], verdicts: dict[str, dict[str, Any]]) -> dict[str, Any]:
    known_evidence = set(corpus["evidence"])
    provenance = {
        case_id: provenance_failure(case, verdicts[case_id], known_evidence)
        for case_id, case in corpus["cases"].items()
    }
    splits = {
        split: score_split(split, corpus, verdicts, provenance)
        for split in SPLITS
    }
    failures = [failure for failure in provenance.values() if failure is not None]
    validation = splits["validation"]
    thresholds = corpus["thresholds"]
    checks = (
        (
            validation["positive_support_coverage"]
            >= thresholds["minimum_validation_support_coverage"],
            "validation positive support coverage is below threshold",
        ),
        (
            validation["contradiction_coverage"]
            >= thresholds["minimum_validation_contradiction_coverage"],
            "validation contradiction coverage is below threshold",
        ),
        (
            validation["insufficient_false_positive_rate"]
            <= thresholds["maximum_validation_insufficient_false_positive_rate"],
            "validation insufficient false-positive rate exceeds threshold",
        ),
        (
            validation["provenance_validity"]
            >= thresholds["minimum_validation_provenance_validity"],
            "validation provenance validity is below threshold",
        ),
        (
            validation["metamorphic_consistency"]
            >= thresholds["minimum_validation_metamorphic_consistency"],
            "validation metamorphic consistency is below threshold",
        ),
    )
    failures.extend(message for passed, message in checks if not passed)
    deduplicated_failures = list(dict.fromkeys(failures))
    return {
        "dataset_id": corpus["dataset_id"],
        "qualified": not deduplicated_failures,
        "thresholds": thresholds,
        "splits": splits,
        "validation": validation,
        "failures": deduplicated_failures,
    }


def oracle_verdicts(corpus: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = {}
    for case_id, case in corpus["cases"].items():
        required = case["expected"]["required_citation_sets"]
        rows[case_id] = {
            "case_id": case_id,
            "verdict": case["expected"]["verdict"],
            "citations": list(required[0]) if required else [],
        }
    return rows


def run_self_test(corpus: dict[str, Any]) -> dict[str, Any]:
    oracle = oracle_verdicts(corpus)
    oracle_report = score_verdicts(corpus, oracle)
    require(oracle_report["qualified"], "internal oracle did not qualify")

    adversarial = copy.deepcopy(oracle)
    target_id = next(
        case_id
        for case_id, case in corpus["cases"].items()
        if case["expected"]["verdict"] == "supported"
    )
    adversarial[target_id]["citations"] = ["ev-invented-self-test"]
    adversarial_report = score_verdicts(corpus, adversarial)
    require(not adversarial_report["qualified"], "invented citation did not fail closed")
    require(
        any("invented citation" in failure for failure in adversarial_report["failures"]),
        "invented citation failure was not reported",
    )

    metamorphic = copy.deepcopy(oracle)
    pair = next(iter(corpus["pairs"].values()))
    variant_id = pair["variant_case_id"]
    metamorphic[variant_id]["verdict"] = "insufficient"
    metamorphic[variant_id]["citations"] = []
    metamorphic_report = score_verdicts(corpus, metamorphic)
    pair_split = corpus["cases"][pair["base_case_id"]]["split"]
    require(
        metamorphic_report["splits"][pair_split]["metamorphic_consistency"] < 1.0,
        "candidate-order mutation was not detected",
    )
    return {
        "ok": True,
        "checks": [
            "oracle verdicts qualify",
            "invented citations fail closed",
            "candidate-order inconsistency fails closed",
        ],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "self-test"):
        child = subparsers.add_parser(command)
        child.add_argument("--corpus", type=Path, required=True)
        child.add_argument("--lock", type=Path)
        child.add_argument("--skip-lock", action="store_true")
    score = subparsers.add_parser("score")
    score.add_argument("--corpus", type=Path, required=True)
    score.add_argument("--verdicts", type=Path, required=True)
    score.add_argument("--lock", type=Path)
    score.add_argument("--skip-lock", action="store_true")
    score.add_argument("--output", type=Path)
    return parser


def write_report(report: dict[str, Any], output: Path | None = None) -> None:
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")


def main() -> int:
    args = build_parser().parse_args()
    try:
        data = load_json(args.corpus)
        corpus = validate_corpus(data)
        digest = corpus_sha256(args.corpus) if args.skip_lock else validate_lock(args.corpus, args.lock)
        if args.command == "validate":
            write_report(
                {
                    "dataset_id": corpus["dataset_id"],
                    "sha256": digest,
                    "valid": True,
                    "cases_by_split": corpus["split_counts"],
                    "scenarios_by_split": corpus["scenario_counts"],
                }
            )
            return 0
        if args.command == "self-test":
            report = run_self_test(corpus)
            report.update({"dataset_id": corpus["dataset_id"], "sha256": digest})
            write_report(report)
            return 0

        verdict_data = load_json(args.verdicts)
        verdicts = validate_verdicts(verdict_data, corpus)
        report = score_verdicts(corpus, verdicts)
        report["corpus_sha256"] = digest
        report["system"] = verdict_data["system"]
        write_report(report, args.output)
        return 0 if report["qualified"] else 1
    except ContractError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
