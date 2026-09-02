# Extractive Brief Baseline

Measured: 2026-09-02  
Code baseline: `30c7580`  
Corpus: eight committed synthetic workdays in `core/brief-eval/fixtures/`

## Reproduce

```bash
cargo run -q -p mci-brief-eval --bin brief-eval -- \
  --all --backend extractive --require-real-model
```

## Result

| Measure | Result |
|---|---:|
| Fixtures passed | 8 / 8 |
| Required-fact coverage | 37 / 37 (100%) |
| Citation validity | 69 / 69 (100%) |
| Unresolved citations | 0 |
| Forbidden-term hits | 0 |
| Stub-signature hits | 0 |
| Total author wall time | 3.20 ms on the audit Mac |

Every fixture met its word-count, bullet-count, and minimum-citation window.
Per-fixture output ranged from 134 to 215 words and six to nine bullets.

## Interpretation

This proves that the shipping zero-download author preserves the facts named by
the current gold files, emits structurally valid briefs, and never invents a
citation on this corpus. It is a much stronger release baseline than the old
Qwen result, which passed four of eight fixtures and took about 71 seconds per
brief in the historical run; a later real run failed to finish one fixture in
121.5 seconds.

It does **not** prove that the brief selects the most important work, separates
personal from professional activity, resolves contradictory updates, groups
repeated evidence, or reads naturally to a person. Because the author extracts
source text, required-fact coverage is easier for it than for a generative
summary. The next corpus revision must add human relevance labels, stale-state
contradictions, repetitive OCR, and prompt-injection-like page text without
weakening this baseline.
