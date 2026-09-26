# Focused-Window Live Qualification

- **Date:** 2026-09-04 PDT
- **Source HEAD:** `79576d3d3529f6915b7a160b3c0be3e2588a839d`
- **Product source digest:** `e7ed2e7e9e46aeece3ec4cf7abf8bc142fd50f513514f5671f00e911cb1f587b`
- **Host:** Apple silicon Mac, macOS with Xcode 26.6 selected
- **Signing identity:** Developer ID Application: Amy Jain (`BV6KGKFKP4`)
- **Qualification app CDHash:** `aef1ac03ded2237d842c613739d56ec3c5e05556`
- **Qualification helper CDHash:** `43881c04edf534b090c2de046ebcf0d80a673a8e`

## Verdict

PASS for focused-window ScreenCaptureKit OCR and the standalone M4 third lift.
The live proof used an isolated encrypted brain and deterministic synthetic
tokens. It did not read or write the user's production brain.

This is the canonical rerun after hardening the harness's event enumeration,
focus-control proof, race-drop denominator, process cleanup, source provenance,
and Apple trust checks. It supersedes the earlier `/tmp/hippo-live.XggUzE`
report, which is not release evidence.

This evidence has two parts from the same exact-source signed bundle:

1. A 30-minute live resource/privacy soak exercising deterministic focus churn.
2. A 20-second cross-application overlap proof using two
   separately bundled macOS applications.

The short proof is not counted as a resource soak. The long run adds repeated
focus rebinding, full-duration resource sampling, and exhaustive memory
readback. Both runs keep a separately bundled background application alive.

## Cross-Application Proof

The verifier assembled and launched both applications through LaunchServices:

| Role | Bundle identifier | Token |
|---|---|---|
| Focused source | `ai.hippocampus.CaptureOverlapCorpus` | `FOCUSED_EVIDENCE_ZEPHYR_9241` |
| Non-frontmost source | `ai.hippocampus.CaptureOverlapBackground` | `BACKGROUND_SECRET_NEBULA_7713` |

The background application launched first and remained alive behind the focused
application throughout capture. Only the focused bundle was in the isolated
allowlist. The runner continuously asserted that both owned processes remained
alive and that the focused corpus remained frontmost.

Command:

```bash
./scripts/run-live-capture-overlap.sh \
  --app /tmp/hippocampus-signed-qualification/Hippocampus.app \
  --signed-debug-qualification \
  --capture-seconds 20 \
  --keep-artifacts
```

Evidence root: `/tmp/hippo-live.wgtIOI`

Exact memory-verifier result:

```json
{"background_token_present": false, "corpus_event_count": 1, "focus_control_token_present": false, "focused_recall_outcome": "degraded", "focused_token_present": true, "foreign_event_count": 0, "timeline_event_count": 1}
```

Capture delivered 38 frames with zero backpressure, late-ack, encode, or
focus-race drops. One OCR event and one authenticated keyframe were retained.
The helper and ingest agent both exited cleanly after the parent-lifetime lease
closed. The separate background token was absent from timeline, app-scoped,
and full-text MCP probes, and no event attributed to a non-corpus application
was present.

## 30-Minute Soak

Command:

```bash
./scripts/run-live-capture-overlap.sh \
  --app /tmp/hippocampus-signed-qualification/Hippocampus.app \
  --signed-debug-qualification \
  --soak
```

Evidence root: `/tmp/hippo-live.mwsEza`

The committed machine-readable report is
`docs/audit/2026-09-04-focused-window-soak.json`.

| Gate | Result |
|---|---:|
| Duration | 1,800 seconds |
| Frames delivered | 3,610 |
| Focus-race drops | 37 (`1.0249%`) |
| Backpressure / late-ack / encode failures | `0 / 0 / 0` |
| OCR events / retained keyframes | `38 / 37` |
| Background token / foreign event | absent / `0` |
| Focus-rebind control token | present |
| Helper CPU p50 / p95 / max | `2.1% / 3.7% / 42.9%` |
| Helper RSS p50 / p95 / max | `50,970,624 / 92,012,544 / 101,548,032` bytes |
| Projected storage | `3,222,844` bytes/hour |

The nonzero race-drop count proves the generation gate was exercised. Its
`1.0249%` fraction uses `frames_delivered` as its denominator, is below the
binding 5% ceiling, and remains far below the historical
73% failure shape. Helper stderr contained no ScreenCaptureKit `-3815` error.

The MCP verifier enumerated all 38 events reported by `mci_stats`, enumerated
all 38 events for the focused corpus bundle, and rejected any count mismatch.
The exact focused and focus-rebind control tokens were present. The background
token was absent from timeline, app-scoped events, focused recall, and its own
full-text query; no event was attributed to another bundle.

## Artifact Binding

The app embedded a `build-provenance.json` manifest covering an exact six-file
`Contents/MacOS` inventory, signature-independent hashes for every Mach-O, all
other bundle payload bytes including model resources, the source HEAD, and the
product source digest above. The runner verified that manifest before capture.
It also evaluated an explicit `anchor apple generic` Developer ID requirement,
including Apple's Developer ID intermediate and application-leaf OIDs plus Team
ID `BV6KGKFKP4`, against both the host app and capture helper.

Raw binary SHA-256 values recorded before the run were:

| Artifact | SHA-256 |
|---|---|
| App executable | `7473966d00d3075a63a0b742b8b5a13795ac207d3b7676e0cd65716a1bcd159d` |
| Capture helper | `bc7479397342ce21c5565c01c28a6c63f3af14b7d07e394bc7c591adc0dfcca7` |
| Agent | `6236a6062af26e6a9aa3acd552d7305e78197cdf16ad60d11fdf68ce13fa5de7` |

## Release Boundary

The qualification capability `--live-overlap-qualification` is compiled only
into debug helpers. `scripts/test-release-ocr-killswitch.sh` proves that the
release helper excludes that flag while production source defaults
`CascadeTwiceOCREmitter.killOcrEmit` to `false`. The emergency switch branch
remains tested and can be re-engaged without redesigning capture.

The production TCC monitor's live revoke-and-two-sample-restore path remains a
separate unproven release hardening case. It is not inferred from a successful
initial grant or from this capture qualification.
