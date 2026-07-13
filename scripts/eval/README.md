# scripts/eval/

Evaluation harnesses run outside the shipping binary — quality
scorecards for the surfaces MCI has to prove (retrieval, brief
authoring, redaction). Sibling to `docs/eval/` which holds the
methodology docs.

## Contents

- `recall/` — the recall-quality benchmark scaffold (from PR #63,
  cycle 8.42 EnviousWispr peer study). JSONL corpus + judge +
  runner emitting precision@k / recall@k / MRR.

## Related

- `../` — parent scripts directory (build + packaging).
- `../../docs/eval/` — evaluation methodology docs
  (`brief-quality.md`, `recall-quality.md`).
- `../../core/brief-eval/` — the in-tree Rust brief-eval crate
  (ADR-0018 §7).
- `../../eval/ner-corpus/` — the NER corpus that ADR-0029 gates on.

## When to edit here

Adding a new eval harness (a new quality surface to measure) or
extending an existing one with new metrics. Any harness must emit a
reproducible scorecard artifact that the fleet can commit to
`docs/eval/` — do NOT produce eval numbers that only live in a
run log. Corpus data goes under a corpus subdir (see
`recall/test-corpus.example.jsonl`), never inline in code.
