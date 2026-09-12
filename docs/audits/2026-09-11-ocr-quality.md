# Screenshot OCR quality repair — September 11

## Changes

Focused captures now retain native Retina pixels up to a 3840-pixel long edge
(previously 1920). The signed app bundles RapidOCR 3.9.2, PP-OCRv6 small detection
and recognition weights, and ONNX Runtime 1.30.0. App assembly requires a worker
whose complete runtime inventory, source inputs and model hashes verify.
Native code is signed inside-out before embedding. An unbundled development
capture helper retains the existing Vision engine.

Only inward-rounded pixels within the admitted ROI enter a one-shot child over
anonymous pipes. Results return in normalized original-image coordinates.
Neither source images nor recognized text are written to temporary files or
sent to a service. Runtime model download is disabled. The reply has a 1 MiB
cap and 4096-line cap. A 30-second outer deadline covers cold dynamic-library
startup and inference, with child kill/reaping on deadline or capture stop.
The existing four-job queue and cascade-twice admission/retention paths remain.
At the maximum square canvas, each BGRA surface is about 59 MB; higher fidelity
and model inference deliberately cost more RAM/CPU than the previous path.

All recognition candidates, including confidence below 0.5, reach the privacy
scan. RapidOCR's default confidence filter was found in independent review and
removed: dropping a low-confidence secret before the scan could otherwise let
the associated image pass retention. No generative rewriting or guessed text
is added. Text inside a screenshot is untrusted evidence, not instructions.

## Measured accuracy

The committed benchmark creates synthetic 2560×1600 screenshots containing ten
fixed chat messages in 10-, 12- and 16-pixel Arial text. These results are from
the actual production Vision runner with its existing one-second budget and
the standalone frozen Paddle worker, measured before the confidence-filter
correction; the corrected worker also passes the exact same 30-line regression.

| Pipeline | Exact lines / 30 | Per-source-line character errors / 828 |
| --- | --- | --- |
| Previous Vision pipeline at 1920 pixels | 19 | 53 |
| Vision at native pixels | 23 | 48 |
| Paddle at 1920 pixels | 21 | 24 |
| Paddle at native pixels | 30 | 0 |

The final chat regression preserves all expected messages in order, not just
selected keywords. Separate small-code probes contain real punctuation and
identifiers; errors remain, especially at ten pixels. This is not a claim of
100% accuracy across arbitrary images, fonts, languages or degraded captures.
Per-line edit distance measures recall; benchmark output also reports returned
line count, because extra/duplicate observations must not disappear from the
measurement. Vision may return duplicate supplemental passes that are compacted
later by the existing memory-text stage.

Typical frozen-worker runs on this Mac were about 1.1–1.7 seconds for these
fixtures; initial dynamic loading after rebuilding exceeded the original
15-second experimental budget. A subsequent first run took 4.3 seconds. These
are measured development observations, not a startup SLA. The larger deadline
must never lengthen capture shutdown; a regression proves stop kills/reaps the
child promptly instead of waiting for the OCR deadline.

The user's attached screenshot was tested locally and showed improved recovery
of tiny embedded messages, with remaining transcription errors. Its private
content and derived outputs are not part of the repository or benchmark.

## Verification and scope

- Full capture-helper suite: 824 tests, zero failures after lifecycle changes.
- Python worker/build checks: 11 tests, zero failures, including exact synthetic
  chat, blank image, cropped bitmap parsing, low-confidence privacy preservation,
  offline networking rejection and collected-library tamper detection.
- New Swift process tests cover cropped pixel content/box mapping, malformed
  output, excessive output, missing executable, hung-child deadline and shutdown.
- Native sizing regressions reproduced the old 1920 cap, then passed at 3840.
- Release contracts: 230 checks passed. Release-safety tests: 16 passed.
  Product-source and artifact provenance checks passed.
- Independent review identified the confidence filter and incomplete frozen
  inventory checks; both were fixed and covered.

Signed embedded-worker inference, assembled app qualification, installation and
hosted checks are separate gates recorded in STATUS as they complete. Historical
OCR is not rewritten by this change. Old captures may already have lost pixel
detail. No migration, user database modification or permission change is made
by these source edits.

Upstream: [RapidOCR](https://github.com/RapidAI/RapidOCR),
[PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR),
[ONNX Runtime](https://github.com/microsoft/onnxruntime).

## Packaged runtime follow-up

The first parent signature failed because `Contents/Helpers` made codesign
interpret a dependency's `.dylibs` directory as a malformed nested bundle.
The runtime now lives under `Contents/Resources/HippocampusOCR`; every native
library remains individually signed and the entire tree is sealed by the
parent signature. The corrected layout passes deep, strict signature validation.
The seven Swift adapter tests pass after updating executable discovery.

An unnotarized signed standalone runtime took 43.8 seconds on its first launch,
with sampling showing dyld code-signature validation. Subsequent runs took
8.7–10.9 seconds during concurrent release compilation. These measurements do
not qualify first-run performance: the final notarized embedded runtime must
still be tested against the 30-second capture deadline before installation.

## Signed candidate qualification

Candidate `f4f7bf1` passed deep/strict signatures, the disposable-home launch
check, notarization (submission `5a8f11f8-eda4-45b9-be86-84cf1a984f18`), stapler
validation and Gatekeeper. Actual Swift-to-embedded-worker inference recovered
10/10 synthetic chat lines in 20.2 seconds before notarization and 24.9 seconds
while final signature assessment ran, both below the unchanged 30-second bound.
A separate executable-layout probe confirmed `Bundle.main` resolves to the
outer app for a nested `Contents/MacOS/MCICaptureHelper` executable.

The synthetic app assembly suite now supplies an OCR worker fixture and asserts
missing workers stop assembly: 16 tests pass. Hosted CI exposed pre-existing
real Vision completeness assumptions at a one-second deadline; local reruns
under load also failed. A trial larger functional-test budget did not resolve
all failures and was reverted. No assertions were removed and the production
Vision deadline was not changed. New Paddle adapter tests pass in that hosted
run. Full hosted green status is not claimed.

The notarized app is ready for a controlled installation after clean Quit.
CUA selection by name, bundle ID and exact installed path could not access the
menu-bar app. The owner was asked to use Quit Hippocampus. No database backup,
replacement, migration or historical OCR rewrite has occurred at this point.

Final warm embedded-worker run: 10/10 exact chat lines in 4.587 seconds, no timeout.
The staged copy also passes deep/strict signing and stapler validation.
