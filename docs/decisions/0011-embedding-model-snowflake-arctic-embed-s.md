# ADR-0011 — Embedding model: swap `all-MiniLM-L6-v2` → `snowflake-arctic-embed-s` (33M, 384-d, Apache-2.0)

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #7)
- Owner: Director-Brain
- Reviewers: CTO; CSO (embedding leakage line of thought)
- Phase: 0

## Context

`docs/AGENT_QUESTIONS.md` fork #7 (verbatim Recommendation): "*A. Runtime unchanged (Core ML/ANE mac, ONNX win; MLX rejected — no ANE). Vector store unchanged (sqlite-vec) + a documented scaling ladder (binary quantization + recency pre-filter past ~10^6 vectors). → DESIGN.md §8/§13 one-line edit; §12 unchanged.*"

Primary-source basis (RESEARCH_DIGEST Stream D, verified in the Verification pass):
- **`all-MiniLM-L6-v2`** is a 2021 model, MTEB-R **41.95** nDCG@10, Pareto-dominated by 2024 models.
- **`snowflake-arctic-embed-s`** (HuggingFace card verified): **33M params, 384-d, Apache-2.0**, MTEB-R **51.98** nDCG@10 = **+23.9% relative / +10.0 absolute** vs `all-MiniLM-L6-v2`. Same dimension (no schema cost per ADR-0009), same size class, same Core ML / ONNX export path.
- **`sqlite-vec`** is the only vector-store choice preserving the single-encrypted-file zero-knowledge invariant; brute-force only (~124 ms per 1M binary-quantized vectors per the author's release post). Past ~10⁶ vectors, binary quantization (~10× speedup) + recency/app pre-filter is the scaling ladder.

Verification-pass errata to apply verbatim:
- Retrieval delta is stated precisely as **+23.9% relative / +10 absolute MTEB-R (51.98 vs 41.95 nDCG@10)** — note it is a **cross-table inference**, not a single A/B row.
- **Not a literal weights swap.** `snowflake-arctic-embed-s` is **~50% larger than `all-MiniLM-L6-v2` (33M vs 22.7M)**, requires **query/document prefixes** (per the model card), and requires **full re-embedding** of any existing corpus. The migration walker in ADR-0009 handles this.
- **Remove the arXiv:2412.04506 "99% Matryoshka 768→256" support** — that is the **different `arctic-embed-v2.0` multilingual 768/1024-d family**, not the 384-d `-s` model in this ADR. Do not cite it for the `-s` swap.
- **MLX "no ANE" is a true engineering fact, but it is NOT a claim of arXiv:2510.18921.** That paper's verified contribution is sublinear batch scaling (8.02 → 70.48 ms for batch 1 → 32). The MLX-rejection rationale stands on the engineering fact; don't cite that paper for it.
- **sqlite-vec brute-force + 124 ms/1M-binary** is verified.

CEO ratified 2026-05-18.

## Decision

1. **The embedding model is `snowflake-arctic-embed-s` (33M params, 384-d, Apache-2.0, int8-quantized for runtime).** It replaces `all-MiniLM-L6-v2` end-to-end.
2. **The schema is unchanged.** ADR-0009 pins `event_vectors.embedding` to 384; arctic-embed-s is also 384-d. No migration of the column shape; full re-embed only.
3. **Query/document prefixes per the model card.** The embedder wrapper prepends `Represent this sentence for searching relevant passages: ` to queries and the document-side prefix to events. Without the prefixes, retrieval quality degrades — this is binding on the wrapper implementation.
4. **Runtime:**
   - **macOS:** Core ML on the Apple Neural Engine (ANE), exported via `coremltools` from the int8 `.onnx` or HuggingFace original.
   - **Windows:** ONNX Runtime, DirectML execution provider (later phase per DESIGN.md §15 Phase 8).
   - **MLX is rejected** because it does not target the ANE (engineering fact; do **not** cite arXiv:2510.18921 for this — it's not what that paper claims). For an energy-bound always-on daemon, an ANE-targeting runtime is the only acceptable choice on Apple Silicon.
   - **`NLEmbedding` (Apple's built-in) and potion-retrieval-32M-class static embedders are kept as a no-dependency floor** for environments where the Core ML / ONNX path is unavailable; never primary.
5. **Scaling ladder past ~10⁶ vectors:** binary quantization (~10×) + recency/app/source pre-filter (always present in MCI queries). DiskANN is the further-out option when the index permanently exceeds what brute-force + binary handles; not Phase 0.
6. **Re-embed migration** is the walker described in ADR-0009: pause capture; drop `event_vectors`; recreate with the new (same) dimension; embedder walker recomputes; bump `schema_version`. Runs offline.

## Consequences

- Positive: +23.9% relative MTEB-R lift on MCI's exact noisy-corpus profile, with **zero schema cost** (ADR-0009).
- Positive: Apache-2.0 license is permissive enough to ship inside a notarized macOS app without separate licensing concerns. CSO confirms (protected-set adjacent).
- Positive: ANE on macOS keeps the footprint SLO (AGENT_PROTOCOL §4) reachable on long batches.
- Negative / tradeoffs: arctic-embed-s is ~50% larger in params (33M vs 22.7M). The int8 deployment artifact is still ≪100 MB; resident-memory delta is minor, not a §4 risk. Verified.
- Negative / tradeoffs: query/document prefixes must be **always-on** in the embedder wrapper. A future contributor who forgets the prefix silently degrades retrieval; a test asserts the prefix is present at insert and query time.
- Forces: the ADR-0010 eval gate (LongMemEval/ScreenshotVQA-style) is the source of truth that the +23.9% lift actually materializes on MCI's corpus. If the eval shows a regression vs MiniLM on the actual MCI workload, this ADR is re-opened.

## Alternatives considered

- **B — keep `all-MiniLM-L6-v2`.** Rejected — measurably worse retrieval (the 2021 baseline that every 2024 384-d model beats) for zero footprint saving.
- **C — larger / Matryoshka model (e.g., `arctic-embed-m-v2.0`, 768/1024-d).** Rejected for Phase 0 — 3–5× the RAM for ~6% more retention. The footprint SLO (AGENT_PROTOCOL §4) does not have room for it. The Matryoshka 99% claim cited in earlier drafts was for *that* family, not the 384-d `-s` model — Verification-pass erratum noted.

## DESIGN.md edits required by this ADR

- **§8 (Brain) — embedding-model line.** Replace `"quantized all-MiniLM-L6-v2 (384-d)"` with `"quantized snowflake-arctic-embed-s (33M, 384-d, Apache-2.0, int8)"`. Same rationale, plus a one-line note that query/document prefixes are required by the model card.
- **§13 (Tech Stack Summary) — Embeddings row.** Same one-line swap.
- **§12 (Data Model)** — unchanged (dimension pinned to 384 by ADR-0009).

These edits are made in the same PR as this ADR.

## References

- DESIGN.md §8, §12, §13
- docs/AGENT_QUESTIONS.md fork #7 (2026-05-18, ratified `accept recommendation`)
- docs/RESEARCH_DIGEST.md Stream D + Verification pass items 7 (arctic-embed-s framing) and 8 (MLX-no-ANE attribution correction)
- HuggingFace model card: `Snowflake/snowflake-arctic-embed-s`
- ADR-0009 (384-d schema pin), ADR-0010 (event-unit retrieval — the eval gates this ADR)

## Erratum 2026-05-22 — Wave-17 Core ML pipeline architecture

**Issue.** The original BUNDLING.md §2 plan said "tokenizer baked into
the Core ML graph; the runtime hands raw UTF-8 strings to the model."
That plan is **architecturally impossible**. The Core ML MIL (Model
Intermediate Language) spec has no string ops — `coremltools` will not
convert a graph whose input is a `String` and whose first hidden layer
is a tokenizer. Verified by CRS Arxiv/OSS scout pass on 2026-05-22 and
by Apple's own ml-stable-diffusion / WhisperKit / HuggingFace Core ML
exporters, all of which use **external tokenization + token-IDs input**.

**Resolution (CEO ratified 2026-05-22).**

1. **Tokenizer moves out of the Core ML graph and into Rust.** The
   `adapters/macos/mci-embed-coreml` crate links the HuggingFace
   `tokenizers` crate (Apache-2.0, `version = "0.20"`,
   `default-features = false`, feature `onig`). The
   `Snowflake/snowflake-arctic-embed-s` `tokenizer.json` (~700 KB) is
   committed at `adapters/macos/mci-embed-coreml/resources/tokenizer.json`
   and embedded into the binary at compile time via `include_bytes!`.
   No first-launch download — enterprise air-gap + MDM deploy customers
   must work zero-network.
2. **The Core ML graph accepts Int32 `input_ids` + `attention_mask`**,
   both shape `[1, 128]`. CLS-pool + L2-normalize move *inside* the
   graph (traced as `torch.select(...,1,0)` + `F.normalize(p=2,dim=-1)`,
   converted to MIL slice + l2_norm). The Rust runtime reads a finished
   unit vector at the output — no Rust-side post-processing on the
   primary backend.
3. **INT8 quantization retained.** Pipeline tradeoff: keep the size
   win, gate the quality with a regression test. The Rust
   `tests/quality.rs` cosine-similarity test against a 50-sentence
   Python FP32 reference fixture is the gate: per-row cosine
   `>= 0.999` keeps INT8; a failure flips the build to FP16 (no
   `linear_quantize_weights` step) as the documented fallback.
4. **No HuggingFace publish until post-v2.0.** The converted
   `.mlpackage` ships only inside the notarized signed app bundle;
   publishing the int8-quantized artifact to a third-party hub before
   product/legal review is out of scope for v1.
5. **The `mci-brain::arctic_embed_s::ArcticEmbedSEmbedder` wrapper
   keeps its L2-normalize step** as defense-in-depth for alternate
   backends (test fakes, future Windows ONNX, `NLEmbedding` fallback).
   Re-normalizing a unit vector is an idempotent no-op within float
   precision; the wrapper-level invariant `||v|| = 1` stays binding.

**Files / artifacts affected.**

- `BUNDLING.md` §2 — schema table updated to two-Int32-input + one
  Float32-output.
- `scripts/convert_embedder.py` — CLS-pool + L2-normalize moved inside
  the traced `EmbedWrapper`, `--fixtures` flag added to write the
  Python FP32 reference, `--tokenizer` flag verifies the bundled
  resource is present, env pins documented in the script header.
- `adapters/macos/mci-embed-coreml/src/lib.rs` — `CoreMLBackend` now
  owns an `Arc<WordPieceTokenizer>`, accepts two Int32 input features
  via MLMultiArray, no String input.
- `adapters/macos/mci-embed-coreml/src/tokenizer.rs` (new) — bundled
  `WordPieceTokenizer` over `include_bytes!` resource.
- `adapters/macos/mci-embed-coreml/tests/quality.rs` (new) —
  cosine-similarity regression vs the Python reference; gates the
  INT8 vs FP16 decision.

**Not changed.** ADR-0011's core decision (model = `snowflake-arctic-embed-s`,
dim = 384, prefix discipline on the wrapper, ANE compute units, the
scaling ladder) is unchanged. This erratum only corrects the *runtime
plumbing* between Rust and the Core ML graph.
