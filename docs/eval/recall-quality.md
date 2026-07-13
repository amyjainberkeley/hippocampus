# Recall-quality eval (ADR-0010 §7 gate)

Companion to `docs/eval/brief-quality.md`. Where brief-quality grades
the brief-author (ADR-0028), **recall-quality grades the retriever** —
the primary user-facing surface. Scaffolded at `scripts/eval/recall/`;
real corpus + scorecard land cycle 8.44+.

## Why this matters

MCI markets "hybrid retriever + entity-fusion + FTS + semantic + graph
fusion" — a skeptic cannot verify that on any public corpus today.
Per the cycle 8.42 EnviousWispr peer study §2, this is the biggest gap
in MCI's trust story. Publishing the harness + corpus + scorecard
closes it. Pattern: EW's `scripts/eval/` (1,890 public cases + runner
+ auto-rendered score card).

## Fit with brief-quality

| Axis | brief-quality | recall-quality |
|---|---|---|
| Surface | brief-author (`core/brief/`) | retriever (`core/brain/`) |
| ADR gate | ADR-0028 | ADR-0010 §7 |
| Metrics | fact_coverage, forbidden_hits, citation_validity, structure, length | precision@k, recall@k, MRR |
| Corpus | 8 hand-authored synthetic days | Cycle 8.44+ seeded synthetic |
| Runner | Rust integration test | Bash + Python |
| Runs today | Yes — 8/8 pass | No — scaffold only |

The evals are independent: brief-quality passes with a broken
retriever (brief-author is fed fixture events directly);
recall-quality passes with a broken brief-author (retriever is scored
on event IDs, no prose scoring).

## What results mean

- **precision@k** — of top-k returned, fraction correct.
- **recall@k** — of correct events, fraction surfaced. **Dominant
  metric** per ADR-0010 §7 + arXiv:2506.06743 (r=0.75).
- **MRR** — mean reciprocal rank of the first correct hit.

Thresholds are **not** proposed here — the peer study is explicit
"the corpus is the load-bearing artifact." Reference regime: MIRIX
(arXiv:2507.07957 Table 1) reports 59.5% structured-episodic.

## Informing ADR-0010 revisions

ADR-0010 §5 sets **starting** CC-fusion weights (`w_sem=0.5, w_lex=0.3,
w_rec=0.15, w_src=0.05`), explicit that they are initial, not frozen.
This harness is the calibration gate: run at shipped weights, record
baseline; grid-search candidate vectors; if a candidate improves
recall@k without regressing MRR by more than 3% (peer-study proposed
scorecard guard), open an ADR-0010 revision with the diff. A revision
that softens the eval (removes cases, loosens k) must show up as FAIL
on a case that used to PASS — the same integrity guard brief-quality
enforces via `StubBriefAuthor`.

## Scope of this scaffold

No corpus (only 8 synthetic schema-demo cases with fake event IDs).
No seed module (cycle 8.44+). No scorecard, no CI release gate.

## References

- `docs/research/2026-07-13-enviouswispr-peer-study.md` §2.
- `docs/decisions/0010-event-episode-retrieval-unit-cc-fusion.md` §5, §7.
- `docs/eval/brief-quality.md` — sibling eval.
- `scripts/eval/recall/{README,SCHEMA}.md`.
- arXiv:2507.07957 (MIRIX), arXiv:2506.06743 (Lifelog review).
