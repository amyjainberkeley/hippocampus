#!/usr/bin/env python3
"""Convert the unqualified MobileBERT SQuAD2 evidence-verifier candidate.

This script proves artifact reproducibility and runtime parity only. It does
not change EVIDENCE_VERIFIER_QUALIFICATION and does not make the model a
release dependency. Qualification additionally requires the locked,
scenario-disjoint semantic corpus and false-positive confidence bound in
ADR-0038.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

MODEL_REPO = "csarron/mobilebert-uncased-squad-v2"
MODEL_REVISION = "6d49c30d06c6042041039f6fe076b011f0c2053c"
SEQUENCE_LENGTH = 384
PARITY_LIMIT = 0.001


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("models/MobileBertQASquad2_FP32.mlpackage"),
    )
    parser.add_argument(
        "--tokenizer-output",
        type=Path,
        default=Path("models/MobileBertQASquad2-tokenizer"),
    )
    parser.add_argument(
        "--compiled-output",
        type=Path,
        help="Optional persistent copy of Core ML's runtime-compiled model.",
    )
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--local-files-only", action="store_true")
    parser.add_argument("--skip-verify", action="store_true")
    return parser.parse_args()


def dependencies():
    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoModelForQuestionAnswering, AutoTokenizer
    except ImportError as error:
        raise SystemExit(
            f"missing conversion dependency: {error}\n"
            "Create an isolated Python 3.11 environment and run:\n"
            "  pip install -r scripts/requirements-evidence-verifier.txt"
        ) from error
    return ct, np, torch, AutoModelForQuestionAnswering, AutoTokenizer


def encoded_inputs(tokenizer, question: str, context: str, np):
    encoded = tokenizer(
        question,
        context,
        return_tensors="np",
        truncation="only_second",
        padding="max_length",
        max_length=SEQUENCE_LENGTH,
        return_offsets_mapping=True,
    )
    offsets = encoded.pop("offset_mapping")[0]
    inputs = {
        name: value.astype(np.int32)
        for name, value in encoded.items()
        if name in {"input_ids", "attention_mask", "token_type_ids"}
    }
    return inputs, offsets


def best_span(question, context, tokenizer, start_logits, end_logits, np):
    _, offsets = encoded_inputs(tokenizer, question, context, np)
    encoded = tokenizer(
        question,
        context,
        truncation="only_second",
        padding="max_length",
        max_length=SEQUENCE_LENGTH,
        return_offsets_mapping=True,
    )
    sequence_ids = encoded.sequence_ids(0)
    best = (-float("inf"), 0, 0)
    for start in range(SEQUENCE_LENGTH):
        if sequence_ids[start] != 1 or offsets[start][0] >= offsets[start][1]:
            continue
        for end in range(start, min(start + 24, SEQUENCE_LENGTH)):
            if sequence_ids[end] != 1 or offsets[end][0] >= offsets[end][1]:
                continue
            candidate = float(start_logits[start] + end_logits[end])
            if candidate > best[0]:
                best = (candidate, start, end)
    start_byte = int(offsets[best[1]][0])
    end_byte = int(offsets[best[2]][1])
    margin = best[0] - float(start_logits[0] + end_logits[0])
    return context[start_byte:end_byte], margin


def verify_parity(coreml_model, reference_model, tokenizer, torch, np) -> None:
    cases = [
        (
            "Which instrument did Nila practice before supper?",
            "Nila practiced the cello in the dining room before supper. "
            "The cello case was resting beside the dining-room chair. "
            "Supper was served after the music practice ended.",
            "cello",
        ),
        (
            "Which instrument did Nila practice before supper?",
            "Nila practiced music in the dining room before supper. "
            "A closed instrument case was beside the chair. "
            "Supper was served after practice ended.",
            "music",
        ),
    ]
    maximum_delta = 0.0
    for question, context, expected_span in cases:
        inputs, _ = encoded_inputs(tokenizer, question, context, np)
        torch_inputs = {name: torch.from_numpy(value) for name, value in inputs.items()}
        with torch.no_grad():
            reference = reference_model(**torch_inputs)
        predicted = coreml_model.predict(inputs)
        start_reference = reference.start_logits.detach().cpu().numpy()[0]
        end_reference = reference.end_logits.detach().cpu().numpy()[0]
        start_coreml = np.asarray(predicted["start_logits"])[0]
        end_coreml = np.asarray(predicted["end_logits"])[0]
        maximum_delta = max(
            maximum_delta,
            float(np.max(np.abs(start_reference - start_coreml))),
            float(np.max(np.abs(end_reference - end_coreml))),
        )
        answer, margin = best_span(
            question, context, tokenizer, start_coreml, end_coreml, np
        )
        if answer != expected_span:
            raise SystemExit(
                f"Core ML span mismatch: expected {expected_span!r}, got {answer!r}"
            )
        print(f"parity fixture: answer={answer!r} margin={margin:.6f}")
    if maximum_delta > PARITY_LIMIT:
        raise SystemExit(
            f"Core ML parity failed: max logit delta {maximum_delta:.8f} "
            f"> {PARITY_LIMIT}"
        )
    print(f"Core ML parity passed: max logit delta={maximum_delta:.8f}")


def main() -> int:
    args = parse_args()
    ct, np, torch, AutoModelForQuestionAnswering, AutoTokenizer = dependencies()
    common = {
        "revision": MODEL_REVISION,
        "cache_dir": str(args.cache_dir) if args.cache_dir else None,
        "local_files_only": args.local_files_only,
    }
    tokenizer = AutoTokenizer.from_pretrained(MODEL_REPO, **common)
    reference_model = AutoModelForQuestionAnswering.from_pretrained(
        MODEL_REPO, use_safetensors=True, **common
    ).eval()

    class QuestionAnsweringWrapper(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, input_ids, attention_mask, token_type_ids):
            output = self.model(
                input_ids=input_ids,
                attention_mask=attention_mask,
                token_type_ids=token_type_ids,
            )
            return output.start_logits, output.end_logits

    sample = tokenizer(
        "Which instrument did Nila practice before supper?",
        "Nila practiced the cello before supper.",
        return_tensors="pt",
        truncation="only_second",
        padding="max_length",
        max_length=SEQUENCE_LENGTH,
    )
    traced = torch.jit.trace(
        QuestionAnsweringWrapper(reference_model).eval(),
        (
            sample["input_ids"].to(torch.int32),
            sample["attention_mask"].to(torch.int32),
            sample["token_type_ids"].to(torch.int32),
        ),
        strict=True,
    )
    shape = (1, SEQUENCE_LENGTH)
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32),
            ct.TensorType(name="token_type_ids", shape=shape, dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="start_logits", dtype=np.float32),
            ct.TensorType(name="end_logits", dtype=np.float32),
        ],
    )
    converted.user_defined_metadata["hippocampus.model_repo"] = MODEL_REPO
    converted.user_defined_metadata["hippocampus.model_revision"] = MODEL_REVISION
    converted.user_defined_metadata["hippocampus.qualification"] = "candidate-only"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(str(args.output))
    args.tokenizer_output.mkdir(parents=True, exist_ok=True)
    tokenizer.save_pretrained(args.tokenizer_output)

    runtime_model = ct.models.MLModel(
        str(args.output), compute_units=ct.ComputeUnit.CPU_ONLY
    )
    if not args.skip_verify:
        verify_parity(runtime_model, reference_model, tokenizer, torch, np)
    if args.compiled_output:
        if args.compiled_output.exists():
            shutil.rmtree(args.compiled_output)
        shutil.copytree(runtime_model.get_compiled_model_path(), args.compiled_output)

    print(f"wrote candidate model: {args.output}")
    print(f"wrote tokenizer: {args.tokenizer_output}")
    print("UNQUALIFIED: artifact parity does not establish safe evidence abstention.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
