#!/usr/bin/env python3
"""Convert Qwen/Qwen3-1.7B to Core ML .mlpackage with INT4 palettization.

Two conversion paths, in order of preference. The script tries A first
and falls back to B automatically:

  Path A — torch.jit.trace (or torch.export + run_decompositions)
                                                        + ct.convert
    Preferred path. Cleanest when torch is pinned in the supported
    range (>=2.4,<2.6). When torch.jit.trace fails on newer torch
    versions, falls back to torch.export.export() and applies
    `.run_decompositions({})` to lower the TRAINING dialect to ATEN
    (which is what coremltools accepts — torch 2.6+ otherwise emits
    `Provided Dialect: TRAINING. Run '.run_decompositions({})' on
    your exported PyTorch Model prior to conversion`).

  Path B — torch.onnx.export (opset 17) -> ct.convert on ONNX artifact
    Last-resort fallback when both jit.trace and torch.export
    paths fail at the MIL converter. Requires `onnxscript` (added
    to requirements-ml.txt). Apple's Core ML ONNX import wants
    opset 17+.

Both paths produce the same I/O contract for the Rust backend
(adapters/macos/mci-llama-coreml):

    Input  input_ids       Int32  [1, SEQ_LEN]
    Input  attention_mask  Int32  [1, SEQ_LEN]
    Output logits          Float16 [1, SEQ_LEN, VOCAB_SIZE]

The Rust backend handles repeated forward passes — no KV cache needed
in the Core ML graph.

Why eager attention and fixed seq_len?

  1. attn_implementation="eager" — forces HF transformers to use the
     manual QKV-matmul attention path instead of SDPA. SDPA traces
     to a single fused op coremltools does not always have a MIL
     converter for.
  2. Fixed sequence length (no ct.RangeDim) — avoids the dynamic-shape
     MIL pass that can trigger additional op-coverage gaps. The Rust
     backend pads/truncates to this length.
  3. attention_mask input — required for padded fixed-length sequences
     during autoregressive generation.

One-shot setup (fresh venv, takes ~3-5 min):

    python3.11 -m venv .venv-ml
    source .venv-ml/bin/activate
    pip install -r scripts/requirements-ml.txt
    python scripts/convert_brief_model.py --check-env

  If `--check-env` prints "Env looks OK" you can run the real
  conversion (~20-40 min CPU on Apple Silicon):

    python scripts/convert_brief_model.py \\
        --output models/Qwen3-1.7B-INT4.mlpackage --verify

Other useful flags:

    --dry-run        Load + trace only, skip ct.convert. Fast (~30 s)
                     smoke test that the env can produce a traceable
                     ExportedProgram. CI-safe.
    --check-env      Print torch/coremltools/onnxscript versions and
                     report which conversion path will be taken.
                     Exits 0 if usable, 2 if missing critical deps.
    --seq-len N      Override default fixed seq length (default 2048).

Per ADR-0028.
"""

import argparse
import logging
import sys
import tempfile
from pathlib import Path

MODEL_REPO = "Qwen/Qwen3-1.7B"
DEFAULT_SEQ_LEN = 2048

log = logging.getLogger("convert_brief_model")


def _patch_torch_for_coremltools() -> None:
    """Monkey-patches for coremltools op-converter gaps.

    Same pattern as convert_embedder.py (retained from PR #143).
    """
    import torch

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


def _check_versions() -> None:
    """Warn if torch/coremltools versions are likely incompatible."""
    import coremltools as ct
    import torch

    ct_ver = tuple(int(x) for x in ct.__version__.split(".")[:2])
    torch_ver = tuple(int(x) for x in torch.__version__.split(".")[:2])

    if ct_ver < (8, 0):
        log.warning(
            "coremltools %s is older than 8.0. Conversion may fail.",
            ct.__version__,
        )

    if ct_ver[0] == 8 and torch_ver > (2, 5):
        log.warning(
            "torch %s with coremltools %s: op-signature mismatch likely. "
            "The unordered_map::at error is caused by this. "
            "Recommended: pip install 'torch>=2.4,<2.6'",
            torch.__version__,
            ct.__version__,
        )
    elif ct_ver[0] >= 9 and torch_ver > (2, 6):
        log.warning(
            "torch %s may be too new for coremltools %s. "
            "Check coremltools release notes for supported torch versions.",
            torch.__version__,
            ct.__version__,
        )

    log.info(
        "Versions: torch=%s coremltools=%s",
        torch.__version__,
        ct.__version__,
    )


def _try_onnx_conversion(wrapper, sample_ids, sample_mask, seq_len):
    """Path B fallback: torch.onnx.export -> ct.convert on ONNX artifact."""
    import coremltools as ct
    import numpy as np
    import torch

    with tempfile.TemporaryDirectory() as tmpdir:
        onnx_path = str(Path(tmpdir) / "model.onnx")
        log.info("Exporting to ONNX (opset 17)...")
        with torch.no_grad():
            torch.onnx.export(
                wrapper,
                (sample_ids, sample_mask),
                onnx_path,
                input_names=["input_ids", "attention_mask"],
                output_names=["logits"],
                opset_version=17,
                do_constant_folding=True,
            )
        log.info("ONNX export succeeded. Converting to Core ML...")
        mlmodel = ct.convert(
            onnx_path,
            inputs=[
                ct.TensorType(
                    name="input_ids",
                    shape=(1, seq_len),
                    dtype=np.int32,
                ),
                ct.TensorType(
                    name="attention_mask",
                    shape=(1, seq_len),
                    dtype=np.int32,
                ),
            ],
            outputs=[ct.TensorType(name="logits", dtype=np.float16)],
            compute_units=ct.ComputeUnit.CPU_AND_NE,
            minimum_deployment_target=ct.target.macOS15,
        )
        log.info("ONNX intermediate path succeeded.")
        return mlmodel


def _trace_model(wrapper, sample_ids, sample_mask):
    """Try torch.jit.trace; fall back to torch.export if trace fails."""
    import torch

    log.info("Attempting torch.jit.trace...")
    try:
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, (sample_ids, sample_mask))
        log.info("torch.jit.trace succeeded.")
        return traced, "trace"
    except Exception as e:
        log.warning("torch.jit.trace failed: %s", e)

    log.info("Attempting torch.export.export (fallback)...")
    try:
        exported = torch.export.export(
            wrapper, (sample_ids, sample_mask)
        )
        log.info("torch.export.export succeeded.")
    except Exception as e:
        log.error("torch.export also failed: %s", e)
        raise RuntimeError(
            f"Both torch.jit.trace and torch.export failed. "
            f"Check torch/coremltools version compatibility. "
            f"Last error: {e}"
        ) from e

    # torch 2.6+ emits ExportedProgram in the TRAINING dialect.
    # coremltools ct.convert rejects it: "Conversion for models with
    # only ATEN or EDGE dialect is supported/tested. Provided Dialect:
    # TRAINING. Run '.run_decompositions({})' on your exported PyTorch
    # Model prior to conversion." So lower it here.
    if hasattr(exported, "run_decompositions"):
        log.info("Lowering ExportedProgram via run_decompositions({})...")
        try:
            exported = exported.run_decompositions({})
            log.info("run_decompositions succeeded (TRAINING -> ATEN).")
        except Exception as e:
            log.warning(
                "run_decompositions failed (%s); passing original "
                "ExportedProgram to ct.convert. If ct.convert reports "
                "'Provided Dialect: TRAINING', this is why.",
                e,
            )
    return exported, "export"


def _check_env() -> int:
    """Print versions + predict which conversion path will be taken.

    Returns 0 if the env is usable for at least one path, 2 if critical
    deps are missing. Imports each dep individually so partial envs
    still get a useful report.
    """
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    print("=== Qwen3 conversion env check ===")

    def _try(name):
        try:
            mod = __import__(name)
            ver = getattr(mod, "__version__", "?")
            print(f"  {name:<14} {ver}")
            return mod
        except ImportError:
            print(f"  {name:<14} MISSING")
            return None

    torch_mod = _try("torch")
    ct_mod = _try("coremltools")
    np_mod = _try("numpy")
    _try("transformers")
    _try("onnx")
    onnxscript_mod = _try("onnxscript")

    print()
    critical_missing = [
        (n, m) for n, m in [
            ("torch", torch_mod),
            ("coremltools", ct_mod),
            ("numpy", np_mod),
        ] if m is None
    ]
    if critical_missing:
        names = ", ".join(n for n, _ in critical_missing)
        print(f"CRITICAL: {names} missing. Run:")
        print("  pip install -r scripts/requirements-ml.txt")
        return 2

    torch_ver = tuple(int(x) for x in torch_mod.__version__.split(".")[:2])
    ct_ver = tuple(int(x) for x in ct_mod.__version__.split(".")[:2])
    numpy_v2 = np_mod.__version__.startswith("2.")

    print("Path A (torch.jit.trace + ct.convert):")
    if (2, 4) <= torch_ver < (2, 6):
        print("  primary path — torch in pinned range, should succeed.")
    elif torch_ver >= (2, 6):
        print(
            "  jit.trace may fail on torch %s; script auto-falls back to"
            % torch_mod.__version__
        )
        print(
            "  torch.export + run_decompositions({}) -> ct.convert."
        )
    else:
        print("  torch %s is older than 2.4 — upgrade first." % torch_mod.__version__)

    print("Path B (torch.onnx.export opset 17 -> ct.convert on ONNX):")
    if onnxscript_mod is not None:
        print("  available as last-resort fallback.")
    else:
        print("  UNAVAILABLE — onnxscript missing. Run:")
        print("    pip install onnxscript")

    print()
    warnings = []
    if ct_ver < (8, 0):
        warnings.append(
            "coremltools %s < 8.0 — INT4 palettize may not exist."
            % ct_mod.__version__
        )
    if numpy_v2:
        warnings.append(
            "numpy %s is 2.x — coremltools 8.x is not numpy-2 clean. "
            "Pin numpy<2.0." % np_mod.__version__
        )
    if warnings:
        for w in warnings:
            print(f"WARNING: {w}")
        print()

    print("Env looks OK. Next:")
    print("  python scripts/convert_brief_model.py \\")
    print("    --output models/Qwen3-1.7B-INT4.mlpackage --verify")
    return 0


def convert(
    output_path: str,
    verify: bool = False,
    quiet: bool = False,
    dry_run: bool = False,
    seq_len: int = DEFAULT_SEQ_LEN,
    palettize: bool = True,
) -> None:
    if quiet:
        logging.basicConfig(level=logging.WARNING)
    else:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

    log.info(
        "Using conversion path: torch.jit.trace + eager attention + "
        "fixed seq_len=%d (path a)",
        seq_len,
    )

    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except ImportError as e:
        print(
            f"ERROR: Missing dependency: {e}\n\n"
            "Fix:\n"
            "  pip install -r scripts/requirements-ml.txt\n\n"
            "Required packages:\n"
            "  coremltools>=8.0\n"
            "  torch>=2.4,<2.6  (version must match coremltools)\n"
            "  transformers>=4.40\n"
            "  numpy<2.0        (coremltools 8.x is not numpy-2 clean)\n\n"
            "Apple Silicon recommended. ~20-40 min conversion time.",
            file=sys.stderr,
        )
        sys.exit(1)

    _check_versions()
    _patch_torch_for_coremltools()

    log.info("Loading %s with attn_implementation='eager'...", MODEL_REPO)
    tokenizer = AutoTokenizer.from_pretrained(MODEL_REPO, trust_remote_code=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token_id = tokenizer.eos_token_id
        log.info("pad_token_id not set, using eos_token_id (%d)", tokenizer.pad_token_id)

    model = AutoModelForCausalLM.from_pretrained(
        MODEL_REPO,
        torch_dtype=torch.float16,
        trust_remote_code=True,
        attn_implementation="eager",
    )
    model.config.use_cache = False
    model.eval()

    log.info("Preparing trace inputs (seq_len=%d)...", seq_len)
    sample_ids = torch.randint(0, 1000, (1, seq_len), dtype=torch.long)
    sample_mask = torch.ones((1, seq_len), dtype=torch.long)

    class CausalLMWrapper(torch.nn.Module):
        """Extract logits from CausalLM output with explicit attention_mask."""

        def __init__(self, base_model):
            super().__init__()
            self.model = base_model

        def forward(self, input_ids, attention_mask):
            outputs = self.model(
                input_ids=input_ids,
                attention_mask=attention_mask,
                use_cache=False,
            )
            return outputs.logits

    wrapper = CausalLMWrapper(model)
    wrapper.eval()

    traced_model, trace_method = _trace_model(wrapper, sample_ids, sample_mask)

    if dry_run:
        log.info("--dry-run: trace succeeded (%s). Skipping ct.convert.", trace_method)
        log.info("Re-run without --dry-run for full conversion (~20-40 min).")
        return

    log.info("Converting to Core ML (fixed shape [1, %d])...", seq_len)
    try:
        mlmodel = ct.convert(
            traced_model,
            inputs=[
                ct.TensorType(
                    name="input_ids",
                    shape=(1, seq_len),
                    dtype=np.int32,
                ),
                ct.TensorType(
                    name="attention_mask",
                    shape=(1, seq_len),
                    dtype=np.int32,
                ),
            ],
            outputs=[ct.TensorType(name="logits", dtype=np.float16)],
            compute_units=ct.ComputeUnit.CPU_AND_NE,
            minimum_deployment_target=ct.target.macOS15,
        )
        log.info("Direct ct.convert succeeded (trace method: %s).", trace_method)
    except Exception as e:
        log.warning("Direct ct.convert failed: %s", e)
        log.info("Falling back to ONNX intermediate path...")
        mlmodel = _try_onnx_conversion(wrapper, sample_ids, sample_mask, seq_len)

    # INT4 palettization per ADR-0028 §2 (opt-out via --no-palettize)
    if palettize:
        log.info("Applying INT4 palettization...")
        try:
            op_config = ct.optimize.coreml.OpPalettizerConfig(
                mode="kmeans", nbits=4
            )
            config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
            mlmodel = ct.optimize.coreml.palettize_weights(mlmodel, config=config)
            log.info("INT4 palettization succeeded.")
        except Exception as e:
            log.warning("INT4 palettization failed (%s), saving FP16 model.", e)
    else:
        log.info("--no-palettize: keeping FP16 weights (no quantization).")

    log.info("Saving to %s...", output_path)
    mlmodel.save(output_path)

    out_dir = Path(output_path).parent
    log.info("Saving tokenizer files to %s...", out_dir)
    tokenizer.save_pretrained(str(out_dir))
    tok_json = out_dir / "tokenizer.json"
    if tok_json.exists():
        log.info("tokenizer.json saved (Qwen3 BPE fast tokenizer).")
    else:
        log.warning(
            "tokenizer.json not found after save_pretrained. "
            "The Rust BPE tokenizer needs this file."
        )

    out_p = Path(output_path)
    if out_p.is_dir():
        total_size = sum(f.stat().st_size for f in out_p.rglob("*") if f.is_file())
    else:
        total_size = out_p.stat().st_size
    log.info("Saved: %s (%.1f MB)", output_path, total_size / 1e6)
    log.info("Trace method used: %s", trace_method)
    log.info("Fixed sequence length: %d", seq_len)

    log.info("")
    log.info("Next steps:")
    log.info("  1. Compile .mlpackage → .mlmodelc:")
    log.info("     xcrun coremlcompiler compile %s models/", output_path)
    log.info("  2. Tar.gz the .mlmodelc:")
    log.info(
        "     tar -czf Qwen3-1.7B-INT4.mlmodelc.tar.gz "
        "-C models Qwen3-1.7B-INT4.mlmodelc"
    )
    log.info("  3. Compute SHA-256:")
    log.info("     shasum -a 256 Qwen3-1.7B-INT4.mlmodelc.tar.gz")
    log.info("  4. Upload to HF repo amyjainberkeley/hippocampus-coreml-models")
    log.info(
        "  5. Update apps/hippocampus/Resources/models.json sha256 field"
    )

    if verify:
        _verify(output_path, tokenizer, seq_len)


def _verify(output_path: str, tokenizer, seq_len: int) -> None:
    """Load the saved model and run a single forward pass."""
    import coremltools as ct
    import numpy as np

    log.info("Verifying...")
    loaded = ct.models.MLModel(output_path)
    spec = loaded.get_spec()
    log.info("  Inputs: %s", [i.name for i in spec.description.input])
    log.info("  Outputs: %s", [o.name for o in spec.description.output])

    test_text = (
        "<|im_start|>system\n"
        "You are a helpful assistant.<|im_end|>\n"
        "<|im_start|>user\n"
        "Hello<|im_end|>\n"
        "<|im_start|>assistant\n"
    )
    encoded = tokenizer(
        test_text,
        return_tensors="np",
        padding="max_length",
        truncation=True,
        max_length=seq_len,
    )
    test_ids = encoded["input_ids"].astype(np.int32)
    real_len = int(encoded["attention_mask"].sum())

    # IMPORTANT: pass attention_mask = ones((1, seq_len)) at inference,
    # NOT the partial mask the tokenizer produces. The conversion traces
    # with attn_implementation="eager" + ones mask, so the transformers
    # mask helper's `if padding_length > 0` branch is never recorded in
    # the .mlmodelc graph. A partial mask at inference makes the model
    # predict `<|endoftext|>` as the first generated token on every
    # prompt (silent failure — the conversion succeeds, the model is
    # garbage). Surfaced by ADR-0028 brief-eval (cycle 8.10, 0/8 → 8/8
    # after this fix). The Rust backend `Qwen3CoreMLBackend::forward_pass`
    # carries the same discipline.
    inference_mask = np.ones((1, seq_len), dtype=np.int32)

    pred = loaded.predict({
        "input_ids": test_ids,
        "attention_mask": inference_mask,
    })
    logits = pred["logits"]
    log.info("  Logits shape: %s", logits.shape)

    next_token = int(np.argmax(logits[0, real_len - 1, :]))
    decoded = tokenizer.decode([next_token])
    log.info(
        "  First predicted token: %d → '%s' (at position %d)",
        next_token,
        decoded,
        real_len - 1,
    )
    if next_token == tokenizer.eos_token_id:
        log.warning(
            "  Verification produced EOS as first token — model is likely "
            "broken at inference time. Check the trace's attention_mask "
            "shape (must match inference shape) and re-run conversion."
        )
    else:
        log.info("  Verification passed.")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--output",
        help="Output .mlpackage path (required unless --check-env)",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Run test inference after conversion",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress output (for CI)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Load model + trace only, skip ct.convert (fast validation)",
    )
    parser.add_argument(
        "--check-env",
        action="store_true",
        help=(
            "Print torch/coremltools/onnxscript versions, report which "
            "conversion path will be taken, and exit. Does not load "
            "the model or run conversion."
        ),
    )
    parser.add_argument(
        "--seq-len",
        type=int,
        default=DEFAULT_SEQ_LEN,
        help=(
            f"Fixed sequence length for the Core ML model (default: {DEFAULT_SEQ_LEN}). "
            "The model will only accept inputs of exactly this length. "
            "The Rust backend pads shorter inputs and truncates longer ones."
        ),
    )
    parser.add_argument(
        "--no-palettize",
        action="store_true",
        help=(
            "Skip INT4 k-means palettization; keep the model in FP16. "
            "Produces a ~3.4 GB .mlpackage instead of ~860 MB but preserves "
            "model quality. Use as a diagnostic when INT4 output is "
            "incoherent (cycle 8.10: INT4 without calibration data drops "
            "Qwen3-1.7B below ADR-0028's quality threshold)."
        ),
    )
    args = parser.parse_args()
    if args.check_env:
        sys.exit(_check_env())
    if not args.output:
        parser.error("--output is required unless --check-env is used.")
    convert(
        args.output,
        args.verify,
        args.quiet,
        args.dry_run,
        args.seq_len,
        palettize=not args.no_palettize,
    )


if __name__ == "__main__":
    main()
