# Arctic Embed S Release Artifact

Hippocampus ships one semantic-search model:
`ArcticEmbedS_FP16.mlmodelc`, converted from
`Snowflake/snowflake-arctic-embed-s`. The compiled bundle is about 66 MB and
is intentionally gitignored. The immutable release archive and the signed,
notarized app are its distribution trust boundaries.

The obsolete adapter-local `download_model.sh` skeleton was removed. It never
performed a conversion and described an ONNX/INT8 pipeline that does not match
the product. `scripts/convert_embedder.py` is the sole conversion entry point.

## Pinned Identity

- Upstream repository: `Snowflake/snowflake-arctic-embed-s`
- Upstream revision: `e596f507467533e48a2e17c007f0e1dacc837b33`
- Precision: FP16; the rejected INT8 experiment is not a shipping option
- Attention: eager primitives with a finite `-10000` mask floor
- Deployment target: macOS 14 / Core ML specification version 8
- Runtime compute policy: CPU and Neural Engine
- Tokenizer: committed in `resources/tokenizer.json` and compiled into Rust

The compiled bundle contains `hippocampus-model.json`, an app-owned contract
covering this identity. Generic Core ML metadata is not accepted in its place.

## Runtime Schema

| Direction | Feature | Type | Shape |
| --- | --- | --- | --- |
| Input | `input_ids` | Int32 multi-array | `[1, 128]` |
| Input | `attention_mask` | Int32 multi-array | `[1, 128]` |
| Output | `embedding` | Float32 multi-array | `[1, 384]` |

Tokenization runs in Rust because MIL has no tokenizer/string operator for
this graph. CLS pooling and L2 normalization run inside Core ML, so the output
is already a unit vector.

## Convert Locally

Use the dependencies pinned in `scripts/requirements-ml.txt`, then run:

```sh
python3 scripts/convert_embedder.py \
  --output models/ArcticEmbedS_FP16.mlpackage \
  --verify
```

The converter:

1. Loads the exact Hugging Face revision with eager attention.
2. Replaces the dtype-minimum sentinel with finite `-10000` before tracing.
3. Exports static `[1, 128]` inputs and a static `[1, 384]` output for macOS 14.
4. Compiles the package to `models/ArcticEmbedS_FP16.mlmodelc`.
5. Writes the app-owned compatibility and provenance contract.
6. Invokes `scripts/coreml_model_contract.py` against the compiled MIL.

Use `--fixtures` only when deliberately regenerating the pinned 50-sentence
FP32 reference. A fixture change is a benchmark input change and belongs in a
reviewed commit.

## Verify Quality

Static verification rejects identity, precision, shape, deployment, weight,
non-finite constant, and attention-mask dataflow drift:

```sh
python3 scripts/coreml_model_contract.py \
  --model models/ArcticEmbedS_FP16.mlmodelc \
  --app-minimum-system-version 14.0
```

Runtime verification evaluates exactly 50 sentences on both CPU-only and
CPU-and-Neural-Engine policies. Every output must be finite, 384-dimensional,
L2 normalized, and at least `0.999` cosine-similar to the FP32 reference:

```sh
MCI_REQUIRE_COREML_QUALITY=1 \
  cargo test --locked -p mci-embed-coreml --test quality -- --nocapture
```

CPU-and-Neural-Engine allows Core ML to choose those units. It does not prove
that every operation physically resides on the Neural Engine.

## Release Assembly

Release CI does not download mutable model files from Hugging Face. An owner
first creates an archive containing the compiled bundle. The tag-owned
`release-models.json` records the immutable HTTPS URL and SHA-256. It must be
provisioned before a release; `UNPROVISIONED` is a deliberate hard stop.

CI reconstructs the archive with:

```sh
scripts/prepare-release-models.sh \
  --archive /path/to/release-models.tar.gz \
  --sha256 EXPECTED_SHA256 \
  --output models
```

That command validates archive safety and the compiled model contract. Release
CI then runs the runtime quality gate before building the signed app.

`apps/hippocampus/Resources/build-app.sh` installs the verified bundle at:

```text
Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_FP16.mlmodelc
```

The agent discovers that bundled path automatically. Local tools and clean
benchmark worktrees can point to the same compiled bundle with
`MCI_ARCTIC_MODEL_PATH=/absolute/path/ArcticEmbedS_FP16.mlmodelc`.
