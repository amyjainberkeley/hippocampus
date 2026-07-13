#!/usr/bin/env python3
"""scripts/eval/recall/judge.py — recall-quality scorer (scaffold).

Reads corpus + runner result file. Emits per-case P@k, R@k, RR + an
aggregate footer (mean P@k, mean R@k, MRR). Cycle 8.42 scaffold;
thresholds land with the real corpus in cycle 8.44+.
"""

from __future__ import annotations
import argparse
import json
import sys
from pathlib import Path


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open() as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                sys.exit(f"judge.py: {path}:{i}: {e}")
    return rows


def score(expected: list, hits: list, k: int) -> tuple[float, float, float]:
    """(precision@k, recall@k, reciprocal_rank_of_first_expected)."""
    exp = {str(x) for x in expected}
    top = [str(x) for x in hits[:k]]
    inter = exp.intersection(top)
    prec = len(inter) / k if k > 0 else 0.0
    rec = len(inter) / len(exp) if exp else 0.0
    rr = 0.0
    for idx, h in enumerate(top, 1):
        if h in exp:
            rr = 1.0 / idx
            break
    return prec, rec, rr


def main() -> int:
    ap = argparse.ArgumentParser(description="Score recall-eval runner output.")
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--results", required=True, type=Path)
    ap.add_argument("--k", type=int, default=10)
    args = ap.parse_args()

    corpus = load_jsonl(args.corpus)
    results = {r["query"]: r for r in load_jsonl(args.results)}

    print(f"{'query':<40}  {'P@k':>6}  {'R@k':>6}  {'RR':>6}")
    print("-" * 66)
    tp = tr = trr = 0.0
    n = 0
    for case in corpus:
        q = case["query"]
        res = results.get(q)
        if res is None:
            print(f"{q[:38]:<40}  {'--':>6}  {'--':>6}  {'--':>6}  (missing)")
            continue
        p, r, rr = score(case.get("expected_top_k", []), res.get("hits", []), args.k)
        tp += p; tr += r; trr += rr; n += 1
        print(f"{q[:38]:<40}  {p:6.3f}  {r:6.3f}  {rr:6.3f}")

    print("-" * 66)
    if n == 0:
        print("judge.py: no scored cases"); return 1
    print(f"aggregate (n={n})  precision@{args.k}={tp / n:.3f}  "
          f"recall@{args.k}={tr / n:.3f}  MRR={trr / n:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
