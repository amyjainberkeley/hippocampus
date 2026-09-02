#!/usr/bin/env python3
"""Render the illustrative CLI asset from the committed benchmark scorecard.

The image is deliberately not presented as a live terminal capture. Its
metrics come from docs/eval/work-memory-baseline.json, making the launch truth
deterministic and keeping personal/local brain contents out of the asset.
"""

import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("ERROR: Pillow not installed. Run: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(REPO, "docs", "eval", "work-memory-baseline.json")
OUT = os.path.join(REPO, "assets", "screenshots", "hero-cli.png")

with open(BASELINE, encoding="utf-8") as baseline_file:
    scorecard = json.load(baseline_file)

hybrid = next(row for row in scorecard["overall"] if row["arm"] == "hybrid")
outcomes = hybrid["outcomes"]

WIDTH, HEIGHT = 1280, 800
BG = (247, 248, 250)
TITLE_BG = (238, 240, 243)
FG = (29, 29, 31)
SUCCESS = (36, 122, 71)
BLUE = (10, 102, 216)
FAILURE = (199, 71, 58)
DIM = (110, 110, 115)

FONT_SIZE = 14
LINE_HEIGHT = 21
MAX_COL = 104

FONT_PATH = "/System/Library/Fonts/Menlo.ttc"
if not os.path.exists(FONT_PATH):
    FONT_PATH = "/System/Library/Fonts/Supplemental/Menlo.ttc"
if not os.path.exists(FONT_PATH):
    print("WARNING: Menlo.ttc not found, using default font", file=sys.stderr)
    FONT_PATH = None

FONT = ImageFont.truetype(FONT_PATH, FONT_SIZE) if FONT_PATH else ImageFont.load_default()
TITLE_FONT = ImageFont.truetype(FONT_PATH, 12) if FONT_PATH else ImageFont.load_default()

image = Image.new("RGB", (WIDTH, HEIGHT), BG)
draw = ImageDraw.Draw(image)

TITLE_BAR_HEIGHT = 28
draw.rectangle([0, 0, WIDTH, TITLE_BAR_HEIGHT], fill=TITLE_BG)
for index, color in enumerate([(255, 96, 92), (255, 189, 46), (39, 201, 63)]):
    draw.ellipse([12 + index * 22, 8, 24 + index * 22, 20], fill=color)
draw.text(
    (WIDTH // 2 - 132, 8),
    "hippocampus - benchmark snapshot",
    fill=DIM,
    font=TITLE_FONT,
)

x = 16
y = TITLE_BAR_HEIGHT + 16


def text(value, color=FG, indent=0):
    global y
    draw.text((x + indent, y), value, fill=color, font=FONT)
    y += LINE_HEIGHT


def prompt(command):
    global y
    prefix = "$ "
    draw.text((x, y), prefix, fill=SUCCESS, font=FONT)
    draw.text((x + FONT.getlength(prefix), y), command, fill=FG, font=FONT)
    y += LINE_HEIGHT


def blank():
    global y
    y += LINE_HEIGHT


def wrapped(value, color=DIM, indent=16):
    words = value.split()
    line = []
    length = 0
    for word in words:
        if line and length + len(word) + 1 > MAX_COL:
            text(" ".join(line), color, indent)
            line = [word]
            length = len(word)
        else:
            line.append(word)
            length += len(word) + 1
    if line:
        text(" ".join(line), color, indent)


prompt("cargo run -q -p mci-agent --bin mci-bench -- --arm both")
blank()
text("Committed synthetic technical-work benchmark", BLUE)
text(
    f"Dataset: {hybrid['instances']} cases "
    f"({hybrid['answerable_instances']} answerable, "
    f"{hybrid['unanswerable_instances']} unanswerable)",
    DIM,
)
text(f"Hybrid recall @3: {hybrid['recall_at']['3']:.0%}")
text(f"MRR: {hybrid['mrr']:.3f}")
text(f"Provenance coverage @3: {hybrid['provenance_coverage_at']['3']:.0%}")
text(
    f"Unanswerable: abstained {outcomes['abstained']}/"
    f"{hybrid['unanswerable_instances']}; false positives: {outcomes['false_positive']}",
    SUCCESS,
)
text(f"Latency p95: {hybrid['latency_ms']['p95']:.1f} ms", DIM)
text(f"Index size p95: {hybrid['index_size_bytes']['p95'] / 1024:.1f} KiB", DIM)
blank()

text(
    f"Regression gate: {'PASS' if scorecard['regression']['passed'] else 'FAIL'}",
    SUCCESS if scorecard["regression"]["passed"] else FAILURE,
)
text(
    f"Quality gate: {'PASS' if scorecard['quality_gate']['passed'] else 'FAIL'}",
    SUCCESS if scorecard["quality_gate"]["passed"] else FAILURE,
)
text(f"Launch qualified: {str(scorecard['launch_qualified']).lower()}", FAILURE)
wrapped("Reason: general evidence critic is not validation-qualified.")
blank()

prompt("jq '.quality_gate, .launch_qualified' docs/eval/work-memory-baseline.json")
blank()
text('{ "quality_gate": { "passed": false }, "launch_qualified": false }', FAILURE)
blank()
wrapped(
    "Retrieval improved and abstention is now correct on this synthetic set. "
    "The evidence policy still blocks launch; this does not claim memory is solved.",
    FG,
    0,
)
blank()

prefix_width = FONT.getlength("$ ")
draw.rectangle([x, y + 2, x + prefix_width, y + LINE_HEIGHT - 2], fill=SUCCESS)
draw.text((x, y), "$ ", fill=BG, font=FONT)

image.save(OUT, "PNG", optimize=True)
size = os.path.getsize(OUT)
print(f"Saved: {OUT}")
print(f"Size: {size} bytes ({size / 1024:.0f} KB)")
