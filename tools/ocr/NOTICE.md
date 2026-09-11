# Local OCR components

Hippocampus uses RapidOCR 3.9.2 and PaddleOCR PP-OCRv6 small detection and
recognition models, distributed under Apache-2.0. The compatibility orientation
model is ch_ppocr_mobile_v2.0_cls_mobile (Apache-2.0); classification is disabled
for upright desktop screenshots. Weights are redistributed unchanged, with
SHA-256 checksums and source URLs in model-manifest.json.

- RapidOCR: https://github.com/RapidAI/RapidOCR (RapidOCR Authors)
- PaddleOCR: https://github.com/PaddlePaddle/PaddleOCR (PaddlePaddle Authors/Baidu)
- ONNX Runtime: https://github.com/microsoft/onnxruntime (Microsoft, MIT)
- Python: https://www.python.org/ (PSF license)
- NumPy: https://numpy.org/ (BSD-3-Clause)
- OpenCV: https://opencv.org/ (Apache-2.0)
- Pillow: https://python-pillow.org/ (MIT-CMU)
- PyInstaller bootloader: https://pyinstaller.org/ (GPL-2.0-or-later with the
  bootloader distribution exception permitting bundled applications).

Installed package licenses are included by the standalone build. OCR runs
locally and has no model-download or inference-service access. Model output is
fallible transcription, not verified source text or executable instructions.
