# Recall and product clarity

## Acceptance order

1. Prove the owner's already-completed focused-window test reached durable
   storage, recall and agent context. Do not reset permissions or request a
   repeat without a diagnosed need. Keep screenshot readback separate from
   text proof.
2. Make literal search predictable. Apply app/date constraints before the
   result limit; offer related-context retrieval explicitly. Add regressions
   for filter starvation, stale searches and missing literal terms.
3. Load the selected memory's stored text on demand instead of presenting a
   280-character list preview as the entire record. Bound reads and reject
   stale results after selection changes.
4. Give each native destination one purpose. Remove the repeated filmstrip,
   redundant sidebar focus targets and ambiguous source status decoration.
   Preserve keyboard navigation and a smaller usable window.
5. Replace the promotional website artwork/copy with a short product
   explanation, a synthetic-data product example and the engineering trail.
   Preserve release/privacy qualifications outside the homepage narrative.
6. Publish a newcomer reading path and an honest, commit-linked development
   history. Document actual storage and inference costs, not planned behavior.
7. Run integrated tests, rebuild/sign/notarize, install without replacing
   memory or keys, and verify the installed artifact. Publish the checked
   source checkpoint to the existing development branch and website privately.

## Boundaries

- Source, installed application, website and public release are different
  artifacts. Record each separately in `docs/STATUS.md`.
- Screenshot counts and episode wall-clock spans are not measured active
  time. A time-allocation chart requires durable activity measurement and
  coverage accounting first. Never imply a messaging app is a distraction
  or a visible task is complete without user-confirmed evidence.
- Improved recall does not qualify an answer as true. Preserve citations,
  unverified/related labels, and abstention.
- Focused-window privacy remains in force. Do not broaden capture to hidden
  tabs or neighboring windows as an OCR workaround.
- Existing age retention is not a disk budget. Session linking is not image
  compression. No silent evidence deletion to satisfy a storage target.
- All screenshots used publicly must contain synthetic data. Tests run with
  an allowlisted environment; no keys or raw personal memory enter artifacts.

## Evidence At Plan Start

- The owner's existing foreground fixture is present across store, recall and
  agent context. The bounded proof remains incomplete because a query reaches
  its result cap and its interface cannot authenticate a screenshot readback.
- The FFI lexical path applied filters after limiting results.
- Native list/detail records exposed the same 280-character snippet.
- Hosted onboarding tests pass at `13e7f7a`; older hosted Vision performance
  and release-contract failures still need diagnosis, not skipped assertions.

## Executed Checkpoint

Steps 2-6 are implemented and published in `c5a8774` and the adjacent website/
guide commits. The native update is locally tested, signed, notarized and
installed; website version 4 is deployed privately. Step 1 has positive evidence
from the owner's original fixture but remains partial for fresh post-install
capture and screenshot readback. Step 7 is complete for local installation and
source/site publication, not public distribution: hosted capture and retention
checks are still red, and the release-model and second-Mac gates remain open.
See [STATUS](../STATUS.md) and the [review](../audits/2026-09-07-recall-usability.md)
for test scope, failures and artifact identities.
