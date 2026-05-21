#!/usr/bin/env python3
"""Generate EULA.rtf and sla.r from docs/legal/terms-of-service.md.

Single source of truth: the markdown file. This script produces:
  - EULA.rtf   — Rich Text for distribution / reference
  - sla.r      — Rez resource source for DMG SLA popup attachment

Regenerate:
    python3 assets/installer/generate-eula.py

Requires: Python 3.8+ (stdlib only).
"""

import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
TOS_PATH = os.path.join(REPO_ROOT, "docs", "legal", "terms-of-service.md")
EULA_PATH = os.path.join(SCRIPT_DIR, "EULA.rtf")
SLA_PATH = os.path.join(SCRIPT_DIR, "sla.r")


def read_terms():
    with open(TOS_PATH) as f:
        return f.read()


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
    return (
        '{\\rtf1\\ansi\\ansicpg1252\n'
        '{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;'
        '\\f1\\fswiss\\fcharset0 Helvetica-Bold;}\n'
        '{\\colortbl;\\red255\\green255\\blue255;'
        '\\red200\\green0\\blue0;}\n'
        '\\paperw11900\\paperh16840'
        '\\margl1440\\margr1440\n'
        '\\pard\\tx720\\pardirnatural\\partightenfactor0\n'
        '{\\cf2\\f1\\b\\fs18 LAWYER: Auto-generated from '
        'docs/legal/terms-of-service.md. '
        'Verify effective date, jurisdiction, and dispute resolution '
        'before distribution. See <!-- LAWYER --> comments in source '
        'for specific review items.}\n'
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


def main():
    if not os.path.isfile(TOS_PATH):
        print(f"ERROR: {TOS_PATH} not found", file=sys.stderr)
        sys.exit(1)

    md_text = read_terms()

    rtf = md_to_rtf(md_text)
    with open(EULA_PATH, 'w') as f:
        f.write(rtf)
    print(f"  EULA.rtf  ({len(rtf):,} bytes)")

    sla = generate_sla_r(md_text)
    with open(SLA_PATH, 'w') as f:
        f.write(sla)
    print(f"  sla.r     ({len(sla):,} bytes)")


if __name__ == "__main__":
    main()
