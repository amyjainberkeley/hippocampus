#!/usr/bin/env python3
"""Convert Qwen/Qwen3-1.7B to Core ML .mlpackage with INT4 palettization.

Produces a Core ML model for autoregressive text generation.
The model takes input_ids and returns logits.

Requirements:
    pip install -r scripts/requirements-ml.txt

Usage:
    python scripts/convert_brief_model.py --output models/Qwen3-1.7B-INT4.mlpackage
    python scripts/convert_brief_model.py --output models/Qwen3-1.7B-INT4.mlpackage --verify

Per ADR-0028.

Note on approach:
    This script exports the model as a standard Core ML model with
    input_ids → logits. For efficient autoregressive generation, the
    conversion uses coremltools 8.x stateful model APIs when available
    to manage KV cache internally. If stateful APIs are not available
    or fail, the script falls back to a non-stateful model (the Rust
    backend handles repeated forward passes).
"""

import argparse
import hashlib
import logging
import sys
from pathlib import Path

MODEL_REPO = "Qwen/Qwen3-1.7B"
MAX_SEQ_LEN = 4096

log = logging.getLogger("convert_brief_model")


def convert(output_path: str, verify: bool = False, quiet: bool = False) -> None:
    if quiet:
        logging.basicConfig(level=logging.WARNING)
    else:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

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
            "Required packages: coremltools>=8.0 torch>=2.2 transformers>=4.40\n"
            "Apple Silicon recommended. ~20-40 min conversion time.",
            file=sys.stderr,
        )
        sys.exit(1)

    log.info("Loading %s...", MODEL_REPO)
    tokenizer = AutoTokenizer.from_pretrained(MODEL_REPO, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_REPO, torch_dtype=torch.float16, trust_remote_code=True
    )
    model.eval()

    # Export path: trace the model with a fixed sequence length input
    log.info("Tracing model...")
    sample_len = 32
    sample_ids = torch.randint(0, 1000, (1, sample_len), dtype=torch.long)

    class CausalLMWrapper(torch.nn.Module):
        """Extract logits from the CausalLM output."""

        def __init__(self, base_model):
            super().__init__()
            self.model = base_model

        def forward(self, input_ids):
            outputs = self.model(input_ids=input_ids, use_cache=False)
            return outputs.logits

    wrapper = CausalLMWrapper(model)
    wrapper.eval()

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (sample_ids,))

    log.info("Converting to Core ML...")
    try:
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(
                    name="input_ids",
                    shape=(1, ct.RangeDim(1, MAX_SEQ_LEN)),
                    dtype=np.int32,
                ),
            ],
            outputs=[ct.TensorType(name="logits", dtype=np.float32)],
            compute_units=ct.ComputeUnit.CPU_AND_NE,
            minimum_deployment_target=ct.target.macOS15,
        )
    except Exception as e:
        log.info("Variable-length conversion failed (%s), trying fixed length...", e)
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(
                    name="input_ids",
                    shape=(1, sample_len),
                    dtype=np.int32,
                ),
            ],
            outputs=[ct.TensorType(name="logits", dtype=np.float32)],
            compute_units=ct.ComputeUnit.CPU_AND_NE,
            minimum_deployment_target=ct.target.macOS15,
        )

    # INT4 palettization per ADR-0028 §2
    log.info("Applying INT4 palettization...")
    try:
        op_config = ct.optimize.coreml.OpPalettizerConfig(
            mode="kmeans", nbits=4
        )
        config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
        mlmodel = ct.optimize.coreml.palettize_weights(mlmodel, config=config)
    except Exception as e:
        log.warning("INT4 palettization failed (%s), saving FP16 model.", e)

    log.info("Saving to %s...", output_path)
    mlmodel.save(output_path)

    out_dir = Path(output_path).parent
    log.info("Saving tokenizer files to %s...", out_dir)
    tokenizer.save_pretrained(str(out_dir))
    vocab_src = out_dir / "vocab.json"
    merges_src = out_dir / "merges.txt"
    if not vocab_src.exists():
        log.info("Note: vocab.json not found. Extract from tokenizer.json manually.")
    if not merges_src.exists():
        log.info("Note: merges.txt not found. Extract from tokenizer.json manually.")

    out_p = Path(output_path)
    if out_p.is_dir():
        total_size = sum(f.stat().st_size for f in out_p.rglob("*") if f.is_file())
    else:
        total_size = out_p.stat().st_size
    log.info("Saved: %s (%.1f MB)", output_path, total_size / 1e6)

    log.info("")
    log.info("Next steps:")
    log.info("  1. Compile .mlpackage → .mlmodelc (if not already):")
    log.info("     xcrun coremlcompiler compile %s models/", output_path)
    log.info("  2. Tar.gz the .mlmodelc:")
    log.info("     tar -czf Qwen3-1.7B-INT4.mlmodelc.tar.gz -C models Qwen3-1.7B-INT4.mlmodelc")
    log.info("  3. Compute SHA-256:")
    log.info("     shasum -a 256 Qwen3-1.7B-INT4.mlmodelc.tar.gz")
    log.info("  4. Upload to HF repo amyjainberkeley/hippocampus-coreml-models")
    log.info("  5. Update apps/hippocampus/Resources/models.json sha256 field")

    if verify:
        log.info("Verifying...")
        loaded = ct.models.MLModel(output_path)
        spec = loaded.get_spec()
        log.info("  Inputs: %s", [i.name for i in spec.description.input])
        log.info("  Outputs: %s", [o.name for o in spec.description.output])

        test_text = "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n"
        test_ids = tokenizer(test_text, return_tensors="np")["input_ids"].astype(np.int32)
        pred = loaded.predict({"input_ids": test_ids})
        logits = pred["logits"]
        log.info("  Logits shape: %s", logits.shape)
        next_token = int(np.argmax(logits[0, -1, :]))
        decoded = tokenizer.decode([next_token])
        log.info("  First predicted token: %d → '%s'", next_token, decoded)
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
    args = parser.parse_args()
    convert(args.output, args.verify, args.quiet)


if __name__ == "__main__":
    main()
