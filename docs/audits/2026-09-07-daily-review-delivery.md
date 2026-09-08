# Daily Review Delivery

This checkpoint implements the owner's request for a usable daily surface,
distinct navigation, selected context sharing, and a simpler product website.
It does not close the screen-memory acceptance gates.

## Product Changes

- Daily Review replaces the overlapping Now/Brief sidebar destinations. Search
  starts with a query; History remains chronological; Sessions groups evidence.
  Existing Brief requests still open the latest saved brief's day and draft.
- Last saved context, an observed app return, and a gap between available screen
  samples link back to evidence. Imports do not establish screen activity. No
  screenshot count is turned into work time, completion, or productivity.
- Current capture health and Handoff sit in the top toolbar. Handoffs preview
  up to 24 rechecked excerpts, read bounded full text, strip internal headers
  before shortening, and revalidate identity before copying or saving.
- The preview uses Foundation's Markdown parser for display only. Captured
  syntax stays escaped; links and image attributes are removed. Exported
  Markdown and its citation/revalidation rules are unchanged.
- The website leads with "Memory for your Mac," an actual Daily Review image,
  and short setup, privacy and source links. The app image uses a disposable
  synthetic store, not the owner's memory. Full-size inspection is available.

## Review Corrections

Independent review found and verified four corrections: popup-only commands
must preserve the selected workspace; legacy Brief requests must preserve the
saved date; a 24-excerpt sample cannot establish gaps in a dense day; and a
long metadata header cannot replace the useful body in exported context.
Regressions cover a 480-minute dense day, long headers, deleted/replaced IDs,
stale day navigation, and changed evidence after preview.

## Verification

The optimized Recall suite passes 497 XCTest cases and three Swift Testing
cases; the optimized parent suite passes 334 tests. The release contract passes
224 assertions and all sixteen release-safety regressions pass. Native
interaction in a disposable development store verified distinct
destinations, a literal "keyboard" search finding the two expected fictional
records, clickable daily observations, authenticated image display, a readable
handoff, and a 10,427-byte export through the native Save dialog. These are
synthetic UI checks, not screen capture qualification.

The website production build, TypeScript, scoped lint and six rendered-route
contracts pass. Mobile visual checks at 390 pixels show the real image and
working navigation. Desktop DOM checks at 1440 pixels find loaded images and
no horizontal overflow. The browser tool's desktop screenshot is clipped to
the physical panel, so full desktop visual qualification remains limited.

The existing isolated clean-home flow passes initialization, synthetic wire
ingestion, indexing, recall, context, deletion and uninstall. A development-only
six-frame review fixture has six passing unit/CLI tests. It creates fictional
app returns and a known gap without manufacturing screenshot files.

## Reliability Findings

The installed supervisor exhausted a lifetime allowance of ten retries. The
observed sequence contains eleven stream-stop exits and ten replacements,
including runs of about 95 minutes and two hours. Parent liveness alone hid
the absence of its helper and writer. Recovery now replenishes the retry budget
after five minutes of a ready, committed generation, measured with a monotonic
clock. Rapid failures retain ten attempts with exponential backoff capped at
60 seconds. Exhaustion gets an explicit menu-bar error. Independent review
found no P1/P2 issues; fifteen focused regressions cover stable runs,
startup/backoff exclusion, retired generations, pause, explicit stop, shutdown
and permission revocation.

The original stream-stop cause remains unknown. A generic stream-stop error
does not identify a WindowServer, permission, or teardown fault. The writer's
`helper_disconnected` receipt records its pipe closing, not the underlying cause.

The updated screen-only fixture emits bounded, content-free system PID/window
and AppKit observations. Its headless exposure, text-integrity and receipt
checks pass; CI now runs all three suites. The automated live attempt ended
without generating a phrase: macOS reported a different foreground process
despite the tool being able to address the fixture's controls. This explains
that attempt's lack of exposure, not the older missing-event problem.

## Still Open

- A fresh screen-only phrase with its matching encrypted image, restart readback
  and approved-client citation has not passed Gate 1.
- The full installed privacy/recovery matrix, overnight reliability, and
  second-Mac installation/update continuity remain unqualified.
- Hosted OCR completeness remains failing; no accuracy threshold, timeout,
  capture exclusion or privacy check was relaxed here.
- Native interaction still emits intermittent AttributeGraph cycle warnings.
  The checked actions completed, but this is not a zero-warning claim.
- Semantic daily synthesis, measured active intervals, confirmed commitments,
  a total storage byte cap and public model distribution remain separate work.

Use [STATUS](../STATUS.md) for the exact source, installed artifact, website
deployment and public-release states. No DNS or audience changes are included.
