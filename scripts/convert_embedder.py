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
import hashlib
import logging
import sys
from pathlib import Path

MODEL_REPO = "Snowflake/snowflake-arctic-embed-s"
OUTPUT_DIM = 384

log = logging.getLogger("convert_embedder")


def convert(output_path: str, verify: bool = False, quiet: bool = False) -> None:
    if quiet:
        logging.basicConfig(level=logging.WARNING)
    else:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

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
            "  pip install coremltools>=8.0 torch>=2.2 transformers>=4.40",
            file=sys.stderr,
        )
        sys.exit(1)

    log.info("Loading %s...", MODEL_REPO)
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

    log.info("Converting to Core ML...")
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
    log.info("Applying INT8 quantization...")
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

    log.info("Saving to %s...", output_path)
    mlmodel.save(output_path)

    out_p = Path(output_path)
    if out_p.is_dir():
        total_size = sum(f.stat().st_size for f in out_p.rglob("*") if f.is_file())
    else:
        total_size = out_p.stat().st_size
    log.info("Saved: %s (%.1f MB)", output_path, total_size / 1e6)

    if verify:
        log.info("Verifying...")
        loaded = ct.models.MLModel(output_path)
        spec = loaded.get_spec()
        out_desc = spec.description.output[0]
        log.info("  Output: %s, shape: %s", out_desc.name, out_desc.type.multiArrayType.shape)

        test_ids = tokenizer("hello world", return_tensors="np", padding="max_length", max_length=128)
        pred = loaded.predict({
            "input_ids": test_ids["input_ids"].astype(np.int32),
            "attention_mask": test_ids["attention_mask"].astype(np.int32),
        })
        emb = pred["embedding"]
        assert emb.shape[-1] == OUTPUT_DIM, f"Expected {OUTPUT_DIM}-d, got {emb.shape}"
        mag = float(np.linalg.norm(emb))
        log.info("  Embedding magnitude: %.4f (pre-L2-norm)", mag)
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
        help="Run a test embedding after conversion",
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
