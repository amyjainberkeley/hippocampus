# OCR transcription: reading order, a warm worker, and text-change capture

Three separate faults made stored screen text worse than the OCR model that
produced it. This checkpoint fixes all three and adds a benchmark that measures
the whole pipeline on realistic app screens.

## What was wrong

1. **Reading order.** The helper joined recognized boxes in engine order with
   newlines. Side-by-side columns (a sidebar beside a chat, a file tree beside
   an editor, three mail panes) were interleaved row by row, one visual row
   became several fragments, and code lost its indentation.
2. **A cold worker per frame.** Each frame started a new PaddleOCR process that
   imported its runtime and loaded its models before reading. That cost 6.3 s
   per 2880×1800 frame on one thread (3.8 s detection, 2.5 s recognition) on top
   of a 0.5–26 s start, the upper end being macOS scanning newly seen libraries.
   Frames timed out and their text was discarded.
3. **Changes never read.** The near-duplicate gate compares a 9×8 grid of
   single sampled pixels. Typing a paragraph or receiving a message rarely moves
   those 72 samples, so the frame was dropped until something larger changed.

## Benchmark

`tools/ocr/screens/` renders eight app-like screens with headless Chrome at
Retina scale (chat, code editor, two-column article, terminal, three-pane mail,
spreadsheet, 11 px settings labels, notes). Every visible string is known, so
truth is complete and ordered. Metrics: exact lines, words recovered (order
ignored), character error over the whole screen in reading order, and the
share of found lines in reading order. All text is fabricated.

Means over the eight screens, measured on this Mac under heavy unrelated load
(load average 7–13), so absolute times are pessimistic:

| Pipeline | Exact lines | Words | Char error | Order | s/frame |
| --- | --- | --- | --- | --- | --- |
| Shipped: Paddle, engine order, cold worker | 0.857 | 0.992 | 0.269 | 0.730 | 6.78 |
| Paddle + reading order | 0.966 | 0.992 | 0.001 | 0.969 | 6.78 |
| **New: warm worker, 4 threads, half-scale detection, reading order** | **0.967** | 0.989 | **0.001** | **0.969** | **1.27** |
| Apple Vision text request + reading order | 0.833 | 0.943 | 0.023 | 0.963 | 0.38 |
| Apple Vision document request (macOS 26) | 0.682 | 0.933 | 0.039 | 0.972 | 0.97 |

Core ML execution for the Paddle models was slower (5.6 s): the exported models
have dynamic shapes Core ML cannot compile, so most work fell back to the CPU.

The remaining misses are recognition, not layout: dropped backticks and one
dropped space in terminal text, `Ok` read as `0k`, and a missing space between
a name and a time. The order score is below 1.0 on screens with repeated short
lines because its fuzzy matcher can pair a repeated name with the wrong
occurrence; those screens have 0.000 character error.

## What changed

- **`OCRReadingOrder`** (Swift, reference `tools/ocr/screens/layout.py`):
  recursive XY-cut at whitespace bands, tables read row by row, rows joined
  left to right, indentation kept, overlapping alternative readings kept on
  their own lines. Iterative, so a screen of thousands of short lines cannot
  exhaust a thread's stack. Eight fixtures of real Paddle output pin the Swift
  port to the reference byte for byte.
- **Persistent worker.** `hippocampus-ocr --serve` loads once, announces
  readiness and answers each frame with one JSON line. A refused frame is
  answered `failed` and the worker stays warm. The helper starts it at launch.
  A frame that misses its deadline does not kill a worker that is still
  loading; its late reply is drained before the next frame. A worker silent for
  two minutes, oversized, or exited is replaced on the next frame. Recall's
  explicit re-read keeps the one-shot mode.
- **Faster reading.** Serve mode uses four inference threads and detects text
  at half scale on Retina-sized frames (long edge ≥ 2560) while recognizing
  from the original pixels.
- **Text catch-up.** Each frame also yields a quarter-scale luminance
  thumbnail. A frame the coarse hash calls a near-duplicate is read anyway when
  at least 48 thumbnail pixels changed since the last read frame and three
  seconds have passed. Two typed words cross that line; a caret blink does not.

The privacy order is unchanged: the complete raw OCR text is checked for
secrets first, then the compacted, reordered text is checked again before
anything is stored.

## Verification

- Swift helper suite: 854 tests. The three real-Vision timing tests fail when
  the machine is heavily loaded (Vision's 1 s budget) and pass otherwise; they
  are not on the shipped path, which uses the bundled worker.
- New: 5 reading-order tests (8-screen parity), 6 persistent-worker tests, 4
  text-change tests; 3 evidence tests updated to the new layout, each still
  asserting its original property.
- Python worker: 16 tests, 4 of them new for serve mode.

Not yet established: accuracy on live captures of real apps, and CPU and
energy over a working day with the warm worker resident.
