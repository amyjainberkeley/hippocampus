# Core ML Model Conversion — Operator Guide

The two `.mlpackage` files Hippocampus needs are produced from Python
conversion scripts. They are NOT committed to the repo (too big, regen-able).

## Prerequisites

```bash
pip install -r scripts/requirements-ml.txt
```

On Apple Silicon: ~5-10 minutes for embedder, ~20-40 minutes for brief model.

## Step 1: Embedder (~33 MB)

```bash
mkdir -p models
python scripts/convert_embedder.py \
  --output models/ArcticEmbedS_INT8.mlpackage \
  --verify
```

After this lands, every `./apps/hippocampus/Resources/build-app.sh` run
bundles the embedder into `Hippocampus.app/Contents/Resources/Models/`.

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
