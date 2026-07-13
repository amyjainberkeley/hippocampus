# docs/eval/

Evaluation methodology docs — the "how we measure quality" side of
the eval story. Paired with `../../scripts/eval/` (the runners) and
`../../core/brief-eval/` (the in-tree brief-eval crate).

## Contents

- `brief-quality.md` — the brief-authoring eval scorecard
  (ADR-0018 §7 gate). Rubric, corpus source, scoring.
- `recall-quality.md` — the recall-quality benchmark methodology
  (paired with `../../scripts/eval/recall/`).

## Related

- `../../scripts/eval/` — the runners that produce scorecards.
- `../../core/brief-eval/` — the in-tree Rust brief-eval crate.
- `../../eval/ner-corpus/` — the NER corpus used by ADR-0029.
- `../decisions/0018-brief-authoring-approval-pipeline.md`,
  `0029-step2-7-corpus-gate.md`.

## When to edit here

Adding or revising a quality-measurement rubric. Any change that
alters what "passing" means for a shipping gate (brief-quality,
recall-quality, NER-corpus) is CEO-ratified — do NOT quietly
weaken a bar. Corpus data + runner code belong under
`../../scripts/eval/` or `../../eval/`, not here.
