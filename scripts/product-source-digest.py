#!/usr/bin/env python3
"""Hash the complete tracked/untracked source surface used to build Hippocampus."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path

SOURCE_PATHS = (
    "Cargo.lock",
    "Cargo.toml",
    "CHANGELOG.md",
    "NOTICE",
    "rust-toolchain.toml",
    "adapters",
    "apps",
    "assets",
    "core",
    "extensions",
    "scripts",
    "server",
    "tools/capture-overlap-corpus",
)

GENERATED_DIRECTORY_NAMES = {
    ".build",
    ".git",
    ".swiftpm",
    ".venv-ml",
    "DerivedData",
    "__pycache__",
    "dist",
    "node_modules",
    "target",
}
GENERATED_FILE_SUFFIXES = {".log", ".profraw", ".pyc", ".pyo"}


class DigestError(ValueError):
    pass


def source_files(repo_root: Path) -> list[Path]:
    relative_paths: list[Path] = []
    for source_name in SOURCE_PATHS:
        source = repo_root / source_name
        if source.is_file() or source.is_symlink():
            relative_paths.append(Path(source_name))
            continue
        if not source.is_dir():
            continue
        for directory, directory_names, file_names in os.walk(source, followlinks=False):
            directory_path = Path(directory)
            retained_directories: list[str] = []
            for name in directory_names:
                candidate = directory_path / name
                relative = candidate.relative_to(repo_root)
                if name in GENERATED_DIRECTORY_NAMES:
                    continue
                if candidate.is_symlink():
                    relative_paths.append(relative)
                    continue
                retained_directories.append(name)
            directory_names[:] = retained_directories
            for name in file_names:
                candidate = directory_path / name
                relative = candidate.relative_to(repo_root)
                if name == ".DS_Store" or candidate.suffix in GENERATED_FILE_SUFFIXES:
                    continue
                relative_paths.append(relative)
    if not relative_paths:
        raise DigestError("product source set is empty")
    return sorted(relative_paths, key=lambda path: os.fsencode(path.as_posix()))


def digest(repo_root: Path) -> str:
    root = repo_root.resolve(strict=True)
    if not (root / ".git").exists() and not (
        subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--git-dir"],
            capture_output=True,
        ).returncode
        == 0
    ):
        raise DigestError(f"not a git checkout: {root}")

    hasher = hashlib.sha256(b"HIPPOCAMPUS-PRODUCT-SOURCE-V1\0")
    for relative_path in source_files(root):
        absolute_path = root / relative_path
        try:
            metadata = absolute_path.lstat()
        except OSError as error:
            raise DigestError(f"could not stat source file {relative_path}: {error}") from error

        path_bytes = os.fsencode(relative_path.as_posix())
        if stat.S_ISLNK(metadata.st_mode):
            kind = b"symlink"
            content = os.fsencode(os.readlink(absolute_path))
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"executable" if metadata.st_mode & stat.S_IXUSR else b"file"
            try:
                content = absolute_path.read_bytes()
            except OSError as error:
                raise DigestError(
                    f"could not read source file {relative_path}: {error}"
                ) from error
        else:
            raise DigestError(f"unsupported source file type: {relative_path}")

        hasher.update(path_bytes)
        hasher.update(b"\0")
        hasher.update(kind)
        hasher.update(b"\0")
        hasher.update(str(len(content)).encode("ascii"))
        hasher.update(b"\0")
        hasher.update(content)
        hasher.update(b"\0")
    return hasher.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        print(digest(args.repo_root))
    except (DigestError, OSError) as error:
        print(f"product source digest failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
