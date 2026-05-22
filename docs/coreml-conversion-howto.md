# Core ML Model Conversion — Operator Guide

The two `.mlpackage` files Hippocampus needs are produced from Python
conversion scripts. They are NOT committed to the repo (too big, regen-able).

## Prerequisites

```bash
pip install -r scripts/requirements-ml.txt
```

On Apple Silicon: ~5-10 minutes for embedder, ~20-40 minutes for brief model.

### Environment pins (Wave 17, locally verified)

- **Python 3.12** (3.13 has not been verified with coremltools 8.x).
- **transformers 4.x** (4.46.3 verified end-to-end).
- **numpy < 2.0** — coremltools 8.x is not numpy-2 clean.
- **torch >= 2.2**.
- **coremltools >= 8.0**.
- **sentence-transformers** — only required for `--fixtures` (writes
  the Python FP32 reference for the Rust cosine-similarity regression
  test).

The script monkey-patches `torch.Tensor.new_ones` for coremltools 9.0
compatibility (retained from PR #143). Do not remove the patch until
coremltools upstream lands the `new_ones` converter.

## Step 1: Embedder (~33 MB)

```bash
mkdir -p models
python scripts/convert_embedder.py \
  --output models/ArcticEmbedS_INT8.mlpackage \
  --verify --fixtures
```

After this lands, every `./apps/hippocampus/Resources/build-app.sh` run
bundles the embedder into `Hippocampus.app/Contents/Resources/Models/`.

The Rust runtime tokenizes on the host (HuggingFace `tokenizers` crate
against `adapters/macos/mci-embed-coreml/resources/tokenizer.json`,
embedded at compile time via `include_bytes!`) and passes Int32
`input_ids` + `attention_mask` tensors into the graph. CLS-pool and
L2-normalize happen inside the Core ML graph, so the output is already
a unit vector. See BUNDLING.md §2 (Wave-17 corrected) and the ADR-0011
erratum.

`--fixtures` writes `tests/fixtures/arctic_embed_sentences.txt` (50
sentences) and `tests/fixtures/arctic_embed_reference.npy` (50 × 384
Float32 unit vectors from sentence-transformers FP32). These power the
`cargo test -p mci-embed-coreml --test quality` cosine-similarity
regression that gates the INT8 vs FP16 decision (target: cosine sim
>= 0.999 per row).

Semantic search now works end-to-end (no zero-vector stub fallback).

## Step 2: Brief model (~950 MB)

```bash
python scripts/convert_brief_model.py \
  --output models/Qwen3-1.7B-INT4.mlpackage \
  --verify
```

After convert, compile + tarball + upload to HF:

```bash
# Compile .mlpackage → .mlmodelc
xcrun coremlcompiler compile models/Qwen3-1.7B-INT4.mlpackage models/

# Tarball
cd models
tar -czf Qwen3-1.7B-INT4.mlmodelc.tar.gz Qwen3-1.7B-INT4.mlmodelc
shasum -a 256 Qwen3-1.7B-INT4.mlmodelc.tar.gz
# Copy hash. Upload tarball to HF repo amyjainberkeley/hippocampus-coreml-models.
```

Then edit `apps/hippocampus/Resources/models.json`:

```json
"sha256": "<paste hash>",
```

Commit the `models.json` change. The download manager now succeeds.

## Step 3: Verify

```bash
scripts/verify-models.sh
```

Builds and checks both models are correctly placed.

## Reference

- ADR-0011 — Arctic Embed S embedder selection
- ADR-0028 — Qwen3-1.7B brief author selection
- `scripts/convert_embedder.py` — embedder conversion
- `scripts/convert_brief_model.py` — brief model conversion
- `scripts/verify-models.sh` — post-build model validation
- `apps/hippocampus/Resources/models.json` — model manifest
