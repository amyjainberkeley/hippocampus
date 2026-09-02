#!/usr/bin/env python3
"""Render hero-cli.png from real mci-brain output against the seed brain.

Requires: Pillow (`pip3 install Pillow`), seed brain populated
(`scripts/demo.sh seed`), and mci-brain built (`cargo build --release
--bin mci-brain`).

Outputs: assets/screenshots/hero-cli.png (1280x800, ~70KB, no metadata).
"""

import os
import subprocess
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("ERROR: Pillow not installed. Run: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAIN = os.environ.get(
    "MCI_BRAIN_BIN",
    os.path.join(REPO, "target", "release", "mci-brain"),
)
OUT = os.path.join(REPO, "assets", "screenshots", "hero-cli.png")

KEY_FILE = os.environ.get("MCI_DB_KEY_FILE", "/tmp/mci-demo-key.hex")
DB_PATH = os.environ.get(
    "MCI_DB_PATH",
    os.path.expanduser("~/Library/Application Support/MCI/mci.sqlite"),
)

if not os.path.exists(BRAIN):
    print(f"ERROR: {BRAIN} not found. Run: cargo build --release --bin mci-brain", file=sys.stderr)
    sys.exit(1)

if "MCI_DB_KEY_HEX" not in os.environ and not os.path.exists(KEY_FILE):
    print(f"ERROR: {KEY_FILE} not found. Run: scripts/demo.sh seed", file=sys.stderr)
    sys.exit(1)

env = os.environ.copy()
env["MCI_DEVELOPMENT_FILE_KEY"] = "1"
if "MCI_DB_KEY_HEX" not in env:
    with open(KEY_FILE, encoding="ascii") as key_file:
        env["MCI_DB_KEY_HEX"] = key_file.read().strip()
env["MCI_DB_PATH"] = DB_PATH


def run_brain(*args):
    r = subprocess.run([BRAIN] + list(args), capture_output=True, text=True, env=env)
    return r.stdout.strip()


stats_out = run_brain("stats")
search1_out = run_brain("search", "retrieval benchmark", "--limit", "3")
search2_out = run_brain("search", "agent context handoff", "--limit", "3")

if not stats_out:
    print("ERROR: mci-brain stats returned empty. Check seed brain.", file=sys.stderr)
    sys.exit(1)

# --- Render ---

WIDTH, HEIGHT = 1280, 800
BG = (246, 248, 251)
FG = (24, 33, 43)
GREEN = (45, 139, 87)
CYAN = (53, 104, 212)
YELLOW = (196, 86, 73)
DIM = (95, 105, 117)

FONT_SIZE = 14
LINE_HEIGHT = 20

FONT_PATH = "/System/Library/Fonts/Menlo.ttc"
if not os.path.exists(FONT_PATH):
    FONT_PATH = "/System/Library/Fonts/Supplemental/Menlo.ttc"
if not os.path.exists(FONT_PATH):
    print("WARNING: Menlo.ttc not found, using default font", file=sys.stderr)
    FONT_PATH = None

FONT = ImageFont.truetype(FONT_PATH, FONT_SIZE) if FONT_PATH else ImageFont.load_default()

img = Image.new("RGB", (WIDTH, HEIGHT), BG)
draw = ImageDraw.Draw(img)

TITLE_BAR_H = 28
draw.rectangle([0, 0, WIDTH, TITLE_BAR_H], fill=(232, 236, 242))
for i, color in enumerate([(255, 96, 92), (255, 189, 46), (39, 201, 63)]):
    draw.ellipse([12 + i * 22, 8, 24 + i * 22, 20], fill=color)
title_font = ImageFont.truetype(FONT_PATH, 12) if FONT_PATH else ImageFont.load_default()
draw.text(
    (WIDTH // 2 - 96, 8),
    "hippocampus — local memory",
    fill=DIM,
    font=title_font,
)

x = 16
y = TITLE_BAR_H + 16


def text(txt, color=FG, indent=0):
    global y
    draw.text((x + indent, y), txt, fill=color, font=FONT)
    y += LINE_HEIGHT


def prompt(cmd):
    global y
    p = "$ "
    draw.text((x, y), p, fill=GREEN, font=FONT)
    draw.text((x + FONT.getlength(p), y), cmd, fill=FG, font=FONT)
    y += LINE_HEIGHT


def blank():
    global y
    y += LINE_HEIGHT


MAX_COL = 82


def wrap_text(s, col=MAX_COL):
    lines = []
    words = s.split()
    cur = []
    length = 0
    for w in words:
        if length + len(w) + 1 > col and cur:
            lines.append(" ".join(cur))
            cur = [w]
            length = len(w)
        else:
            cur.append(w)
            length += len(w) + 1
    if cur:
        lines.append(" ".join(cur))
    return lines


def render_output(raw):
    for line in raw.split("\n"):
        if line.startswith("event:"):
            parts = line.split(" | ", 3)
            header = " | ".join(parts[:3]) if len(parts) >= 3 else line
            text(header, YELLOW)
            if len(parts) >= 4:
                title_url_body = parts[3]
                sub = title_url_body.split(" | ")
                for s in sub:
                    s = s.strip()
                    if s.startswith("http"):
                        text("  " + s[:MAX_COL], CYAN, indent=8)
                    elif len(s) > MAX_COL - 4:
                        for wl in wrap_text(s, MAX_COL - 4):
                            text("  " + wl, DIM, indent=8)
                    else:
                        text("  " + s, FG, indent=8)
        elif line.startswith("Events:"):
            text(line, CYAN)
        elif line.startswith("Oldest:") or line.startswith("Newest:"):
            text(line, DIM)
        else:
            text(line, FG)


prompt("mci-brain stats")
blank()
render_output(stats_out)
blank()

prompt('mci-brain search "retrieval benchmark" --limit 3')
blank()
render_output(search1_out)
blank()

prompt('mci-brain search "agent context handoff" --limit 3')
blank()
render_output(search2_out)
blank()

pw = FONT.getlength("$ ")
draw.rectangle([x, y + 2, x + pw, y + LINE_HEIGHT - 2], fill=GREEN)
draw.text((x, y), "$ ", fill=BG, font=FONT)

img.save(OUT, "PNG", optimize=True)
size = os.path.getsize(OUT)
print(f"Saved: {OUT}")
print(f"Size: {size} bytes ({size / 1024:.0f} KB)")
