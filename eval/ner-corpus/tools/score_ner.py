#!/usr/bin/env python3
"""Per-kind NER scorer for the MCI screen-text bake-off.

Scores a model's predicted entity spans against the gold corpus produced
by `build_corpus.py`. This is the harness the V2-P5+ Phase-3 bake-off
reuses to compare candidate NER models (DistilBERT-CoNLL floor vs a
bert-base-class P/O/L model vs an NLTagger/A-B baseline) on real MCI
screen-text genres — every public NER F1 is CoNLL newswire and does not
transfer to OCR'd screen text.

Metrics (per entity kind, plus micro and macro aggregates):
    precision = TP / (TP + FP)
    recall    = TP / (TP + FN)
    F1        = 2PR / (P + R)
two matching modes:
    EXACT    — predicted (span_start, span_end) must equal a gold span of
               the same kind (the strict V2-P3 entity-row criterion).
    RELAXED  — predicted span need only OVERLAP a gold span of the same
               kind (any shared byte). Tolerates off-by-a-token boundary
               drift, which OCR'd screen text induces heavily.
Matching is one-to-one and greedy: each gold span is consumed by at most
one predicted span and vice-versa (exact pairs first, then, in RELAXED,
remaining pairs by descending overlap). This prevents one fat predicted
span from claiming credit for several gold spans.

Schema (matches build_corpus.py / Tier1Match / Tier2Match):
    gold  : corpus JSON — list of {id, text, entities:[{kind,span_start,span_end,...}]}
    pred  : list of {id, entities:[{kind,span_start,span_end}]}  (mention_text optional)
            OR a dict {id: [entities]}. Spans are UTF-8 byte offsets.
    --kind-map JSON optionally remaps predicted kind strings onto the MCI
    set, e.g. '{"PER":"person_name","ORG":"organization","LOC":"location"}'.

KIND set is config-driven (the `--kinds` flag / KINDS default) so that the
Director-defined `date`/`time` strings can be renamed in one place once the
V2-P4 Date/Time regex lands without touching the matcher.

Usage:
    python3 score_ner.py --gold synthetic/test.json --pred preds.json
    python3 score_ner.py --self-test synthetic/test.json     # gold-vs-gold, asserts F1==1.0
    python3 score_ner.py --unit-test                         # matcher correctness on a known case
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

KINDS = ["person_name", "organization", "location", "date", "time"]


# ---------------------------------------------------------------------------
# Core matcher
# ---------------------------------------------------------------------------

def match_spans(gold: list[tuple[int, int]], pred: list[tuple[int, int]], relaxed: bool) -> tuple[int, int, int]:
    """One-to-one greedy match of pred spans to gold spans (same kind).

    Returns (tp, fp, fn). Exact (start,end) pairs are matched first; in
    RELAXED mode, remaining pairs are then matched by descending byte
    overlap. Each span is used at most once.
    """
    g_used = [False] * len(gold)
    p_used = [False] * len(pred)
    tp = 0

    # Pass 1 — exact span equality.
    for pi, (ps, pe) in enumerate(pred):
        for gi, (gs, ge) in enumerate(gold):
            if not g_used[gi] and ps == gs and pe == ge:
                g_used[gi] = True
                p_used[pi] = True
                tp += 1
                break

    # Pass 2 — overlap (RELAXED only), greedy by largest overlap first.
    if relaxed:
        cands = []
        for pi, (ps, pe) in enumerate(pred):
            if p_used[pi]:
                continue
            for gi, (gs, ge) in enumerate(gold):
                if g_used[gi]:
                    continue
                ov = min(pe, ge) - max(ps, gs)
                if ov > 0:
                    cands.append((ov, pi, gi))
        # Deterministic: largest overlap, then lowest pred idx, then lowest gold idx.
        cands.sort(key=lambda c: (-c[0], c[1], c[2]))
        for _ov, pi, gi in cands:
            if not p_used[pi] and not g_used[gi]:
                p_used[pi] = True
                g_used[gi] = True
                tp += 1

    fp = p_used.count(False)
    fn = g_used.count(False)
    return tp, fp, fn


def prf(tp: int, fp: int, fn: int) -> tuple[float, float, float]:
    if tp + fp + fn == 0:
        # Nothing to find and nothing predicted: vacuously perfect.
        return 1.0, 1.0, 1.0
    p = tp / (tp + fp) if (tp + fp) else 0.0
    r = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * p * r / (p + r) if (p + r) else 0.0
    return p, r, f1


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def spans_by_kind(entities: list[dict], kind: str, kind_map: dict[str, str] | None) -> list[tuple[int, int]]:
    out = []
    for e in entities:
        k = e["kind"]
        if kind_map:
            k = kind_map.get(k, k)
        if k == kind:
            out.append((int(e["span_start"]), int(e["span_end"])))
    return out


def score(gold_records: list[dict], pred_by_id: dict[str, list[dict]], kinds: list[str],
          kind_map: dict[str, str] | None) -> dict:
    result = {"exact": {}, "relaxed": {}}
    for mode in ("exact", "relaxed"):
        relaxed = mode == "relaxed"
        per_kind = {k: [0, 0, 0] for k in kinds}  # tp, fp, fn
        for rec in gold_records:
            gold_ents = rec.get("entities", [])
            pred_ents = pred_by_id.get(rec["id"], [])
            for k in kinds:
                g = spans_by_kind(gold_ents, k, None)
                p = spans_by_kind(pred_ents, k, kind_map)
                tp, fp, fn = match_spans(g, p, relaxed)
                per_kind[k][0] += tp
                per_kind[k][1] += fp
                per_kind[k][2] += fn

        kinds_out = {}
        micro = [0, 0, 0]
        f1s = []
        for k in kinds:
            tp, fp, fn = per_kind[k]
            p, r, f1 = prf(tp, fp, fn)
            kinds_out[k] = {"tp": tp, "fp": fp, "fn": fn, "precision": round(p, 4), "recall": round(r, 4), "f1": round(f1, 4)}
            micro[0] += tp
            micro[1] += fp
            micro[2] += fn
            f1s.append(f1)
        mp, mr, mf1 = prf(*micro)
        result[mode] = {
            "per_kind": kinds_out,
            "micro": {"tp": micro[0], "fp": micro[1], "fn": micro[2], "precision": round(mp, 4), "recall": round(mr, 4), "f1": round(mf1, 4)},
            "macro_f1": round(sum(f1s) / len(f1s), 4) if f1s else 0.0,
        }
    return result


def load_pred(obj) -> dict[str, list[dict]]:
    if isinstance(obj, dict) and "predictions" in obj:
        obj = obj["predictions"]
    if isinstance(obj, dict):
        return {k: v for k, v in obj.items()}
    out: dict[str, list[dict]] = {}
    for rec in obj:
        out[rec["id"]] = rec.get("entities", [])
    return out


# ---------------------------------------------------------------------------
# Self-test + unit-test
# ---------------------------------------------------------------------------

def self_test(gold_path: Path, kinds: list[str]) -> int:
    """Score the gold corpus against itself; assert every F1 == 1.0."""
    gold = json.loads(gold_path.read_text(encoding="utf-8"))
    pred_by_id = {r["id"]: r.get("entities", []) for r in gold}
    res = score(gold, pred_by_id, kinds, None)
    ok = True
    for mode in ("exact", "relaxed"):
        for k, m in res[mode]["per_kind"].items():
            if m["f1"] != 1.0:
                ok = False
                print(f"SELF-TEST FAIL [{mode}/{k}]: f1={m['f1']} tp={m['tp']} fp={m['fp']} fn={m['fn']}", file=sys.stderr)
        if res[mode]["micro"]["f1"] != 1.0:
            ok = False
            print(f"SELF-TEST FAIL [{mode}/micro]: {res[mode]['micro']}", file=sys.stderr)
        if res[mode]["macro_f1"] != 1.0:
            ok = False
            print(f"SELF-TEST FAIL [{mode}/macro]: {res[mode]['macro_f1']}", file=sys.stderr)
    n = len(gold)
    nm = sum(len(r.get("entities", [])) for r in gold)
    if ok:
        print(f"SELF-TEST PASS: gold-vs-gold F1 == 1.0 for all {len(kinds)} kinds, both modes ({n} samples, {nm} mentions).")
        return 0
    return 1


def unit_test() -> int:
    """Matcher correctness on a hand-built case (proves F1==1.0 is not vacuous).

    gold person_name spans: (0,5)=A, (10,15)=B, (20,25)=C
    pred person_name spans: (0,5) exact-hit A
                            (11,16) overlaps B  (relaxed-hit, exact-miss)
                            (40,45) spurious    (FP)
                            -> C never predicted (FN)
    EXACT:   tp=1, fp=2, fn=2
    RELAXED: tp=2, fp=1, fn=1
    """
    gold = [{"id": "u1", "entities": [
        {"kind": "person_name", "span_start": 0, "span_end": 5},
        {"kind": "person_name", "span_start": 10, "span_end": 15},
        {"kind": "person_name", "span_start": 20, "span_end": 25},
    ]}]
    pred = {"u1": [
        {"kind": "person_name", "span_start": 0, "span_end": 5},
        {"kind": "person_name", "span_start": 11, "span_end": 16},
        {"kind": "person_name", "span_start": 40, "span_end": 45},
    ]}
    res = score(gold, pred, ["person_name"], None)
    ex = res["exact"]["per_kind"]["person_name"]
    rx = res["relaxed"]["per_kind"]["person_name"]
    expect_ex = {"tp": 1, "fp": 2, "fn": 2}
    expect_rx = {"tp": 2, "fp": 1, "fn": 1}
    ok = all(ex[k] == v for k, v in expect_ex.items()) and all(rx[k] == v for k, v in expect_rx.items())

    # Overlap one-to-one guard: one fat pred must NOT claim two gold spans.
    gold2 = [{"id": "u2", "entities": [
        {"kind": "location", "span_start": 0, "span_end": 4},
        {"kind": "location", "span_start": 5, "span_end": 9},
    ]}]
    pred2 = {"u2": [{"kind": "location", "span_start": 0, "span_end": 9}]}  # spans both
    res2 = score(gold2, pred2, ["location"], None)
    rx2 = res2["relaxed"]["per_kind"]["location"]
    ok2 = rx2 == {"tp": 1, "fp": 0, "fn": 1, "precision": 1.0, "recall": 0.5, "f1": 0.6667}

    # Kind-map remap.
    gold3 = [{"id": "u3", "entities": [{"kind": "person_name", "span_start": 0, "span_end": 3}]}]
    pred3 = {"u3": [{"kind": "PER", "span_start": 0, "span_end": 3}]}
    res3 = score(gold3, pred3, ["person_name"], {"PER": "person_name"})
    ok3 = res3["exact"]["per_kind"]["person_name"]["f1"] == 1.0

    if ok and ok2 and ok3:
        print("UNIT-TEST PASS: exact (tp1/fp2/fn2), relaxed (tp2/fp1/fn1), one-to-one overlap guard, kind-map remap.")
        return 0
    print(f"UNIT-TEST FAIL: ex={ex} rx={rx} rx2={rx2} ok3={ok3}", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def render(res: dict, kinds: list[str]) -> str:
    lines = []
    for mode in ("exact", "relaxed"):
        lines.append(f"\n=== {mode.upper()} match ===")
        lines.append(f"{'kind':<14}{'P':>8}{'R':>8}{'F1':>8}{'TP':>7}{'FP':>7}{'FN':>7}")
        for k in kinds:
            m = res[mode]["per_kind"][k]
            lines.append(f"{k:<14}{m['precision']:>8.3f}{m['recall']:>8.3f}{m['f1']:>8.3f}{m['tp']:>7}{m['fp']:>7}{m['fn']:>7}")
        mi = res[mode]["micro"]
        lines.append(f"{'MICRO':<14}{mi['precision']:>8.3f}{mi['recall']:>8.3f}{mi['f1']:>8.3f}{mi['tp']:>7}{mi['fp']:>7}{mi['fn']:>7}")
        lines.append(f"{'MACRO-F1':<14}{res[mode]['macro_f1']:>8.3f}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Per-kind NER scorer for the MCI screen-text bake-off.")
    ap.add_argument("--gold", type=Path, help="gold corpus JSON (from build_corpus.py)")
    ap.add_argument("--pred", type=Path, help="predictions JSON (list of {id,entities} or {id:[entities]})")
    ap.add_argument("--kinds", default=",".join(KINDS), help="comma-separated kind set (default: the 5 MCI kinds)")
    ap.add_argument("--kind-map", type=Path, default=None, help="optional JSON mapping predicted kind strings -> MCI kinds")
    ap.add_argument("--json-out", type=Path, default=None, help="optional path to write the full result JSON")
    ap.add_argument("--self-test", type=Path, default=None, help="score the given gold corpus against itself; assert F1==1.0")
    ap.add_argument("--unit-test", action="store_true", help="run the built-in matcher correctness test")
    args = ap.parse_args()

    kinds = [k.strip() for k in args.kinds.split(",") if k.strip()]

    if args.unit_test:
        return unit_test()
    if args.self_test:
        return self_test(args.self_test, kinds)

    if not args.gold or not args.pred:
        ap.error("--gold and --pred are required (unless --self-test / --unit-test)")

    gold = json.loads(args.gold.read_text(encoding="utf-8"))
    pred_by_id = load_pred(json.loads(args.pred.read_text(encoding="utf-8")))
    kind_map = json.loads(args.kind_map.read_text(encoding="utf-8")) if args.kind_map else None

    res = score(gold, pred_by_id, kinds, kind_map)
    print(render(res, kinds))
    if args.json_out:
        args.json_out.write_text(json.dumps(res, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
