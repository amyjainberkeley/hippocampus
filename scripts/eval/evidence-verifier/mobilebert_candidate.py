#!/usr/bin/env python3
"""Score the Core ML MobileBERT QA candidate on the disjoint v1 fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import time
from pathlib import Path

SEQUENCE_LENGTH = 384
MAX_ANSWER_TOKENS = 24
TARGET_POSITIVE_COVERAGE = 0.90
TARGET_FALSE_POSITIVE_RATE = 0.05


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument(
        "--dataset", type=Path, default=Path("eval/relevance-calibration/v1.json")
    )
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def artifact_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    files = sorted(item for item in path.rglob("*") if item.is_file())
    for item in files:
        digest.update(item.relative_to(path).as_posix().encode())
        digest.update(b"\0")
        with item.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


class Candidate:
    def __init__(self, model_path: Path, tokenizer_path: Path):
        import coremltools as ct
        import numpy as np
        from transformers import AutoTokenizer

        self.np = np
        model_type = (
            ct.models.CompiledMLModel
            if model_path.suffix == ".mlmodelc"
            else ct.models.MLModel
        )
        self.model = model_type(str(model_path), compute_units=ct.ComputeUnit.CPU_ONLY)
        self.tokenizer = AutoTokenizer.from_pretrained(
            tokenizer_path, local_files_only=True
        )

    def score(self, question: str, documents: list[str]) -> dict:
        context = " ".join(documents)
        encoded = self.tokenizer(
            question,
            context,
            return_tensors="np",
            truncation="only_second",
            padding="max_length",
            max_length=SEQUENCE_LENGTH,
            return_offsets_mapping=True,
        )
        offsets = encoded.pop("offset_mapping")[0]
        sequence_ids = encoded.sequence_ids(0)
        inputs = {
            name: value.astype(self.np.int32)
            for name, value in encoded.items()
            if name in {"input_ids", "attention_mask", "token_type_ids"}
        }
        started = time.perf_counter()
        output = self.model.predict(inputs)
        latency_ms = (time.perf_counter() - started) * 1000
        start_logits = self.np.asarray(output["start_logits"])[0]
        end_logits = self.np.asarray(output["end_logits"])[0]
        best = (-float("inf"), 0, 0)
        for start in range(SEQUENCE_LENGTH):
            if sequence_ids[start] != 1 or offsets[start][0] >= offsets[start][1]:
                continue
            for end in range(start, min(start + MAX_ANSWER_TOKENS, SEQUENCE_LENGTH)):
                if sequence_ids[end] != 1 or offsets[end][0] >= offsets[end][1]:
                    continue
                score = float(start_logits[start] + end_logits[end])
                if score > best[0]:
                    best = (score, start, end)
        start_byte = int(offsets[best[1]][0])
        end_byte = int(offsets[best[2]][1])
        margin = best[0] - float(start_logits[0] + end_logits[0])
        return {
            "margin": margin,
            "answer": context[start_byte:end_byte],
            "latency_ms": latency_ms,
        }


def metrics(rows: list[dict], split: str, threshold: float) -> dict:
    selected = [row for row in rows if row["split"] == split]
    positives = sum(row["supporting"]["margin"] >= threshold for row in selected)
    false_positives = sum(
        row["insufficient"]["margin"] >= threshold for row in selected
    )
    return {
        "cases": len(selected),
        "positive_coverage": positives / len(selected),
        "negative_false_positive_rate": false_positives / len(selected),
        "positive_supported": positives,
        "negative_false_positives": false_positives,
    }


def main() -> int:
    args = parse_args()
    dataset = json.loads(args.dataset.read_text(encoding="utf-8"))
    candidate = Candidate(args.model, args.tokenizer)
    rows = []
    latencies = []
    for case in dataset["cases"]:
        supporting = candidate.score(case["query"], case["supporting_documents"])
        insufficient = candidate.score(case["query"], case["insufficient_documents"])
        latencies.extend([supporting["latency_ms"], insufficient["latency_ms"]])
        rows.append(
            {
                "id": case["id"],
                "split": case["split"],
                "query": case["query"],
                "supporting": supporting,
                "insufficient": insufficient,
            }
        )

    calibration_positive = sorted(
        row["supporting"]["margin"]
        for row in rows
        if row["split"] == "calibration"
    )
    required = math.ceil(len(calibration_positive) * TARGET_POSITIVE_COVERAGE)
    threshold = calibration_positive[len(calibration_positive) - required]
    by_split = {
        split: metrics(rows, split, threshold)
        for split in ["fit", "calibration", "validation"]
    }
    validation = by_split["validation"]
    qualification_failures = []
    if validation["positive_coverage"] < TARGET_POSITIVE_COVERAGE:
        qualification_failures.append("validation positive coverage missed the target")
    if validation["negative_false_positive_rate"] > TARGET_FALSE_POSITIVE_RATE:
        qualification_failures.append("validation false-positive rate exceeded the target")
    qualification_failures.extend(
        [
            "v1 fixture has only six validation scenarios",
            "v1 fixture does not cover contradiction, temporal change, synthesis, provenance, or order metamorphics",
            "candidate has no release-owned immutable model archive",
        ]
    )
    report = {
        "candidate": "csarron-mobilebert-uncased-squad-v2-fp32-coreml",
        "candidate_revision": "6d49c30d06c6042041039f6fe076b011f0c2053c",
        "dataset_id": dataset["dataset_id"],
        "dataset_sha256": hashlib.sha256(args.dataset.read_bytes()).hexdigest(),
        "model_artifact_sha256": artifact_sha256(args.model),
        "threshold_policy": {
            "target_calibration_positive_coverage": TARGET_POSITIVE_COVERAGE,
            "selected_no_answer_margin": threshold,
        },
        "quality_targets": {
            "minimum_validation_positive_coverage": TARGET_POSITIVE_COVERAGE,
            "maximum_validation_false_positive_rate": TARGET_FALSE_POSITIVE_RATE,
        },
        "by_split": by_split,
        "latency_ms": {
            "samples": len(latencies),
            "median": statistics.median(latencies),
            "p95": percentile(latencies, 0.95),
            "maximum": max(latencies),
        },
        "validation_qualified": False,
        "qualification_failures": qualification_failures,
        "results": rows,
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
