#!/usr/bin/env python3
import json
import tempfile
from pathlib import Path

from coreml_model_contract import ContractError, validate_arctic_model


CONTRACT = {
    "attentionImplementation": "eager",
    "attentionMaskFloor": -10000.0,
    "embeddingDimension": 384,
    "maxSequenceLength": 128,
    "minimumSystemVersion": "14.0",
    "modelID": "arctic-embed-s-fp16",
    "precision": "float16",
    "schemaVersion": 1,
    "sourceRepo": "Snowflake/snowflake-arctic-embed-s",
    "sourceRevision": "e596f507467533e48a2e17c007f0e1dacc837b33",
    "specificationVersion": 8,
}

SAFE_MIL = """program(1.0)
{
    func main<ios17>(tensor<int32, [1, 128]> attention_mask, tensor<int32, [1, 128]> input_ids) {
        tensor<fp16, [384, 384]> encoder_weight_to_fp16 = const();
        tensor<fp16, [1, 1, 1, 128]> mask_cast_fp16 = cast(x = attention_mask);
        tensor<fp16, [1, 1, 1, 128]> inverted_mask = sub(x = one, y = mask_cast_fp16);
        tensor<fp16, []> finite_attention_floor = const()[val = tensor<fp16, []>(-0x1.388p+13)];
        tensor<fp16, [1, 1, 1, 128]> attention_mask_cast_fp16 = mul(x = inverted_mask, y = finite_attention_floor);
        tensor<fp16, [1, 12, 128, 128]> masked_scores = add(x = attention_scores, y = attention_mask_cast_fp16);
        tensor<fp16, [1, 12, 128, 128]> probabilities = softmax(x = masked_scores);
        tensor<fp32, [1, 384]> embedding = cast();
    } -> (embedding);
}
"""


def write_fixture(root: Path, *, mil: str = SAFE_MIL, contract: dict = CONTRACT) -> Path:
    model = root / "ArcticEmbedS_FP16.mlmodelc"
    (model / "weights").mkdir(parents=True)
    (model / "weights" / "weight.bin").write_bytes(b"weights")
    (model / "coremldata.bin").write_bytes(b"metadata")
    (model / "model.mil").write_text(mil, encoding="utf-8")
    (model / "hippocampus-model.json").write_text(
        json.dumps(contract), encoding="utf-8"
    )
    return model


def expect_error(model: Path, phrase: str) -> None:
    try:
        validate_arctic_model(model, app_minimum_system_version="14.0")
    except ContractError as error:
        assert phrase in str(error), str(error)
    else:
        raise AssertionError(f"expected validation error containing {phrase!r}")


with tempfile.TemporaryDirectory(prefix="hippocampus-coreml-contract.") as temp:
    root = Path(temp)
    safe = write_fixture(root / "safe")
    validate_arctic_model(safe, app_minimum_system_version="14.0")

    for label, value in (
        ("negative-infinity", "-inf"),
        ("positive-infinity", "+INF"),
        ("nan", "NaN"),
    ):
        unsafe = write_fixture(
            root / label, mil=SAFE_MIL.replace("-0x1.388p+13", value)
        )
        expect_error(unsafe, "non-finite")

    zero_floor = write_fixture(
        root / "zero-floor", mil=SAFE_MIL.replace("-0x1.388p+13", "0.0")
    )
    expect_error(zero_floor, "finite -10000 attention mask")

    disconnected_mask = write_fixture(
        root / "disconnected-mask",
        mil=SAFE_MIL.replace(
            "attention_mask_cast_fp16);", "unrelated_mask);"
        ),
    )
    expect_error(disconnected_mask, "not applied before every softmax")

    wrong_shape = write_fixture(
        root / "wrong-shape",
        mil=SAFE_MIL.replace("[1, 384]> embedding", "[1, 768]> embedding"),
    )
    expect_error(wrong_shape, "static [1, 384] embedding output")

    false_contract = dict(CONTRACT)
    false_contract["minimumSystemVersion"] = "13.0"
    mislabeled = write_fixture(root / "mislabeled", contract=false_contract)
    expect_error(mislabeled, "shipping contract")

print("PASS: compiled Core ML graph and app-owned contract are independently validated")
