# ADR-0033 — `mci-coreml-bridge`: generic Core ML wrapper + per-model shims (Path A refactor + rename)

- Status: **Accepted** (2026-06-03; CEO-ratified Path A — see memory `[[project-coreml-bridge-path-a]]`)
- Owners: **Director-Brain** (refactor + rename + consumer migration; V2-P5+ GLiNER spike Phase 0)
- Reviewers: CEO (ratified the path + the rename name `mci-coreml-bridge` on the spike PR); CTO (adapter-below-the-seam discipline); CSO (no protected-set surface — this is a pure internal refactor, no crypto/capture/sync change).
- Phase: V2-P5+ (hybrid GLiNER NER spike), Phase 0 — lands ahead of the six measurement-bound spike phases.
- **Protected-set: no.** No change to crypto, key-management, sync, the sensitive-capture denylist/redaction, the stores, or entitlements. The crate is a macOS Core ML adapter that runs on-device model inference; it never touches user content at rest or the sync server.
- **Launch-blocker: no.** Internal refactor; the daily-brief author behavior is preserved byte-for-byte (see Consequences).
- **Relationship:** extends ADR-0028 (the Qwen3-1.7B brief author now loads through the generic `CoreMLModel` core rather than a bespoke Qwen-only loader; the `.mlmodelc` schema contract and the `attention_mask` all-ones invariant are unchanged). Sits below the `mci_brief::llama_backend::LlamaBackend` seam (ADR-0018 §1.2). The forthcoming GLiNER NER shim (V2-P5+ Phases 1–6) and the existing Qwen Tier-2 NER path (PR #288) are layered, not merged.

## Context

### The verify-audit finding (2026-06-01)

The V2-P5+ GLiNER spike dispatch assumed the `mci-llama-coreml` crate already exposed a *generic* `MLModel.prediction(from:)` wrapper that a GLiNER backend could reuse (CRS scout claim, reproduced in the dispatch as ratification #3). A pre-Phase-1 source audit refuted this:

- `Qwen3CoreMLBackend::open(model_path, tokenizer_dir)` was Qwen-specific: it loaded a byte-level BPE tokenizer (`vocab.json` + `merges.txt` → `tokenizer.json`) and ran `verify_schema()` that *required* exactly the inputs `input_ids` + `attention_mask` and the output `logits`.
- `forward_pass()` hardcoded a two-input feature dict, `Int32` dtype, shape `[1, 2048]`, and last-position logit extraction.
- `LlamaBackend::generate()` was an autoregressive sample-then-feedback loop. There was no flexible-IO `predict(feature_dict)` method.

GLiNER (`knowledgator/gliner-multitask-large-v0.5`, the CEO-ratified variant — see `[[project-gliner-variant-pin]]`) needs a different IO contract entirely: a DeBERTa-v3 SentencePiece tokenizer, multi-tensor inputs (`input_ids`, `attention_mask`, `words_mask`, `text_lengths`, `span_idx`, `span_mask`), and a span-score-grid output decoded by a span decoder — a single forward pass, not autoregressive sampling.

There was therefore no way to drive a GLiNER `.mlmodelc` through the Qwen-only surface. The spike halted before Phase 1 and escalated for a material-fork ratification. (The stale "generic FFI" claim is recorded in `[[project-mci-llama-coreml-is-generic]]`; the scout-claim-verification discipline that caught it is `[[feedback-crs-scout-subagent-hallucinates]]`.)

### Why `apps/agent` cannot host the FFI directly

`apps/agent/src/lib.rs` is `#![forbid(unsafe_code)]`, and `apps/agent` does not depend on `objc2-core-ml`/`objc2-foundation`. The adapter-below-the-seam discipline (ADR-0018 §1.2) reserves Core ML / `objc2` calls to the macOS adapter tier. A new `gliner_backend.rs` inside `apps/agent` that called Core ML inline is structurally blocked.

## Decision

**Path A (CEO-ratified):** refactor the crate into a generic core plus per-model shims, and rename it.

1. **Generic core** — `mci_coreml_bridge::model::CoreMLModel`: loads a compiled `.mlmodelc`, introspects its IO schema (`has_input`, `output_is_multi_array`), and runs an N-input feature-dict `predict(&[(&str, &MLMultiArray)])` returning a `Prediction` from which named `MLMultiArray` outputs are read. Plus `MLMultiArray` builders/readers (`multi_array_i32`, `read_f32_slice`, `f16_to_f32`) and a generic `CoreMLError`. No model-specific assumptions. (Int64 builders + a compute-unit-pinned loader + a full-array reader are added in later phases as the GLiNER shim needs them.)
2. **Qwen3 shim** — `mci_coreml_bridge::qwen3::Qwen3CoreMLBackend`: the existing `LlamaBackend` impl, now holding a `CoreMLModel` and routing load/predict/read through the generic core. The autoregressive `generate()` loop, temperature/top-p sampling, and repetition penalty are preserved verbatim. `CoreMLError` is mapped into `GenerateError::Backend` by display string, preserving every human-readable message (including the "model not found" path the unit tests assert).
3. **GLiNER shim** — added on top of the generic core in spike Phase 4 (DeBERTa-v3 SentencePiece tokenizer, multi-tensor IO, span-grid decoder), wired at the integration site, not before. Not part of this ADR's Phase 0.
4. **Rename** — `mci-llama-coreml` → **`mci-coreml-bridge`**. "Bridge" is the repo's established term for a Rust↔platform-runtime FFI seam (cf. the Rust↔Swift bridge); "adapter" is reserved for the `CaptureSource` capture seam, and bare `mci-coreml` undersells that this crate *is* the unsafe FFI boundary to Core ML. Crate-root re-exports (`pub use qwen3::Qwen3CoreMLBackend` etc.) keep the public symbol paths identical, so consumers change only the crate name.

### Consumers migrated

Workspace member path; `apps/agent` (dep + two `mci_coreml_bridge::Qwen3CoreMLBackend::open` call sites in `mci_agent.rs`); `core/brief-eval` (optional dep + `coreml` feature + the `build_coreml_author` call site). `apps/agent/src/tier2_qwen_backend.rs` depends on `mci_brief::llama_backend::LlamaBackend`, **not** on this crate, so it is untouched by the rename.

### Cosmetic debt (deliberately deferred)

Prose references to `mci-llama-coreml` survive in files outside the spike's touch-set (`README.md`, `core/brief/src/*`, `adapters/macos/mci-embed-coreml/*`, `adapters/macos/mci-mail-reader/*`, `scripts/convert_brief_model.py`, and historical entries in `docs/STATE.md` / `docs/NIGHTLY_LOG.md` / ADR-0028). These are comments/history, not code references — left intact to respect the touch-set bind. The `core/brief-eval` fixture `day_blocked.jsonl` *contains* the string as simulated screen-capture content and must not change. A trivial cosmetic-sweep PR can retire the live-doc references in a later cycle.

## Alternatives considered

- **(B) New `gliner` module inside the existing crate, no shared core.** Rejected: duplicates the `objc2` plumbing and bakes a same-crate-two-purposes smell; the worst of A and C.
- **(C) New sibling crate `mci-gliner-coreml`.** Viable and respected the original (pre-expansion) touch-set, but leaves ~150–200 LoC of `objc2` plumbing duplicated against the Qwen backend until a future consolidation. Was the recommended *minimal* path before the CEO expanded the touch-set; superseded by A, which the CEO ratified as the best long-term shape (one Core ML adapter for all on-device models, zero duplication).
- **(D) Inline FFI in `apps/agent`.** Dead: blocked by `#![forbid(unsafe_code)]` and the adapter-tier discipline.

## Consequences

- **One Core ML adapter for every on-device model.** The embedder (`mci-embed-coreml`) remains separate for now, but the brief author and the forthcoming GLiNER NER backend share `CoreMLModel`. Future on-device models reuse the generic core instead of forking a new bespoke loader.
- **Brief author preserved.** The Qwen path is behaviorally identical: same schema contract, same sampling, same messages. Regression gate = `cargo test` on the renamed crate + `mci-brief` + `mci-agent` + `mci-brief-eval` with zero new failures vs. the pre-refactor baseline.
- **No net-new third-party crate.** The `objc2` family and `tokenizers` are already on the lockfile; ADR-0008's dependency-addition gate is not tripped. Only the in-workspace crate name and path change.
- **No ABI / on-disk change.** The `.mlmodelc` schema, the model download layout, and `tokenizer.json` co-location (ADR-0028 amendment) are unchanged.
