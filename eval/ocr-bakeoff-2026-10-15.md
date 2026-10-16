# Reader bake-off, 2026-10-15

Which engine reads the screen in 0.3.0: Apple Vision, tuned, or the bundled
PP-OCR worker? The launch plan (item 4) set the test. On the repo bench's
8 flat screens and 7 windows, Vision had to reach exact lines of 0.95 or more
and searchable words of 0.98 or more (PP-OCR's figures there were 0.967 and
0.989), with every hard gate of the transcript bench still met.

**Decision: PP-OCR stays the reader for 0.3.0.** Vision missed the test as the
code is, and missed it again after the worker's pane-separator step was
ported to Swift. The worker now leaves out FFmpeg, x264 and x265, which
solves the licence problem without changing readers.

## How it was measured

- **Screens.** `tools/ocr/screens/render.py` draws every scene with headless
  Chrome 155 at 2x: the 8 flat screens of `scenes.py`, and from `windows.py`
  the 7 windows (editor, chat, mail, article, video, notes, messages) and the
  6 decoys. All text is made up.
- **Readers, as the capture helper runs them.** `OCRQualityProbe --serve`
  (helper package, `Tests/Fixtures`) reads each screen with the helper's own
  engine, one warm process per run:
  - Vision: `VisionOCRRunner`, `.accurate`, `usesLanguageCorrection = false`,
    en-US with automatic language detection; the whole frame, then up to four
    overlapping quarters while its 1000 ms deadline allows.
  - PP-OCR: `PaddleOCRRunner` with the frozen worker (RapidOCR 3.9.2,
    PP-OCRv6 small, ONNX Runtime 1.30, two threads), kept warm, sent a 144 dpi
    bitmap.
  - Each read is the first read of a focused Retina window: the whole frame,
    2 pixels per point. Each run first reads an inverted screen that is not in
    the set, so loading models and the worker's remembered lines stay out of
    the numbers. Three runs per engine.
- **Scoring.** `tools/ocr/screens/bakeoff.py score`, whose docstring defines
  each measure.
  - Flat screens: the Oct 8 audit's measures (`bench.legacy_score`) on the
    text the app stores, which is `layout.py`'s reading with the window's
    geometry.
  - Windows: a window's truth is its tagged strings, so a string counts as
    exact when it appears whole in the stored text.
  - Words are whitespace tokens, the audit's measure. Searchable words are
    FTS5 `unicode61` tokens, what search sees.
  - Hard gates: `bench.py`'s own on each engine's reading, and the same
    content gates against PP-OCR's reading.
- **Cost.** `proc_pid_rusage` on the probe and its worker child: CPU time,
  CPU energy and peak physical footprint. Vision's Neural Engine time is not
  CPU time and is not counted.
- **Machine.** MacBook Air M3 (Mac15,13; 4 performance and 4 efficiency
  cores, 16 GB), macOS 26.5 (25F71). The Mac was shared with other builds.
  The accuracy runs ran at a load average of about 4. Later timing runs ran
  at 150 to 250 and say so.
- **Check of the instrument.** On the flat screens PP-OCR scores 0.967 exact
  lines and 0.990 words, the audit's 0.967 and 0.989. Vision reading the whole
  frame in one pass scores 0.833 and 0.943, exactly the audit's Vision row.

## Results

Means over the screens; the three runs of each engine are shown as a range.

| | Gate | PP-OCR | Vision, as the code is | Vision with pane separators | Vision, one pass per pane |
|---|---|---|---|---|---|
| Flat screens: exact lines | ≥ 0.95 | **0.967** | 0.939 | 0.939 | 0.882 |
| Flat screens: words | ≥ 0.98 | **0.990** | 0.975 | 0.975 | 0.960 |
| Flat screens: searchable words | | 0.997 | 0.994 | 0.994 | 0.991 |
| Windows: exact strings | ≥ 0.95 | 0.936 | 0.884 to 0.887 | 0.878 to 0.898 | 0.710 to 0.853 |
| Windows: words | ≥ 0.98 | 0.974 | 0.964 to 0.965 | 0.964 to 0.965 | 0.742 to 0.885 |
| Windows: searchable words | | 0.991 | 0.990 | 0.990 to 0.992 | 0.769 to 0.912 |
| Decoys: exact strings | | 0.973 | 0.951 | 0.951 | 0.588 to 0.873 |
| Transcript bench, its own hard gates | all met | met | 2 failed | 1 to 2 failed | 1 to 3 failed |
| Content against PP-OCR's reading | | | 10 to 11 failed | 9 to 11 failed | 10 to 14 failed |
| Chrome by word (target ≤ 0.25) | | 0.12 | 0.61 to 0.64 | 0.36 to 0.40 | 0.25 to 0.30 |
| Junk tokens per window (target ≤ 2) | | 0.54 | 8.5 to 8.9 | 6.3 to 6.7 | 2.5 to 3.0 |
| CPU s per read, median (p95) | | 3.7 to 4.8 (7.8 to 12.2) | 0.48 to 0.49 (0.65 to 0.76) | 0.50 to 0.52 (0.69 to 0.74) | 0.29 to 0.30 (0.51 to 0.62) |
| Wall s per read, median | | 1.9 to 2.6 | 0.53 to 0.54 | 0.54 to 0.59 | 0.32 to 0.43 |
| Peak memory, helper and worker | | 1.3 to 1.7 GB | 0.30 GB | 0.29 to 0.30 GB | 0.24 to 0.28 GB |
| Reads lost to the deadline (of 21) | | 0 | 0 | 0 | 0, 2 and 1 |

PP-OCR misses the window rows too. Some tagged strings are cut short on the
screen with an ellipsis, so no reader can match them whole. The window rows
compare the readers with each other; they don't measure either one against
the threshold.

The gate's "searchable words" could mean either words row. The plan quotes
PP-OCR's 0.989, which is the whitespace measure, but its budget defines
searchable words as FTS5 tokens. On FTS5 tokens Vision passes (0.994).
The decision doesn't turn on it: Vision misses exact lines and the hard
gates either way.

Per flat screen, exact lines (PP-OCR / Vision as the code is): chat 0.957 /
1.000, code 0.967 / 0.833, two-column article 1.000 / 1.000, terminal 0.812 /
0.812, mail 1.000 / 1.000, table 1.000 / 1.000, small labels 1.000 / 0.867,
notes 1.000 / 1.000. Vision loses on code, the terminal and small labels.

### Where Vision loses

The misses are recognition errors, not layout:

- **Code.** In the editor window Vision reads `///` as `I1/`, `->` as `→`,
  `Ok(0)` as `0k(0)`, `+=` as `t=` and `.chunks` as `. chunks`, and drops the
  lines that hold only `}`. The code then fails the bench's code check. PP-OCR
  reads every line of it exactly.
- **Terminal.** `Compiling mci-agent` loses its space, `]` becomes `l` and
  backticks become quotes.
- **Content.** Against PP-OCR's reading, Vision's transcript loses content
  in the editor (0.68 against 0.97), notes, video, small labels, the code
  screen and two decoys (a to-do list and a full-screen document).
- **Interface text.** Vision reads more of the interface into the main text:
  chrome by word is 0.61 to 0.64 against PP-OCR's 0.12.
- **A busy Mac.** At a load average of 150 to 250, the helper's Vision path
  timed out on all 15 reads of the helper's completeness benchmark. Its
  passes run at utility priority against a 1000 ms deadline. Its first
  pass took 0.35 to 4.1 s; the same plain pass, run by the test itself just
  before, took 0.06 to 0.40 s. If Vision is ever made the reader, it needs a
  longer deadline. It also has to charge the shared read budget
  (`CaptureReadBudget`), which today only the PP-OCR runner does.

### The pane-separator port

The plan said to port the worker's pane-separator step to Swift and vImage if
Vision missed, and run again.

- `PaneSeparators.swift` is that port. Given the same text boxes, it finds
  the same separators as the Python worker on all 21 screens.
  `PaneSeparatorsTests` pins the worker's output for synthetic pictures.
- **With separators**, Vision's accuracy did not move: its misses are
  recognition. Its transcripts are cleaner: chrome by word 0.38 instead of
  0.63, and 6.5 junk tokens instead of 8.6. That column was measured while
  the separators were still found inside the read, before its passes. The
  committed code finds them after the read, which only leaves the read more
  of its deadline.
- **One pass per pane** was worse: 0.882 exact lines and 0.960 words, and 3
  of 63 reads ran past the 1000 ms deadline and returned nothing.
- **Kept.** Vision reads now carry separators, found after the read and
  outside its deadline. A helper without the worker reads with Vision, as a
  development build does, and now cuts its reading at the same separators
  the worker reports. The pane plan stays a bench option.

## What the decision means for 0.3.0

- PP-OCR stays the reader. `build-app.sh` keeps embedding the worker, and the
  helper's choice of reader is unchanged.
- **The worker leaves out video.** The opencv-python-headless wheel brings a
  GPL build of FFmpeg with the x264 and x265 encoders. FFmpeg and what only it
  needs made up 75 of the worker's 121 libraries (66.8 MB), among them
  libpostproc, Rubber Band and vid.stab (GPL), and GnuTLS, Nettle and GMP
  (LGPL).
  - `prepare.py` makes OpenCV's links to FFmpeg weak, marks every symbol it
    binds from FFmpeg as a weak import, and removes every library that only
    FFmpeg reached.
  - `bundle.py` refuses to embed a worker that still has one.
  - The rebuilt worker reads all 21 screens byte for byte as the old one
    did, in four runs of the two alternating: the same lines, confidences,
    boxes and separators. All 155 worker tests pass.
- **Copyleft that remains**, as NOTICE now says: GEOS (LGPL-2.1, with
  Shapely), GLib and gettext's libintl (LGPL-2.1-or-later), and Graphite2
  (MPL-2.0, one of its licences). All are separate, replaceable dynamic
  libraries.
- **Costs that remain.** PP-OCR uses 8 to 10 times Vision's CPU per read and
  about 5 times its memory. The reading budget (plan item 5) and the
  footprint work have to hold that.

## Reproduce

```sh
PY=tools/ocr/.venv/bin/python
$PY tools/ocr/screens/render.py SCREENS
scripts/swift-package.sh build -c release --package-path adapters/macos/MCICaptureHelper --product OCRQualityProbe
$PY tools/ocr/screens/bakeoff.py read SCREENS OUT --worker tools/ocr/dist/hippocampus-ocr/hippocampus-ocr \
    --probe adapters/macos/MCICaptureHelper/.build/release/OCRQualityProbe --panes --runs 3
$PY tools/ocr/screens/bakeoff.py score OUT --misses vision-1
```
