#!/usr/bin/env python3
"""Generate or verify EULA.rtf from the canonical license terms.

Single source of truth: the markdown file. This script produces:
  - EULA.rtf   — Rich Text for distribution / reference

Regenerate:
    python3 assets/installer/generate-eula.py

Verify without writing:
    python3 assets/installer/generate-eula.py --check

Requires: Python 3.8+ (stdlib only).
"""

import argparse
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
TOS_PATH = os.path.join(REPO_ROOT, "docs", "legal", "terms-of-service.md")
EULA_PATH = os.path.join(SCRIPT_DIR, "EULA.rtf")

PROHIBITED_GUARANTEES = (
    (r"crypto[\s-]*shred", "unimplemented range-key deletion"),
    (r"zero[\s-]*knowledge", "unimplemented server/sync guarantee"),
    (r"secure\s+enclave", "unimplemented hardware-backed key custody"),
    (r"neural\s+engine", "unverified compute-unit guarantee"),
    (r"sqlite[\s-]*vec", "unshipped vector extension"),
    (r"no\s+third\s+party\s+can\s+decrypt", "absolute decryption guarantee"),
)


def read_terms():
    with open(TOS_PATH, encoding="utf-8") as f:
        return f.read()


def validate_terms(text):
    failures = []
    for pattern, description in PROHIBITED_GUARANTEES:
        if re.search(pattern, text, flags=re.IGNORECASE):
            failures.append(description)
    if failures:
        joined = ", ".join(failures)
        raise ValueError(f"prohibited unshipped guarantee in legal source: {joined}")


def strip_comments(text):
    return re.sub(r'<!--.*?-->', '', text, flags=re.DOTALL)


def rtf_esc(text):
    out = []
    for ch in text:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '{':
            out.append('\\{')
        elif ch == '}':
            out.append('\\}')
        elif ord(ch) > 127:
            out.append(f'\\u{ord(ch)}?')
        else:
            out.append(ch)
    return ''.join(out)


def inline_to_rtf(text):
    text = re.sub(r'\[(.+?)\]\((.+?)\)', r'\1', text)
    text = re.sub(r'`(.+?)`', r'\1', text)
    parts = re.split(r'(\*\*.+?\*\*)', text)
    result = []
    for part in parts:
        if part.startswith('**') and part.endswith('**'):
            result.append(f'\\b {rtf_esc(part[2:-2])}\\b0 ')
        else:
            result.append(rtf_esc(part))
    return ''.join(result)


def md_to_rtf(md_text):
    text = strip_comments(md_text)
    lines = text.strip().split('\n')
    body = []

    for line in lines:
        s = line.strip()

        if re.match(r'^---+$', s):
            body.append('\\par ')
            continue

        m = re.match(r'^(#{1,6})\s+(.*)', s)
        if m:
            level = len(m.group(1))
            title = inline_to_rtf(m.group(2))
            sz = {1: 32, 2: 28}.get(level, 24)
            body.append(f'\\par \\f1\\b\\fs{sz} {title}\\par ')
            body.append('\\f0\\b0\\fs24 ')
            continue

        if s.startswith('- '):
            content = inline_to_rtf(s[2:])
            body.append(f'\\li360\\fi-360 \\bullet  {content}\\par ')
            body.append('\\li0\\fi0 ')
            continue

        if not s:
            body.append('\\par ')
            continue

        body.append(f'{inline_to_rtf(s)}\\par ')

    joined = '\n'.join(body)
    joined = re.sub(r"[ \t]+$", "", joined, flags=re.MULTILINE)
    return (
        '{\\rtf1\\ansi\\ansicpg1252\n'
        '{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;'
        '\\f1\\fswiss\\fcharset0 Helvetica-Bold;}\n'
        '{\\colortbl;\\red255\\green255\\blue255;'
        '\\red200\\green0\\blue0;}\n'
        '\\paperw11900\\paperh16840'
        '\\margl1440\\margr1440\n'
        '\\pard\\tx720\\pardirnatural\\partightenfactor0\n'
        '{\\cf2\\f1\\b\\fs18 NOTICE: Auto-generated from '
        'docs/legal/terms-of-service.md. '
        'Product behavior was reconciled with docs/STATUS.md; '
        'legal owner approval remains a release gate.}\n'
        '\\f0\\b0\\fs24\\par\\par\n'
        f'{joined}\n'
        '}'
    )


def check_artifact(path, expected):
    if not os.path.isfile(path):
        print(f"ERROR: generated legal artifact is missing: {path}", file=sys.stderr)
        return False
    with open(path, encoding="utf-8") as artifact:
        actual = artifact.read()
    if actual != expected:
        print(
            f"ERROR: generated legal artifact differs from source: {path}",
            file=sys.stderr,
        )
        print(
            "Regenerate with: python3 assets/installer/generate-eula.py",
            file=sys.stderr,
        )
        return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify generated artifacts without modifying them",
    )
    args = parser.parse_args()

    if not os.path.isfile(TOS_PATH):
        print(f"ERROR: {TOS_PATH} not found", file=sys.stderr)
        sys.exit(1)

    md_text = read_terms()
    try:
        validate_terms(md_text)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

    rtf = md_to_rtf(md_text)

    if args.check:
        if not check_artifact(EULA_PATH, rtf):
            sys.exit(1)
        print("Legal artifact matches the canonical source and product-truth policy.")
        return

    with open(EULA_PATH, "w", encoding="utf-8", newline="") as f:
        f.write(rtf)
    print(f"  EULA.rtf  ({len(rtf):,} bytes)")


if __name__ == "__main__":
    main()
