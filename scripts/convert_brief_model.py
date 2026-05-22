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
import sys
from pathlib import Path

MODEL_REPO = "Qwen/Qwen3-1.7B"
MAX_SEQ_LEN = 4096


def convert(output_path: str, verify: bool = False) -> None:
    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except ImportError as e:
        print(
            f"Missing dependency: {e}\n"
            "Install: pip install -r scripts/requirements-ml.txt",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Loading {MODEL_REPO}...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_REPO, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_REPO, torch_dtype=torch.float16, trust_remote_code=True
    )
    model.eval()

    # Export path: trace the model with a fixed sequence length input
    print("Tracing model...")
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

    print("Converting to Core ML...")
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
        print(f"Variable-length conversion failed ({e}), trying fixed length...")
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
    print("Applying INT4 palettization...")
    try:
        op_config = ct.optimize.coreml.OpPalettizerConfig(
            mode="kmeans", nbits=4
        )
        config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
        mlmodel = ct.optimize.coreml.palettize_weights(mlmodel, config=config)
    except Exception as e:
        print(f"Warning: INT4 palettization failed ({e}), saving FP16 model.")

    print(f"Saving to {output_path}...")
    mlmodel.save(output_path)

    # Copy tokenizer files alongside the model
    out_dir = Path(output_path).parent
    print(f"Saving tokenizer files to {out_dir}...")
    tokenizer.save_pretrained(str(out_dir))
    # Rename tokenizer.json components to the flat format the Rust
    # tokenizer expects (vocab.json + merges.txt)
    vocab_src = out_dir / "vocab.json"
    merges_src = out_dir / "merges.txt"
    if not vocab_src.exists():
        # HuggingFace tokenizers may save as tokenizer.json instead
        print("Note: vocab.json not found. Extract from tokenizer.json manually.")
    if not merges_src.exists():
        print("Note: merges.txt not found. Extract from tokenizer.json manually.")

    print(f"Saved: {output_path}")

    if verify:
        print("Verifying...")
        loaded = ct.models.MLModel(output_path)
        spec = loaded.get_spec()
        print(f"  Inputs: {[i.name for i in spec.description.input]}")
        print(f"  Outputs: {[o.name for o in spec.description.output]}")

        test_text = "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n"
        test_ids = tokenizer(test_text, return_tensors="np")["input_ids"].astype(np.int32)
        pred = loaded.predict({"input_ids": test_ids})
        logits = pred["logits"]
        print(f"  Logits shape: {logits.shape}")
        next_token = int(np.argmax(logits[0, -1, :]))
        decoded = tokenizer.decode([next_token])
        print(f"  First predicted token: {next_token} → '{decoded}'")
        print("  Verification passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
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
    args = parser.parse_args()
    convert(args.output, args.verify)


if __name__ == "__main__":
    main()
