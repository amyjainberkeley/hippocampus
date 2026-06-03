#!/usr/bin/env python3
"""Convert a supervised NER token-classifier to Core ML for MCI's V2-P5+
sync-hot-path entity extraction (Person/Org/Location).

This is the CEO-ratified V2-P5+ NER path (2026-06-03): GLiNER was dropped
(every strong variant is DeBERTa-v3, which does not convert — see
docs/research/2026-06-03-ner-backbone-convertibility-scan.md). MCI's 5
kinds are FIXED, so zero-shot is unnecessary; a standard supervised NER
covers Person/Org/Location and the shipped V2-P4 Tier-1 regex covers
Date/Time. The default model `dslim/distilbert-NER` is proven-convertible
on this stack (100% of ops, 100% argmax fidelity FP16-vs-FP32).

Same shape as scripts/convert_embedder.py and scripts/convert_brief_model.py
(load -> new_ones patch -> jit.trace -> ct.convert), specialized for a
token-classification head (output `logits [1, seq, num_labels]`) that the
Rust BIO decoder (P2') consumes.

# Ratified compute-unit policy (do NOT bake in ANE-only)

The per-token logits head does NOT ANE-compile on this stack (the §7.1
spike: ANECCompile fails in FP16 AND INT8, while the production pooled
ArcticEmbedS_INT8 compiles clean on the same Mac — so it's the per-token
head, not the environment). Ratification #4 was relaxed accordingly:
**GPU/CPU residency, footprint-gated in Phase 5.** So the default
`--compute-units cpu_and_gpu` avoids the ANE gamble; the runtime app sets
its own compute units at load anyway. Revisit ANE only if Phase-5
footprint fails.

# Both precisions

Emits FP16 (default) and INT8 (linear-symmetric weight quant) so Phase-3
can bake off quality vs footprint. `--variants both` (default) writes both.

# Usage

    # default: dslim/distilbert-NER, FP16 + INT8, GPU/CPU, compile + verify
    .venv-ml/bin/python scripts/convert_ner.py --verify --compile

    # one precision / a different model / a flexible max len
    .venv-ml/bin/python scripts/convert_ner.py --variants int8 \
        --model dslim/bert-base-NER --max-len 256

    # probe the toolchain only
    .venv-ml/bin/python scripts/convert_ner.py --env-check
"""

from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
from pathlib import Path

DEFAULT_MODEL = "dslim/distilbert-NER"
DEFAULT_OUT_DIR = "models"
# DistilBERT/BERT support 512; 256 is plenty for an OCR/text-chunk event and
# keeps the model lighter. The seq dim is flexible (RangeDim) up to this.
DEFAULT_MAX_LEN = 256

# Convert-time compute-unit policy. The runtime app re-selects at load; this
# sets the conversion default. Per §7.1 the per-token head is not ANE-resident,
# so the default deliberately excludes ANE.
COMPUTE_UNITS = {
    "cpu_and_gpu": "CPU_AND_GPU",  # ratified default — GPU/CPU residency
    "all": "ALL",                  # let Core ML choose (ANE attempt -> GPU/CPU fallback)
    "cpu_only": "CPU_ONLY",
    "cpu_and_ne": "CPU_AND_NE",    # only for a future ANE-head spike
}

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("convert_ner")


def _env_check() -> int:
    log.info("Python %s", sys.version.split()[0])
    missing = []
    for name in ("torch", "coremltools", "transformers", "numpy"):
        try:
            m = __import__(name)
            log.info("  ok   %-12s %s", name, getattr(m, "__version__", "?"))
        except Exception as e:  # pragma: no cover
            missing.append(name)
            log.error("  MISS %-12s (%s)", name, e)
    if missing:
        log.error("Install: pip install -r scripts/requirements-ml.txt")
        return 1
    log.info("All conversion deps present.")
    return 0


def _patch_new_ones(torch) -> None:
    """coremltools has no `new_ones` converter; BERT attention-mask code
    uses it. Route through `torch.ones` (identical semantics, traceable).
    Same patch as convert_embedder.py / convert_brief_model.py."""

    def _patched(self, *size, **kwargs):
        if len(size) == 1 and isinstance(size[0], (tuple, list)):
            size = tuple(size[0])
        kwargs.setdefault("dtype", self.dtype)
        kwargs.setdefault("device", self.device)
        if len(size) == 0:
            return torch.ones(size=(), **kwargs)
        return torch.ones(*size, **kwargs)

    torch.Tensor.new_ones = _patched
    log.info("Patched torch.Tensor.new_ones for coremltools compatibility.")


def _compile_mlmodelc(mlpackage_path: Path) -> Path | None:
    """Compile a .mlpackage to a .mlmodelc via xcrun coremlcompiler (the
    runtime-loadable form the bundle consumes). Returns the .mlmodelc path."""
    out_dir = mlpackage_path.parent
    try:
        subprocess.run(
            ["xcrun", "coremlcompiler", "compile", str(mlpackage_path), str(out_dir)],
            check=True,
            capture_output=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        log.warning("coremlcompiler compile failed (%s). Compile manually: "
                    "xcrun coremlcompiler compile %s %s", e, mlpackage_path, out_dir)
        return None
    mlmodelc = out_dir / (mlpackage_path.stem + ".mlmodelc")
    if mlmodelc.exists():
        log.info("Compiled -> %s", mlmodelc)
        return mlmodelc
    log.warning("coremlcompiler ran but %s not found.", mlmodelc)
    return None


def convert(
    model_repo: str,
    out_dir: str,
    variants: list[str],
    compute_units: str,
    max_len: int,
    verify: bool,
    compile_mlmodelc: bool,
) -> None:
    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoModelForTokenClassification, AutoTokenizer
    except ImportError as e:
        print(f"ERROR: Missing dependency: {e}\n  pip install -r scripts/requirements-ml.txt",
              file=sys.stderr)
        sys.exit(1)

    _patch_new_ones(torch)

    log.info("Loading %s ...", model_repo)
    tokenizer = AutoTokenizer.from_pretrained(model_repo)
    model = AutoModelForTokenClassification.from_pretrained(model_repo, torch_dtype=torch.float32)
    model.eval()
    id2label = {int(k): v for k, v in model.config.id2label.items()}
    log.info("labels (%d): %s", len(id2label), list(id2label.values()))

    sample = "Alice Smith joined Anthropic in San Francisco."
    enc = tokenizer(sample, return_tensors="pt", padding="max_length",
                    truncation=True, max_length=max_len)
    ids, mask = enc["input_ids"], enc["attention_mask"]

    class NerWrapper(torch.nn.Module):
        """Return raw per-token logits [1, seq, num_labels]; the Rust side
        argmaxes + BIO-merges (keeps confidence for the decoder)."""

        def __init__(self, base):
            super().__init__()
            self.model = base

        def forward(self, input_ids, attention_mask):
            return self.model(input_ids=input_ids, attention_mask=attention_mask).logits

    wrapper = NerWrapper(model).eval()
    traced = torch.jit.trace(wrapper, (ids, mask), strict=False)
    log.info("Trace OK. Converting to Core ML (compute_units=%s, target=macOS15)...",
             compute_units)

    cu = getattr(ct.ComputeUnit, COMPUTE_UNITS[compute_units])
    base = ct.convert(
        traced,
        source="pytorch",
        inputs=[
            ct.TensorType(name="input_ids",
                          shape=(1, ct.RangeDim(1, max_len)), dtype=np.int32),
            ct.TensorType(name="attention_mask",
                          shape=(1, ct.RangeDim(1, max_len)), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float16)],
        compute_units=cu,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    log.info("ct.convert OK.")

    out_root = Path(out_dir)
    out_root.mkdir(parents=True, exist_ok=True)
    base_name = model_repo.split("/")[-1].replace("-", "_")

    # Reference logits (FP32) for the fidelity check.
    with torch.no_grad():
        ref = wrapper(ids, mask).numpy()
    ref_arg = ref.reshape(ref.shape[1], -1).argmax(-1)
    real = int(mask.sum())

    produced = []
    for variant in variants:
        if variant == "int8":
            cfg = ct.optimize.coreml.OptimizationConfig(
                global_config=ct.optimize.coreml.OpLinearQuantizerConfig(
                    mode="linear_symmetric", dtype="int8"))
            ml = ct.optimize.coreml.linear_quantize_weights(base, config=cfg)
        else:
            ml = base
        out_path = out_root / f"{base_name}_{variant.upper()}.mlpackage"
        ml.save(str(out_path))
        size_mb = sum(f.stat().st_size for f in out_path.rglob("*") if f.is_file()) / 1e6
        log.info("Saved %s (%.1f MB)", out_path, size_mb)
        produced.append(out_path)

        if verify:
            loaded = ct.models.MLModel(str(out_path), compute_units=cu)
            pred = loaded.predict({"input_ids": ids.numpy().astype(np.int32),
                                   "attention_mask": mask.numpy().astype(np.int32)})
            cml = np.asarray(list(pred.values())[0]).reshape(max_len, -1)
            agree = float((cml[:real].argmax(-1) == ref_arg[:real]).mean())
            log.info("  [%s] argmax agreement vs torch-FP32: %.1f%% over %d real tokens",
                     variant, agree * 100, real)
            tags = [(tokenizer.convert_ids_to_tokens([int(t)])[0], id2label[int(l)])
                    for t, l in zip(ids[0][:real], cml[:real].argmax(-1)) if id2label[int(l)] != "O"]
            log.info("  [%s] sample tags: %s", variant, tags[:8])

        if compile_mlmodelc:
            _compile_mlmodelc(out_path)

    # Sidecars the Rust shim (P2') needs: the label set + the tokenizer.
    labels_path = out_root / f"{base_name}_labels.json"
    labels_path.write_text(json.dumps({"id2label": id2label,
                                        "scheme": "BIO",
                                        "model_repo": model_repo}, indent=2))
    log.info("Wrote label map -> %s", labels_path)
    tokenizer.save_pretrained(str(out_root / f"{base_name}_tokenizer"))
    log.info("Wrote tokenizer -> %s/", out_root / f"{base_name}_tokenizer")

    log.info("")
    log.info("Next steps (P2'-P6):")
    log.info("  - P2': Rust WordPiece tokenizer (tokenizers crate) + BIO span-merge decoder")
    log.info("         over the %d-label set; argmax over logits[1, seq, %d].",
             len(id2label), len(id2label))
    log.info("  - Bundle (P6): upload the chosen .mlmodelc to HF + add a models.json entry")
    log.info("         (same flow as ADR-0028 Qwen / ArcticEmbedS); models/* is gitignored.")
    log.info("  - Footprint gate (P5): the real ANE-vs-GPU/CPU decision on the running model.")
    log.info("Done. Produced: %s", ", ".join(p.name for p in produced))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=DEFAULT_MODEL,
                    help=f"HF token-classification model (default {DEFAULT_MODEL})")
    ap.add_argument("--output-dir", default=DEFAULT_OUT_DIR,
                    help="dir for the .mlpackage/.mlmodelc + sidecars (default models/)")
    ap.add_argument("--variants", choices=["both", "fp16", "int8"], default="both",
                    help="which precision(s) to emit (default both)")
    ap.add_argument("--compute-units", choices=list(COMPUTE_UNITS), default="cpu_and_gpu",
                    help="convert-time compute units; default cpu_and_gpu (NOT ANE — §7.1)")
    ap.add_argument("--max-len", type=int, default=DEFAULT_MAX_LEN)
    ap.add_argument("--verify", action="store_true",
                    help="load each model + assert argmax fidelity vs torch-FP32")
    ap.add_argument("--compile", action="store_true",
                    help="also compile each .mlpackage to .mlmodelc (xcrun coremlcompiler)")
    ap.add_argument("--env-check", action="store_true", help="probe deps and exit")
    args = ap.parse_args()

    if args.env_check:
        return _env_check()

    variants = ["fp16", "int8"] if args.variants == "both" else [args.variants]
    convert(args.model, args.output_dir, variants, args.compute_units,
            args.max_len, args.verify, args.compile)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
