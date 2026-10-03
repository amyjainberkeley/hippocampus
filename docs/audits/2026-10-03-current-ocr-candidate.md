# Current private OCR and Recall candidate

Source: `4983f6cbeb376125b0df5b9125741047015c52d3`.

A new complete private Hippocampus 0.2.0 (build 2) candidate now contains both
the OCR repairs and the separate Control–Shift–Space Recall shortcut. The
previous `2f4293c` signed candidate is preserved with its original provenance;
it has not been overwritten or relabeled. Neither candidate is installed or
available as a public download.

## Qualification

All five release-build commands passed, covering both Rust shipping executables
and all four Swift packages. Builds used the existing incremental caches, an
explicit minimal environment, the macOS 14 deployment target and two jobs.
The production assembler then signed a new complete app with Developer ID,
including the OCR runtime, Safari extension and Sparkle components. It verified
nested signatures, the host/extension App Group, required model contracts,
resource paths and release-documentation gates. Optional BERT NER and Qwen
artifacts are absent; Tier 1 extraction and extractive briefs remain available.

The unchanged mandatory 20-second launch gate passed in a disposable home,
with first-run onboarding attached. Its cleanup left no candidate process
running. This is a structural startup check, not a visual onboarding, physical
keyboard, Keychain continuity or live capture test.

A separate post-assembly provenance check matched the exact source SHA, full
source digest, all six shipping executable hashes and complete payload digest.
Deep strict signature checks passed both before and after running the actual
embedded OCR executable. No source or packaged file changed during qualification.

| Synthetic fixture | Result | Elapsed |
| --- | --- | --- |
| 12-pixel chat | 10/10 exact lines, no extras or character errors | 3.427 s |
| 12-pixel code | 8/8 exact lines, no extras or character errors | 3.003 s |
| Blank 3840×1 | No text | 0.465 s |
| Blank 1×3840 | No text | 0.483 s |
| Blank 3000×20 | No text | 0.474 s |
| Blank 20×3000 | No text | 0.492 s |

Every worker invocation kept the original 30-second deadline and used only
fabricated pixels through stdin. These are the first probe calls to this copy,
on the same Mac that had already exercised previous runtimes. They do not
establish cold-machine performance, general screenshot accuracy or total-process
memory limits. The earlier fresh-runtime timeout remains recorded in the
[resize audit](2026-10-03-ocr-resize-bounds.md).

The [machine-readable receipt](../release/candidate-0.2.0-4983f6c-2026-10-03.json)
binds this candidate to its source and payload. Source regression checks remain
those in the [shortcut](2026-10-03-recall-shortcut.md),
[OCR quality](2026-10-03-ocr-quality.md),
[resize](2026-10-03-ocr-resize-bounds.md), and
[storage](2026-10-03-storage-regressions.md) audits; no broad suite was repeated
for this build-only follow-up.

## Remaining qualification

The candidate is signed but **not notarized, installed or public**. The previous
notarization-profile failure is still pending the owner's unlock; no new profile
lookup or credential replacement was attempted. Live shortcut delivery and
parent/onboarding event ownership, OCR result/copy/cancel UI, Screen Recording,
clean-machine startup, controlled installation, store upgrade and rollback still
need qualification. The known unbundled Apple Vision fallback failures remain
open and are not hidden by packaged-worker success.

The installed app manifest still identifies `f4f7bf1`, version 0.1.0. Owner
settings, permissions and private memory were not changed. Existing screenshot
text and search indexes remain original evidence; this candidate does not
silently rewrite them. Superapp and all website/email work are unchanged.
