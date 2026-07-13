# Recall-quality benchmark harness (scaffold)

Public benchmark for MCI's recall surface — the primary product
feature. Sibling to `docs/eval/brief-quality.md` and the ADR-0010 §7
eval gate. Scaffolded per cycle 8.42 EnviousWispr peer study
(`docs/research/2026-07-13-enviouswispr-peer-study.md` §2).

**Scope:** scaffolding only. Real corpus + scorecard land cycle 8.44+.

## Why + methodology

MCI's "hybrid retriever + entity-fusion + FTS + semantic + graph
fusion" claim is not currently verifiable on any public corpus. EW's
`scripts/eval/` (1,890 public cases + runner + score card) is the
pattern. Each case is a JSONL row `{query, expected_top_k,
context_note}`; the judge computes precision@k, recall@k, MRR.
Categories: URL lookup, entity mention, cross-app dot-connect,
temporal, semantic. See `SCHEMA.md`.

## Run

```text
# Seed a scratch brain (seed module ships cycle 8.44+), then:
scripts/eval/recall/runner.sh \
    --corpus scripts/eval/recall/test-corpus.example.jsonl \
    --limit 10 --out /tmp/recall-eval.jsonl

python3 scripts/eval/recall/judge.py \
    --corpus scripts/eval/recall/test-corpus.example.jsonl \
    --results /tmp/recall-eval.jsonl --k 10
```

Runner shells `mci-brain search <query> --limit N --json`
(`apps/agent/src/bin/mci_brain.rs`). The MCP `mci_recall` tool
returns the same shape; a future revision can add `--mcp`.

## Interpret

Per row: `P@k`, `R@k`, `RR`; footer aggregates give P@k, R@k, MRR.
Recall is the dominant signal (ADR-0010 §7, arXiv:2506.06743 r=0.75).
Thresholds land with the real corpus; interpretation lives in
`docs/eval/recall-quality.md`.

## Contribute

Append a JSONL row matching `SCHEMA.md`. `context_note` = one sentence
naming the retrieval mechanism. Synthetic only; 1–3 expected IDs
(more makes recall@k trivially high).
