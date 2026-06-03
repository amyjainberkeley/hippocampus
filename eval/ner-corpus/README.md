# MCI synthetic screen-text NER eval corpus

A labeled, **100 % fabricated** corpus for evaluating named-entity
recognition (NER) on **screen text** across the five MCI entity kinds:
`person_name`, `organization`, `location`, `date`, `time`.

It exists because **every public NER benchmark is newswire** (CoNLL-2003,
OntoNotes) and those F1 numbers do **not** transfer to OCR'd screen text —
chat fragments, email headers, UI chrome, notification banners, terminal
output, with OCR noise, truncation, and no sentence boundaries. The
V2-P5+ NER pin (a supervised CoNLL token-classifier for Person/Org/Loc;
see [`project-gliner-variant-pin`] and
`docs/research/2026-06-03-ner-backbone-convertibility-scan.md`) must be
chosen on **our** domain, so we need a screen-text-domain labeled set to
run the bake-off against.

No public screen-text NER corpus exists, so this clean, reproducible
synthetic set is also a candidate **publishable artifact**
([`project-open-to-publish-novel-work`]). This README is the reproducibility
record: generation method, per-kind label guidelines, the hardness
taxonomy, and the measured annotation consistency.

> **Scope note — this is the FABRICATED SYNTHETIC BULK only.** The CEO
> ratified a *hybrid* corpus: this synthetic bulk (committable / shareable)
> **plus** a separate, later, **local-only hand-labeled REAL slice** of the
> CEO's own captured OCR text. The real slice touches `mci.sqlite` (a §5
> protected store) and the CEO's real screen content — it **must stay
> local-only / gitignored, never committed**, and is a deliberately
> separate task. **Nothing in this directory touches `mci.sqlite` or any
> real capture.**

---

## Layout

```
eval/ner-corpus/
├── README.md                   ← this file
├── raw/
│   ├── raw_marked_samples.json ← LLM fleet output (inline-markup), pre-build provenance
│   └── dropped.json            ← samples rejected by the builder (malformed markup), with reasons
├── synthetic/
│   ├── corpus.full.json        ← all 415 samples
│   ├── dev.json                ← 190 samples (40 %, stratified) — for any threshold tuning
│   ├── test.json               ← 225 samples (60 %, stratified) — for the reported bake-off number
│   ├── manifest.json           ← build stats (per-kind / genre / variant / hardness distribution)
│   └── consistency.json        ← measured annotation-consistency report
└── tools/
    ├── build_corpus.py         ← markup → byte-offset gold; validate; dedup; stratified split
    ├── score_ner.py            ← per-kind P/R/F1 scorer (EXACT + RELAXED); self-test; unit-test
    └── consistency_report.py   ← reproducible annotation-consistency measurement
```

---

## Gold schema (matches the V2-P4/V2-P5 extractor surface exactly)

Each sample:

```json
{
  "id": "browser_page-adversarial_negatives-0000",
  "genre": "browser_page",
  "variant": "adversarial_negatives",
  "text": "Greyhill Daily · World\nHome › Politics › Coverage\n\nFlood Defenses Hold as Storm Nears Carrowmere\nBy Dana Sterling · Updated June 14, 9:42 AM\n...",
  "entities": [
    { "kind": "location",    "span_start": 91,  "span_end": 101, "mention_text": "Carrowmere" },
    { "kind": "person_name", "span_start": 105, "span_end": 118, "mention_text": "Dana Sterling" },
    { "kind": "date",        "span_start": 130, "span_end": 137, "mention_text": "June 14" },
    { "kind": "time",        "span_start": 139, "span_end": 146, "mention_text": "9:42 AM" }
  ],
  "hardness_tags": ["all_caps", "ambiguous_token", "multi_entity", "ui_chrome_interleaved"]
}
```

Each entity mirrors the in-memory schema that **both** the V2-P4
`Tier1Match` and the V2-P5 `Tier2Match` emit
(`core/brain/src/extraction/{tier1,tier2}.rs`):

| field          | meaning |
| -------------- | ------- |
| `kind`         | one of the 5 `entities.kind` strings below |
| `span_start`   | **inclusive UTF-8 byte offset** into `text` |
| `span_end`     | **exclusive UTF-8 byte offset** into `text` |
| `mention_text` | the literal surface; **invariant:** `text.encode('utf-8')[span_start:span_end].decode() == mention_text` |

This is exactly the Tier 2 extractor's `verify_span` check. `canonical_name`
is **intentionally omitted** from gold — it is an extractor-side
normalization (title-case for people, digits-only for phones, …), not a
labeling target. The bake-off scores **span detection + kind
classification**, keyed on `(kind, span_start, span_end)`.

### Entity-kind strings

| corpus kind     | MCI `entities.kind` | source of truth |
| --------------- | ------------------- | --------------- |
| Person          | `person_name`       | `core/brain/src/extraction/tier2.rs::KIND_PERSON_NAME` (**locked in code**) |
| Organization    | `organization`      | `core/brain/src/extraction/tier2.rs::KIND_ORGANIZATION` (**locked in code**) |
| Location        | `location`          | `core/brain/src/extraction/tier2.rs::KIND_LOCATION` (**locked in code**) |
| Date            | `date`              | **Director-defined** (see fork below) |
| Time            | `time`              | **Director-defined** (see fork below) |

> ### ⚠️ Date/Time schema fork (verify-audit finding, surface to CTO/CEO)
>
> The ratification memo ([`project-gliner-variant-pin`]) states Date/Time
> come from "the **shipped** V2-P4 Tier-1 regex". **Verify-audit against
> `main@2983fc9` found this is not yet true:** PR #282
> (`core/brain/src/extraction/tier1.rs`) ships URL / email / phone / IP /
> crypto / UUID / ULID / github-ref / file-path / redacted-token regexes
> and **no `date` or `time` kind**. There is no Date/Time `kind` string
> anywhere in `core/`.
>
> So `date` / `time` here are **Director-chosen**, following the existing
> lowercase-snake convention (`person_name`, `organization`, `location`,
> `url`, `email`, …). When the V2-P4 Date/Time regex actually lands, if it
> picks different strings, **only one line changes**: `KINDS` in
> `tools/score_ner.py` (and `tools/build_corpus.py`). The scorer's kind set
> is config-driven (`--kinds`) precisely so this rename is free, and
> `--kind-map` remaps a model's own label strings (e.g. `PER →
> person_name`) onto the corpus set.

---

## Per-kind label guidelines

A mention is labeled wherever it appears in the text — in prose **and** in
structural positions (chat speaker tags, email header values, calendar
fields, commit authors) — because a CoNLL-trained model will surface
name-shaped tokens regardless of position, and the eval must score that
fairly.

- **`person_name`** — a human name: given/family names, `Dr. Chen`,
  `Coach Drummond`, initials used as a name, a handle that clearly denotes
  a person. Span = the name only (not a trailing `:` speaker colon, not a
  job title alone).
- **`organization`** — a company, team, institution, agency, school, club,
  band, publication: `Tornquist Labs`, `Greyhill Capital`, `the Brain
  team`, `City Health Dept`, `Northwind Aviation`.
- **`location`** — a physical place: city, country, region, building, room,
  street, venue, landmark: `Carrowmere`, `Building 4`, `Room 3F`,
  `412 Alder St`, `Dunmore Pier`, `the north office`.
- **`date`** — a calendar date or day-denoting expression: `2026-06-03`,
  `3/3/2026`, `March 3`, `Jun 14`, `Tue`, `Tuesday`, `tomorrow`,
  `yesterday`, `next Monday`, `the 14th`, `Q3`. Span = the **minimal
  contiguous** date expression.
- **`time`** — a clock time or named time-of-day: `3:00 PM`, `15:00`,
  `9am`, `9:30`, `noon`, `midnight`, `07:45`. **Durations are NOT time**
  (`5 minutes`, `2 hours` stay unlabeled). For a combined `2026-06-03
  14:30`, label `date="2026-06-03"` and `time="14:30"` as two adjacent
  spans.

### Hard negatives (the point of the corpus)

Left **unlabeled** on purpose, to test precision:

- Capitalized non-entities: sentence-initial caps, Title-Cased UI labels
  (`Save As`, `New Folder`, `Sign In`), Title-Cased common nouns.
- ALL-CAPS emphasis/labels: `URGENT`, `ERROR`, `TODO`, `WARNING`, `OK`,
  `CANCEL`, `SHARE · SAVE · PRINT`.
- **Ambiguous tokens** used in their non-entity / different-kind sense.
  The corpus deliberately reuses: `Washington, Apple, Phoenix, Jordan,
  Sydney, May, April, June, August, Mark, Bill, Rose, Grant, Will, Summit,
  Orange, Frank, Sterling, Brooklyn, Madison, Charlotte, Cleveland,
  Houston, Reading, Mobile, Nice`. E.g. `I'll mark it resolved` (verb,
  unlabeled) vs `Mark shipped it` (person); `Apple stock` (org) vs `an
  apple a day` (unlabeled); `flew to Phoenix` (location) vs `Phoenix Vela
  texted` (person).

---

## Genres (8) and hardness variants (3)

**Genres** (~52 samples each): `chat_imessage`, `email`, `browser_page`,
`doc_notes`, `ui_chrome`, `calendar_event`, `notification_banner`,
`terminal_code`.

**Variants** (~135–144 each):

- `natural_mixed` — realistic, mostly clean, mixed-case; multi-entity
  density; all 5 kinds.
- `ocr_noisy` — heavy OCR degradation applied to content **and** entity
  surfaces (entities are labeled on their noised surface).
- `adversarial_negatives` — dense hard negatives + ambiguous tokens in
  both senses + zero-entity samples; precision stress.

### Hardness taxonomy (`hardness_tags`)

| tag | meaning |
| --- | ------- |
| `ocr_noise`           | simulated OCR errors: `rn↔m`, `0↔O`, `l↔1↔I`, `cl↔d`, `vv↔w`, dropped/injected spaces, doubled/missing letters |
| `truncated`           | a word/fragment cut at an edge (`…quarterly revi`) |
| `no_boundary`         | run-on text with missing sentence boundaries |
| `all_caps`            | ALL-CAPS spans present (entities and/or negatives) |
| `mixed_case`          | natural mixed/erratic casing |
| `ui_chrome_interleaved` | UI chrome (receipts, buttons, nav, timestamps) interleaved with content |
| `ambiguous_token`     | contains a token from the ambiguous list (in entity and/or negative sense) |
| `multi_entity`        | ≥ 3 labeled entities (derived from the gold) |
| `hard_negative`       | contains deliberate capitalized/ALL-CAPS/ambiguous non-entities |
| `zero_entity`         | no labeled entity at all — pure precision probe (derived from the gold) |

`multi_entity` and `zero_entity` are **derived from the actual entity
count** by the builder, so they are authoritative regardless of how the
generator tagged a sample.

---

## How it was generated (reproducibility)

1. **Generate.** 24 cells = 8 genres × 3 variants. One LLM agent per cell
   produced ~17–18 samples, emitting each sample as one screen-text
   fragment with **inline entity markup**: `⟦KIND⊳SURFACE⟧` (sentinels
   `⟦` U+27E6, `⊳` U+22B3, `⟧` U+27E7 — effectively impossible in real
   screen text). Hard negatives are left unwrapped.
2. **Audit.** An independent LLM agent re-audited each cell's batch for
   label correctness (wrong kind, loose spans, missed entities, false
   wraps, markup errors). 101 of 417 samples were auditor-corrected.
3. **Build (deterministic, this repo's `build_corpus.py`).** Parse the
   markup left-to-right, **computing exact UTF-8 byte offsets in code** —
   the generator never counts offsets, it only draws spans, so the
   `text[s:e] == mention` invariant holds by construction. Validate, drop
   malformed markup (2 of 417), dedup, and split dev/test by a
   deterministic per-(genre,variant) round-robin (no RNG).

Why markup → code-computed offsets: LLMs are unreliable at counting
byte/char offsets, especially on OCR-noised or truncated text. Letting
code derive the offsets from a drawn span eliminates that entire error
class and makes the gold-vs-gold scorer self-test a trivial F1 = 1.0.

Regenerate the corpus from the frozen raw markup at any time:

```bash
python3 eval/ner-corpus/tools/build_corpus.py \
  --raw eval/ner-corpus/raw/raw_marked_samples.json \
  --out-dir eval/ner-corpus/synthetic \
  --manifest eval/ner-corpus/synthetic/manifest.json \
  --dropped-out eval/ner-corpus/raw/dropped.json
```

---

## Scoring (the bake-off harness)

```bash
# self-test: gold scored against itself -> F1 == 1.0 for all kinds, both modes
python3 eval/ner-corpus/tools/score_ner.py --self-test eval/ner-corpus/synthetic/test.json

# matcher correctness on a known case (proves F1==1.0 is not vacuous)
python3 eval/ner-corpus/tools/score_ner.py --unit-test

# score a model's predictions (same entity schema; mention_text optional)
python3 eval/ner-corpus/tools/score_ner.py \
  --gold eval/ner-corpus/synthetic/test.json \
  --pred preds.json \
  --kind-map '{"PER":"person_name","ORG":"organization","LOC":"location"}'
```

Predictions format: `[{ "id": "...", "entities": [{ "kind", "span_start",
"span_end" }] }, …]` (or `{id: [entities]}`). Reports **per-kind +
micro + macro** precision / recall / F1 in two modes:

- **EXACT** — predicted `(span_start, span_end)` equals a gold span of the
  same kind (strict V2-P3 entity-row criterion).
- **RELAXED** — predicted span overlaps a gold span of the same kind (any
  shared byte). Tolerates the off-by-a-token boundary drift OCR induces.

Matching is one-to-one and greedy (exact pairs first, then in RELAXED the
rest by descending overlap), so one fat predicted span cannot claim credit
for several gold spans. Report **both** modes; the gap between them is the
model's boundary-precision tax on screen text.

---

## Annotation consistency (measured, honest)

Like any multi-annotator corpus, this one has residual drift; we measure
rather than hide it (`tools/consistency_report.py`,
`synthetic/consistency.json`):

- **Multi-kind surfaces (11):** almost entirely **intentional ambiguous
  tokens** (`Phoenix`, `Washington`, `Madison`, `Sydney`, `Houston`,
  `Greyhill`, …) taking different senses by context — the designed hard
  ambiguity. A few single-off minority assignments reflect genuine
  contextual ambiguity.
- **Speaker-tag misses:** 6 mentions (~**0.47 %**) where a chat speaker
  `Name:` was left unlabeled though the same name is labeled elsewhere —
  one-directional (recall holes in gold), so it depresses precision
  equally for **every** bake-off candidate and does not change the
  ranking.
- **Article/boundary variation (32 occurrences):** known entity surfaces
  appearing unlabeled as a substring, almost all because the labeled span
  omits a leading determiner (`the Brain team` vs labeled `Brain team`).
  The **RELAXED** scorer mode absorbs these; **EXACT** correctly counts
  them as a boundary miss.

Net genuine one-directional label noise is **< 1 %** — within normal human
NER inter-annotator disagreement and, being one-directional and uniform,
ranking-robust for a relative bake-off. Gold spans were **not**
auto-mutated to chase this last fraction: mutation would muddy the
artifact's provenance and risk introducing new errors. The convention is
documented above; the residual is reported here.

---

## Provenance / privacy

100 % fabricated — invented-but-realistic names, orgs, places, dates,
times. **Zero** real people, companies, products, addresses, or data from
any real source or machine. No `mci.sqlite` access, no real capture, no
network. Safe to commit, share, and publish. See the PR's driver-CSO
mini-audit note.

[`project-gliner-variant-pin`]: docs/research/2026-06-03-ner-backbone-convertibility-scan.md
[`project-open-to-publish-novel-work`]: docs/DESIGN.md
