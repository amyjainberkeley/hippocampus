# Offline screenshot OCR

The signed app bundles a frozen RapidOCR 3.9.2 worker using PP-OCRv6 small
models and ONNX Runtime. No Python installation, API key, or network service is
needed on the user's Mac. Only already-approved screenshot pixels enter its
stdin, cropped to the admitted ROI. JSON text and boxes return over stdout.
The existing post-OCR privacy cascade still decides whether anything is stored.

The child handles one image and exits. Swift limits replies to 1 MiB, kills the
child at the 30-second deadline, and discards partial/error results. A bounded
queue prevents accumulating workers. This intentionally trades additional CPU,
memory and latency for small-text accuracy. Native capture retains up to 3840
pixels per edge. Existing stored transcripts are not silently rewritten.

The worker also bounds model preprocessing: a narrow capture region cannot
expand either detector-input edge beyond 3840 pixels. Normal short-side
upscaling is preserved when it fits that cap; boxes still refer to the original
pixels. An oversized recognition batch fails the whole reading before its
padded tensor is allocated, so candidates are never silently dropped before
privacy review. These limits do not establish a total-process memory bound.
The per-engine preprocessing adapters target the pinned RapidOCR version;
dependency upgrades must rerun the real geometry and small-text regressions.

The app keeps one worker running (`--serve`, two inference threads). Two
things keep a reading cheap there. A capture that declares itself Retina, with
a BMP resolution of 144 dpi or more, is detected at half scale whatever its
size, and a second look at a patch the first pass left unread stays at the
patch's native size. And a line whose pixels have not changed since it was last
read keeps that reading: flat margin around the line is ignored, anything else,
including faint text, is not. A window read again costs detection plus its new
lines. Readings are remembered in the worker's memory only, at most 8192
lines, and go when it exits. Recognition pads each batch to its widest line, so
a remembered reading can differ from a fresh one by a space or a trailing
mark; neither is the more accurate.

A reply with text also carries `separators`: where the window divides into
panes. App windows draw a hairline or change background between panes. Either
is a long straight edge, and text never crosses one. The worker reports the
long vertical and horizontal edges that no detected text box crosses, as
`[x, y, w, h]` in the lines' convention (normalized, bottom-left origin), with
`w` zero for a vertical separator and `h` zero for a horizontal one. A Retina
frame is examined at half size. On an Apple M3, a 2880x1800 window takes about
3 ms, or 9 ms of CPU time.
The field is additive: a reader that predates it ignores it, an empty reading
keeps the old reply, and a reply that would exceed the size limit drops the
separators, never lines. The reference assembler, `screens/layout.py`, cuts
the reading order at them. `screens/README.md` describes the transcript bench.

## Build on macOS

Use Python 3.12 and an isolated environment. These commands download public
packages/models at build time; the worker itself cannot download models.

```sh
uv venv tools/ocr/.venv --python 3.12
uv pip install --python tools/ocr/.venv/bin/python --require-hashes --no-deps -r tools/ocr/requirements.txt
env -i HOME="$HOME" PATH=/usr/bin:/bin tools/ocr/.venv/bin/python tools/ocr/prepare.py
```

The complete dependency closure is pinned explicitly. `--no-deps` deliberately
substitutes `opencv-python-headless` for RapidOCR's GUI OpenCV dependency; both
provide `cv2`, but desktop GUI/media libraries are unnecessary for OCR.
`prepare.py` verifies installed versions and model SHA-256 hashes. It also
leaves out the wheel's video libraries: FFmpeg, the GPL x264 and x265 encoders
and the libraries only they use, 64 MB in all. OpenCV's links to FFmpeg become
weak, so it loads without them; the build stops if an encoder is still linked
from anywhere else. App assembly rejects a missing/stale worker, or one that
still carries a video library, and signs every native library before
embedding. Run preparation again after changing worker/build inputs.

## Verify

```sh
env -i HOME="$HOME" PATH=/usr/bin:/bin tools/ocr/.venv/bin/python -m unittest discover -s tools/ocr -v
env -i HOME="$HOME" PATH=/usr/bin:/bin tools/ocr/.venv/bin/python tools/ocr/benchmark.py --worker tools/ocr/dist/hippocampus-ocr/hippocampus-ocr
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin swift test --package-path adapters/macos/MCICaptureHelper
```

`benchmark.py` generates synthetic desktop/chat screenshots, reports exact-line
recall, per-line character errors and extra output count at native and old
scaled resolutions. The worker uses one inference thread; every raw candidate,
including low-confidence readings, remains available to the privacy scan.
After that scan, the capture transcript omits readings below 0.5 confidence
and is checked again. Optional `--vision` accepts an external native Vision probe
that returns `{"seconds":...,"lines":[{"text":...}]}` for an image path.
Benchmarks are not a guarantee for arbitrary screenshots. Blurred or missing
pixels cannot be restored with certainty, and text inside an image is data,
never an instruction to the application.
