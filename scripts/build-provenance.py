#!/usr/bin/env python3
"""Create and verify signed Hippocampus build provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MANIFEST_NAME = "build-provenance.json"
STAPLED_TICKET_PATH = "CodeResources"
BINARY_NAMES = (
    "Hippocampus",
    "MCICaptureHelper",
    "mci-agent",
    "recall-ui",
    "onboarding",
    "hippocampus-native-host",
)
MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
}
BINARY_DIGEST_KIND = "codesign-stripped-sha256-v1"


class ProvenanceError(ValueError):
    pass


def hash_file(path: Path) -> str:
    hasher = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(chunk)
    except OSError as error:
        raise ProvenanceError(f"could not hash {path}: {error}") from error
    return hasher.hexdigest()


def signature_independent_binary_hash(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            magic = handle.read(4)
    except OSError as error:
        raise ProvenanceError(f"could not inspect {path}: {error}") from error
    if magic not in MACHO_MAGICS:
        return hash_file(path)

    try:
        with tempfile.TemporaryDirectory(prefix="hippocampus-provenance-") as raw_temp:
            normalized = Path(raw_temp) / path.name
            shutil.copy2(path, normalized)
            result = subprocess.run(
                ["/usr/bin/codesign", "--remove-signature", str(normalized)],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                detail = result.stderr.strip() or "codesign returned nonzero"
                raise ProvenanceError(
                    f"could not normalize signed Mach-O {path.name}: {detail}"
                )
            return hash_file(normalized)
    except OSError as error:
        raise ProvenanceError(f"could not normalize signed Mach-O {path}: {error}") from error


def binary_hashes(app: Path) -> dict[str, str]:
    binary_root = app / "Contents" / "MacOS"
    if not binary_root.is_dir():
        raise ProvenanceError(f"assembled app has no MacOS directory: {binary_root}")
    actual_names = {path.name for path in binary_root.iterdir()}
    expected_names = set(BINARY_NAMES)
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        unexpected = sorted(actual_names - expected_names)
        raise ProvenanceError(
            f"assembled MacOS inventory mismatch; missing={missing}, unexpected={unexpected}"
        )
    hashes: dict[str, str] = {}
    for name in BINARY_NAMES:
        path = binary_root / name
        if not path.is_file() or path.is_symlink():
            raise ProvenanceError(f"required assembled binary is missing: {path}")
        hashes[name] = signature_independent_binary_hash(path)
    return hashes


def payload_paths(app: Path) -> list[Path]:
    contents = app / "Contents"
    if not contents.is_dir():
        raise ProvenanceError(f"assembled app has no Contents directory: {app}")
    paths: list[Path] = []
    for path in contents.rglob("*"):
        relative = path.relative_to(contents)
        if relative.parts[0] == "MacOS":
            continue
        if relative.as_posix() == STAPLED_TICKET_PATH:
            if path.is_symlink() or not path.is_file():
                raise ProvenanceError(
                    f"invalid top-level notarization ticket: {relative}"
                )
            continue
        if "_CodeSignature" in relative.parts:
            continue
        if relative.as_posix() == f"Resources/{MANIFEST_NAME}":
            continue
        if path.is_dir() and not path.is_symlink():
            continue
        paths.append(path)
    return sorted(paths, key=lambda path: os.fsencode(path.relative_to(contents).as_posix()))


def payload_digest(app: Path) -> str:
    contents = app / "Contents"
    hasher = hashlib.sha256(b"HIPPOCAMPUS-ASSEMBLED-PAYLOAD-V1\0")
    for path in payload_paths(app):
        relative = path.relative_to(contents)
        try:
            metadata = path.lstat()
        except OSError as error:
            raise ProvenanceError(f"could not stat payload file {relative}: {error}") from error
        if stat.S_ISLNK(metadata.st_mode):
            kind = b"symlink"
            content_digest = hashlib.sha256(os.fsencode(os.readlink(path))).digest()
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"executable" if metadata.st_mode & stat.S_IXUSR else b"file"
            content_digest = bytes.fromhex(signature_independent_binary_hash(path))
        else:
            raise ProvenanceError(f"unsupported payload file type: {relative}")
        hasher.update(os.fsencode(relative.as_posix()))
        hasher.update(b"\0")
        hasher.update(kind)
        hasher.update(b"\0")
        hasher.update(content_digest)
        hasher.update(b"\0")
    return hasher.hexdigest()


def manifest_path(app: Path) -> Path:
    return app / "Contents" / "Resources" / MANIFEST_NAME


def load_manifest(app: Path) -> dict[str, Any]:
    path = manifest_path(app)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"invalid build provenance at {path}: {error}") from error
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise ProvenanceError("build provenance has an unsupported schema")
    if not isinstance(payload.get("source_head"), str) or not payload["source_head"]:
        raise ProvenanceError("build provenance has no source_head")
    source_digest = payload.get("source_digest")
    if not isinstance(source_digest, str) or len(source_digest) != 64:
        raise ProvenanceError("build provenance has no valid source_digest")
    if not isinstance(payload.get("current_source_qualification"), bool):
        raise ProvenanceError("build provenance has no qualification mode")
    if payload.get("binary_digest_kind") != BINARY_DIGEST_KIND:
        raise ProvenanceError("build provenance has an unsupported binary digest kind")
    return payload


def write_manifest(app: Path, payload: dict[str, Any]) -> None:
    path = manifest_path(app)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        temporary.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except OSError as error:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise ProvenanceError(f"could not write build provenance: {error}") from error


def create(args: argparse.Namespace) -> None:
    payload = {
        "schema_version": SCHEMA_VERSION,
        "source_head": args.source_head,
        "source_digest": args.source_digest,
        "current_source_qualification": args.current_source_qualification,
        "binary_digest_kind": BINARY_DIGEST_KIND,
        "binaries": binary_hashes(args.app),
        "payload_digest": payload_digest(args.app),
    }
    write_manifest(args.app, payload)


def verify(args: argparse.Namespace) -> None:
    payload = load_manifest(args.app)
    if payload["source_head"] != args.expected_source_head:
        raise ProvenanceError("assembled app source HEAD does not match this checkout")
    if payload["source_digest"] != args.expected_source_digest:
        raise ProvenanceError("assembled app source digest does not match this checkout")
    if args.require_current_source and payload["current_source_qualification"] is not True:
        raise ProvenanceError("signed qualification app was not built in current-source mode")
    if args.forbid_current_source and payload["current_source_qualification"] is not False:
        raise ProvenanceError("release packaging refuses a current-source qualification app")
    if payload.get("binaries") != binary_hashes(args.app):
        raise ProvenanceError("assembled binary hashes do not match build provenance")
    if payload.get("payload_digest") != payload_digest(args.app):
        raise ProvenanceError("assembled payload does not match build provenance")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--app", type=Path, required=True)
    create_parser.add_argument("--source-head", required=True)
    create_parser.add_argument("--source-digest", required=True)
    create_parser.add_argument("--current-source-qualification", action="store_true")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--app", type=Path, required=True)
    verify_parser.add_argument("--expected-source-head", required=True)
    verify_parser.add_argument("--expected-source-digest", required=True)
    qualification_mode = verify_parser.add_mutually_exclusive_group()
    qualification_mode.add_argument("--require-current-source", action="store_true")
    qualification_mode.add_argument("--forbid-current-source", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        {"create": create, "verify": verify}[args.command](args)
    except ProvenanceError as error:
        print(f"build provenance failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
