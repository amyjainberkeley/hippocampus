# Local extractive relevance regressions

This is a deterministic, synthetic regression corpus for source selection and
presentation. It does not measure semantic understanding, correctness of captured
claims, or trusted-answer qualification. All generated briefs remain Drafts.

## Reproduce

Run from the workspace root, using the default shared target directory:

```sh
cargo test --offline --locked -j 2 -p mci-brief-eval --test extractive_quality -- --nocapture
cargo run --offline --locked -j 2 -p mci-brief-eval --bin brief-eval -- --all --backend extractive
```

The first command scores `fixtures/extractive/corpus.json`. The second uses the
eight historical synthetic days and their original gold answers. No historical
day, gold answer, scripted output, or threshold was changed for these regressions.

## Rubric

- Noise: count fixture-labeled unwanted strings still present in output.
- Repetition: count extra occurrences of labeled excerpts, including repetition
  within one bullet, or identical repeated bullets, whichever count is larger.
- Source retention: a labeled source excerpt must appear intact in a bullet with
  an allowed event ID. A raw dump still earns retention credit where appropriate.
- Grounding: every parsed bullet's evidence, after reversing numeric Markdown
  escapes and removing its source label, must occur in the cited event after
  whitespace normalization. This checks textual containment, not factual truth.
- Injection: count fixture-labeled instruction and active-formatting strings.
  Captured links and HTML must render as literal text. These finite labels cannot
  establish resistance to all possible prompt injection.
- Draft and structure: no approval or approver; at most nine bullets; every bullet
  has one generated citation marker; markers match the citation list. Cases
  labeled empty must return `NoEvents`, not a synthetic work statement.

The scorer has negative controls for dropping all useful work, repeating text
inside or across bullets, citing stale or nonexistent sources, invented text,
injected instructions, and non-Draft state.

## Historical measurements

The 2026-09-02 historical report in `docs/eval/brief-extractive-baseline.md`
records 8/8 on the original corpus, with 37/37 required facts and 69/69 valid
citations. That result concerns its original substring/structure rubric. It is
not a relevance score, and `--require-real-model` only rejects the known stub
signature; passing that flag does not mean an extractive author is an LLM.

Measured before changing the author on 2026-09-05:

- Checkout: `5613e3c839aa871ec0742ab06e771f174450d00b`.
- Author source blob: `f9c639607032ffa7e13cc068bc0be3330ea8bbbb`.
- Author provenance: `hippocampus-extractive`, version `1`.
- New corpus: 2/10 cases passed; 15/18 source excerpts retained; 13 noise hits;
  three extra repetitions; nine injection/formatting hits; one ungrounded or
  malformed bullet. Every produced object was a Draft.

These are recorded pre-change results, not a frozen reimplementation of the old
author. The corpus's new expectations were exercised against that author before
implementation; the original gold answers remain independently tested.

September 6 integration, extractive author version 2: **10/10 cases passed**,
18/18 labeled source excerpts retained, zero labeled noise, extra repetitions,
injection/formatting hits or ungrounded/malformed bullets. The historical eight
days also pass without changing their inputs or thresholds. This is a finite
regression result, not a claim of complete recall or prompt-injection immunity.

Separate oversized-input regressions reproduced a 1,125,249-byte body and a
long hypothetical sentence being admitted without any size limit. The author
now bounds escaped body output to 16,384 bytes, omits source lines larger than
2,048 bytes whole, and falls back from oversized source labels. It does not
truncate a sentence before a trailing qualification. Generated citations refer
only to emitted bullets; the complete original event remains in the store.

Live review of the September 6 installed app exposed another gap outside the
ten-case corpus: Finder gallery metadata, OCR icon fragments and counters still
filled daily-summary slots. Two new behavioral regressions in
`core/brief/tests/extractive_regressions.rs` failed before the correction.
Finder excerpts now require at least three words and a recognized work-activity
signal. Useful file-preview work excerpts remain eligible, but unfamiliar
Finder prose can be omitted. Other applications are not subjected to that
Finder-specific rule. This improves source selection, not semantic truth, and
does not remove original events or images. The ten-case and historical corpus
inputs and scores are unchanged; the separate regression suite has 15 cases.

## Limits

Filtering and ranking use finite, primarily English lexical rules. Unrecognized
content remains eligible, and relevant prose using familiar UI words is retained.
The author does not infer tasks, reconcile contradictions, resolve negation, or
judge personal versus professional importance. It keeps differing wording and
numbers rather than using fuzzy similarity to merge facts. The caller supplies
sampled 512-byte snippets; evidence beyond those snippets is unavailable here.

The structural tripwire is unchanged and uses word overlap, not per-claim proof.
No installed app, capture runtime, production brain, configuration, network, or
model download is involved in these tests. Integration and installed-app review
remain separate work.
