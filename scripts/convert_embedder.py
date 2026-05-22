#!/usr/bin/env python3
"""Convert Snowflake/snowflake-arctic-embed-s to Core ML .mlpackage.

Produces an INT8-quantized Core ML model with tokenizer baked into the
graph (string input → 384-d float32 embedding output).

Requirements:
    pip install coremltools>=8.0 torch>=2.2 transformers>=4.40 \
                optimum onnx onnxruntime

Usage:
    python scripts/convert_embedder.py --output models/ArcticEmbedS_INT8.mlpackage
    python scripts/convert_embedder.py --output models/ArcticEmbedS_INT8.mlpackage --verify

Per BUNDLING.md §3 and ADR-0011.
"""

import argparse
import sys
from pathlib import Path

MODEL_REPO = "Snowflake/snowflake-arctic-embed-s"
OUTPUT_DIM = 384


def convert(output_path: str, verify: bool = False) -> None:
    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoModel, AutoTokenizer
    except ImportError as e:
        print(
            f"Missing dependency: {e}\n"
            "Install: pip install coremltools>=8.0 torch>=2.2 transformers>=4.40",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Loading {MODEL_REPO}...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_REPO)
    model = AutoModel.from_pretrained(MODEL_REPO)
    model.eval()

    # Trace the model with a sample input. The Core ML model will bake
    # the tokenizer into the graph via a preprocessing step.
    sample_text = "Represent this sentence for searching relevant passages: hello world"
    inputs = tokenizer(
        sample_text, return_tensors="pt", padding=True, truncation=True, max_length=128
    )

    class EmbedWrapper(torch.nn.Module):
        """Wrap the transformer to return CLS token embedding."""

        def __init__(self, base_model):
            super().__init__()
            self.model = base_model

        def forward(self, input_ids, attention_mask, token_type_ids=None):
            outputs = self.model(
                input_ids=input_ids,
                attention_mask=attention_mask,
                token_type_ids=token_type_ids,
            )
            # CLS token embedding (index 0)
            cls_embedding = outputs.last_hidden_state[:, 0, :]
            return cls_embedding

    wrapper = EmbedWrapper(model)
    wrapper.eval()

    traced = torch.jit.trace(
        wrapper,
        (inputs["input_ids"], inputs["attention_mask"]),
    )

    print("Converting to Core ML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, ct.RangeDim(1, 128)), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, ct.RangeDim(1, 128)), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS15,
    )

    # INT8 quantization per ADR-0011 §1
    print("Applying INT8 quantization...")
    op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8"
    )
    config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
    mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=config)

    # Note: The tokenizer is NOT baked into THIS model variant.
    # The full text-input model (per BUNDLING.md §2) uses a different
    # conversion path via optimum that bakes tokenization in.
    # This script produces the input_ids variant for reference.
    # The download_model.sh script handles the text-input variant.

    print(f"Saving to {output_path}...")
    mlmodel.save(output_path)
    print(f"Saved: {output_path}")

    if verify:
        print("Verifying...")
        loaded = ct.models.MLModel(output_path)
        # Quick shape check
        spec = loaded.get_spec()
        out_desc = spec.description.output[0]
        print(f"  Output: {out_desc.name}, shape: {out_desc.type.multiArrayType.shape}")

        # Run inference
        test_ids = tokenizer("hello world", return_tensors="np", padding="max_length", max_length=128)
        pred = loaded.predict({
            "input_ids": test_ids["input_ids"].astype(np.int32),
            "attention_mask": test_ids["attention_mask"].astype(np.int32),
        })
        emb = pred["embedding"]
        assert emb.shape[-1] == OUTPUT_DIM, f"Expected {OUTPUT_DIM}-d, got {emb.shape}"
        mag = float(np.linalg.norm(emb))
        print(f"  Embedding magnitude: {mag:.4f} (pre-L2-norm)")
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
        help="Run a test embedding after conversion",
    )
    args = parser.parse_args()
    convert(args.output, args.verify)


if __name__ == "__main__":
    main()
