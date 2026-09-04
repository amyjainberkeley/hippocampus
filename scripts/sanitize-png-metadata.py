#!/usr/bin/env python3
"""Atomically remove private text and EXIF chunks from PNG product captures."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import struct
import sys
import tempfile


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PRIVATE_CHUNKS = {b"eXIf", b"iTXt", b"tEXt", b"zTXt"}


def sanitized_bytes(path: Path) -> bytes:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG")

    output = bytearray(PNG_SIGNATURE)
    offset = len(PNG_SIGNATURE)
    saw_end = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("truncated PNG chunk header")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("truncated PNG chunk payload")
        chunk_type = data[offset + 4 : offset + 8]
        if chunk_type not in PRIVATE_CHUNKS:
            output.extend(data[offset:end])
        offset = end
        if chunk_type == b"IEND":
            saw_end = True
            break

    if not saw_end or offset != len(data):
        raise ValueError("invalid data after PNG end marker")
    return bytes(output)


def sanitize(path: Path) -> None:
    output = sanitized_bytes(path)
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(output)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main(arguments: list[str]) -> int:
    if not arguments:
        print("usage: sanitize-png-metadata.py PNG [PNG ...]", file=sys.stderr)
        return 2
    try:
        for argument in arguments:
            sanitize(Path(argument))
    except (OSError, ValueError) as error:
        print(f"sanitize-png-metadata: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
