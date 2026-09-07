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

## Residual Risks

The unchanged focused-child reader collapses some errors/type failures to nil.
The unchanged array reader treats some malformed successful responses as empty.
The separate descendant-subrole signal still has error masking after traversal
progress. This patch does not establish that all AX failures are fail-closed or
qualify the broader privacy/recovery gate. These paths need their own scoped
regressions and review before public release. Hosted OCR deadline and accuracy
failures remain separate blockers.
