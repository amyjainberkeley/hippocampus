# ADR-0028 — Brief Author Model: Qwen3-1.7B via Core ML

- Status: Accepted (2026-05-22; ratifies the brief-author model selection from CEO decision session 2026-05-21. CEO chose Qwen3-1.7B over CRS recommendation of Qwen2.5-1.5B, preferring the newer model generation).
- Owners: **Director-Brain** (conversion script + `CoreMLBriefModel` impl) + **Director-Recording** (download manager UX in Hippocampus.app)
- Reviewers: CSO (model download path — network fetch of binary must not exfiltrate data); CTO (sequencing); CEO (ratification)
- Phase: 5 (Agent Shell — replaces current `StubLlamaBackend`)
- **Protected-set: no.** The model processes already-captured event text that is already in the brain store. No new data surface. No crypto/sync change. CSO reviews the model download path (network fetch of model binary) to ensure no data exfiltration risk, but this is advisory, not veto-gate.

## Context

MCI's Agent Shell generates daily briefs summarizing user activity from captured episodes (ADR-0018). This requires a small on-device LLM. The model must run 100% on-device — user's screen activity data never leaves the machine (ADR-0001 local-first, zero-knowledge invariant).

The CRS Arxiv/OSS Scout evaluated candidate models (2026-05-21 scan). Recommendation was Qwen2.5-1.5B for maturity. CEO overrode: Qwen3-1.7B is one generation newer (April 2025), marginal size increase (~200M more params), Apache 2.0, and includes a "thinking mode" toggle that allows direct (no chain-of-thought) generation for structured summarization — faster, more concise briefs.

The embedder is a separate concern: Arctic Embed S (ADR-0011) is bundled in the app (~33 MB). This ADR covers only the brief-author LLM.

## Decision

### 1. Model selection

**Qwen3-1.7B** (`Qwen/Qwen3-1.7B` on HuggingFace). 1.7B parameters, Apache 2.0 license. INT4-quantized via `coremltools` palettization. ~950 MB on disk.

### 2. Architecture and quantization

Standard GQA + RoPE transformer. Qwen3's "thinking mode" toggle — MCI uses **direct mode** (no chain-of-thought) for structured summarization. Faster, more concise output.

Quantization: INT4 palettized via `coremltools` 8.x (or from pre-quantized GPTQ checkpoint if available). Split into **prefill + decode** models using stateful model APIs. Compile to `.mlmodelc` pair.

Conversion script: `scripts/convert_brief_model.py` using `coremltools` 8.x.

### 3. Tokenizer

BPE tokenizer (Qwen3 variant). Ship `vocab.json` + `merges.txt` + `tokenizer_config.json` alongside the model. Swift BPE tokenizer implementation needed (~300 lines).

Prompt format: Qwen3 ChatML (`<|im_start|>system`, `<|im_start|>user`, `<|im_start|>assistant`). `DailyBriefPrompt.swift` emits this format.

### 4. Bundling and download

**NOT bundled in the .app.** Downloaded on demand when the user enables daily briefs.

- **Storage:** `~/Library/Application Support/MCI/Models/Qwen3-1.7B-INT4.mlmodelc`
- **Hosting:** HuggingFace model repo (e.g., `amyjainberkeley/hippocampus-coreml-models`). Free CDN, Git LFS, versioned. WhisperKit pattern.
- **Download trigger:** User enables daily briefs in Settings or Onboarding → progress dialog → download ~950 MB → compile → ready.
- **Manifest:** `models.json` bundled in app with expected model version + SHA-256 checksum. Verified after download. Checksum mismatch = download rejected + user notified.

### 5. Inference profile

Batch only, idle-triggered (not interactive). ~2K input tokens (episode data), ~512 output tokens.

Performance estimates (INT4 on Apple Silicon):

| Chip | Prefill | Generation | Total |
|------|---------|------------|-------|
| M1   | ~3s     | ~19s (~30 tok/s) | ~22s per brief |
| M2+  | ~2s     | ~10s (~50 tok/s) | ~12s per brief |

### 6. Memory footprint

~400–500 MB during inference. Loaded on demand, unloaded after generation completes. Exceeds the 250 MB steady-state RAM target but is **transient/batch** — acceptable per DESIGN.md §3 ("GPU/ANE: Idle except during search or inference"). The model is never resident during normal capture operation.

### 7. Fallback

If model download fails or user declines, `StubLlamaBackend` remains active (returns canned brief with "[Model not downloaded]" notice). Brain search works regardless — the brief author is independent of the retrieval pipeline.

### 8. Upgrade path

New Qwen generations can be published to the HuggingFace repo. App checks for model updates during idle (compare `models.json` bundled version vs remote). User confirms before downloading a new version. Old model is retained until new one is verified.

### 9. CSO advisory: download path

The model download is a network fetch of a large binary. CSO reviews:

- Download URL is pinned to the HuggingFace repo in `models.json`. No dynamic URL resolution.
- SHA-256 checksum verified post-download. Mismatch = reject.
- No telemetry or user data is sent during the download request. The request is a standard HTTPS GET with no MCI-specific headers beyond `User-Agent`.
- The downloaded artifact is a Core ML model — it processes text, it does not phone home. No network capability in the inference path.

## Consequences

- **Positive:** Users get real daily briefs summarizing their activity, generated entirely on-device. Zero-knowledge invariant preserved — screen activity data never leaves the machine.
- **Positive:** Apache 2.0 license is permissive for commercial distribution. No separate licensing concerns for notarized macOS app.
- **Positive:** Qwen3-1.7B's direct mode (no thinking tokens) produces concise, structured output suitable for daily summaries without the latency overhead of chain-of-thought.
- **Positive:** On-demand download keeps the app bundle small (~33 MB for embedder only). Users who don't want briefs pay zero disk cost.
- **Negative / tradeoff:** ~950 MB download is large. Users on slow connections may wait minutes. Progress dialog mitigates UX frustration but doesn't eliminate it.
- **Negative / tradeoff:** ~400–500 MB transient memory during inference. On 8 GB M1 MacBook Air, this is ~5–6% of total RAM. Acceptable for batch/idle but inference must not run during high-memory-pressure conditions. The scheduler checks `os_proc_available_memory()` before launching.
- **Negative / tradeoff:** Swift BPE tokenizer is a new component (~300 lines). Must be tested against the reference Python tokenizer output for correctness. Tokenizer bugs produce silent quality degradation.
- **Negative / tradeoff:** INT4 quantization loses some quality vs FP16. For structured summarization of screen activity (not creative writing), the quality delta is negligible. The ADR-0010 eval gate applies: if brief quality is poor on real MCI data, the quantization level or model can be revisited.

## Alternatives considered

- **A — Qwen2.5-1.5B (CRS recommendation).** Rejected by CEO. One generation older, marginally smaller (200M fewer params), lacks the thinking-mode toggle. Qwen3 generation preferred.
- **B — Llama 3.2 1B / 3B.** 1B is too small for coherent multi-paragraph briefs. 3B exceeds the transient memory budget on 8 GB machines and doubles inference time. License (Meta Community License) has usage thresholds; Apache 2.0 is cleaner.
- **C — Apple Intelligence / on-device foundation model.** Not available as a developer API. Apple's on-device models are locked to system features (Writing Tools, Siri). Cannot be called programmatically for custom summarization tasks.
- **D — Cloud LLM (GPT-4o, Claude, etc.).** Rejected outright — violates ADR-0001 (local-first) and the zero-knowledge invariant. User's screen activity data must never leave the machine.
- **E — No brief author (keep StubLlamaBackend permanently).** Rejected — daily briefs are a core product feature (ADR-0018). The stub is a development placeholder, not a shipping product.
- **F — Bundle the model in the .app.** Rejected — adds ~950 MB to the app bundle. Users who don't want briefs shouldn't download a 1 GB app. On-demand download follows the WhisperKit pattern established in the Apple ML ecosystem.

## References

- **ADR-0001** — local-first, zero-knowledge invariant. The brief author must run 100% on-device.
- **ADR-0011** — Arctic Embed S (embedder, separate from this ADR). Parallel model-selection ADR for the embedding pipeline.
- **ADR-0018** — Brief authoring + approval pipeline. Defines the brief generation flow that this model powers.
- **DESIGN.md §3** — footprint budget. GPU/ANE idle except during search or inference.
- **DESIGN.md §8** — Brain architecture. Brief author is a component of the Agent Shell.
- **CRS scan 2026-05-21** — Arxiv/OSS Scout model evaluation. Recommended Qwen2.5-1.5B; CEO overrode to Qwen3-1.7B.
- HuggingFace model card: `Qwen/Qwen3-1.7B`
- `coremltools` 8.x documentation: stateful model APIs, INT4 palettization.
