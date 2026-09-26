# Capture Overlap Corpus

This deterministic macOS fixture opens two overlapping windows in one app:

- `FOCUSED_EVIDENCE_ZEPHYR_9241` is in the key window and must be captured.
- `BACKGROUND_SECRET_NEBULA_7713` is in the overlapping background window and
  must never enter memory.

Build the disposable app with:

```bash
tools/capture-overlap-corpus/build-app.sh /tmp/CaptureOverlapCorpus.app
```

The fixture contains no user data. Add bundle identifier
`ai.hippocampus.CaptureOverlapCorpus` to the test user's `user-allowlist.toml`
before a live run. A passing privacy run requires the focused token in an OCR
event, zero occurrences of the background token, and a nonzero focused-window
generation in helper telemetry.
