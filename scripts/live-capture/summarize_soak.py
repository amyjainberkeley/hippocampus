#!/usr/bin/env python3
"""Build a fail-closed capture-soak report from content-free telemetry."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from pathlib import Path
from typing import Any

MINIMUM_QUALIFYING_SECONDS = 30 * 60
HELPER_CPU_P95_LIMIT = 15.0
HELPER_RSS_P95_LIMIT_BYTES = 2 * 1024 * 1024 * 1024
FOCUS_RACE_DROP_FRACTION_LIMIT = 0.05

COUNTER_FIELDS = (
    "frames_delivered",
    "frames_suppressed",
    "frames_redacted_by_failsafe",
    "cascade_forced_count",
    "frames_dropped_backpressure",
    "frames_dropped_late_ack",
    "frames_encode_failed",
    "frames_focus_race_dropped",
)


class ReportInputError(ValueError):
    pass


def nonnegative_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ReportInputError(f"{field} must be a non-negative integer")
    return value


def load_health(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ReportInputError(f"could not read helper health log: {error}") from error

    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ReportInputError(
                f"helper health line {line_number} is not JSON: {error}"
            ) from error
        if not isinstance(record, dict):
            raise ReportInputError(
                f"helper health line {line_number} is not an object"
            )
        for field in COUNTER_FIELDS:
            nonnegative_int(record.get(field), f"health.{field}")
        records.append(record)

    if not records:
        raise ReportInputError("helper health log contains no samples")
    return records


def load_footprint(path: Path) -> tuple[list[float], list[int]]:
    cpu_values: list[float] = []
    rss_values: list[int] = []
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames != ["ts_unix", "helper_pid", "rss_kb", "cpu_pct"]:
                raise ReportInputError(
                    "footprint CSV must use ts_unix,helper_pid,rss_kb,cpu_pct"
                )
            for line_number, row in enumerate(reader, start=2):
                try:
                    cpu = float(row["cpu_pct"])
                    rss_kb = int(row["rss_kb"])
                except (KeyError, TypeError, ValueError) as error:
                    raise ReportInputError(
                        f"footprint line {line_number} has invalid numeric fields"
                    ) from error
                if not math.isfinite(cpu) or cpu < 0 or rss_kb < 0:
                    raise ReportInputError(
                        f"footprint line {line_number} has negative or non-finite data"
                    )
                cpu_values.append(cpu)
                rss_values.append(rss_kb * 1024)
    except OSError as error:
        raise ReportInputError(f"could not read footprint CSV: {error}") from error

    if not cpu_values:
        raise ReportInputError("footprint CSV contains no samples")
    return cpu_values, rss_values


def load_memory(path: Path) -> dict[str, Any]:
    try:
        memory = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReportInputError(f"could not read memory verification: {error}") from error
    if not isinstance(memory, dict):
        raise ReportInputError("memory verification must be a JSON object")
    if not isinstance(memory.get("focused_token_present"), bool):
        raise ReportInputError("memory.focused_token_present must be boolean")
    if not isinstance(memory.get("background_token_present"), bool):
        raise ReportInputError("memory.background_token_present must be boolean")
    if not isinstance(memory.get("focus_control_token_present"), bool):
        raise ReportInputError("memory.focus_control_token_present must be boolean")
    nonnegative_int(memory.get("corpus_event_count"), "memory.corpus_event_count")
    nonnegative_int(memory.get("foreign_event_count"), "memory.foreign_event_count")
    return memory


def percentile(values: list[float] | list[int], quantile: float) -> float | int:
    ordered = sorted(values)
    index = max(0, math.ceil(quantile * len(ordered)) - 1)
    return ordered[index]


def storage_metrics(brain_dir: Path, capture_seconds: int) -> dict[str, int]:
    if not brain_dir.is_dir():
        raise ReportInputError(f"brain directory does not exist: {brain_dir}")

    database_bytes = sum(
        path.stat().st_size
        for path in brain_dir.glob("mci.sqlite*")
        if path.is_file() and not path.is_symlink()
    )
    blob_dir = brain_dir / "blobs"
    blob_files = (
        [path for path in blob_dir.iterdir() if path.is_file() and not path.is_symlink()]
        if blob_dir.is_dir()
        else []
    )
    blob_bytes = sum(path.stat().st_size for path in blob_files)
    total_bytes = database_bytes + blob_bytes
    return {
        "blob_bytes": blob_bytes,
        "database_bytes": database_bytes,
        "projected_bytes_per_hour": round(total_bytes * 3600 / capture_seconds),
        "total_bytes": total_bytes,
    }


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    health = load_health(args.health_jsonl)
    cpu_values, rss_values = load_footprint(args.footprint_csv)
    memory = load_memory(args.memory_json)
    storage = storage_metrics(args.brain_dir, args.capture_seconds)
    latest = health[-1]
    counters = {
        field: max(nonnegative_int(record[field], f"health.{field}") for record in health)
        for field in COUNTER_FIELDS
    }
    blob_dir = args.brain_dir / "blobs"
    keyframes_retained = (
        sum(1 for path in blob_dir.iterdir() if path.is_file() and not path.is_symlink())
        if blob_dir.is_dir()
        else 0
    )

    cpu_p95 = float(percentile(cpu_values, 0.95))
    rss_p95 = int(percentile(rss_values, 0.95))
    # A race-dropped frame is already included in frames_delivered by the
    # helper pipeline, so delivered is the complete denominator.
    focus_race_denominator = counters["frames_delivered"]
    focus_race_drop_fraction = (
        counters["frames_focus_race_dropped"] / focus_race_denominator
        if focus_race_denominator > 0
        else 0.0
    )
    minimum_health = args.minimum_health_samples
    if minimum_health is None:
        minimum_health = max(1, math.floor((args.capture_seconds / 2) * 0.8))
    minimum_footprint = args.minimum_footprint_samples
    if minimum_footprint is None:
        minimum_footprint = max(1, math.floor((args.capture_seconds / 5) * 0.8))

    failures: list[str] = []
    if args.capture_seconds < MINIMUM_QUALIFYING_SECONDS:
        failures.append("capture_duration_below_1800_seconds")
    if memory["focused_token_present"] is not True:
        failures.append("focused_token_missing")
    if memory["background_token_present"] is not False:
        failures.append("background_token_present")
    if memory["foreign_event_count"] != 0:
        failures.append("foreign_event_present")
    if memory["corpus_event_count"] == 0:
        failures.append("no_ocr_events")
    if len(health) < minimum_health:
        failures.append("insufficient_health_samples")
    if len(cpu_values) < minimum_footprint:
        failures.append("insufficient_footprint_samples")
    if counters["frames_delivered"] == 0:
        failures.append("no_frames_delivered")
    if counters["frames_dropped_backpressure"] != 0:
        failures.append("frame_backpressure_drops")
    if counters["frames_dropped_late_ack"] != 0:
        failures.append("frame_late_ack_drops")
    if counters["frames_encode_failed"] != 0:
        failures.append("frame_encode_failures")
    if args.capture_seconds >= MINIMUM_QUALIFYING_SECONDS:
        if memory["focus_control_token_present"] is not True:
            failures.append("focus_control_token_missing")
        if counters["frames_focus_race_dropped"] == 0:
            failures.append("focus_race_gate_unexercised")
        elif focus_race_drop_fraction >= FOCUS_RACE_DROP_FRACTION_LIMIT:
            failures.append("focus_race_drop_fraction_at_or_above_5_percent")
    if cpu_p95 > HELPER_CPU_P95_LIMIT:
        failures.append("helper_cpu_p95_above_15_percent")
    if rss_p95 > HELPER_RSS_P95_LIMIT_BYTES:
        failures.append("helper_rss_p95_above_2_gib")

    storage["keyframes_retained"] = keyframes_retained
    return {
        "schema_version": 1,
        "qualified": not failures,
        "failures": failures,
        "capture_seconds": args.capture_seconds,
        "privacy": {
            "background_token_present": memory["background_token_present"],
            "focused_recall_outcome": memory.get("focused_recall_outcome"),
            "focused_token_present": memory["focused_token_present"],
            "focus_control_token_present": memory["focus_control_token_present"],
            "foreign_event_count": memory["foreign_event_count"],
        },
        "capture": {
            **counters,
            "focus_race_drop_fraction": focus_race_drop_fraction,
            "health_samples": len(health),
            "keyframes_retained": keyframes_retained,
            "ocr_events": memory["corpus_event_count"],
            "uptime_ms_latest": nonnegative_int(
                latest.get("uptime_ms"), "health.uptime_ms"
            ),
        },
        "resources": {
            "footprint_samples": len(cpu_values),
            "helper_cpu_pct_max": max(cpu_values),
            "helper_cpu_pct_p50": percentile(cpu_values, 0.50),
            "helper_cpu_pct_p95": cpu_p95,
            "helper_rss_bytes_max": max(rss_values),
            "helper_rss_bytes_p50": percentile(rss_values, 0.50),
            "helper_rss_bytes_p95": rss_p95,
        },
        "storage": storage,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--health-jsonl", type=Path, required=True)
    parser.add_argument("--footprint-csv", type=Path, required=True)
    parser.add_argument("--memory-json", type=Path, required=True)
    parser.add_argument("--brain-dir", type=Path, required=True)
    parser.add_argument("--capture-seconds", type=int, required=True)
    parser.add_argument("--minimum-health-samples", type=int)
    parser.add_argument("--minimum-footprint-samples", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.capture_seconds <= 0:
        parser.error("--capture-seconds must be positive")
    for value, name in (
        (args.minimum_health_samples, "--minimum-health-samples"),
        (args.minimum_footprint_samples, "--minimum-footprint-samples"),
    ):
        if value is not None and value <= 0:
            parser.error(f"{name} must be positive")
    return args


def main() -> int:
    args = parse_args()
    try:
        report = build_report(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except ReportInputError as error:
        print(f"capture-soak report error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0 if report["qualified"] else 5


if __name__ == "__main__":
    raise SystemExit(main())
