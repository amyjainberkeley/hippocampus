#!/usr/bin/env python3
"""Verify and atomically unpack the immutable release-model archive."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile


MAX_UNPACKED_BYTES = 8 * 1024 * 1024 * 1024
MAX_MEMBERS = 100_000
REQUIRED_MODELS = (
    "ArcticEmbedS_INT8.mlmodelc",
)


class ModelArchiveError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ModelArchiveError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative_path(name: str) -> Path:
    archive_path = PurePosixPath(name)
    require(not archive_path.is_absolute(), f"archive member is absolute: {name}")
    require(".." not in archive_path.parts, f"archive member escapes output: {name}")
    require(len(archive_path.parts) >= 2 and archive_path.parts[0] == "models", f"unexpected archive member: {name}")
    return Path(*archive_path.parts[1:])


def is_macos_metadata(name: str) -> bool:
    parts = PurePosixPath(name).parts
    return bool(parts) and (parts[0] == "__MACOSX" or any(part.startswith("._") for part in parts))


def validate_model(root: Path, model: str) -> None:
    model_path = root / model
    require(model_path.is_dir(), f"required model is missing: {model}")
    require((model_path / "model.mil").is_file(), f"{model} has no model.mil")
    require((model_path / "coremldata.bin").is_file(), f"{model} has no coremldata.bin")
    weights = model_path / "weights"
    require(weights.is_dir(), f"{model} has no weights directory")
    require(any(path.is_file() for path in weights.rglob("*")), f"{model} has no weight files")


def install(archive: Path, expected_sha: str, output: Path) -> None:
    require(archive.is_file(), f"model archive is missing: {archive}")
    require(len(expected_sha) == 64 and all(character in "0123456789abcdefABCDEF" for character in expected_sha), "--sha256 must be 64 hexadecimal characters")
    actual_sha = sha256(archive)
    require(actual_sha == expected_sha.lower(), f"model archive SHA-256 mismatch: expected {expected_sha.lower()}, got {actual_sha}")
    require(not output.exists(), f"output already exists; refusing to overwrite: {output}")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp-", dir=output.parent))
    try:
        seen: set[Path] = set()
        total_size = 0
        with tarfile.open(archive, mode="r:*") as bundle:
            members = bundle.getmembers()
            require(len(members) <= MAX_MEMBERS, "model archive has too many members")
            for member in members:
                if is_macos_metadata(member.name):
                    continue
                if member.isdir() and member.name.rstrip("/") == "models":
                    continue
                relative = safe_relative_path(member.name)
                require(relative not in seen, f"duplicate archive member: {member.name}")
                seen.add(relative)
                require(not (member.issym() or member.islnk()), f"links are forbidden in model archive: {member.name}")
                require(member.isdir() or member.isfile(), f"unsupported archive member type: {member.name}")
                total_size += member.size
                require(total_size <= MAX_UNPACKED_BYTES, "model archive exceeds 8 GiB unpacked limit")
                destination = temporary / relative
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = bundle.extractfile(member)
                require(source is not None, f"could not read archive member: {member.name}")
                with source, destination.open("xb") as target:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
                destination.chmod(0o644)

        for model in REQUIRED_MODELS:
            validate_model(temporary, model)
        os.rename(temporary, output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output", type=Path, default=Path("models"))
    args = parser.parse_args()
    install(args.archive.resolve(), args.sha256, args.output.resolve())
    print(f"Release models installed and verified at {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ModelArchiveError, tarfile.TarError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
