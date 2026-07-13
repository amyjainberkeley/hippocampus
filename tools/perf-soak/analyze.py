#!/usr/bin/env python3
"""tools/perf-soak/analyze.py — score an agent-soak JSONL run.

Reads the 1 Hz JSONL emitted by `agent-soak.sh`, computes mean / p50 /
p95 / p99 for CPU (% of one core) + RSS (KB), and compares against the
pinned `expected-baseline.json`. Score card covers both G2 SLO tiers.

Exit codes: 0 = ok, 1 = --strict + drift, 2 = no samples.
Deps: stdlib only (json, statistics, argparse, sys, pathlib).
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

# G2 SLO bars from DESIGN.md (ratified 2026-05-31): steady-state
# (default tier) and Performance (opt-in via OnboardingTier).
SLO_STEADY_CPU_PCT = 15.0
SLO_STEADY_RSS_MB = 2048.0
SLO_PERF_CPU_PCT = 2.0
SLO_PERF_RSS_MB = 250.0


def pct(values: list[float], p: int) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, (len(ordered) * p) // 100)
    return ordered[idx]


def load_samples(path: Path) -> list[dict]:
    samples: list[dict] = []
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                samples.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"analyze: skipping malformed line: {e}", file=sys.stderr)
    return samples


def score(samples: list[dict]) -> dict:
    cpu = [float(s.get("cpu_pct", 0.0)) for s in samples]
    rss_kb = [float(s.get("rss_kb", 0.0)) for s in samples]
    rss_mb = [v / 1024.0 for v in rss_kb]
    return {
        "n": len(samples),
        "duration_s": max((int(s.get("t_s", 0)) for s in samples), default=0),
        "cpu_mean": statistics.fmean(cpu) if cpu else 0.0,
        "cpu_p50": pct(cpu, 50),
        "cpu_p95": pct(cpu, 95),
        "cpu_p99": pct(cpu, 99),
        "rss_mb_mean": statistics.fmean(rss_mb) if rss_mb else 0.0,
        "rss_mb_p50": pct(rss_mb, 50),
        "rss_mb_p95": pct(rss_mb, 95),
        "rss_mb_p99": pct(rss_mb, 99),
    }


def render(s: dict, baseline: dict) -> tuple[str, bool]:
    """Format the score card. Returns (text, within_envelope)."""
    lines: list[str] = []
    lines.append("=" * 68)
    lines.append("perf-soak agent scorecard (CRS G6 interim baseline)")
    lines.append("=" * 68)
    lines.append(f"samples: {s['n']}   duration: {s['duration_s']}s")
    lines.append("")
    lines.append(f"{'metric':<12}{'mean':>10}{'p50':>10}{'p95':>10}{'p99':>10}")
    lines.append(
        f"{'cpu %':<12}{s['cpu_mean']:>10.3f}{s['cpu_p50']:>10.3f}"
        f"{s['cpu_p95']:>10.3f}{s['cpu_p99']:>10.3f}"
    )
    lines.append(
        f"{'rss MB':<12}{s['rss_mb_mean']:>10.1f}{s['rss_mb_p50']:>10.1f}"
        f"{s['rss_mb_p95']:>10.1f}{s['rss_mb_p99']:>10.1f}"
    )
    lines.append("")
    # SLO score card — both tiers.
    lines.append("SLO check (p95):")
    ok_steady = s["cpu_p95"] <= SLO_STEADY_CPU_PCT and s["rss_mb_p95"] <= SLO_STEADY_RSS_MB
    ok_perf = s["cpu_p95"] <= SLO_PERF_CPU_PCT and s["rss_mb_p95"] <= SLO_PERF_RSS_MB
    lines.append(
        f"  steady-state (default tier ≤{SLO_STEADY_CPU_PCT:.0f}% / ≤{SLO_STEADY_RSS_MB:.0f} MB): "
        f"{'PASS' if ok_steady else 'FAIL'}"
    )
    lines.append(
        f"  performance tier (opt-in ≤{SLO_PERF_CPU_PCT:.0f}% / ≤{SLO_PERF_RSS_MB:.0f} MB): "
        f"{'PASS' if ok_perf else 'FAIL'}"
    )
    # Baseline drift envelope.
    lines.append("")
    lines.append("Baseline drift (pinned expected-baseline.json):")
    exp_cpu = float(baseline["expected"]["cpu_pct_p95"])
    exp_rss = float(baseline["expected"]["rss_mb_p95"])
    env = float(baseline["drift_envelope_multiplier"])
    cpu_ratio = (s["cpu_p95"] / exp_cpu) if exp_cpu > 0 else float("inf")
    rss_ratio = (s["rss_mb_p95"] / exp_rss) if exp_rss > 0 else float("inf")
    within = cpu_ratio <= env and rss_ratio <= env
    lines.append(
        f"  cpu p95 = {s['cpu_p95']:.3f}%  vs baseline {exp_cpu:.3f}%   "
        f"ratio={cpu_ratio:.2f}x  envelope=±{env:.1f}x"
    )
    lines.append(
        f"  rss p95 = {s['rss_mb_p95']:.1f} MB  vs baseline {exp_rss:.1f} MB   "
        f"ratio={rss_ratio:.2f}x  envelope=±{env:.1f}x"
    )
    lines.append(f"  verdict: {'WITHIN ENVELOPE' if within else 'DRIFT DETECTED'}")
    lines.append("=" * 68)
    return "\n".join(lines), within


def main() -> int:
    ap = argparse.ArgumentParser(description="Score an agent-soak JSONL run.")
    ap.add_argument("jsonl", type=Path, help="path to agent-soak JSONL")
    ap.add_argument("--baseline", type=Path, required=True, help="expected-baseline.json")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="exit 1 when drift falls outside the baseline envelope (CI mode)",
    )
    args = ap.parse_args()

    samples = load_samples(args.jsonl)
    if not samples:
        print(f"analyze: no samples found in {args.jsonl}", file=sys.stderr)
        return 2

    with args.baseline.open() as fh:
        baseline = json.load(fh)

    stats = score(samples)
    text, within = render(stats, baseline)
    print(text)

    if args.strict and not within:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
