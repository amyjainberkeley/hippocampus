# Optional Accessibility Labels

## Finding

The keyword backstop in `AXSubroleProbe.identifierRegexSignal` used a
string-or-nil reader for optional identifier, title and placeholder attributes.
That erased the distinction between a documented absent attribute and an AX
messaging failure. An ordinary text area without any of those labels became
unknown and could not pass the capture cascade. Conversely, a readable ordinary
label could hide a real error in a sibling or visited child.

Apple's local SDK `AXUIElement.h` distinguishes `attributeUnsupported` and
`noValue` from messaging, invalid-element and API failures. Absence establishes
only the absence of a keyword in that optional metadata, not the safety of the
field or window. Existing secure-subrole, hidden-value, descendant, browser,
source and post-OCR checks remain separate requirements.

## Correction

- Preserve each optional string attribute's AX result alongside its value.
- Treat documented optional absence as negative keyword evidence.
- Treat successful non-string/missing payloads and actual AX failures as errors.
- Preserve errors across ordinary siblings and visited children.
- Require a readable nonempty role before deciding whether traversal is needed.
- Keep positive secure-keyword evidence dominant and stop subsequent AX reads.

Fourteen tests cover the classifier and its production keyword traversal using
injected attribute readers. They perform no live AX attribute queries. The
initial eleven cases produced thirteen failing assertions against the old
behavior; a later short-circuit case separately failed with three reads instead
of one. The independent source review found no blocking issue in this scope.
The final optimized capture suite passes 707 tests locally. Hosted OCR failures
are not waived by that local result.

## Proof Boundary

The screen-only fixture recorded twenty seconds of sampled active/key/visible
text-focus state, but no event was returned for its source app. Recorder
suppression was observed. This makes optional-label handling a plausible
contributor, not a proven explanation of every missing event. A fixture's own
AppKit state does not prove that the helper successfully read its AX attributes.
The signed installed candidate still needs the complete screen, encrypted-image,
search, restart and approved-client test in the [gate ledger](2026-09-07-observable-gates.md).

## Follow-Up Read And Traversal Corrections

The initial correction left three independently reproducible risks: failed or
malformed focused-child reads became nil, malformed successful child arrays
became empty, and descendant errors could disappear after benign progress.
The follow-up preserves those errors through both backstops. Valid children
from a mixed array can still establish secure evidence, but cannot erase its
incomplete status. Arrays are inspected only up to the existing 32-node bound.
Uninspected queued work beyond the node/depth limit remains unknown; a proven
leaf exactly at the bound can still be negative. Secure detections still win.

Twenty-two injected-reader regressions cover malformed shapes, actual error
codes, mixed arrays, secure-positive precedence, cycles and exact/over-budget
trees. They query no live app. The final optimized helper suite passes 737 tests
locally; installed live qualification is separate and remains open.

## Content-Free Health Diagnostics

The helper now has a separate health sink reusing the probe's existing results.
It accepts only numeric AX statuses, booleans and outcome enums. It cannot
receive a window title, identifier, value, OCR text, URL or screenshot. Skipped
backstops are explicitly unobserved, not mislabeled negative. Unknown results
produce at most one local stderr line per thirty seconds of monotonic uptime,
even if the error changes on every frame. The limiter is lock-protected;
healthy/secure classifications do not consume its budget.

Eight tests cover exact output, skipped checks, repeated/changing failures,
invalid/regressing clocks, concurrent calls and production probe wiring. The
initial reporter tests produced ten failures; the wiring test separately failed
when its callback was absent. Review replaced that test's real system focus
query with injected error, absent-focus and malformed-focus outcomes. Its
initializer regression produced six failures when the injected reader was not
used. All eight pass after implementation, without querying a real app. These
are diagnostic contracts, not evidence that any owner's screen was read.

## Residual Risks

Bounded traversal does not guarantee bounded wall-clock latency for every AX
server. No live protected-field, lock, permission-revocation or recovery matrix
is passed by these synthetic tests. More conservative error and exhaustion
handling may suppress complex or malformed app trees; do not replace unknown
with safe to improve apparent capture yield. Hosted OCR deadline and accuracy
failures remain separate blockers. Installation identity and the latest actual
screen proof are recorded in the gate ledger, not inferred from this source.
