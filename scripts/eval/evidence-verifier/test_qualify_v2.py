#!/usr/bin/env python3
"""Contract tests for the model-agnostic evidence-verifier qualifier."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS = Path(__file__).with_name("qualify_v2.py")


def corpus() -> dict:
    return {
        "schema_version": 2,
        "dataset_id": "test-evidence-verifier-v2",
        "qualification_thresholds": {
            "minimum_validation_support_coverage": 1.0,
            "minimum_validation_contradiction_coverage": 1.0,
            "maximum_validation_insufficient_false_positive_rate": 0.0,
            "minimum_validation_provenance_validity": 1.0,
            "minimum_validation_metamorphic_consistency": 1.0,
        },
        "required_categories": [
            "direct_answer",
            "paraphrase_coreference",
            "temporal_update",
            "contradiction",
            "cross_document_synthesis",
            "provenance_enforcement",
            "absent_answer",
            "concrete_distractor",
        ],
        "evidence": [
            {"id": "ev-fit-a", "scenario_id": "fit-a", "source_id": "src-fit-a", "text": "Fit alpha is one."},
        {"id": "ev-fit-a2", "scenario_id": "fit-a", "source_id": "src-fit-a2", "text": "Fit alpha also has a concrete distractor."},
        {"id": "ev-fit-b2", "scenario_id": "fit-b", "source_id": "src-fit-b2", "text": "Fit beta also has a second concrete distractor."},
        {"id": "ev-fit-b", "scenario_id": "fit-b", "source_id": "src-fit-b", "text": "Fit beta is two."},
            {"id": "ev-cal-a", "scenario_id": "cal-a", "source_id": "src-cal-a", "text": "Calibration alpha is three."},
        {"id": "ev-cal-a2", "scenario_id": "cal-a", "source_id": "src-cal-a2", "text": "Calibration alpha also has a concrete distractor."},
        {"id": "ev-cal-b2", "scenario_id": "cal-b", "source_id": "src-cal-b2", "text": "Calibration beta also has a second concrete distractor."},
        {"id": "ev-cal-b", "scenario_id": "cal-b", "source_id": "src-cal-b", "text": "Calibration beta is four."},
            {"id": "ev-val-a", "scenario_id": "val-a", "source_id": "src-val-a", "text": "Validation alpha is five."},
        {"id": "ev-val-a2", "scenario_id": "val-a", "source_id": "src-val-a2", "text": "Validation alpha also has a concrete distractor."},
        {"id": "ev-val-b2", "scenario_id": "val-b", "source_id": "src-val-b2", "text": "Validation beta also has a second concrete distractor."},
        {"id": "ev-val-b", "scenario_id": "val-b", "source_id": "src-val-b", "text": "Validation beta is six."},
        ],
        "cases": [],
        "metamorphic_pairs": [],
    }


def add_split_cases(data: dict, split: str, prefix: str) -> None:
    categories = data["required_categories"]
    for index, category in enumerate(categories):
        scenario = f"{prefix}-a" if index % 2 == 0 else f"{prefix}-b"
        candidate = f"ev-{prefix}-a" if index % 2 == 0 else f"ev-{prefix}-b"
        expected = "supported"
        required = [[candidate]]
        if category == "contradiction":
            expected = "contradicted"
        elif category in {"absent_answer", "concrete_distractor"}:
            expected = "insufficient"
            required = []
        data["cases"].append(
            {
                "id": f"case-{prefix}-{category}",
                "scenario_id": scenario,
                "split": split,
                "category": category,
                "query": f"Question for {prefix} {category}?",
                "candidate_ids": [candidate],
                "expected": {
                    "verdict": expected,
                    "required_citation_sets": required,
                },
            }
        )


def complete_corpus() -> dict:
    data = corpus()
    add_split_cases(data, "fit", "fit")
    add_split_cases(data, "calibration", "cal")
    add_split_cases(data, "validation", "val")
    for prefix in ("fit", "cal", "val"):
        base = next(case for case in data["cases"] if case["id"] == f"case-{prefix}-direct_answer")
        variant = dict(base)
        variant["id"] = f"case-{prefix}-direct_answer-order"
        variant["candidate_ids"] = [f"ev-{prefix}-a2", f"ev-{prefix}-a"]
        base["candidate_ids"] = [f"ev-{prefix}-a", f"ev-{prefix}-a2"]
        data["cases"].append(variant)
        data["metamorphic_pairs"].append(
            {
                "id": f"meta-{prefix}-direct",
                "base_case_id": base["id"],
                "variant_case_id": variant["id"],
                "relation": "candidate_order_invariant",
            }
        )
        insufficient_base = next(
            case
            for case in data["cases"]
            if case["id"] == f"case-{prefix}-concrete_distractor"
        )
        insufficient_variant = dict(insufficient_base)
        insufficient_variant["id"] = f"case-{prefix}-concrete_distractor-order"
        insufficient_variant["candidate_ids"] = [f"ev-{prefix}-b2", f"ev-{prefix}-b"]
        insufficient_base["candidate_ids"] = [f"ev-{prefix}-b", f"ev-{prefix}-b2"]
        data["cases"].append(insufficient_variant)
        data["metamorphic_pairs"].append(
            {
                "id": f"meta-{prefix}-insufficient",
                "base_case_id": insufficient_base["id"],
                "variant_case_id": insufficient_variant["id"],
                "relation": "candidate_order_invariant",
            }
        )
    return data


def perfect_verdicts(data: dict) -> dict:
    verdicts = []
    for case in data["cases"]:
        required = case["expected"]["required_citation_sets"]
        verdicts.append(
            {
                "case_id": case["id"],
                "verdict": case["expected"]["verdict"],
                "citations": required[0] if required else [],
            }
        )
    return {
        "schema_version": 1,
        "dataset_id": data["dataset_id"],
        "system": {"name": "test-system", "version": "1"},
        "verdicts": verdicts,
    }


class QualifierContractTests(unittest.TestCase):
    def invoke(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HARNESS), *args],
            check=False,
            capture_output=True,
            text=True,
        )

    def write_json(self, directory: Path, name: str, value: dict) -> Path:
        path = directory / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_validate_accepts_scenario_disjoint_complete_corpus(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            corpus_path = self.write_json(Path(directory), "corpus.json", complete_corpus())
            result = self.invoke("validate", "--corpus", str(corpus_path), "--skip-lock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["valid"])

    def test_validate_rejects_a_self_declared_reduced_category_set(self) -> None:
        data = complete_corpus()
        removed = "concrete_distractor"
        data["required_categories"].remove(removed)
        removed_case_ids = {
            case["id"] for case in data["cases"] if case["category"] == removed
        }
        data["cases"] = [
            case for case in data["cases"] if case["id"] not in removed_case_ids
        ]
        data["metamorphic_pairs"] = [
            pair
            for pair in data["metamorphic_pairs"]
            if pair["base_case_id"] not in removed_case_ids
            and pair["variant_case_id"] not in removed_case_ids
        ]
        with tempfile.TemporaryDirectory() as directory:
            corpus_path = self.write_json(Path(directory), "corpus.json", data)
            result = self.invoke("validate", "--corpus", str(corpus_path), "--skip-lock")
        self.assertEqual(result.returncode, 2)
        self.assertIn("required_categories", result.stderr)

    def test_validate_requires_supported_and_insufficient_order_pairs_per_split(self) -> None:
        data = complete_corpus()
        removed_pair_ids = {
            pair["id"]
            for pair in data["metamorphic_pairs"]
            if pair["id"].endswith("-insufficient")
        }
        removed_case_ids = {
            pair["variant_case_id"]
            for pair in data["metamorphic_pairs"]
            if pair["id"] in removed_pair_ids
        }
        data["metamorphic_pairs"] = [
            pair
            for pair in data["metamorphic_pairs"]
            if pair["id"] not in removed_pair_ids
        ]
        data["cases"] = [
            case for case in data["cases"] if case["id"] not in removed_case_ids
        ]

        with tempfile.TemporaryDirectory() as directory:
            corpus_path = self.write_json(Path(directory), "corpus.json", data)
            result = self.invoke("validate", "--corpus", str(corpus_path), "--skip-lock")

        self.assertEqual(result.returncode, 2)
        self.assertIn("supported and insufficient", result.stderr)

    def test_score_perfect_verdicts_qualifies(self) -> None:
        data = complete_corpus()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = self.write_json(root, "corpus.json", data)
            verdicts_path = self.write_json(root, "verdicts.json", perfect_verdicts(data))
            result = self.invoke(
                "score", "--corpus", str(corpus_path), "--verdicts", str(verdicts_path), "--skip-lock"
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["qualified"])
        self.assertEqual(report["validation"]["positive_support_coverage"], 1.0)
        self.assertEqual(report["validation"]["contradiction_coverage"], 1.0)
        self.assertEqual(report["validation"]["insufficient_false_positive_rate"], 0.0)
        self.assertEqual(report["validation"]["provenance_validity"], 1.0)
        self.assertEqual(report["validation"]["metamorphic_consistency"], 1.0)

    def test_invented_citation_fails_closed(self) -> None:
        data = complete_corpus()
        verdicts = perfect_verdicts(data)
        verdicts["verdicts"][0]["citations"] = ["ev-invented"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = self.write_json(root, "corpus.json", data)
            verdicts_path = self.write_json(root, "verdicts.json", verdicts)
            result = self.invoke(
                "score", "--corpus", str(corpus_path), "--verdicts", str(verdicts_path), "--skip-lock"
            )
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertFalse(report["qualified"])
        self.assertIn("invented citation", " ".join(report["failures"]))

    def test_malformed_citations_are_rejected(self) -> None:
        data = complete_corpus()
        verdicts = perfect_verdicts(data)
        verdicts["verdicts"][0]["citations"] = "ev-fit-a"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = self.write_json(root, "corpus.json", data)
            verdicts_path = self.write_json(root, "verdicts.json", verdicts)
            result = self.invoke(
                "score", "--corpus", str(corpus_path), "--verdicts", str(verdicts_path), "--skip-lock"
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("citations must be an array", result.stderr)

    def test_candidate_order_change_is_reported(self) -> None:
        data = complete_corpus()
        verdicts = perfect_verdicts(data)
        variant = next(
            row for row in verdicts["verdicts"] if row["case_id"] == "case-val-direct_answer-order"
        )
        variant["verdict"] = "insufficient"
        variant["citations"] = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = self.write_json(root, "corpus.json", data)
            verdicts_path = self.write_json(root, "verdicts.json", verdicts)
            result = self.invoke(
                "score", "--corpus", str(corpus_path), "--verdicts", str(verdicts_path), "--skip-lock"
            )
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["validation"]["metamorphic_consistency"], 0.5)


if __name__ == "__main__":
    unittest.main()
