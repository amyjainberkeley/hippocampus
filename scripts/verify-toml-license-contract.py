#!/usr/bin/env python3
"""Verify pinned TOML parser licenses before app assembly."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


EXPECTED_MANIFEST: dict[str, Any] = {
    "schema_version": 1,
    "swift_package": {
        "identity": "tomlkit",
        "location": "https://github.com/LebJe/TOMLKit.git",
        "revision": "ec6198d37d495efc6acd4dffbd262cdca7ff9b3f",
        "version": "0.6.0",
    },
    "licenses": [
        {
            "component": "TOMLKit",
            "version": "0.6.0",
            "license_path": "third_party/licenses/TOMLKit-0.6.0-LICENSE.txt",
            "license_sha256": "bccd5fe8b98c6caede07def6c03f55877416ec40ea5fcd18e668b5c6fbb10abe",
            "reviewed_source_path": "LICENSE",
            "reviewed_source_sha256": "bccd5fe8b98c6caede07def6c03f55877416ec40ea5fcd18e668b5c6fbb10abe",
            "source_url": "https://github.com/LebJe/TOMLKit",
        },
        {
            "component": "toml++",
            "version": "3.4.0",
            "license_path": "third_party/licenses/tomlplusplus-3.4.0-LICENSE.txt",
            "license_sha256": "529bc3900a9571e49db285b0df432397e70b881cc3bf48de6667ae74ff4b06d8",
            "reviewed_source_path": "Sources/CTOML/Sources/toml.hpp",
            "reviewed_source_sha256": "6b5172ad4dd6519aec67b919181fa7a38a2234131e5b2afa232dfe444819783e",
            "source_url": "https://github.com/marzer/tomlplusplus",
        },
    ],
}

REQUIRED_MIT_CLAUSES = (
    "Permission is hereby granted, free of charge, to any person obtaining a copy",
    "The above copyright notice and this permission notice shall be included in all",
    'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND',
    "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER",
    "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE",
)


class ContractError(Exception):
    pass


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ContractError(f"cannot read {path}: {error}") from error


def read_json(path: Path) -> Any:
    try:
        return json.loads(read_text(path))
    except json.JSONDecodeError as error:
        raise ContractError(f"invalid JSON in {path}: {error}") from error


def sha256(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise ContractError(f"cannot read {path}: {error}") from error


def verify_manifest(root: Path) -> dict[str, Any]:
    path = root / "third_party/licenses/toml-license-manifest.json"
    manifest = read_json(path)
    if manifest != EXPECTED_MANIFEST:
        raise ContractError(
            "TOML license manifest drifted from the reviewed 0.6.0/3.4.0 sources"
        )
    return manifest


def verify_package_pin(root: Path, package: dict[str, str]) -> None:
    package_swift = read_text(root / "apps/hippocampus/Package.swift")
    declaration = (
        f'.package(url: "{package["location"]}", exact: "{package["version"]}")'
    )
    if package_swift.count(declaration) != 1:
        raise ContractError("Package.swift must exact-pin the reviewed TOMLKit package")

    resolved_path = root / "apps/hippocampus/Package.resolved"
    resolved = read_json(resolved_path)
    pins = resolved.get("pins") if isinstance(resolved, dict) else None
    if not isinstance(pins, list):
        raise ContractError("Package.resolved does not contain a pins array")
    matches = [
        pin
        for pin in pins
        if isinstance(pin, dict) and pin.get("identity") == package["identity"]
    ]
    if len(matches) != 1:
        raise ContractError("Package.resolved must contain exactly one TOMLKit pin")
    pin = matches[0]
    state = pin.get("state")
    if not isinstance(state, dict):
        raise ContractError("TOMLKit resolved pin has no state")
    actual = {
        "identity": pin.get("identity"),
        "location": pin.get("location"),
        "revision": state.get("revision"),
        "version": state.get("version"),
    }
    if actual != package:
        raise ContractError(
            "Package.resolved TOMLKit identity, URL, version, or revision drifted"
        )


def verify_license(root: Path, notice: str, license_entry: dict[str, str]) -> None:
    relative_path = Path(license_entry["license_path"])
    path = root / relative_path
    text = read_text(path)
    normalized_text = re.sub(r"\s+", " ", text)
    for clause in REQUIRED_MIT_CLAUSES:
        if clause not in normalized_text:
            raise ContractError(
                f"{license_entry['component']} license is missing required MIT text: {clause}"
            )
    actual_hash = sha256(path)
    if actual_hash != license_entry["license_sha256"]:
        raise ContractError(f"canonical license hash drifted: {relative_path}")
    if f"{license_entry['component']} {license_entry['version']}" not in notice:
        raise ContractError(
            f"NOTICE is missing {license_entry['component']} {license_entry['version']} attribution"
        )
    complete_text = text.rstrip("\n")
    if notice.count(complete_text) != 1:
        raise ContractError(
            f"NOTICE must contain exactly one complete canonical {license_entry['component']} license"
        )


def verify(root: Path) -> None:
    manifest = verify_manifest(root)
    verify_package_pin(root, manifest["swift_package"])
    notice = read_text(root / "NOTICE")
    for entry in manifest["licenses"]:
        verify_license(root, notice, entry)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root to verify",
    )
    args = parser.parse_args()
    try:
        verify(args.repo_root.resolve())
    except ContractError as error:
        print(f"TOML license contract failed: {error}", file=sys.stderr)
        return 1
    print("TOML license contract verified: TOMLKit 0.6.0 and toml++ 3.4.0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
