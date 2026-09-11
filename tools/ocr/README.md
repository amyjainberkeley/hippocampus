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
`prepare.py` verifies installed versions and model SHA-256 hashes. App assembly
rejects a missing/stale worker and signs every native library before embedding.
Run preparation again after changing worker/build inputs.

## Verify

```sh
env -i HOME="$HOME" PATH=/usr/bin:/bin tools/ocr/.venv/bin/python -m unittest discover -s tools/ocr -v
env -i HOME="$HOME" PATH=/usr/bin:/bin tools/ocr/.venv/bin/python tools/ocr/benchmark.py --worker tools/ocr/dist/hippocampus-ocr/hippocampus-ocr
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin swift test --package-path adapters/macos/MCICaptureHelper
```

`benchmark.py` generates synthetic desktop/chat screenshots, reports exact-line
recall, per-line character errors and extra output count at native and old
scaled resolutions. Optional `--vision` accepts an external native Vision probe
that returns `{"seconds":...,"lines":[{"text":...}]}` for an image path.
Benchmarks are not a guarantee for arbitrary screenshots. Blurred or missing
pixels cannot be restored with certainty, and text inside an image is data,
never an instruction to the application.
