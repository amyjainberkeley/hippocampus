# Brief-author quality eval (ADR-0028 gate)

This is the offline, reproducible quality gate behind `docs/DOGFOOD_V1.md` item #20.
The framework lives in `core/brief-eval/` and exists so that when the CEO runs the
Core ML conversion (`docs/STATE.md` `OWNER_TASKS` #17), there is a real way to decide
whether `Qwen3-1.7B` INT4 is good enough to ship.

The framework writes nothing to the protected set
(`docs/AGENT_PROTOCOL.md` §5). It reads synthetic JSONL fixtures, calls the
existing `BriefAuthor` surface (`core/brief/`), and emits a structured
PASS / FAIL report. CI runs the deterministic scripted backend; the CEO points
the same driver at the real `.mlmodelc` after the conversion lands.

## Corpus

Eight synthetic "day's worth of events" fixtures live under
`core/brief-eval/fixtures/days/`. Each is paired with a hand-authored gold
spec under `fixtures/gold/<name>.json` and a scripted "what a passing brief
should look like" Markdown file under `fixtures/scripted/<name>.md`. All
data is synthetic — no real user content.

| Fixture | Character | Events | Notes |
|---|---|---|---|
| `day_light` | Low activity | 6 | Email cleanup, two Slack DMs about icon mocks, one Notion edit |
| `day_deep_work` | Single-app focus | 10 | VS Code + Terminal stretch; wrote a scorer, fixed one test, shipped a PR |
| `day_fragmented` | Context-switching | 15 | Planned fixtures work, got pulled into a PR #155 entitlements triage |
| `day_all_meetings` | Meeting day | 9 | 5 Zoom sessions plus a hiring loop |
| `day_shipping` | Ship-day | 10 | PR #164 reviewed by CSO and merged same day |
| `day_blocked` | Stuck-all-day | 10 | Wrestled a Qwen3 Core ML shape mismatch; never resolved |
| `day_research` | Reading + notes | 10 | Three arxiv papers, three Notion writeups, handoff to CRS |
| `day_review_heavy` | Code review | 9 | Reviewed 3 PRs, merged 2, flagged an incognito-exclusion regression |

The corpus deliberately spans the brief-author's failure modes: under-claiming
on a light day, mis-summarizing a fragmented day, hallucinating shipped work
when the day was actually blocked, inventing app names that weren't present.

## Metrics

The scorer (`core/brief-eval/src/scorer.rs`) computes six metrics per fixture:

| Metric | Definition | Default threshold |
|---|---|---|
| `fact_coverage` | Fraction of `required_facts` substrings (case-insensitive) appearing in the brief title or body | ≥ 0.80 |
| `forbidden_hits` | Count of `forbidden_terms` substrings appearing in the brief | = 0 |
| `structure` | Brief has a non-empty title AND ≥ `min_section_bullets` bullet lines (`- `, `* `, `• `) AND ≥ `min_citations` `[event:N]` markers | true |
| `length` | Word count of the body within `[min_words, max_words]` | true |
| `citation_validity` | Fraction of unique cited event IDs that resolve to a real fixture event | ≥ 0.90 |
| `stub_fallback` | Count of `Worked on task related to event` (the `StubLlamaBackend` signature) | informational; required to be 0 when `--require-real-model` is set |

The fixture passes only when every metric passes. The aggregate run passes
only when every fixture passes.

### Proposed thresholds

`docs/decisions/0028-brief-author-model-qwen3-1.7b-coreml.md` cites the
ADR-0010 retrieval eval as the precedent gate for brief quality but does not
specify numeric thresholds for INT4 brief output. The defaults in
`PassThresholds::default()` are this PR's proposal:

- `min_fact_coverage = 0.80` — the brief must mention at least 4 in 5 named
  facts. Stricter (0.95) overfits the gold spec; weaker (0.60) lets a
  noticeably-bad brief through. 0.80 catches both "missed two big things" and
  "missed one big thing plus had a vague day."
- `max_forbidden_hits = 0` — any hallucinated app or product name fails. The
  zero-knowledge invariant means we cannot afford a brief that mentions tools
  the user didn't actually use. Per ADR-0018 §4.8 the structural tripwire
  enforces this on the citation side; the scorer extends it to the prose.
- `min_citation_validity = 0.90` — mirrors ADR-0018 §4.8 ("every output
  bullet carries ≥ 1 source-event-ID"). 1.0 is too strict for INT4 (a single
  rare digit-corruption fails the run); 0.90 tolerates the occasional model
  glitch while still rejecting wholesale fabrication.
- `require_real_model = false` — default off, since the scripted-backend CI
  run still uses the wrapper. The CEO flips it on for the real-model run.

The CEO either ratifies these defaults or proposes revised values in the same
session as `OWNER_TASKS` #17.

## How to run it

### Default CI run (deterministic, no model)

```text
cargo test -p mci-brief-eval --test brief_eval
```

The integration test (`core/brief-eval/tests/brief_eval.rs`) walks every
fixture under `fixtures/days/`, runs `LlamaBriefAuthor` with the
`ScriptedLlamaBackend` (replaying `fixtures/scripted/<name>.md`), and
asserts every fixture passes. A second test asserts `StubBriefAuthor` does
NOT pass — so a future scorer regression that softens the eval is loud.

### Interactive run with the scripted backend

```text
cargo run -p mci-brief-eval --bin brief-eval -- --all
```

Tabular per-fixture, per-metric output. Exit code 0 on pass, 1 on fail.

### Real-model run (CEO mode, after `OWNER_TASKS` #17)

```text
cargo run -p mci-brief-eval --bin brief-eval --features coreml -- \
    --all --backend coreml \
    --model-path  "$HOME/Library/Application Support/MCI/Models/Qwen3-1.7B-INT4.mlmodelc" \
    --tokenizer-dir "$HOME/Library/Application Support/MCI/Models/Qwen3-1.7B-INT4-tokenizer" \
    --require-real-model
```

The `--require-real-model` flag adds the `stub_fallback` metric gate, so any
run that silently falls back to the stub backend (e.g. a missing
`.mlmodelc`) fails loudly instead of producing a misleadingly-passing report.

The eval reuses the production wrapper. The model gets the same prompt
template the agent shell will eventually feed it, including the
`###CITATIONS:` stop marker and the Qwen3 ChatML `/no_think` directive.

## What a pass means

A passing run on the scripted backend proves the eval's framework + scorer
work end-to-end — it does NOT prove the real model is shippable.

A passing run on the `coreml` backend with `--require-real-model` on a clean
fixture set means:

- Qwen3-1.7B INT4 produces briefs that name ≥ 80% of the right things, with
  zero hallucinated apps/products, with valid citations on ≥ 90% of bullets,
  with the expected section/bullet structure, within the expected length
  window — across a representative spread of day types.
- The model is ready to flip the daily-brief surface on for the dogfood
  cohort. `DOGFOOD_V1.md` item #20 can be checked off.

A FAIL on the `coreml` backend is read by inspecting which metric tripped
on which fixture. Common failure modes:

| Failure | Reading |
|---|---|
| Low `fact_coverage` on `day_deep_work` or `day_shipping` | Model isn't anchoring on artifacts (PR numbers, scorer name). Try lower temperature or a longer prompt. |
| Non-zero `forbidden_hits` on `day_blocked` | Model is inventing wins (e.g. "merged PR" on a day where nothing merged). Quantization or prompt issue — escalate to CRS Arxiv/OSS Scout for re-eval. |
| Low `citation_validity` | Tokenizer drift between the prompt-time event IDs and what the model emits. Re-check `vocab.json` + `merges.txt` are the Qwen3 variant. |
| Out-of-window `length` on `day_light` | Model padding short days. Acceptable if the proposed thresholds widen `max_words`; otherwise revisit prompt instructions. |
| `stub_fallback` > 0 with `--require-real-model` | `.mlmodelc` failed to load; the path or tokenizer dir is wrong. |

## Worked example

A run against the scripted backend on the `day_light` fixture:

```text
$ cargo run -p mci-brief-eval --bin brief-eval -- --fixture day_light
MCI brief-author eval — backend: scripted (LlamaBriefAuthor + ScriptedLlamaBackend)
Fixtures: 1 | Passed: 1 | Author time: 51.00µs
------------------------------------------------------------------------
[PASS] day_light                words=63   bullets=5   cites=5   unresolved=0
  ✓ fact_coverage        value=1.000    threshold=0.800     4/4 required facts present
  ✓ forbidden_hits       value=0.000    threshold=0.000     none
  ✓ structure            value=1.000    threshold=1.000     5 bullets (need ≥3), 5 citation markers (need ≥3), title_present=true
  ✓ length               value=63.000   threshold=30.000    63 words (window: 30..220)
  ✓ citation_validity    value=1.000    threshold=0.900     5/5 cited ids resolve
  ✓ stub_fallback        value=0.000    threshold=0.000     informational; 0 stub-signature phrases

Overall: PASS (1/1 passed)
```

The brief being scored is `fixtures/scripted/day_light.md`. Its source
events live in `fixtures/days/day_light.jsonl`. The gold spec
(`fixtures/gold/day_light.json`) listed `["Slack", "icon", "Notion",
"inbox"]` as `required_facts` — all four appear in the brief body, so
`fact_coverage = 4/4`. The gold listed `["Xcode", "Zoom", "GitHub", "PR #",
"deploy"]` as `forbidden_terms` — none appear, so `forbidden_hits = 0`.
Bullets and citation markers exceed the gold minimums; word count sits
inside the window; every citation resolves to a real `event_id` in the
fixture. All six metrics pass.

If you then run the same fixture with the stub backend
(`--backend stub`), the run fails as expected: `StubBriefAuthor`
concatenates raw event text with no citations or bullet markers, so the
`structure` metric trips. That's the framework working as designed — the
stub is a development placeholder, not a shipping product.

## Adding a fixture

1. Write `fixtures/days/<name>.jsonl` — synthetic events, one per line.
   Pick a coherent day character. Keep event IDs unique within the file
   and disjoint from existing fixtures if possible (helps reading the
   per-fixture failure dumps).
2. Hand-author `fixtures/scripted/<name>.md` — the brief you'd want a
   passing model to produce. Use `[event:N]` markers and a
   `###CITATIONS:` trailer. Add a title on the first line.
3. Write `fixtures/gold/<name>.json` — describe what makes a passing
   brief for this day: `required_facts`, `forbidden_terms`, length window,
   bullet/citation minimums. Tune the thresholds against the scripted
   brief — the integration test asserts the scripted brief passes.
4. Run `cargo test -p mci-brief-eval --test brief_eval`. If the new
   fixture fails the scripted-backend pass, either the gold thresholds
   are too tight or the scripted brief doesn't cover the gold's required
   facts. Loop until green.

## Relationship to ADR-0028

- ADR-0028 §"Negative / tradeoff" cites ADR-0010 as the eval gate for
  brief quality. ADR-0010 is the retrieval eval (event-as-unit, CC fusion);
  this framework is its brief-author counterpart.
- ADR-0028 § 7 says `StubLlamaBackend` remains active when the model is
  not downloaded. The `--require-real-model` flag here gives the CEO a
  way to assert "no, I really did want the real model" — the eval reports
  the stub signature explicitly instead of silently grading stub output.
- The framework grades the brief-author end-to-end, not just the model.
  Tokenizer bugs, prompt regressions, citation-parser regressions all
  show up as eval failures with a specific metric to read.

## Relationship to ADR-0018

The hallucination tripwire in ADR-0018 §4.8 is structural (every bullet
must carry a resolvable `[event:N]`). The eval's `citation_validity`
metric is the test-side complement: it grades the same property on
hand-curated fixtures so a tripwire-breaking model change is caught
before it ships.
