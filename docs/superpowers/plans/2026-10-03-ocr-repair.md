# Screenshot OCR quality and local re-reading

> **For agentic workers:** Use superpowers:executing-plans. The owner has authorized implementation and local verification; no additional design approval is needed.

**Goal:** Stop presenting uncertain OCR as reliable text, preserve useful screenshot detail, and let the owner re-read retained screenshots locally.

**Architecture:** The original complete OCR output continues through the privacy scan. Only afterwards does transcript presentation remove readings below 0.5 confidence. Retained screenshots preserve capture resolution up to 3840 pixels with a bounded encoded size; list thumbnails remain small. A deliberate re-read uses the authenticated saved image and bundled offline worker, checks raw and cleaned text with the same privacy rules, and shows a cancellable preview without rewriting historical evidence or search indexes.

**Tech stack:** Swift/SwiftUI, CoreImage, existing encrypted keyframe codec, pinned RapidOCR/ONNX worker.

**Spec:** Owner's October 3 screenshot/OCR complaint; the constraints in this document.

## Global constraints

- No user screenshot, extracted text, or memory database enters source control or a cloud service.
- Keep the 30-second child-process deadline and all existing ROI/privacy/blob-authentication boundaries.
- Confidence measures recognition uncertainty; it is not a guarantee that a reading is correct.
- No generative spelling correction or reconstruction of covered/missing pixels.
- Old stored transcripts and search results remain original evidence until a separately designed, reversible index repair exists. The re-read action must disclose that boundary.
- Storage remains age based; increasing image detail can increase disk use. Bound each image and refuse oversize blobs rather than silently degrading text resolution.

## Review focus

1. Low-confidence secrets must still block storage and preview: exercise raw and cleaned privacy scans.
2. Confident short, non-Latin, and punctuation-only text must survive: behavioral transcript tests.
3. Large, tampered, outside-root and symlink images must stay bounded/rejected: authenticated image provider tests.
4. Changing selection, deleting evidence, or dismissing during OCR must clear output and kill the worker: generation/cancellation tests.
5. Old low-resolution images, no text and deadlines must explain limitations, never masquerade as successful repairs: view-model tests and local OCR benchmark.

## Steps

- [x] Add failing regression coverage for uncertain transcripts/privacy, preserved pixels, detailed image reads, and preview lifecycle.
- [x] Implement transcript quality handling after privacy, retain bounded source detail, and keep small list reads.
- [x] Compare actual worker runtime under one and two inference threads; change resource configuration only if the measured bounded worker improves while synthetic text remains exact.
- [x] Implement local re-read preview with raw/cleaned privacy checks, explicit source limitations, cancellation, and separate copy action.
- [ ] Run affected native suites and worker tests in minimal environments; inspect actual UI with synthetic data.
- [ ] Obtain fresh independent source review, update status/audit, publish a verified source checkpoint to the existing draft PR. Track installation separately.

## Qualification checkpoint

541 Recall XCTest cases plus four Swift Testing cases, 32 focused helper tests,
11 worker tests and both packaged-worker transcription checks pass. The whole
helper suite's eight failing assertions were independently reproduced on the
unchanged public baseline; they remain open. Source review is complete with no
blocking findings. The native UI reached the real worker's loading state, then
macOS locked. Final visual result inspection, installation and historical
search-index repair are not claimed. See the linked status/audit for receipts.
