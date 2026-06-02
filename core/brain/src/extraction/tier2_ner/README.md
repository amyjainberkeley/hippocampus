# Tier 2 Qwen NER — V2-P5

Model-driven named-entity recognition for the entity kinds that Tier 1
(V2-P4, `tier1_regex/`) cannot reach without LLM context: person names,
organizations, project / product names, locations, and free-form topics.

**Scope:** soft / open-vocab entities. Anything that has a deterministic
shape (URLs, emails, phone digits, IPs, crypto addresses, UUIDs, ULIDs,
GitHub PR refs, file paths, token-shape REDACT) is **out of scope** for
Tier 2 — Tier 1 already extracts it cheaply on the brain ingest hot path.

**Provenance tag** on every emitted `entity_mentions` row:
`extractor_kind = "qwen"` (V2-P3 schema convention; V2-P4 → `"regex"`,
V2-P5 → `"qwen"`, V2-P12 → `"user"`).

**Footprint discipline (G2 raised SLO).** Tier 2 runs in an async
idle-batch worker, NOT on the brain ingest hot path. Qwen3-1.7B
inference is ~100-500ms per call — well above the per-event burst
budget (≤25% CPU brief sub-second) the hot path holds. The idle-batch
pattern mirrors `apps/agent/src/idle_batch.rs` (the embedder batch);
single-flight + a tokio sleep interval bound the steady-state cost.

---

## Composition with V2-P4 (POST-cascade, POST-tier1)

Tier 2 runs **after** the ADR-0016 cascade AND after V2-P4's Tier 1
pass on the same event:

- Pixel-time §1–§5/§7 cascade arms have already dropped the frame
  (`BrainStore::put_event` rejects `cascade_reason != 0` per ADR-0016
  §4.3).
- OCR-time §6 redaction has replaced sensitive byte ranges with
  `[REDACTED:…]` markers.
- V2-P4 Tier 1 (`extraction/tier1.rs`) has already extracted URL,
  email, phone, IP, crypto-address, UUID, ULID, GitHub-ref,
  file-path, and `(redacted_token, <subkind>)` mentions.

Tier 2 composes two filters on top of the raw NER output:

### 1. Cascade-marker SKIP

A `[REDACTED:…]` span in the event text is content the cascade
already removed. The marker is **not** an entity for Tier 2 — V2-P4
already wrote a `(redacted_token, cascade_redacted)` entity for it.
Tier 2 drops any NER match whose `(span_start, span_end)` overlaps
a cascade-marker span.

### 2. Token-REDACT downstream SKIP (load-bearing)

V2-P4's token-shape REDACT discipline replaces source bytes with
subkind labels in `entities.canonical_name` / `entity_mentions.
mention_text`. The source bytes (e.g. the JWT, the AWS access key)
are still present in `events.text` — V2-P4 doesn't rewrite the text,
it just refuses to persist the bytes through the entity surface.

A naive Tier 2 NER pass could re-leak the bytes: Qwen might classify
a JWT as an `organization` because the base64url shape looks
identifier-like, then persist the JWT bytes as `mention_text =
"eyJhbGc…"`. That defeats V2-P4's token-shape REDACT discipline.

So Tier 2 derives the V2-P4 redacted-token span set on the same
text (no DB roundtrip, just rerun the Tier 1 regex bank) and drops
any NER match whose span overlaps. CSO mini-audit row #3 pins this.

The redacted-token-shape kinds Tier 1 covers are: `jwt`,
`aws_access_key`, `github_pat`, `stripe_api_key`, `bitcoin_wif`,
`cascade_redacted`. All overlap-with-Tier1-redaction get dropped from
Tier 2 output.

---

## Entity kinds

Each kind in this table is an `entities.kind` value. The full set is
documented in `extraction/tier2.rs` as `KIND_*` constants.

| Kind             | Canonical-name normalisation                                                                     | Why Qwen + not regex                                                                                              | Fixture                          |
| ---------------- | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| `person_name`    | Title-cased display form (e.g. `Alice Smith`, `Dr. Chen`). V2-P6 `AliasResolver` clusters later. | Person names are open-vocab; capitalised-bigram regex over-matches (every TitleCase phrase) and under-matches (lowercased mentions). | `fixtures/person_name.txt`       |
| `organization`   | As-displayed form (e.g. `Anthropic`, `Stripe Inc.`, `the Brain team`).                          | Orgs span proper nouns, acronyms, possessives, and informal team names ("the Brain team") — no closed shape.       | `fixtures/organization.txt`      |
| `project_name`   | As-displayed (e.g. `MCI`, `V2-P5`, `the recall surface rewrite`).                                | Projects are often jargon, acronyms, or informal references that require LLM context.                              | `fixtures/project_name.txt`      |
| `product_name`   | As-displayed (e.g. `Hippocampus`, `Claude Code`, `iPhone 15 Pro`).                              | Products mix branded names + model numbers + versions; regex would need a huge gazetteer.                          | `fixtures/product_name.txt`     |
| `location`       | As-displayed (e.g. `San Francisco`, `Apple Park`, `office 3F`).                                  | Locations include cities, building names, and informal labels — open-vocab.                                        | `fixtures/location.txt`         |
| `topic`          | Lowercased noun phrase (e.g. `footprint slo`, `oauth migration`, `q3 hiring`).                  | Free-form subject matter; no structural shape.                                                                     | `fixtures/topic.txt`            |

---

## Confidence threshold

Mentions below the per-extractor confidence floor are dropped. Default
is `DEFAULT_CONFIDENCE_THRESHOLD = 0.5`. The Qwen structured-output
prompt instructs the model to emit a per-mention confidence in
`[0.0, 1.0]`; 0.5 leaves a margin for borderline mentions while
dropping the obvious hallucinations.

Tests can override via `Tier2Extractor::with_threshold(...)`.

---

## Hallucination guard

Backends emit `(kind, canonical_name, mention_text, span_start,
span_end, confidence)` for each candidate. The extractor verifies:

1. `span_end > span_start` and `span_end <= text.len()`.
2. Both span boundaries land on UTF-8 char boundaries.
3. `text[span_start..span_end] == mention_text` (verbatim).

A backend that emits a span pointing at "Alice" but a mention_text
of "Bob" (model hallucinated the offset) is dropped. A backend that
emits an out-of-bounds span is dropped. A backend that emits a span
landing mid-multi-byte-char is dropped.

This guard is necessary because Qwen-with-structured-output
occasionally drifts on offsets when the input contains tokenisation
boundaries the model can't see (e.g. non-ASCII text).

---

## Idempotency

Same content-stable ULID discipline as V2-P4 (see
`core/brain/src/graph.rs` module doc):

- `Entity::derive_id(kind, canonical_name)` — same input → same ULID.
- `EntityMention::derive_id(entity_id, event_id, "qwen",
  mention_text)` — same input → same ULID.

Running the extractor twice on the same event produces the same
matches; the SQLCipher impl's `INSERT OR IGNORE` on `entity_mentions`
makes the second pass a no-op at the row level.

---

## Sentinel "processed" marker (idle-batch watermark)

Per processed event, the worker writes:

- 0..N real Tier 2 mentions (real entities + mentions).
- **1 sentinel mention** pointing from the singleton
  `(extractor_status, qwen_tier2_processed)` entity to the event,
  with `extractor_kind = "qwen"`, `mention_text = None`,
  `confidence = 1.0`.

The "needs processing" query then becomes:

```sql
SELECT e.id, e.text, ...
FROM events e
LEFT JOIN entity_mentions m
  ON m.event_id = e.id
  AND m.entity_id = <sentinel_id>
WHERE m.event_id IS NULL
ORDER BY e.id
LIMIT ?
```

The sentinel guarantees an event whose NER output is empty is still
marked "done" and not re-scanned every cycle. This is the V2-P5
analog of V2-P3 / P3.8's `unembedded_events` query.

---

## Backend / Qwen prompt design

The `NerBackend` trait in `extraction/tier2.rs` is the abstract seam.
Production implementations:

- **`QwenTier2Backend`** (`apps/agent/src/tier2_qwen_backend.rs`) —
  wraps a `LlamaBackend` (`Qwen3CoreMLBackend` on macOS). Builds a
  structured-output prompt that asks Qwen to emit JSON of the form:

  ```json
  {
    "entities": [
      {
        "kind": "person_name",
        "canonical": "Alice Smith",
        "text": "Alice Smith",
        "span": [12, 23],
        "confidence": 0.95
      },
      ...
    ]
  }
  ```

  The prompt template lists the per-kind definitions (Person /
  Organization / Project / Product / Location / Topic) so the model
  has a closed kind set to choose from. The output is parsed by
  `parse_qwen_ner_output()` in the same file.

- **`MockNerBackend`** (in `extraction/tier2.rs`, ships in the
  `mci-brain` crate) — returns canned fixtures on every call. Used
  by tests + by the wiring-proof integration test in
  `apps/agent/tests/brain_tier2_wiring.rs` so the full pipeline
  exercises without needing the Qwen `.mlmodelc` on disk.

---

## Opt-in download / graceful no-op

Qwen3-1.7B is an **opt-in download** (per
[[project-llm-model-decisions]]), not bundled in the DMG. The model
lives at
`~/Library/Application Support/MCI/Models/qwen3-1.7b-fp16/Qwen3-1.7B-FP16.mlmodelc`
after the user opts in via the brief-author onboarding flow.

When the model is **not present** on disk, the V2-P5 idle-batch
worker enters **disabled-idle mode** — same pattern as
`apps/agent/src/brief_worker.rs::run_disabled_idle`. The worker
logs one line and idles on the shutdown channel; no busy-loop, no
repeated failure logs.

V2-P4 Tier 1 continues writing `(extractor_kind = "regex")`
mentions on the hot path regardless. Users who opt out of the LLM
download still get all V2-P4 structural entities.

When the model is present, the worker spawns a Qwen-backed
`Tier2Extractor` and processes events.

---

## Anti-patterns (deliberately skipped in Tier 2)

- **Token-shape extraction.** V2-P4 owns this; V2-P5 must not
  re-emit JWT / AWS / Stripe / GitHub-PAT / Bitcoin-WIF bytes. The
  cascade-skip + token-REDACT downstream filters above are
  load-bearing for this discipline.
- **Cross-event alias resolution.** "Alice", "alice@…",
  "+1 415 555…" → same Person ULID. That's V2-P6 `AliasResolver`,
  next-cycle PR. V2-P5 emits each mention as its own canonical_name
  and lets V2-P6 cluster them.
- **Cross-app `episode_edges`.** That's a Phase 6 PR 11 writer that
  reads V2-P5 + V2-P4 + V2-P6 output and writes the typed
  cross-episode graph.
- **Per-event semantic summary.** That's the V2-P5-after `entities.
  summary` + `summary_embedding` fill; out of scope for the
  initial Tier 2 PR.

---

## Forward compat (V2-MCP-3)

V2-MCP-3 (PR #286, merged 2026-06-02) shipped the hybrid materialize/
catalog aggregator. It did **not** add a `source` column to
`events`; V2-P5 reads the existing `events` schema unchanged. If a
future MCP transport PR adds a per-event source provenance tag,
V2-P5's filter chain is unaffected — it operates on `events.text`
only.
