# `arctic-embed-s.mlpackage` — Model Bundling

This document describes how the `snowflake-arctic-embed-s` Core ML model
is produced and bundled into the signed macOS app for production
deployment.

**The `.mlpackage` is NOT checked into this repository.** Reasons:

- Size (~30–50 MB) makes the repo painful to clone.
- Provenance: the trust boundary is the signed `.app` bundle
  (notarized in Phase 5). The model is downloaded + converted + signed
  at release time from a pinned upstream source, never committed in
  binary form.

The signed-app build pipeline (Phase 5) runs `scripts/download_model.sh`
at release time to produce `arctic-embed-s.mlpackage` and copies it into
the app bundle's `Resources/` directory.

## 1. Upstream source

- **Model:** `Snowflake/snowflake-arctic-embed-s`
- **License:** Apache-2.0
- **Source:** <https://huggingface.co/Snowflake/snowflake-arctic-embed-s>
- **ADR:** [`docs/decisions/0011-embedding-model-snowflake-arctic-embed-s.md`](../../../docs/decisions/0011-embedding-model-snowflake-arctic-embed-s.md)

## 2. Expected `.mlpackage` schema

The runtime (`CoreMLBackend` in `src/lib.rs`) expects the model to expose
exactly one input feature and one output feature:

| Direction | Feature name | `MLFeatureType` | dtype             | Shape          |
|-----------|--------------|-----------------|-------------------|----------------|
| Input     | `text`       | `String`        | UTF-8 NSString    | scalar         |
| Output    | `embedding`  | `MultiArray`    | `Float32`         | `[384]` or `[1, 384]` |

The tokenizer is baked into the model graph via `coremltools` (see §3),
so the runtime hands raw UTF-8 strings to the model — no tokenizer
integration is required in Rust. If a future conversion script changes
the input feature type to `MultiArray<Int32>` (raw token ids), the
runtime will fail `CoreMLBackend::open()` with a clear schema-mismatch
diagnostic (covered by the verification in `verify_schema()`).

## 3. Conversion recipe

`scripts/download_model.sh` runs the following steps:

1. Pull the HuggingFace `Snowflake/snowflake-arctic-embed-s` weights
   (PyTorch `.bin` + `tokenizer.json` + `config.json`) at the version
   pinned in the script's `MODEL_REVISION` constant.
2. Convert to ONNX with optimum-cli for an intermediate representation
   that preserves the tokenizer as a preprocessing layer.
3. Convert ONNX → Core ML `.mlpackage` via `coremltools.converters.mil`,
   targeting the input/output schema in §2.
4. Quantize to int8 via `coremltools.optimize.coreml.palettize_weights`
   (per ADR-0011 §1: "int8-quantized for runtime").
5. Set the `computeUnits` hint to `.cpuAndNeuralEngine` so Core ML
   prefers ANE eligibility when the device supports it.
6. Verify the resulting `.mlpackage` round-trips a known fixture text
   to a 384-d float32 vector with magnitude ≈ 1.0 (post the wrapper's
   L2 step in `mci-brain::arctic_embed_s`).

## 4. Reproducibility

`scripts/download_model.sh` pins:

- the HuggingFace model revision (commit SHA, not branch),
- the `coremltools` version,
- the `optimum` version,
- the `transformers` version,
- the `tokenizers` version,
- the `onnx` runtime version.

A failed conversion (e.g. upstream weights changed under the same
revision SHA) aborts the release build — never silently produces a
different model.

## 5. Signed-app integration

Phase 5 packaging copies the `.mlpackage` into the app bundle:

```
MCI.app/Contents/Resources/arctic-embed-s.mlpackage/
```

The `mci-agent` daemon opens it via:

```rust
let bundle = std::env::current_exe()?
    .parent().unwrap()
    .parent().unwrap()
    .join("Resources/arctic-embed-s.mlpackage");
let backend = std::sync::Arc::new(mci_embed_coreml::CoreMLBackend::open(&bundle)?);
let query_emb = mci_brain::arctic_embed_s::ArcticEmbedSEmbedder::new_query(backend.clone());
let doc_emb   = mci_brain::arctic_embed_s::ArcticEmbedSEmbedder::new_document(backend);
```

Notarization signs the model along with the rest of the bundle —
tampering with the model breaks the notarization signature, which the
OS refuses to launch. Same trust boundary as the rest of the app.

## 6. Dev / CI / headless tests

The `mci-embed-coreml` crate **does not require** the `.mlpackage` to
build or to run its unit tests. The tests cover the load-path error
surface and the trait-shape contract; full end-to-end inference
against the real model is exercised at **P3.11 live-Mac audit** per
ADR-0016 §7. CI never downloads the model.

A developer who wants to exercise end-to-end inference locally runs:

```sh
adapters/macos/mci-embed-coreml/scripts/download_model.sh \
    --output ~/Library/Application\ Support/MCI/arctic-embed-s.mlpackage
```

and points the dev `mci-agent` build at that path via the
`MCI_EMBED_MODEL_PATH` environment variable (wired in P3.7 when the
agent gets the real embedder runtime).
