# Retained JPEG screenshot OCR qualification

Previous real-worker probes exercised uncompressed fabricated pixels. This
check adds the actual retained-image path: production JPEG encoding and
encryption, authenticated decoding, local re-reading and the installed frozen
OCR worker. No screen, owner memory, Keychain item or external provider is used.

## Method

A private standalone Swift probe links the existing optimized libraries from
`afed4a3`. It draws ten fabricated chat lines in alternating dark and green
bubbles inside a 2560×1600 image using Core Text's Arial at 10, 12 and 16 pixels.
For each size, it calls `KeyframeBlobEncoder.encodeAndEncrypt` with the default
0.88 JPEG quality. One case uses the current 3840-pixel maximum long edge, which
preserves these native dimensions; a comparison uses 1280. Compression quality
is held constant to isolate the effect of scaling. This comparison is not a
reconstruction of every historical encoding setting.

Only the key is injected. The real codec seals the image into a content-addressed
encrypted blob. `ThumbnailDataProvider` authenticates and decodes it;
`LocalScreenshotRereader` performs bounded image conversion, launches the actual
worker from `/Applications/Hippocampus.app`, and applies raw and cleaned privacy
review. The worker is from the installed exact `8e82e03` candidate; the standalone
probe is not the signed application. The worker hash is unchanged before/after.
No recognizer response is mocked and no plaintext image is written to disk.

## Results

| Font size | Retention limit | Exact lines / 10 | Output lines | Omitted lines | Seconds |
| --- | --- | --- | --- | --- | --- |
| 10 px | 3840 px | 10 | 10 | 0 | 3.763 |
| 10 px | 1280 px | 0 | 7 | 0 | 0.934 |
| 12 px | 3840 px | 10 | 10 | 0 | 2.282 |
| 12 px | 1280 px | 0 | 9 | 0 | 0.984 |
| 16 px | 3840 px | 10 | 10 | 0 | 2.329 |
| 16 px | 1280 px | 6 | 10 | 0 | 1.064 |

All three native transcripts also match the complete expected line order,
with no additional text. All six child invocations finish within the unchanged
30-second deadline. Timings measure re-reading after encoding and writing the
synthetic blob; they exclude those preparation steps. Independent read-only
review found no blocking issue in the probe, receipts or these bounded claims.
The degraded comparisons return readings despite errors;
zero omitted lines does not mean recognition was correct. A confidence threshold
alone cannot establish the truth of a transcript.

The source, compile log, encrypted synthetic fixtures, per-case outputs,
worker/probe hashes and verification receipt are private at
`/Users/amy/Hippocampus-verification/retained-screenshot-ocr-20261007` (mode 0700).
Only these aggregate findings are included in the source repository.

## Limits

The result supports preserving native image detail, already implemented in the
installed update. It does not recover pixels missing from old retained images,
repair historical search indexes, or prove accuracy for the owner's screenshots.
It does not test source admission, screen capture, event/database publication,
real Keychain access, UI rendering, physical shortcuts or MCP readback.

This is the same Mac with previously executed OCR libraries, not a cold-machine
or first-install test. The earlier frozen-worker first-start timeout remains
recorded. No product code, model, deadline, permission, installed bundle,
historical record, website, public download or Superapp component changed.
