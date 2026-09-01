#!/usr/bin/env python3
"""Fail-closed identity gate for Hippocampus release artifacts."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import os
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET


FEED_URL = "https://amyjainberkeley.github.io/hippocampus/appcast.xml"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_RE = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


class ReleaseIdentityError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseIdentityError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_changelog(path: Path, version: str) -> None:
    require(path.is_file(), f"CHANGELOG.md is missing: {path}")
    header = re.compile(r"^## \[([^]]+)\]")
    in_release = False
    found_release = False
    in_section = False
    has_item = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        match = header.match(line)
        if match:
            if in_release:
                break
            in_release = match.group(1) == version
            found_release = found_release or in_release
            in_section = False
            continue
        if not in_release:
            continue
        if line.startswith("### "):
            in_section = True
        elif in_section and line.startswith(("- ", "* ")) and line[2:].strip():
            has_item = True
    require(found_release and has_item, f"CHANGELOG.md has no nonempty [{version}] release")


def validate_prebuild(root: Path, tag: str) -> dict[str, str]:
    match = VERSION_RE.fullmatch(tag)
    require(match is not None, f"release tag must be strict vMAJOR.MINOR.PATCH, got {tag!r}")
    version = tag[1:]
    plist_path = root / "apps/hippocampus/Resources/Info.plist"
    require(plist_path.is_file(), f"Info.plist is missing: {plist_path}")
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)

    bundle_version = str(plist.get("CFBundleShortVersionString", ""))
    build_number = str(plist.get("CFBundleVersion", ""))
    minimum_system = str(plist.get("LSMinimumSystemVersion", ""))
    feed_url = str(plist.get("SUFeedURL", ""))
    public_key = str(plist.get("SUPublicEDKey", ""))

    require(bundle_version == version, f"tag {tag} does not match bundle version {bundle_version!r}")
    require(build_number.isdigit() and int(build_number) > 0, "CFBundleVersion must be a positive integer")
    require(bool(minimum_system), "LSMinimumSystemVersion is missing")
    require(feed_url == FEED_URL, f"SUFeedURL must match publication target {FEED_URL}")
    try:
        decoded_public_key = base64.b64decode(public_key, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ReleaseIdentityError("SUPublicEDKey is not valid base64") from error
    require(len(decoded_public_key) == 32, "SUPublicEDKey must decode to 32 bytes")
    validate_changelog(root / "CHANGELOG.md", version)

    return {
        "version": version,
        "build": build_number,
        "minimum_system": minimum_system,
    }


def validate_staged(
    root: Path,
    tag: str,
    identity: dict[str, str],
    dmg: Path,
    appcast: Path,
    repository: str,
) -> None:
    version = identity["version"]
    expected_name = f"Hippocampus-{version}.dmg"
    require(dmg.is_file(), f"DMG is missing: {dmg}")
    require(dmg.name == expected_name, f"DMG must be named {expected_name}, got {dmg.name}")

    sidecar = Path(f"{dmg}.sha256")
    require(sidecar.is_file(), f"DMG checksum is missing: {sidecar}")
    checksum_fields = sidecar.read_text(encoding="utf-8").strip().split()
    require(len(checksum_fields) == 2, "DMG checksum sidecar must contain hash and filename")
    require(checksum_fields[1].lstrip("*") == expected_name, "DMG checksum filename does not match")
    require(checksum_fields[0].lower() == sha256(dmg), "DMG checksum does not match artifact bytes")

    require(appcast.is_file(), f"appcast is missing: {appcast}")
    try:
        document = ET.parse(appcast)
    except ET.ParseError as error:
        raise ReleaseIdentityError(f"appcast is not well-formed XML: {error}") from error

    version_tag = f"{{{SPARKLE_NS}}}shortVersionString"
    build_tag = f"{{{SPARKLE_NS}}}version"
    minimum_tag = f"{{{SPARKLE_NS}}}minimumSystemVersion"
    candidates = [
        item
        for item in document.findall("./channel/item")
        if item.findtext(version_tag) == version
    ]
    require(len(candidates) == 1, f"appcast must contain exactly one item for version {version}")
    item = candidates[0]
    require(item.findtext(build_tag) == identity["build"], "appcast build number does not match Info.plist")
    require(
        item.findtext(minimum_tag) == identity["minimum_system"],
        "appcast minimum system version does not match Info.plist",
    )

    enclosure = item.find("enclosure")
    require(enclosure is not None, "appcast release item has no enclosure")
    expected_url = f"https://github.com/{repository}/releases/download/{tag}/{expected_name}"
    require(enclosure.get("url") == expected_url, f"appcast enclosure URL must be {expected_url}")
    require(enclosure.get("length") == str(dmg.stat().st_size), "appcast enclosure length does not match DMG")
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature", "")
    try:
        decoded_signature = base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ReleaseIdentityError("appcast EdDSA signature is not valid base64") from error
    require(len(decoded_signature) == 64, "appcast EdDSA signature must decode to 64 bytes")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--phase", choices=("prebuild", "staged"), required=True)
    parser.add_argument("--tag", default=os.environ.get("GITHUB_REF_NAME", ""))
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--appcast", type=Path)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "amyjainberkeley/hippocampus"))
    args = parser.parse_args()

    root = args.repo_root.resolve()
    require(bool(args.tag), "--tag or GITHUB_REF_NAME is required")
    identity = validate_prebuild(root, args.tag)
    if args.phase == "staged":
        require(args.dmg is not None, "--dmg is required for staged verification")
        require(args.appcast is not None, "--appcast is required for staged verification")
        validate_staged(root, args.tag, identity, args.dmg.resolve(), args.appcast.resolve(), args.repository)
    print(f"Release identity verified: {args.tag} (build {identity['build']}, phase {args.phase})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReleaseIdentityError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
