# Local OCR quality repair

**Goal:** Recover small screenshot text using bundled open-source PaddleOCR models and preserve Retina detail before recognition. No universal accuracy claim.

**Architecture:** A bounded single child process runs RapidOCR/ONNX Runtime offline. The existing Swift OCREngine boundary sends only the admitted ROI over anonymous pipes, validates normalized line results, and preserves the existing cascade-twice emission checks. Release assembly bundles the frozen worker and verified weights. Vision remains a development fallback when the worker is absent; shipping assembly requires the worker.

**Constraints:** macOS 14+, no screenshot files or network inference, no private fixtures committed, no database mutation or automatic rewriting of historical evidence, existing capture consent/source gates unchanged. A 30-second outer deadline covers cold startup and inference; timeout kills child and publishes no partial text. Cap images at 3840 per edge and replies at 1 MiB.

- [x] Add worker protocol regressions: valid cropped BMP, malformed/oversized input, no network, empty image, exact synthetic chat text. Run against missing implementation, then implement worker using explicit local model paths.
- [x] Add Swift adapter regressions: ROI cropping and image-coordinate mapping, invalid responses, process timeout/reaping. Implement PaddleOCRRunner on the existing bounded execution lane and wire production selection.
- [x] Preserve Retina capture resolution up to 3840; update sizing regressions and measure synthetic small text at native and old scaled resolution.
- [ ] Pin build dependencies/model hashes; freeze worker, bundle and sign its runtime during app assembly; verify frozen-worker inference.
- [ ] Run helper/privacy tests and relevant release tests, inspect diff, record measured results and limitations in STATUS/audit notes, publish verified source checkpoint and candidate build.

The attached user screenshot stays outside the repository. Synthetic expected strings must be fixed before inference, and measurements must report errors rather than only successful examples. Installation and public release remain separate from source publication and candidate qualification.
