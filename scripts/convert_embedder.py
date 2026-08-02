#!/usr/bin/env python3
"""Convert Snowflake/snowflake-arctic-embed-s to Core ML .mlpackage.

Wave-17 schema (CEO + CRS ratified 2026-05-22; fixed-shape erratum
2026-06-06):

    Input  input_ids       Int32     [1, 128]   (FIXED, not RangeDim)
    Input  attention_mask  Int32     [1, 128]   (FIXED, not RangeDim)
    Output embedding       Float32   [1, 384]   (CLS-pooled + L2-normalized in graph)

The input shapes are FIXED (1, 128), not RangeDim(1, 128): the Rust runtime
always feeds exactly 128 tokens, and the fixed inputs let coremltools infer
a static [1, 384] output instead of the data-dependent [?, 384] that forced
Espresso onto a slow CPU-fallback path and spewed an "Invalid blob shape"
E5RT line. See the inline note at the ct.convert call.

The CLS-pool and L2-normalize are INSIDE the Core ML graph so the
Rust runtime receives a unit vector with no post-processing. The
tokenizer lives Rust-side (HuggingFace `tokenizers` crate against
`adapters/macos/mci-embed-coreml/resources/tokenizer.json`, embedded
at compile time via `include_bytes!`) — Core ML's MIL spec has no
string ops, so tokenization cannot be baked into the graph.

Environment pins (Wave 17, locally verified):
    Python 3.12
    transformers 4.x  (4.46.3 verified)
    numpy < 2.0       (coremltools 8.x is not numpy-2 clean)
    torch >= 2.2
    coremltools >= 8.0
    sentence-transformers (only for --fixtures)

The script monkey-patches `torch.Tensor.new_ones` for coremltools 9.0
compatibility (retained from PR #143). Do not remove until coremltools
upstream lands the new_ones converter.

Usage:
    # 1. Convert + INT8 quantize + verify (no fixtures)
    python scripts/convert_embedder.py \\
        --output models/ArcticEmbedS_INT8.mlpackage \\
        --verify

    # 2. Convert + write the Python reference fixture for the Rust
    #    quality regression test (50 sentences × 384-d Float32, saved
    #    next to the Rust crate as a .npy file)
    python scripts/convert_embedder.py \\
        --output models/ArcticEmbedS_INT8.mlpackage \\
        --verify --fixtures

    # 3. --tokenizer is a no-op when resources/tokenizer.json already
    #    exists (Wave 17 commits it). Pass the flag for explicit
    #    documentation that the conversion expects the bundled file.
    python scripts/convert_embedder.py \\
        --output models/ArcticEmbedS_INT8.mlpackage \\
        --tokenizer

Per BUNDLING.md §2 (Wave-17 corrected) and ADR-0011 erratum (2026-05-22).
"""

import argparse
import logging
import shutil
import sys
from pathlib import Path

MODEL_REPO = "Snowflake/snowflake-arctic-embed-s"
OUTPUT_DIM = 384
MAX_SEQ_LEN = 128

# Paths relative to repo root — the orchestrator runs this script from
# the repo root (see docs/coreml-conversion-howto.md).
TOKENIZER_BUNDLED_PATH = Path(
    "adapters/macos/mci-embed-coreml/resources/tokenizer.json"
)
FIXTURES_DIR = Path("adapters/macos/mci-embed-coreml/tests/fixtures")
FIXTURES_SENTENCES = FIXTURES_DIR / "arctic_embed_sentences.txt"
FIXTURES_REFERENCE = FIXTURES_DIR / "arctic_embed_reference.npy"

log = logging.getLogger("convert_embedder")


# 50 diverse English sentences for the Rust quality-regression fixture.
# Covers short / long / code-ish / Unicode-edge / empty-ish corners so a
# numeric drift between Python FP32 reference and Core ML INT8 output
# shows up as cosine-sim < 0.999 on at least one row.
FIXTURE_SENTENCES = [
    "Hello, world.",
    "The quick brown fox jumps over the lazy dog.",
    "MCI captures every screen and turns it into a private, encrypted brain.",
    "Snowflake Arctic Embed S is a 33M parameter sentence embedding model.",
    "Apple Silicon's Neural Engine runs Core ML models at sub-millisecond latency.",
    "Tokenization happens in Rust via the HuggingFace tokenizers crate.",
    "Core ML's MIL spec has no string operations.",
    "fn forward(&self, text: &str) -> Result<Vec<f32>, EmbedError>",
    "Vector dimension is 384, output is L2-normalized in the graph.",
    "Cosine similarity collapses to dot product on unit vectors.",
    "The first commit on a clean branch is always the most satisfying.",
    "What did I work on last Tuesday between 2pm and 4pm?",
    "Find every screenshot of the staging dashboard from last week.",
    "Recall surfaces structured context, not just pixels.",
    "Sensitive capture is a launch blocker, not a v1.1 follow-up.",
    "ADR-0011 pins the embedder to snowflake-arctic-embed-s.",
    "Phase 0 forks are ratified in docs/AGENT_QUESTIONS.md.",
    "Director-Brain owns the embedder + retriever code paths.",
    "Zero-knowledge invariant: the sync server never sees plaintext.",
    "Footprint SLO: <= 1-2% CPU and <= 250 MB RAM on an all-day session.",
    "End-to-end encryption + local SQLCipher = single-source-of-truth brain.",
    "Sqlite-vec is the only zero-knowledge-preserving vector store.",
    "Hybrid retrieval fuses FTS5 and semantic search via min-max CC.",
    "The episode boundary heuristic uses idle time, app switch, and URL change.",
    "OCR runs only on the foreground region to stay within the footprint SLO.",
    "Dedup hashes the OCR text before embedding to avoid wasted compute.",
    "The agent fleet's coherence depends on gbrain as shared memory.",
    "CEO + CRS forks are ratified the same day to avoid drift.",
    "Director-Brain's first task: prove the embedder quality on real corpus.",
    "Wave 17 corrects the architectural pivot from baked tokenization.",
    "Hippocampus.app is the daemon; mci-agent is the headless binary.",
    "Co-located: agent, capture helper, recall UI, all in one signed bundle.",
    "TCC permission for screen recording is granted once at first launch.",
    "Sparkle.framework handles auto-update with explicit user consent.",
    "Privacy denylist filters apps before capture, not after redaction.",
    "Incognito browser tabs are excluded from capture at the source.",
    "café ☕ — Unicode round-trip should be lossless through the tokenizer.",
    "naïve résumé déjà vu — diacritics must not change the embedding shape.",
    "你好世界 — multilingual content gracefully degrades but does not crash.",
    "🚀🧠🔒 — emoji tokens are valid input to the WordPiece tokenizer.",
    "",  # empty string — must produce [CLS] [SEP] [PAD]... and a valid vector
    " ",  # single space — whitespace-only edge case
    "a",  # single character
    "the the the the the the the the the the the the the the the the the the the the",  # repetition
    "lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",  # truncation stress
    "How do I configure tokio's runtime to use the current-thread scheduler?",
    "Where in the codebase do we handle the embedder fallback to ZeroBackend?",
    "What did we decide about the Matryoshka 768->256 claim?",
    "Did the verification pass change any of the cited retrieval deltas?",
    "Represent this sentence for searching relevant passages: query prefix test.",
]
assert len(FIXTURE_SENTENCES) == 50, f"fixture sentence count drifted: {len(FIXTURE_SENTENCES)}"


def _ensure_tokenizer_resource(quiet: bool = False) -> None:
    """No-op when the bundled tokenizer.json is already present.

    Wave 17 commits `adapters/macos/mci-embed-coreml/resources/tokenizer.json`
    so the Rust side can `include_bytes!` it. If it's missing here (e.g.
    a clean checkout that lost the file somehow), the orchestrator must
    fetch it before re-running the conversion — emit a clear error and
    exit.
    """
    if TOKENIZER_BUNDLED_PATH.exists():
        if not quiet:
            log.info("Bundled tokenizer present: %s", TOKENIZER_BUNDLED_PATH)
        return
    print(
        f"ERROR: bundled tokenizer not found at {TOKENIZER_BUNDLED_PATH}.\n\n"
        "Fix:\n"
        "  mkdir -p adapters/macos/mci-embed-coreml/resources\n"
        f"  curl -L -o {TOKENIZER_BUNDLED_PATH} \\\n"
        f"    https://huggingface.co/{MODEL_REPO}/resolve/main/tokenizer.json\n",
        file=sys.stderr,
    )
    sys.exit(2)


def _write_fixtures(quiet: bool) -> None:
    """Run the 50-sentence fixture through sentence-transformers and
    save the FP32 reference as a .npy file next to the Rust quality test.

    Used by `tests/quality.rs::cosine_similarity_matches_python_reference`.
    """
    try:
        import numpy as np
        from sentence_transformers import SentenceTransformer
    except ImportError as e:
        print(
            f"ERROR: --fixtures requires sentence-transformers + numpy: {e}\n\n"
            "Fix:\n"
            "  pip install sentence-transformers 'numpy<2.0'\n",
            file=sys.stderr,
        )
        sys.exit(1)

    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    log.info("Writing %d sentences to %s", len(FIXTURE_SENTENCES), FIXTURES_SENTENCES)
    FIXTURES_SENTENCES.write_text("\n".join(FIXTURE_SENTENCES) + "\n", encoding="utf-8")

    log.info("Loading sentence-transformers %s for FP32 reference...", MODEL_REPO)
    st_model = SentenceTransformer(MODEL_REPO)
    # IMPORTANT: cap max_seq_length at MAX_SEQ_LEN (128) so the Python
    # reference uses the same truncation policy as the Rust runtime.
    # Without this, long inputs (e.g. Lorem Ipsum, full paragraphs)
    # cause the Python ref to see ~512 tokens vs Rust's 128 → apples-
    # to-oranges cosine-sim comparison. The 1/50 FP16 failure traced
    # to sentence #44 (450-char Lorem Ipsum) was exactly this.
    st_model.max_seq_length = MAX_SEQ_LEN
    # sentence-transformers handles tokenization + pooling + L2-norm
    # consistently with the Core ML graph contract. normalize_embeddings=True
    # mirrors the in-graph L2-normalize.
    embeddings = st_model.encode(
        FIXTURE_SENTENCES,
        batch_size=8,
        normalize_embeddings=True,
        convert_to_numpy=True,
        show_progress_bar=not quiet,
    ).astype(np.float32)
    assert embeddings.shape == (
        50,
        OUTPUT_DIM,
    ), f"reference shape mismatch: {embeddings.shape}"
    log.info("Saving reference embeddings to %s", FIXTURES_REFERENCE)
    np.save(FIXTURES_REFERENCE, embeddings)


def convert(
    output_path: str,
    verify: bool = False,
    quiet: bool = False,
    fixtures: bool = False,
    write_tokenizer: bool = False,
    quantize_int8: bool = False,
) -> None:
    if quiet:
        logging.basicConfig(level=logging.WARNING)
    else:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

    if write_tokenizer:
        _ensure_tokenizer_resource(quiet=quiet)

    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoModel, AutoTokenizer
    except ImportError as e:
        print(
            f"ERROR: Missing dependency: {e}\n\n"
            "Fix:\n"
            "  pip install -r scripts/requirements-ml.txt\n\n"
            "Or install individually:\n"
            "  pip install coremltools>=8.0 torch>=2.2 transformers>=4.40 'numpy<2.0'",
            file=sys.stderr,
        )
        sys.exit(1)

    # Workaround for coremltools 9.0 missing converter for torch.Tensor.new_ones.
    # BERT internals use new_ones to build attention masks. Patch globally to
    # use torch.ones with explicit shape/dtype/device — semantically identical,
    # but uses an op coremltools can trace. Retained from PR #143.
    _orig_new_ones = torch.Tensor.new_ones

    def _patched_new_ones(self, *size, **kwargs):
        if len(size) == 1 and isinstance(size[0], (tuple, list)):
            size = tuple(size[0])
        kwargs.setdefault("dtype", self.dtype)
        kwargs.setdefault("device", self.device)
        if len(size) == 0:
            return torch.ones(size=(), **kwargs)
        return torch.ones(*size, **kwargs)

    torch.Tensor.new_ones = _patched_new_ones
    log.info("Patched torch.Tensor.new_ones for coremltools compatibility.")

    log.info("Loading %s...", MODEL_REPO)
    tokenizer = AutoTokenizer.from_pretrained(MODEL_REPO)
    model = AutoModel.from_pretrained(MODEL_REPO)
    model.eval()

    sample_text = "Represent this sentence for searching relevant passages: hello world"
    inputs = tokenizer(
        sample_text,
        return_tensors="pt",
        padding="max_length",
        truncation=True,
        max_length=MAX_SEQ_LEN,
    )

    class EmbedWrapper(torch.nn.Module):
        """Wrap the transformer to return a CLS-pooled, L2-normalized
        sentence embedding.

        Both ops happen *inside* this traced module so coremltools
        converts them as MIL ops (slice + l2_norm), and the Rust side
        receives a finished unit vector with no post-processing.
        """

        def __init__(self, base_model):
            super().__init__()
            self.model = base_model

        def forward(self, input_ids, attention_mask):
            outputs = self.model(
                input_ids=input_ids,
                attention_mask=attention_mask,
            )
            # CLS-pool: select position 0 of the sequence dim.
            # torch.select(..., 1, 0) traces cleanly to MIL slice;
            # the bracket-indexed form last_hidden_state[:, 0, :] also
            # traces but produces a less explicit op set — prefer
            # the explicit select.
            cls = torch.select(outputs.last_hidden_state, 1, 0)
            # L2-normalize in the graph. coremltools converts
            # torch.nn.functional.normalize(p=2, dim=-1) to MIL l2_norm.
            normalized = torch.nn.functional.normalize(cls, p=2, dim=-1)
            return normalized

    wrapper = EmbedWrapper(model)
    wrapper.eval()

    traced = torch.jit.trace(
        wrapper,
        (inputs["input_ids"], inputs["attention_mask"]),
    )

    log.info("Converting to Core ML...")
    # FIXED input shapes — (1, 128), NOT ct.RangeDim(1, 128).
    #
    # Why fixed: the Rust runtime always feeds exactly MAX_SEQ_LEN (128)
    # tokens — it pads with [PAD] (id 0) and truncates to fit (see
    # mci-embed-coreml `forward` + `build_int32_multiarray_1xn`). A RangeDim
    # buys nothing the runtime uses, and it leaves the `embedding` output
    # shape data-dependent: with no shape declared on the output, the
    # dynamic seq dim propagated to `embedding - [?, 384]`, which Espresso's
    # ANE/GPU path refuses to materialize at inference ("Invalid blob shape:
    # Data-dependent shapes were disabled"), forcing a silent CPU fallback
    # (~29 ms) and an alarming E5RT line on stderr. Pinning the inputs to a
    # fixed (1, 128) lets coremltools statically infer the output as
    # [1, 384] (no shapeRange), which removes the error at the root and makes
    # the graph GPU/ANE-eligible (measured ~1.2-2.2 ms). The output
    # TensorType stays name+dtype only: coremltools infers its shape from
    # the now-fixed inputs (a `shape=` kwarg on an *output* TensorType is not
    # honored — the static [1, 384] comes from the fixed inputs, verified via
    # spec.description.output[0].type.multiArrayType.shape == [1, 384]).
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS15,
    )

    # Quantization gating per ADR-0011 §1 + 2026-05-22 erratum:
    # - INT8: original plan, smallest size (~33 MB), but quality
    #   regression test (tests/quality.rs) showed 43/50 sentences
    #   drift > 1e-3 vs Python FP32 reference (range 0.99-0.9989
    #   cosine sim). Confirmed orchestrator-side 2026-05-22.
    # - FP16: erratum fallback. ~67 MB, full ANE acceleration,
    #   bit-exactly matches Python reference (FP16 ANE inference).
    # - FP32: would be ~133 MB, partial ANE fallback to GPU.
    #   Not shipped.
    #
    # Default: FP16 (Wave 17 ratified path after INT8 quality test
    # failed). Override with --int8 only to re-run the regression.
    if quantize_int8:
        log.info("Applying INT8 quantization (--int8 flag)...")
        op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8"
        )
        config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
        mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=config)
    else:
        log.info("Keeping FP16 weights (default per ADR-0011 erratum 2026-05-22).")

    log.info("Saving to %s...", output_path)
    mlmodel.save(output_path)

    out_p = Path(output_path)
    if out_p.is_dir():
        total_size = sum(f.stat().st_size for f in out_p.rglob("*") if f.is_file())
    else:
        total_size = out_p.stat().st_size
    log.info("Saved: %s (%.1f MB)", output_path, total_size / 1e6)

    # Compile to .mlmodelc.
    #
    # This step used to be missing, and its absence was invisible until
    # runtime: the Rust loader calls MLModel(contentsOf:), which refuses a
    # raw .mlpackage with
    #
    #   Unable to load model: … Compile the model with Xcode or
    #   MLModel.compileModel(at:)
    #
    # `load_backend_or_fallback` swallows that error and silently returns
    # the zero-vector backend, so the only symptom was mcp-serve reporting
    # `recall=lexical-only` forever with a perfectly good model on disk.
    #
    # `xcrun coremlcompiler` would do this but ships only with full Xcode.
    # coremltools compiles on load and will hand us the path, which works
    # on a Command Line Tools box too.
    compiled_path = out_p.with_suffix(".mlmodelc")
    log.info("Compiling to %s...", compiled_path)
    try:
        # Hold the MLModel in a named variable for the whole copy. The
        # compiled directory lives in a temp dir owned by that object, so
        # `ct.models.MLModel(...).get_compiled_model_path()` as a one-liner
        # returns a path that is already deleted by the time copytree runs.
        loaded_for_compile = ct.models.MLModel(output_path)
        compiled_src = loaded_for_compile.get_compiled_model_path()
        if compiled_path.exists():
            shutil.rmtree(compiled_path)
        shutil.copytree(compiled_src, compiled_path)
        del loaded_for_compile
        compiled_size = sum(
            f.stat().st_size for f in compiled_path.rglob("*") if f.is_file()
        )
        log.info(
            "Compiled: %s (%.1f MB) — this is the one the Rust loader wants.",
            compiled_path,
            compiled_size / 1e6,
        )
    except Exception as e:  # noqa: BLE001 - surface any compile failure verbatim
        log.error(
            "Compile to .mlmodelc FAILED: %s\n"
            "The .mlpackage above is valid but the Rust loader cannot read it "
            "directly. Point MCI_ARCTIC_MODEL_PATH at a .mlmodelc, or compile "
            "manually with: xcrun coremlcompiler compile %s %s",
            e,
            output_path,
            out_p.parent,
        )
        raise

    if verify:
        log.info("Verifying...")
        loaded = ct.models.MLModel(output_path)
        spec = loaded.get_spec()
        out_desc = spec.description.output[0]
        out_shape = list(out_desc.type.multiArrayType.shape)
        out_ranges = list(out_desc.type.multiArrayType.shapeRange.sizeRanges)
        log.info(
            "  Output: %s, shape: %s, shapeRange: %s",
            out_desc.name,
            out_shape,
            [(r.lowerBound, r.upperBound) for r in out_ranges],
        )
        # Fixed-shape contract (2026-06-06 erratum): the output must be a
        # static [1, 384] with NO symbolic/data-dependent dim. A non-empty
        # shapeRange or a non-[1, 384] shape means the data-dependent-shape
        # regression is back — that is exactly what triggered the Espresso
        # "Invalid blob shape" E5RT failover. Fail the conversion loudly.
        assert out_shape == [1, OUTPUT_DIM], (
            f"output shape is {out_shape}, expected [1, {OUTPUT_DIM}]. The "
            "data-dependent-shape regression is back — check that the inputs "
            "are fixed shape=(1, 128), NOT ct.RangeDim."
        )
        assert not out_ranges, (
            f"output declares a flexible shapeRange {out_ranges}; expected a "
            "static shape. RangeDim inputs leak a symbolic dim into the output."
        )

        test_ids = tokenizer(
            "hello world",
            return_tensors="np",
            padding="max_length",
            max_length=MAX_SEQ_LEN,
        )
        pred = loaded.predict(
            {
                "input_ids": test_ids["input_ids"].astype(np.int32),
                "attention_mask": test_ids["attention_mask"].astype(np.int32),
            }
        )
        emb = pred["embedding"]
        assert emb.shape[-1] == OUTPUT_DIM, f"Expected {OUTPUT_DIM}-d, got {emb.shape}"
        mag = float(np.linalg.norm(emb))
        log.info("  Embedding magnitude: %.6f (expected ~1.0 from in-graph L2-norm)", mag)
        # In-graph L2-normalize: |v| must be 1.0 to within INT8 quant noise.
        assert abs(mag - 1.0) < 1e-3, (
            f"L2-norm in graph appears broken: |emb| = {mag} (expected 1.0). "
            "If you see this, the Python -> MIL conversion of F.normalize "
            "regressed. See BUNDLING.md §2."
        )
        log.info("  Verification passed (|emb| ~= 1.0).")

    if fixtures:
        _write_fixtures(quiet=quiet)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output .mlpackage path (e.g. models/ArcticEmbedS_INT8.mlpackage)",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Run a test embedding after conversion + assert |emb| ~= 1.0",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress output (for CI)",
    )
    parser.add_argument(
        "--fixtures",
        action="store_true",
        help=(
            "Write the 50-sentence Python FP32 reference fixture next to "
            "the Rust quality regression test (saves "
            "adapters/macos/mci-embed-coreml/tests/fixtures/"
            "arctic_embed_{sentences.txt,reference.npy})."
        ),
    )
    parser.add_argument(
        "--tokenizer",
        action="store_true",
        help=(
            "Verify the bundled tokenizer.json is present at "
            "adapters/macos/mci-embed-coreml/resources/tokenizer.json. "
            "No-op when the file already exists (Wave 17 commits it). "
            "Errors out with a curl command if missing."
        ),
    )
    parser.add_argument(
        "--int8",
        action="store_true",
        help=(
            "Apply INT8 weight quantization. Default is FP16 per ADR-0011 "
            "erratum 2026-05-22 (INT8 cosine-sim regression test failed "
            "43/50 sentences). Pass --int8 only to re-run the regression."
        ),
    )
    args = parser.parse_args()
    convert(
        args.output,
        verify=args.verify,
        quiet=args.quiet,
        fixtures=args.fixtures,
        write_tokenizer=args.tokenizer,
        quantize_int8=args.int8,
    )


if __name__ == "__main__":
    main()
