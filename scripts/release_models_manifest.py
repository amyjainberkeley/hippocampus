#!/usr/bin/env python3
"""Validate the tag-owned immutable release-model manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse


EXPECTED_MODELS = {
    "arctic-embed-s-fp16": "ArcticEmbedS_FP16.mlmodelc",
}
VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


class ModelManifestError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ModelManifestError(message)


def load_and_validate(path: Path, release_version: str) -> dict[str, object]:
    require(VERSION_RE.fullmatch(release_version) is not None, "release version must be MAJOR.MINOR.PATCH")
    require(path.is_file(), f"release model manifest is missing: {path}")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as error:
        raise ModelManifestError(f"release model manifest is invalid JSON: {error}") from error

    require(isinstance(manifest, dict), "release model manifest must be an object")
    require(manifest.get("schemaVersion") == 1, "release model manifest schemaVersion must be 1")
    require(
        manifest.get("releaseVersion") == release_version,
        "release model manifest version does not match the release",
    )

    archive_url = manifest.get("archiveURL")
    require(isinstance(archive_url, str), "release model archiveURL must be a string")
    parsed = urlparse(archive_url)
    expected_suffix = f"/releases/download/v{release_version}/release-models-{release_version}.tar.gz"
    require(
        parsed.scheme == "https"
        and parsed.netloc == "github.com"
        and parsed.path.endswith(expected_suffix)
        and not parsed.query
        and not parsed.fragment,
        "release model archiveURL must be an immutable GitHub release asset for this version",
    )

    archive_sha = manifest.get("archiveSHA256")
    require(
        isinstance(archive_sha, str)
        and len(archive_sha) == 64
        and all(character in "0123456789abcdef" for character in archive_sha),
        "release model archiveSHA256 must be 64 lowercase hexadecimal characters",
    )

    models = manifest.get("models")
    require(isinstance(models, list), "release model models must be an array")
    observed: dict[str, str] = {}
    for model in models:
        require(isinstance(model, dict), "each release model entry must be an object")
        model_id = model.get("id")
        bundle = model.get("bundle")
        require(isinstance(model_id, str) and isinstance(bundle, str), "model id and bundle must be strings")
        require(model_id not in observed, f"duplicate release model id: {model_id}")
        observed[model_id] = bundle
    require(observed == EXPECTED_MODELS, "release model manifest must name exactly the required retrieval bundle")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--release-version", required=True)
    parser.add_argument("--field", choices=("archive-url", "archive-sha256"))
    args = parser.parse_args()
    manifest = load_and_validate(args.manifest.resolve(), args.release_version)
    if args.field == "archive-url":
        print(manifest["archiveURL"])
    elif args.field == "archive-sha256":
        print(manifest["archiveSHA256"])
    else:
        print(f"Release model manifest verified for {args.release_version}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ModelManifestError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
