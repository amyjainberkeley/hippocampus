#!/usr/bin/env python3
import importlib.util
import json
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
CONVERTER_PATH = REPO_ROOT / "scripts" / "convert_embedder.py"

spec = importlib.util.spec_from_file_location("convert_embedder", CONVERTER_PATH)
assert spec is not None and spec.loader is not None
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)

assert hasattr(converter, "write_model_contract"), (
    "converter must write signed model compatibility metadata"
)

with tempfile.TemporaryDirectory(prefix="hippocampus-model-contract.") as temp:
    compiled_path = Path(temp) / "ArcticEmbedS_FP16.mlmodelc"
    compiled_path.mkdir()
    converter.write_model_contract(
        compiled_path,
        precision="float16",
        minimum_system_version="14.0",
        specification_version=8,
    )

    contract = json.loads(
        (compiled_path / "hippocampus-model.json").read_text(encoding="utf-8")
    )
    assert contract == {
        "attentionImplementation": "eager",
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

print("PASS: converter writes the canonical Core ML compatibility contract")
