#!/usr/bin/env python3
"""Generate or verify EULA.rtf and sla.r from the canonical license terms.

Single source of truth: the markdown file. This script produces:
  - EULA.rtf   — Rich Text for distribution / reference
  - sla.r      — Rez resource source for DMG SLA popup attachment

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
SLA_PATH = os.path.join(SCRIPT_DIR, "sla.r")

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


def md_to_plain(md_text):
    text = strip_comments(md_text)
    lines = []
    for line in text.split('\n'):
        line = re.sub(r'^#{1,6}\s+', '', line)
        line = re.sub(r'\*\*(.+?)\*\*', r'\1', line)
        line = re.sub(r'\*(.+?)\*', r'\1', line)
        line = re.sub(r'\[(.+?)\]\((.+?)\)', r'\1 (\2)', line)
        line = re.sub(r'`(.+?)`', r'\1', line)
        if re.match(r'^---+$', line.strip()):
            line = ''
        lines.append(line)
    result = re.sub(r'\n{3,}', '\n\n', '\n'.join(lines))
    return result.strip()


def rez_string_escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"')


def generate_sla_r(md_text):
    plain = md_to_plain(md_text)
    text_lines = []
    for line in plain.split('\n'):
        escaped = rez_string_escape(line)
        text_lines.append(f'    "{escaped}\\n"')
    text_data = '\n'.join(text_lines)

    return f'''/* DMG Software License Agreement resources.
 * Auto-generated from docs/legal/terms-of-service.md.
 * Regenerate: python3 assets/installer/generate-eula.py
 *
 * Attach to DMG:
 *   hdiutil unflatten Hippocampus.dmg
 *   Rez -append assets/installer/sla.r -o Hippocampus.dmg
 *   hdiutil flatten Hippocampus.dmg
 */

data 'LPic' (5000) {{
    $"0000"  /* default language */
    $"0001"  /* count */
    $"0000"  /* English */
    $"0000"  /* resource ID offset */
    $"0000"  /* reserved */
}};

resource 'STR#' (5000, "English buttons") {{
    {{
        "English",
        "Agree",
        "Disagree",
        "Print",
        "Save\\311",
        "If you agree with the terms of this license, click "
        "\\"Agree\\" to install the software. "
        "If you do not agree, click \\"Disagree\\"."
    }}
}};

data 'TEXT' (5000, "English") {{
{text_data}
}};

data 'styl' (5000, "English") {{
    $"0001"           /* 1 style run */
    $"00000000"       /* start offset */
    $"000C"           /* height */
    $"000A"           /* ascent */
    $"0000"           /* font ID (system) */
    $"0000"           /* face (plain) */
    $"000A"           /* size 10 */
    $"0000 0000 0000" /* color (black) */
}};
'''


def rendered_artifacts(md_text):
    return md_to_rtf(md_text), generate_sla_r(md_text)


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

    rtf, sla = rendered_artifacts(md_text)

    if args.check:
        valid = check_artifact(EULA_PATH, rtf) & check_artifact(SLA_PATH, sla)
        if not valid:
            sys.exit(1)
        print("Legal artifacts match the canonical source and product-truth policy.")
        return

    with open(EULA_PATH, "w", encoding="utf-8", newline="") as f:
        f.write(rtf)
    print(f"  EULA.rtf  ({len(rtf):,} bytes)")

    with open(SLA_PATH, "w", encoding="utf-8", newline="") as f:
        f.write(sla)
    print(f"  sla.r     ({len(sla):,} bytes)")


if __name__ == "__main__":
    main()
