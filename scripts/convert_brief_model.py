#!/usr/bin/env python3
"""Convert Qwen/Qwen3-1.7B to Core ML .mlpackage with INT4 palettization.

Conversion approach (path a — fixed sequence length, eager attention):

  The original script failed with:
      RuntimeError: unordered_map::at: key not found
  Root cause: torch/coremltools op-signature mismatch. coremltools 8.x
  expects torch <=2.5 op signatures; newer torch versions produce
  traced ops with different signatures (coremltools#2504). Additionally,
  torch.nn.functional.scaled_dot_product_attention (SDPA) traces to a
  single fused op that coremltools may not have a MIL converter for.

  Fixes applied:
    1. attn_implementation="eager" — forces HF transformers to use the
       manual QKV-matmul attention path instead of SDPA. All resulting
       ops (matmul, softmax, reshape) have stable coremltools converters.
    2. Fixed sequence length (no ct.RangeDim) — avoids the dynamic-shape
       MIL pass that can trigger additional op-coverage gaps.
    3. attention_mask input — required for padded fixed-length sequences
       during autoregressive generation.
    4. torch version gate — warns if torch >2.5.x (likely incompatible
       with coremltools 8.x op registry).
    5. Fallback to torch.export.export() if torch.jit.trace fails
       (better op decomposition for newer torch versions).

  Paths tried and status:
    (a) Fixed seq len + eager attn + version pin: THIS PATH (chosen).
    (b) optimum-cli export coreml: does not exist. optimum[coreml] is
        not a real pip extra. HF moved Core ML to a separate 'exporters'
        library that only supports vision models.
    (c) ExecuTorch: not attempted (path a works).
    (d) Llama 3.2 1B fallback: not needed (path a works).

  Evidence the architecture converts:
    - wolfofbackstreet/Qwen3-0.6B-Coreml exists on HuggingFace.
    - CoreML-LLM project (john-rocky/CoreML-LLM) claims Qwen3 support.
    - Qwen3's RoPE uses sin/cos form (not complex-number ops), so no
      monkey-patching needed for rotary embeddings.

Produces a Core ML model for stateless autoregressive text generation:
    Input  input_ids       Int32  [1, SEQ_LEN]
    Input  attention_mask  Int32  [1, SEQ_LEN]
    Output logits          Float16 [1, SEQ_LEN, VOCAB_SIZE]

The Rust backend (core/brief/llama_backend.rs) handles repeated forward
passes — no KV cache needed in the Core ML graph.

Requirements:
    pip install -r scripts/requirements-ml.txt

Usage:
    python scripts/convert_brief_model.py --output models/Qwen3-1.7B-INT4.mlpackage
    python scripts/convert_brief_model.py --output models/Qwen3-1.7B-INT4.mlpackage --verify
    python scripts/convert_brief_model.py --output models/Qwen3-1.7B-INT4.mlpackage --seq-len 512

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
        return exported, "export"
    except Exception as e:
        log.error("torch.export also failed: %s", e)
        raise RuntimeError(
            f"Both torch.jit.trace and torch.export failed. "
            f"Check torch/coremltools version compatibility. "
            f"Last error: {e}"
        ) from e


def convert(
    output_path: str,
    verify: bool = False,
    quiet: bool = False,
    dry_run: bool = False,
    seq_len: int = DEFAULT_SEQ_LEN,
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

    # INT4 palettization per ADR-0028 §2
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
    test_mask = encoded["attention_mask"].astype(np.int32)

    pred = loaded.predict({
        "input_ids": test_ids,
        "attention_mask": test_mask,
    })
    logits = pred["logits"]
    log.info("  Logits shape: %s", logits.shape)

    # Find last real token position (before padding)
    real_len = int(test_mask.sum())
    next_token = int(np.argmax(logits[0, real_len - 1, :]))
    decoded = tokenizer.decode([next_token])
    log.info(
        "  First predicted token: %d → '%s' (at position %d)",
        next_token,
        decoded,
        real_len - 1,
    )
    log.info("  Verification passed.")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output .mlpackage path",
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
        "--seq-len",
        type=int,
        default=DEFAULT_SEQ_LEN,
        help=(
            f"Fixed sequence length for the Core ML model (default: {DEFAULT_SEQ_LEN}). "
            "The model will only accept inputs of exactly this length. "
            "The Rust backend pads shorter inputs and truncates longer ones."
        ),
    )
    args = parser.parse_args()
    convert(args.output, args.verify, args.quiet, args.dry_run, args.seq_len)


if __name__ == "__main__":
    main()
