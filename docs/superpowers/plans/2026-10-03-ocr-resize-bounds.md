# Bound local OCR model inputs

> Use superpowers:executing-plans. Existing implementation and draft-publication authorization applies.

**Spec:** The owner's screenshot-transcription repair request and the existing offline, privacy-first, bounded-child contract. Valid narrow capture regions must not expand into unbounded model inputs.

**Finding:** RapidOCR 3.9.2's global minimum-side resize can expand a valid 3840×1 image to 115200×32 before detection. Detection independently enlarges the short side to 736. Recognition also pads each batch to its widest aspect ratio.

**Constraints:** No personal fixtures or cloud OCR. Preserve all recognition candidates for privacy. Keep the 30-second child deadline, reply limit, model hashes, signed bundle inventory, and historical evidence unchanged. No installation, TCC modification or release claim. A model-input dimension limit is not a total-process memory guarantee.

## Task 1: Bound detector and recognizer preprocessing

- Add a safe failing regression against the configured engine that intercepts oversized OpenCV resizes before allocation; include both strip orientations and non-multiple-of-32 sizes.
- Disable the hidden global resize/padding and provide a per-engine detector preprocessor that preserves normal short-side upscaling while capping each model-input edge at 3840 and maintaining 32-pixel alignment. Detection still maps boxes to the original image.
- Fail the entire operation before recognition allocation when the padded batch width exceeds the cap. Do not drop individual candidates, truncate text, or publish partial output.
- Add an actual narrow-text geometry regression and retain exact synthetic chat and privacy-candidate tests.
- Run the complete worker/build tests in the pinned minimal environment. Expected: all pass; baseline regressions first fail without allocating oversized images.

## Task 2: Qualify the frozen worker and publish the source checkpoint

- Rebuild the frozen worker; verify its source/model/native inventory.
- Exercise real child processes on blank strips and synthetic chat, preserving the existing deadline; verify the authenticated native re-read path with fabricated encrypted evidence.
- Obtain a fresh independent review, resolve findings with red/green tests, and record measurements and limitations in the audit/STATUS.
- Scan, commit, push and verify the existing draft branch/PR. Keep installed app and downloads unchanged. Expected: exact remote SHA and explicit source-only qualification.

## Qualification outcome

The 15 worker/build tests pass, including the safely reproduced pre-fix resource
failures. Fresh source review has no actionable findings. Frozen source/model/
runtime inventory passes. First fresh-runtime launch timed out at 30 seconds;
warm strip/chat/code runs pass. Preserve that failure and qualify cold-start
latency with the signed app before release. No deadline was increased. See the
audit for measurements; this plan ends at a draft source checkpoint.
