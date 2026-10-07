# October 3 OCR model-input bounds

While qualifying screenshot re-reading, we found that the pinned RapidOCR
preprocessor could expand valid narrow capture regions beyond the worker's
input cap. A 3840×1 image requested a 115200×32 resize; 3000×20 requested
4512×32. The detector independently attempted to upscale the short edge to
736. Regression probes intercepted these allocations before creating them.

The worker now preserves original pixels through the global preprocessing
stage and uses a per-engine detector resize. It retains normal short-side
upscaling where possible, rounds to the model's 32-pixel alignment and caps
both detector edges at 3840. Original-image crops and coordinate mapping remain
in RapidOCR's existing pipeline. Its hidden global resize and vertical padding
are disabled. No upstream package files are modified.

Recognition padding also depends on the widest crop in a batch. An oversized
recognition width now raises a failure before allocation. The entire reading
fails; individual candidates are not removed and partial results do not reach
the parent. All low-confidence candidates from successful readings still reach
the raw privacy scan. The 30-second deadline, offline enforcement, models,
reply/count limits and historical evidence are unchanged.

## Qualification

- The two new resource regressions failed against the previous implementation
  before the fix, with oversized allocations intercepted. The final pinned
  worker/build suite passes all 15 tests in 17.209 seconds.
- Tests cover both strip orientations, non-aligned dimensions, full preprocessing
  flow before inference, batch failure propagation, a real narrow text line
  with original-image coordinates, and exact chat at 10/12/16-pixel fonts.
- Fresh independent review found no actionable issues after checking the
  actual pinned dependency's resizing, mapping and exception behavior.
- The frozen worker was rebuilt and its source, models and complete native
  runtime inventory passed verification. The **first fresh-runtime invocation
  exceeded the unchanged 30-second deadline**, even with a blank strip. That
  failure is retained; the successful later run does not erase it. Cold-start
  latency still needs diagnosis and qualification in the signed application.
- A subsequent warm run returned no text for all four blank strip orientations
  in 0.788–2.417 seconds. It read 10/10 synthetic 12-pixel chat lines in 4.842
  seconds and 8/8 code lines in 5.925 seconds, with zero measured character
  errors or extra lines. Each subprocess kept the same 30-second timeout.
- The production authenticated-image provider → native screenshot re-reader →
  newly frozen worker → raw/cleaned privacy review returned both fabricated
  expected sentences exactly, with no omitted readings, in approximately two
  seconds. This local native probe does not verify the locked window's final
  visual state or repair historical search snippets.

## Boundaries

This prevents the reproduced model-input expansion; it is not a measured upper
bound on total process memory or a latency guarantee. Very thin pixels contain
little recoverable text. Extreme recognition crops fail rather than invent a
reading. Broad language, rotated-text and real-capture accuracy still need
qualification. Synthetic fixtures and logs stayed local; no personal screenshot
or memory was published or sent to a provider.

The installed owner application, settings, historical transcripts/search index
and public downloads remain unchanged. The earlier full-helper Apple Vision
fallback failures, locked final UI inspection and Screen Recording permission
gate remain recorded in the preceding OCR audit and STATUS.
