#!/usr/bin/env python3
"""Validate the shipping Arctic Core ML bundle without executing it."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


EXPECTED_ARCTIC_CONTRACT = {
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


class ContractError(RuntimeError):
    """The compiled model and its declared release contract disagree."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def _version(value: str) -> tuple[int, ...]:
    try:
        return tuple(int(part) for part in value.split("."))
    except ValueError as error:
        raise ContractError(f"invalid system version {value!r}") from error


def _mil_operations(mil: str) -> dict[str, tuple[str, dict[str, str]]]:
    operations: dict[str, tuple[str, dict[str, str]]] = {}
    assignment = re.compile(
        r"^\s*tensor<[^>]+>\s+([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\((.*)\).*;\s*$",
        re.MULTILINE,
    )
    argument = re.compile(r"\b([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)")
    for output, operation, arguments in assignment.findall(mil):
        operations[output] = (operation, dict(argument.findall(arguments)))
    return operations


def _depends_on(
    variable: str,
    ancestor: str,
    operations: dict[str, tuple[str, dict[str, str]]],
    seen: set[str] | None = None,
) -> bool:
    if variable == ancestor:
        return True
    visited = set() if seen is None else seen
    if variable in visited:
        return False
    visited.add(variable)
    operation = operations.get(variable)
    if operation is None:
        return False
    return any(
        _depends_on(dependency, ancestor, operations, visited)
        for dependency in operation[1].values()
    )


def _scalar_fp16_constant(mil: str, variable: str) -> float | None:
    pattern = re.compile(
        rf"^\s*tensor<fp16,\s*\[\]>\s+{re.escape(variable)}\s*=\s*const\(\).*"
        r"val\s*=\s*tensor<fp16,\s*\[\]>\(([^)]+)\).*;\s*$",
        re.MULTILINE,
    )
    match = pattern.search(mil)
    if match is None:
        return None
    literal = match.group(1).strip()
    try:
        return float.fromhex(literal) if "0x" in literal.lower() else float(literal)
    except ValueError:
        return None


def _validate_attention_mask_dataflow(mil: str) -> None:
    operations = _mil_operations(mil)
    mask_operation = operations.get("attention_mask_cast_fp16")
    _require(
        mask_operation is not None and mask_operation[0] == "mul",
        "compiled graph does not construct the finite -10000 attention mask",
    )

    mask_factors = [
        mask_operation[1].get("x", ""),
        mask_operation[1].get("y", ""),
    ]
    floor_variables = [
        variable
        for variable in mask_factors
        if _scalar_fp16_constant(mil, variable) == -10000.0
    ]
    _require(
        len(floor_variables) == 1,
        "compiled graph does not construct the finite -10000 attention mask",
    )
    inverted_mask = next(
        variable for variable in mask_factors if variable != floor_variables[0]
    )
    inverted_operation = operations.get(inverted_mask)
    _require(
        inverted_operation is not None
        and inverted_operation[0] == "sub"
        and _depends_on(inverted_mask, "attention_mask", operations),
        "compiled graph's finite attention mask is disconnected from attention_mask",
    )

    softmaxes = [details for details in operations.values() if details[0] == "softmax"]
    _require(softmaxes, "compiled graph contains no attention softmax operations")
    for _, arguments in softmaxes:
        softmax_input = arguments.get("x", "")
        add_operation = operations.get(softmax_input)
        _require(
            add_operation is not None
            and add_operation[0] == "add"
            and "attention_mask_cast_fp16" in {
                add_operation[1].get("x", ""),
                add_operation[1].get("y", ""),
            },
            "compiled graph's finite attention mask is not applied before every softmax",
        )


def validate_arctic_model(
    model_path: Path, *, app_minimum_system_version: str | None = None
) -> None:
    """Validate the exact contract, compiled graph shape, opset, and precision."""
    _require(model_path.name == "ArcticEmbedS_FP16.mlmodelc", "unexpected model bundle name")
    _require(model_path.is_dir(), f"model bundle is missing: {model_path}")

    contract_path = model_path / "hippocampus-model.json"
    if not contract_path.is_file():
        raise ContractError(
            "shipping FP16 model requires app-owned compatibility metadata "
            f"at {contract_path}"
        )
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as error:
        raise ContractError(f"model compatibility metadata is unreadable: {error}") from error

    contract_model_id = contract.get("modelID", "")
    _require(
        contract_model_id == EXPECTED_ARCTIC_CONTRACT["modelID"],
        f"compatibility metadata identifies {contract_model_id!r}, expected 'arctic-embed-s-fp16'",
    )
    precision = contract.get("precision", "")
    _require(
        precision == "float16",
        f"model claims FP16 but compatibility metadata says {precision}",
    )

    if app_minimum_system_version:
        app_version = _version(app_minimum_system_version)
        model_version = _version(contract["minimumSystemVersion"])
        width = max(len(app_version), len(model_version))
        _require(
            app_version + (0,) * (width - len(app_version))
            >= model_version + (0,) * (width - len(model_version)),
            f"model requires macOS {contract['minimumSystemVersion']} but the app supports macOS {app_minimum_system_version}",
        )

    _require(contract == EXPECTED_ARCTIC_CONTRACT, "metadata does not match the shipping contract")

    mil_path = model_path / "model.mil"
    try:
        mil = mil_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ContractError(f"compiled MIL program is unreadable: {error}") from error

    _require("func main<ios17>" in mil, "compiled graph is not the macOS 14 / iOS 17 opset")
    _require(
        "tensor<int32, [1, 128]> attention_mask" in mil
        and "tensor<int32, [1, 128]> input_ids" in mil,
        "compiled graph does not expose static [1, 128] integer inputs",
    )
    _require(
        "tensor<fp32, [1, 384]> embedding" in mil,
        "compiled graph does not expose a static [1, 384] embedding output",
    )
    _require(
        re.search(r"_weight_to_fp16\s*=\s*const", mil) is not None,
        "compiled graph does not contain FP16 model weights",
    )
    _require("tensor<int8" not in mil, "compiled graph contains INT8 tensors")
    _require(
        re.search(
            r"(?<![A-Za-z0-9_])[+-]?(?:inf(?:inity)?|nan)(?![A-Za-z0-9_])",
            mil,
            re.IGNORECASE,
        )
        is None,
        "compiled graph contains a non-finite constant",
    )
    _validate_attention_mask_dataflow(mil)

    core_data = model_path / "coremldata.bin"
    weights = model_path / "weights"
    _require(core_data.is_file() and core_data.stat().st_size > 0, "compiled metadata is missing")
    _require(
        weights.is_dir()
        and any(path.is_file() and path.stat().st_size > 0 for path in weights.rglob("*")),
        "compiled weights are missing",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--app-minimum-system-version")
    args = parser.parse_args()
    try:
        validate_arctic_model(
            args.model,
            app_minimum_system_version=args.app_minimum_system_version,
        )
    except ContractError as error:
        print(f"ERROR: {error}")
        return 1
    print(f"OK: verified compiled Arctic model contract at {args.model}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
