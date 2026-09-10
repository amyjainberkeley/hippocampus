# Hippocampus Status

_Updated on 2026-09-09; qualification scope is recorded per checkpoint._

Audited code baseline: `c9b323d`

This SHA is the immediate committed baseline before this status refresh. The
release assembler requires it to be an ancestor of `HEAD` and no more than
three commits behind. This file is the repository's canonical product and
release truth; README, design docs, release notes, and UI copy must not claim
more than this page.

## September 9 Installer Repair

The [installer checkpoint](audits/2026-09-09-installer-experience.md) replaces
the nested H artwork with a simple brain mark and repairs the oversized DMG.
The 640x420 layout is generated and read back headlessly, with clear update
instructions and accessible legal terms. Builds no longer detach similarly
named user volumes or silently ship a missing layout. Two hash-pinned Python
packages are build-only; neither is bundled into the app.

The parent now accepts genuine macOS core/quit Apple events through the existing
verified supervisor shutdown. Its full optimized suite passes 342 tests, with
eight new request-gate regressions. Generic unrequested termination remains
blocked. This source correction does not change the already-running old app.

Local checks pass 11 layout tests, nine runtime/cleanup checks, two installer
brand checks, 11 Recall design tests, 230 release-contract assertions and 16
release-safety tests. The layout test includes remounting a synthetic disk image;
final candidate Finder inspection and notarization are not yet recorded here.

The installed build still reports `fe90a3d`. Its background parent/helper/writer
remain active even with no Recall window. Finder's refusal and surviving MCP
readers require the [controlled upgrade](release/OWNER_UPGRADE_2026-09-09.md),
not a forced overwrite or blanket client shutdown. No private database backup,
migration, installation, key or permission change has occurred at this checkpoint.

## September 9 Work Memory

The [work-memory checkpoint](audits/2026-09-09-work-memory.md) separates Today,
Search and History, nests Sessions, adds query-centered lexical excerpts and
wires independent measured activity through the helper, encrypted store, FFI
and Today. App totals and the longest measured stretch link to their intervals.
Missing time remains unknown; these are not productivity or completion scores.

Additional work hardens scoped memory corrections, activity deletion against
late writes and bounded helper transport. A versioned sequential evaluation is
a deterministic policy comparison, not demonstrated real-agent learning.

A controlled regression reproduced an unchanged-screen loss: the sole retained
pixel retry ran while Vision's timed-out attempt still occupied its lane. The
worker now waits boundedly for availability before consuming that queued retry.
The recognition deadline and privacy path are unchanged. Focused recovery tests
verify an encrypted image linked to the emitted event, with negative stop,
secret and hung-work cases. This is not a substitute for the live capture gate.

Optimized Recall verification passes 526 XCTest and three Swift Testing cases. The earlier debug run
passed 527 before two further stretch regressions; preview-only tests are
excluded from optimized builds. Parent tests pass 334 cases; release-contract
and release-safety checks pass 230 and 16 respectively. The final full Rust
workspace passes 2,130 tests (nine ignored); strict Clippy and formatting pass.
The final optimized helper suite passes all 817 tests twice in separate
processes, including real Apple Vision fixtures, after concurrent builds end.
Earlier runs failed 30 OCR assertions across 804 tests and one across 13 in an
isolated rerun. Baseline recognition itself can exceed the one-second budget
under observed conditions; the failures and cold-start measurements remain in
the audit. Test-lane cleanup and the separate static-screen recovery correction
do not change the recognition deadline, quality assertions or privacy rules.
No universal OCR/hardware or live-capture qualification is claimed.

**Source `fb73f77` is published** on `codex/hippocampus-v1` in
`amyjainberkeley/hippocampus`; PR25 remains draft. Its private release-profile
candidate is signed with Developer ID `BV6KGKFKP4`, notarized and stapled.
The app inside the installer passes strict nested-signature, Gatekeeper and
source/payload provenance checks; disposable-home startup and onboarding pass.
The actual candidate's bundled Arctic model also passes all seven strict
runtime-quality checks, including the 50-sentence reference on CPU and Neural
Engine. Missing-model skips are disabled for that run. This verifies the model
artifact, not end-to-end retrieval accuracy.

Owner installer: `/Users/amy/hippo-work/releases/2026-09-09-fb73f77/Hippocampus-0.1.0.dmg`.
SHA-256: `736f68d54c99014c221ebaa9b593579c7c76d8ca688de0a824768344057e41b1`.
Product-source digest: `9625269a42430bf232f65685b7a491e917fe025eda0ded6f9db9569e9de7150f`.
Apple accepted app submission `7a5b7feb-59f8-4ac0-857d-72f2bbb9a23e` and
installer submission `621994f5-85d7-408d-9d0c-adb98ce5e838`.

**Installed app remains `fe90a3d`**, not this candidate. Its manifest and running
parent/helper/writer/Recall mappings were checked again. The native UI-control
attempt timed out; the owner was asked to choose Quit before the controlled
upgrade. No private database backup or migration has been performed. Follow the
[owner upgrade procedure](release/OWNER_UPGRADE_2026-09-09.md); an archived old
app alone does not make schema downgrade safe. Website version 5 remains
owner-private and unchanged. No main merge, public installer or domain launch
is implied.

Hosted `fb73f77` passes Rust tests/format/Clippy, advisory, parent, Recall,
onboarding and installer-smoke checks. Capture has **59 OCR-completeness
assertion failures across 817 tests**; the dense single-pass baseline takes
3,620-3,773 ms and cannot fit the unchanged one-second budget. All five controlled
static-screen quarantine-recovery cases pass on that runner. The hosted
release-contract and workflow-validation jobs subsequently passed. The OCR failures
remain release blockers; local passes and notarization do not waive them.

The fresh screen-only proof is still open: automated attempts did not generate
the phrase. A system notification held the actual foreground during the latest
attempt, and the fixture reported itself inactive. No permission bypass or
capture-policy change was used. Authenticated-image readback, restart, actual
client retrieval, live privacy/recovery and second-Mac qualification remain
separate unmet gates.

## September 7 Capture And Recall Corrections

The [capture/readability checkpoint](audits/2026-09-07-capture-readability.md)
adds post-privacy OCR duplicate removal, a bounded hydrated latest-context
preview, and content-free stream-failure diagnostics. Local optimized tests
pass 759 capture cases and 510 Recall XCTest plus three Swift Testing cases.
The release contract passes 224 assertions and sixteen release-safety tests.
No OCR deadline, recognition level, source exclusion or permission is relaxed.

**Current installed app: `fe90a3d`**, at `/Applications/Hippocampus.app`.
The signed app and private installer are notarized and stapled. Strict signing,
Gatekeeper, post-copy provenance and the disposable-home launch check pass.
The prior `0bb07eb` installation is preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-0bb07eb-live-before-fe90a3d.app`.
No memory, key, capture policy or macOS permission was reset.

Private installer: `/Users/amy/hippo-work/releases/2026-09-07-fe90a3d/Hippocampus-0.1.0.dmg`.
SHA-256: `ea6323a5d7843adc7ff32f7db544e8e7b6bc0f11f55ed8d3ec4386c2c878b9a4`.
Product-source digest:
`ae87a41bc552b754db2d57a11ae8c107fe9c7b564fa4dcadcbf174ed4d484521`.
Apple accepted app `ec84f22e-9ff1-418b-b761-d02702e3f4b6` and installer
`85315571-956f-4aed-b356-e23203b03707`.

The new parent, helper, writer and Recall use installed executable mappings.
The helper's capture-enabled readiness generation matches its arguments;
helper output and writer input are connected, and writer/Recall use the same
existing database inode. Eight newer screen-origin events are visible to this
Codex MCP client after installation. The receipt advanced from 913 frames/450
screenshots to 921/452. These are ingestion observations, not phrase/image
identity or restart-readback proof. The UI-control tool still times out on the
installed window; no visual qualification or permission reset was inferred.

A later check captured a real `stream_delegate` failure with
`SCStreamErrorDomain` code `-3815`, mapped by the installed SDK to no capture
source. The supervisor replaced the helper and writer and the new stream
received a callback. The latest stored-frame timestamp still preceded that
replacement, with `failsafe-unknown` suppression at the final receipt read.
Process recovery is observed; resumed storage and why the source disappeared
remain unproven. See the capture/readability audit for the exact distinction.

The final review also corrected test-only stderr temporary files: atomic,
exclusive, no-follow creation with mode 0600, including descriptor cleanup.
A permissive-umask regression failed before the fix; all thirteen diagnostic
tests and the full 759-case capture suite then passed. This test-only follow-up
is not a new installed executable revision.

The previous hosted release-contract run has now completed successfully at
`0bb07eb`. At `fe90a3d`, hosted Recall, parent, onboarding, installer smoke,
Rust tests/format/Clippy and advisory checks pass; capture has 62 assertion
failures across 758 tests, all in OCR completeness. The new release-contract
run remains in progress at this checkpoint. The full runner log identifies an
arm64 `VirtualMac2,1` with CPU/GPU but no advertised Neural Engine, not an Intel
Mac. Accurate recognition alone exceeds the one-second budget on that runner.
Changing compute-device selection did not reliably resolve it. Local passing
tests do not waive that failure or qualify every supported Mac.

Gate 1 still needs a fresh screen-only phrase, matching authenticated image,
restart readback and real client retrieval. Additional stored frames since the
prior install and continued helper replacements are observations, not that
proof. Website version 5 and its private audience are unchanged. Public binary
release, domain launch and the remaining product gates remain separate.

## September 7 Daily Review Delivery

**Installed at this earlier checkpoint: `0bb07eb`**, at `/Applications/Hippocampus.app`.
The source checkpoint is published on `codex/hippocampus-v1` in the canonical
GitHub repository; PR25 remains draft. Strict nested signing, notarization,
stapled ticket, Gatekeeper and post-copy source/digest checks pass. The previous
`4f5c75a` app is preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-4f5c75a-live-before-0bb07eb.app`.
No memory, key, permission or capture-policy reset was performed.

Private owner installer:
`/Users/amy/hippo-work/releases/2026-09-07-0bb07eb/Hippocampus-0.1.0.dmg`.
SHA-256: `caec470b70faaf016f5c5c47db192013d37e57e04bdf51b9ee457a0b84c3620a`.
Product-source digest:
`963b2242d36cceaf5f16dc3bf745023aa0f1200354481584c5462abedecc607f`.
Apple accepted app submission `ab682c77-de82-4566-807c-223dfd685bf4` and DMG
submission `c7050bad-5bec-405f-86bd-e7a564c247de`. This private image uses the
standard Applications drag target and license, without Finder layout scripting.
It is not a public release or second-Mac distribution qualification.

The new app launched its parent, Recall, helper and writer from the installed
bundle. A controlled SIGTERM of that helper produced one automatic replacement
helper/writer generation; its capture-enabled readiness receipt matches the
helper argument. The writer's input pipe matches helper output, and writer and
Recall open the same existing database inode. Post-install ingestion advanced
to 790 frames and 365 screenshots before the interruption. No new stored frame
was established after that restart at the checkpoint read. These observations
do not qualify fresh phrase/image identity, privacy recovery or overnight uptime.

The [daily review checkpoint](audits/2026-09-07-daily-review-delivery.md)
adds distinct Daily Review, Search, History and Sessions destinations; cited
observations of last context, app returns and available-sample gaps; and a
readable, revalidated daily handoff. These are observations, not semantic
truth, measured activity or task completion. Optimized Recall verification
passes 497 XCTest and three Swift Testing cases. Native synthetic UI checks
exercise navigation, text search, image inspection and file export. Intermittent
AttributeGraph warnings remain a recorded UI reliability limitation.

Website source now presents the literal purpose, an actual synthetic-data
Daily Review image and short practical links. Production build, TypeScript,
scoped lint and six rendered-page contracts pass. Installation and website
publication are separate: website version 5 is successfully deployed at
`https://hippocampus-memory.amyjain.chatgpt.site/`, still owner-private.
Its website-rooted source is `fa160610c2400cec58d1723c39959e803ba351c0`, with
the same tree as `0bb07eb:website`. The deployed page and real product image
were checked in the authenticated browser. No domain, audience, public DMG,
main-branch or release-tag change was made.

Live triage found a stopped helper/writer despite the surviving parent: ten
retries were consumed across the app's entire lifetime, including long recovered
runs. The recovery correction replenishes the bounded retry budget after five
minutes of a ready, committed generation and makes exhaustion explicit. The
optimized parent suite passes 334 tests, including the new recovery scenarios.
The release contract passes 224 assertions and sixteen release-safety tests.
The underlying repeated stream-stop cause is not identified. The new
screen-proof receipt distinguishes actual system foreground identity from
background UI control; the automated attempt did not generate a phrase and
cannot close Gate 1. All privacy, recovery and fresh-agent gates remain open.

Hosted tests at `0bb07eb` pass Recall, parent, onboarding, installer smoke,
Rust tests/format/Clippy, advisory scan and workflow validation. The capture
lane still fails: 57 assertions across 737 tests, all in OCR completeness.
The release-contract job is still running at this ledger checkpoint. No
production OCR change or waiver is included. The local website dev server
also emitted multiple-renderer warnings during hot reload; the published
production routes render, but this is not a zero-diagnostic claim.

## September 7 Product Clarity Checkpoint

The next qualification pass uses the owner's ordered
[observable gates](audits/2026-09-07-observable-gates.md). Runtime identity is
established, but the new random screen-only phrase and linked-image/restart
proof remain open. No later product gate is claimed from an earlier fixed-token
test. The intended `usehippocampus.com` launch is deferred; no DNS or access
change has been made.

The initial [Accessibility classifier correction](audits/2026-09-07-ax-optional-labels.md)
shipped in signed owner candidate `48251bd`. Optional absent labels no longer
masquerade as messaging failures in the keyword probe, and actual attribute,
required-role and visited-child errors cannot be hidden by readable siblings.
Secure evidence still wins and stops further label reads. That checkpoint did
not resolve the separate traversal-helper risks or establish live fixture
capture. Its optimized capture suite passed 707 tests locally, including
fourteen new classifier/path regressions. Installation and signature verification
do not establish that the screen-only capture gate passes.

**Earlier installed application: `4f5c75a`**, superseded by `0bb07eb` above.
Its parent, helper, writer and Recall processes run from that bundle. The helper
and writer share the capture pipe; writer and Recall open the same existing
database. The new helper's generation matches its capture-enabled receipt.
Post-copy strict nested signature, Gatekeeper, stapled ticket and source/digest verification
pass. The installer is private owner qualification only:
`/Users/amy/hippo-work/releases/2026-09-07-4f5c75a/Hippocampus-0.1.0.dmg`.
SHA-256: `36fd2bec645a221ccfc007e170c7eb4895703dbfccab51abda1291891cf06fa3`.
Product-source digest:
`b1f9dd850260163743e6c6f7b3e257787faac3b041f5bafe361af9a0a372bb63`.
Apple accepted app submission `9f7a2398-f868-4452-8c6e-b805a3a165a5` and DMG
submission `e02f8da8-5447-491c-abc0-aa5b7967f409`. The prior live bundle is
preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-48251bd-live-before-4f5c75a.app`.
No memory, keys, permissions or capture policy were reset. Repeated stream-stop
errors observed before this installation remain unexplained. The supervisor
was observed replacing failed children and receiving new stream callbacks;
that is restart evidence, not resumed-memory or full privacy/recovery proof.

A follow-up source correction preserves failed/malformed child reads and
incomplete bounded traversal through both AX backstops. It adds rate-limited,
content-free health diagnostics without extra AX attribute reads. The new
health wiring test uses injected focus results, not the real focused app.
Final optimized helper verification passes 737 tests locally (22 new traversal
regressions and eight health tests). The existing suite still emits CoreData
XPC diagnostics; passing tests do not qualify live capture or overnight health.
These changes are included in the installed `4f5c75a` artifact. Its content-free
diagnostic emitted an unknown descendant-check outcome; that observation is
not attributed to the test window and does not establish its missing-event cause.

The qualification checkpoint adds distinct build/locate/run/consumer gates to
the retention test runner, eleven passing failure-propagation and diagnostic
regressions, and bounded hosted termination diagnostics. The real local
retention contract and all 224 release-contract assertions pass. Forty-one
focused optimized OCR tests pass locally, including timeout quarantine and
recovery. Added OCR diagnostics record the hardware/toolchain, original-pass
timing, deadline status and unobserved passes. Production recognition, deadline,
confidence and privacy policy are unchanged. These changes instrument the
hosted failures; they do not establish that either failure is fixed. The
standalone screen-only fixture is not part of the installed application.

The first hosted diagnostic run stopped before retention: an existing safety
test compared the entire launcher to its former one-line command. The test now
locates the named gate and checks environment ordering, the clean launcher and
mandatory failure behavior. All 13 release-safety and 11 runner regressions
pass locally after this correction. Hosted fixture termination remains
unresolved until the corrected workflow reaches that gate.

At `347b1b9`, the hosted retention contract passed both Swift fixtures and the
Rust compatibility test (1 passed, 0 failed, 0 ignored). The original SIGKILL
cause was not reproduced or explained. The later clean-home test failed at its
synthetic brief seed: the production drain had already created today's brief.
The fixture now uses a separate historical date without disabling overwrite
protection. Six deterministic regressions and the complete isolated local
clean-home flow pass. Hosted clean-home verification then passed at `1c32747`
and `48251bd`. Synthetic wire injection is not screen-capture qualification.

The next hosted failure was app assembly: the workflow had built fixtures but
not all required app executables. It now builds the four Swift products and
Rust executables before the unchanged mandatory assembly gate, with two build
jobs. Fifteen local release-safety tests pass, including seven inert execution
scenarios proving that any build or assembly failure stops later work. The
complete hosted release-contract workflow passed at `31f6736`, including app
assembly and clean-home checks. The Recall lane still failed at that revision:
its direct-call stale-search test raced the view model's initial empty-query
debounce. The test now consumes initialization and explicitly releases the old
read after the new result, with no production-search change. All twelve focused
Recall tests pass in independent local verification. Hosted Recall, onboarding,
parent, installer smoke, Rust and the complete release-contract workflow pass
at `4f5c75a`. Hosted OCR remains the failing lane.

The screen-only fixture now records sampled active/key/visible/text-focus
exposure, resetting on focus loss or a gap over two seconds. Its calculation
has deterministic coverage and a hosted check. A fresh phrase reached twenty
seconds in those native observations but still returned no event for the
fixture app through MCP. The recorder reports fail-safe suppression. Capture,
linked-image readback and restart qualification remain **open**; foreground
observations cannot substitute for an actual stored event. That twenty-second
exposure preceded the current installation. A post-update automated click/hold
still reported zero foreground seconds, and the fixture's MCP query returned
no event. The owner's manual foreground check is pending; the new build has
not passed the exposure, capture, image or restart proof.

Hosted OCR at `347b1b9` had 49 assertion failures across 692 tests, all in the
completeness suite: deadline failures and empty consequences, supplemental-pass
assumptions, and nine non-timeout completeness/accuracy failures. Correct text
can have lower confidence than incorrect text. A synthetic compute-device
comparison and failure-only isolated diagnostic are added. At `1c32747`, 52
assertions across 693 tests failed in completeness. Explicit CPU/GPU routing
did not reliably meet the unchanged deadline. The capture lane remains red at
`4f5c75a`: 53 assertions fail across 737 tests, all in OCR completeness. No
production OCR fix or deadline waiver is established.

The website source replaces the conceptual glass artwork and curved mark with
a flat H, a compact product explanation, an actual synthetic-data example and
four practical uses: finding captured text, revisiting work, reviewing a cited
daily draft, and handing relevant context to an agent. Release and privacy
qualifications remain on the linked pages. Production build, TypeScript and
scoped lint pass. Version 4 is deployed successfully at
`https://hippocampus-memory.amyjain.chatgpt.site/`, still owner-private. Its
website-rooted source is `43e3ad4`, exported from canonical commit `f3a689c`.
All four pages and the current product image returned HTTP 200 in authenticated
checks. The image is an unedited screenshot of the actual optimized Recall
interface built from `c5a8774`, using a disposable synthetic store. It shows
Text search and selected full-text evidence, not personal memory. Native UI
interaction was checked; no website browser visual QA was performed.

The README now gives a newcomer reading path. `docs/guide/` explains the
architecture, actual commit history, implemented storage policies, local compute,
and remaining distribution obligations. It distinguishes session linking from
storage compaction and hypothetical growth arithmetic from measured usage.

The owner's already-completed foreground fixture is now present across durable
storage, recall and agent context. The bounded check identifies the same event
across surfaces and reports no observed background marker in its returned
evidence, but its result cap prevents exhaustive negative qualification.
Authenticated screenshot readback is still not established. Do not ask the
owner to repeat the foreground exercise or claim the full gate passed.

### Earlier Native Qualification (Superseded Installation)

The following native fixes were installed in `c5a8774`: filter-before-limit
lexical search, explicit Text/Related search, selected-event full-text
inspection, workspace simplification, and bounded managed-storage accounting.
Hosted onboarding, parent, Recall, installer, Rust tests/format/Clippy, cargo
audit, workflow checks and PR title pass at `f3a689c`. Capture still reports
56 failures across 691 tests on the hosted Mac; the retention-contract run
still exits 137 after compiling the parent fixture. These failures remain
release blockers. See the ordered plan in
`docs/plans/2026-09-07-recall-and-product-clarity.md`.

Additional native review found filtered-history starvation, next-midnight
inclusion, misleading rank percentages, a snippet-only screenshot inspector,
compact-window layout instability, valid MCP source IDs rejected by filters,
and a picker that could exceed the 32-source wire limit. Source corrections and
regressions are included in the installed `c5a8774` update.
The review and proof boundaries are recorded in
`docs/audits/2026-09-07-recall-usability.md`.

Fresh local optimized tests pass 324 parent-app and 242 onboarding cases. The
capture suite failed during concurrent builds, then passed all 691 cases on a
separate rerun. This sensitivity remains a performance concern, not a waived
deadline. Initial integrated Recall verification passed 448 XCTest and three
Swift Testing cases before the final filtered-browse and compact-pane additions.
The first full Rust run found an intermittent writer-lock reacquisition failure;
a duplicate-descriptor regression reproduced it deterministically and now passes
with all 19 crash-recovery tests after explicit clean unlock. The full rerun
passes 2,031 tests with nine explicit ignores. After final source-ID and selected
text identity changes, the brain/FFI suites pass 836 tests with one explicit
ignore, including real model-backed retrieval. All-target workspace strict
Clippy and formatting pass. The complete Recall debug suite passes 474 XCTest
plus three Swift Testing cases. Presentation contracts pass 20 checks, and
local release-contract and release-safety checks pass 224 and 13 respectively.
Hosted capture and retention-contract checks remain red at
`f3a689c`; local results do not supersede those failures. See
[capture run](https://github.com/amyjainberkeley/hippocampus/actions/runs/34154561579)
and [release contracts](https://github.com/amyjainberkeley/hippocampus/actions/runs/34154561586).

Synthetic native interaction checks verify Text/no-match/detail, smaller-window
back navigation, distinct destinations, full-text screenshot inspection and
storage breakdown. Later AttributeGraph warnings led to narrower root/overlay
subscriptions: command-list changes no longer invalidate the whole workspace.
The follow-up search/detail/no-match, resize and help/palette pass emitted no
warnings; this is not overnight proof. A command-palette initial-focus issue
was also reproduced and corrected with deferred, cancellable focus. The fresh
optimized build passes all 474 XCTest and three Swift Testing cases. Its actual
command-palette test focused the field on opening and dismissed with Escape
without an extra click; no runtime warnings were emitted in that check. The
Rust workspace release build also completes successfully.

Selected-text responses now verify timestamp and app as well as numeric ID.
This rejects common delete/reinsert races, but an identical tuple can still be
reused; a durable event-generation identity is not implemented. The latest
content-free installed receipt advanced after replacement to 646 stored frames
and 286 screenshots with a write at 19:17:29 UTC. It establishes new ingestion,
not OCR completeness or correct screenshot attribution.

**Earlier installed application: `c5a8774`**, superseded by `48251bd` above.
The optimized app and installer are Developer ID signed, notarized and stapled.
Strict nested signature, Gatekeeper, disposable-home onboarding launch and
post-copy source-provenance checks pass. Installer:
`/Users/amy/hippo-work/releases/2026-09-07-c5a8774/Hippocampus-0.1.0.dmg`.
SHA-256: `9bd1ffe3daf4a8238f25f9bd35c59ce579e048bd82b6f46158cf0013083e018c`.
Product-source digest:
`bc83104929ecae6aef0c74142eb975b9cb5b7d07e8cd5d7db34548fa7bf85764`.
App notarization `e3c22796-6e09-438a-b1c5-94ab2d404acd`; DMG notarization
`c89b9519-b344-4816-8c12-03a6022c1c4f`, both Accepted. The previous live app
is preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-bb02bb4-live-before-c5a8774.app`.
Memory, keys, permissions and capture policy were not reset.

The installed read-only agent still finds the owner's earlier controlled
foreground fixture across durable storage, recall and context with matching
event identity. That is continuity evidence, not a new post-install capture
fixture. A later automated TextEdit exercise did not establish a fresh matching
event across these surfaces; background app control does not prove actual
foreground capture. No fresh fixture success is claimed. The bounded proof
also remains capped and cannot authenticate a screenshot readback.
Production-window inspection through the GUI tool timed out; the interaction
proof above belongs to the optimized synthetic preview, not that production
window. Public binary release remains gated by these qualifications, hosted
failures, second-Mac work and unprovisioned release-model assets.

## Earlier September 7 Website And Memory-Quality Work

At this earlier checkpoint, the website led with local-first personal memory for the Mac and AI tools,
using a paired hippocampal mark and a conceptual transparent-memory illustration.
It explains capture, recognition, local storage and selected context sharing,
with shared navigation, mobile menus and keyboard skip links. It explicitly
discloses focused-window coverage, imperfect OCR, extractive drafts and current
download gates. It does not advertise employee monitoring or completed activity/
commitment features. Source lives in `website/`, not the old standalone checkout.
Production build, TypeScript and scoped lint checks pass. Version 2 is deployed
at `https://hippocampus-memory.amyjain.chatgpt.site`, still owner-private, using
website-rooted source `9e8d3f2` exported from canonical commit `912822f` with
identical tree content. All four pages and both new images returned HTTP 200 in
authenticated owner checks. No browser interaction/visual QA was performed;
the in-app handoff was queued because this task was not foregrounded.

The first hosted release-contract check failed because the macOS runner lacked
ripgrep, producing 201 misleading assertion failures. CI now provisions it
before checks, and the contract script exits before assertions if it is absent.
Both new regressions failed before their fixes. All 10 safety tests and all 224
release-contract assertions pass locally; the hosted rerun remains separate.

Native OCR now preserves the original pass and adds bounded admitted-region
passes inside the existing one-second budget. Synthetic 12-pixel label recall
improved from 0/4 to 4/4 at both 1920 x 1080 and 1920 x 1920. Full optimized
capture tests pass 691 cases; parent tests pass 324. Review caught and fixed a
privacy regression in an initial deduplication attempt: all completed pass text
now remains contiguous, and the real-Vision secret fixture blocks retention.
OCR can still fail or time out, and duplicated observations are preserved for
privacy. Recognition does not expand the focused-window capture boundary.

Pasted boolean words are literal search text. Generated fallback alternatives
use a separate typed, bounded API, preserving the agent's degraded recall and
answer-relation abstention. Daily drafts remove exact browser-menu noise and
potentially clipped final lines without rewriting original source memory.
These are source-tested improvements, not completed semantic understanding,
commitment tracking, or measured activity. The quality report records the
corpora, timings, failed attempts, and limitations:
`docs/audits/2026-09-07-memory-quality.md`.

Hosted checks also exposed stale product-truth assertions, two Swift test-only
Sendable compatibility errors, strict Rust lints, and an unstaged Recall FFI
archive. Corrections preserve runtime behavior and use the supported Recall
build/staging wrapper. The isolated release-safety suite passes 11 tests and
product-truth checks pass. Hosted reruns and the older-runner onboarding
signal-5 failure remain separate from the passing local onboarding suite.
CI now records the actual onboarding toolchain and attempts a bounded LLDB
diagnostic on failure; the cause is not yet established. Local debugger attach
was denied, and no system permissions were changed to obtain it.

Fresh all-feature Rust workspace verification passes 1,992 tests with nine
explicitly ignored model/performance/fixture-dependent cases. Workspace-wide
all-target strict Clippy and formatting pass. The optimized local onboarding
suite passes 241 tests. The staged source secret scan returned zero alerts;
no actual screenshots, memory, credentials or installer binaries are published.

**Earlier installed artifact: `bb02bb4`**, superseded by `c5a8774` above.
The fresh optimized binaries were assembled, Developer ID signed, notarized,
stapled and installed. Strict nested signature, Gatekeeper and post-copy
source-provenance verification pass. Installer:
`/Users/amy/hippo-work/releases/2026-09-07-bb02bb4/Hippocampus-0.1.0.dmg`.
SHA-256: `46c666aed7a70c72e38ae8d48f12b70fabcd5941b76028289ec8f3e0bc6df893`.
Product-source digest:
`05d49db1c9e2848dd712055d98132da7c5907ce6f5821bf0aeaa92dc05f23d9f`.
App notarization `5bac4d1f-3709-4ebf-8d42-f6adb70f0c37`; DMG notarization
`9c6cba79-d2bd-4854-9806-68d383dcd6a1`, both Accepted. The previous live app
is preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-224466d-live-before-bb02bb4.app`.
Memory, keys, permissions and capture policy were not reset.

**Fresh end-to-end capture qualification remains incomplete.** The first
installed generation received frames but initially suppressed every frame,
mostly `failsafe-unknown`. The stored-frame receipt subsequently advanced from
468 to 480 and screenshots from 198 to 205, with a new write at 08:40:27 UTC
September 7. These counters establish new ingestion, not correct recognition
or screenshot attribution. The bounded synthetic-fixture check did not find
its fresh marker in timeline, recall and context together. No authenticated
screenshot readback was established. Background TextEdit control is not proof
of the real foreground window; owner foreground confirmation was requested.
Do not represent this installation as fully live-qualified or expand capture
admission to make the fixture pass.

Hosted checks for `bb02bb4` pass Rust tests/format/Clippy, the parent app,
Recall (including its fixed archive staging), installer smoke and cargo audit.
The capture suite fails 56 assertions on the older virtual Mac: even original
single-pass recognition takes several seconds against the one-second budget.
The actual supplemental-secret privacy fixture passes there. Onboarding still
traps on the older toolchain; its first LLDB diagnostic stopped at exec rather
than the actual crash. The next diagnostic disables that initial exec stop.
Neither failure is hidden, and neither is disproved by the passing local suites.

The hosted release contract advanced past its prior missing-ripgrep failure,
then found the macOS 14 runner's Swift 5.10 incompatible with Swift 6 packages.
The contract job now uses the same macOS 15 runner as Swift CI and records its
toolchain. Both new CI regression checks failed before correction; all 13
isolated release-safety tests pass locally. The hosted rerun passed that
toolchain boundary but was killed with signal 9 after compiling the parent
retention fixture. Its cause remains unproved; the complete local retention
contract passes and the hosted release gate remains red.

Further onboarding review found a real test-isolation defect: the Safari branch
bypassed its injected browser launcher and opened the real application during
unit tests. It now uses that launcher, and the production completion is
explicitly Sendable outside the main-actor view model. A source-boundary
regression failed before the fix; fake-launcher routing and all 242 onboarding
tests pass in both debug and optimized builds. The older-hosted crash mechanism
is still a hypothesis until its actual stopped frame or new suite run supports
it. This follow-up is not yet in the installed `bb02bb4` artifact.

The revised crash diagnostic also revealed that a test bundle is not a directly
executable program. CI now launches the actual `xctest` host with the whole
bundle, uses crash backtraces, disables debugger init files, and passes only an
explicit non-secret environment. The same host invocation successfully ran the
isolated preparation regression locally. No debugger permissions were changed.
Plan:
`docs/plans/2026-09-07-memory-quality-and-website.md`.

## September 7 Source Publication

The desktop history and exact website source now share the canonical
`amyjainberkeley/hippocampus` GitHub repository on `codex/hippocampus-v1`.
Website source lives in `website/`; its original `e50f448` commit is preserved
as a merge parent. At that earlier publication checkpoint, desktop product
sources were unchanged from `7b1fc0d` and the installed binary was `224466d`.
The newer installation is recorded above. Source publication does not promote
`main`, create a release tag, publish a DMG or change website access.
`AGENTS.md` records the owner's instruction to push future versioned updates;
`docs/PUBLISHING.md` documents locations, workflow and the history secret scan.
Live-capture results below remain the prior installed-check record, not a new
capture claim in this source-publication task.

## September 6 OCR, Summary, And Setup Update

Source-tested and installed; live capture qualification is recorded below. Apple
Vision's prose correction inserted spaces into synthetic code. Accurate raw
recognition reduced character edits from 14 to 7 across the same 987-character
12/16/24-point corpus. It is not an all-language accuracy score. No remote OCR,
generated correction, screenshot replacement, or privacy-path bypass was added.
Candidate confidence now comes from the selected recognized text.

Now exports combine the matching saved daily draft with up to 24 sampled source
excerpts, including dates, provenance, Draft/observation warnings, and local
event links. Brief copy/export uses the same bounded format. Captured Markdown
is escaped; unknown author formats remain literal. Day changes, stale reads,
unexpected event IDs and out-of-day evidence cannot silently change the packet.
Brief-only days can be exported. This is not semantic reconciliation or measured
activity, and dense days remain sampled.

Required permission denials stay visible during onboarding and recover after
Settings grants. Encryption preparation gates Continue/Get Started, a resumed
Done step checks the key, failures have retry, and failed completion-file writes
do not mark setup complete. Updater startup preserves saved preferences; private
defaults now live in Info.plist. Live second-Mac and locked-Keychain denial
qualification remains open.

Fresh optimized suites: capture 676; Recall 418 XCTest plus 3 Swift Testing;
parent 324; onboarding 241, all passing. The onboarding full-suite initially
failed five obsolete expectations that denied permissions disappear from the
sequence; corrected recovery expectations and the final full rerun pass. The
initial preparation compile also overlapped a source edit; only the completed
final source build is accepted. Separate coding workers reached their account
limit; integration and review were performed in the main task, not independently
security-certified.

Website source: `/Users/amy/hippocampus-website`. It is an owner-only product,
setup, privacy and release-status preview. Build and TypeScript checks pass;
the updated lockfile has zero reported npm advisories at this check. Its only
product screenshot is synthetic. No user memory endpoint, signup, analytics,
payment flow or installer upload was introduced. Public download is explicitly
unavailable pending qualification and distribution packaging. Release review
also found missing full model-license packaging, unresolved legal-owner review,
UNPROVISIONED immutable model assets and second-Mac/update continuity checks.
These gates were not disabled. The owner-only website is deployed at
`https://hippocampus-memory.amyjain.chatgpt.site`, source `e50f448`. All four
published pages returned HTTP 200 in authenticated owner checks. Public access
has been requested but not approved; no installer was uploaded to the site.

**Previous installed artifact: `224466d`**, replaced by `bb02bb4` above.
Strict nested signatures, Gatekeeper, notarization, stapling and post-copy
source-provenance verification pass. Installer:
`/Users/amy/hippo-work/releases/2026-09-06-224466d/Hippocampus-0.1.0.dmg`.
SHA-256: `5d2802d5619b9c227a64eaa627e277e1d09435037670d666fdc49fe03ba2265e`.
Product-source digest:
`be9a279e2c24b963e31e0a40b4d3f9ce2ce272d384d0a7f9c26ffe0395043936`.
App notarization `065138b1-4df6-465f-b311-a6a778130b8a`; DMG notarization
`51ed01bf-a59e-4aa7-9632-16c2d628ae07`, both Accepted. Prior app preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-2e5fc82-before-224466d.app`.

Native Now displayed the new Copy day summary and Export day context controls,
the saved daily draft and explicit capture-withheld/disconnected states.
Fresh capture of the literal-code fixture has NOT yet been established on this
artifact. At 03:44 UTC September 7, the receipt still showed 264 screen records
and 108 screenshots, last written at 03:33:46 UTC before this installation.
Initial suppression was failsafe-unknown; the relaunched generation reported
denylist-source while the excluded Hippocampus preferences were open. A separate
content-free diagnostic classified the test window non-secure, but ended with
streamStoppedUnexpectedly; it was not a production storage proof. It is reaped.
The production parent was deliberately stopped for native UI inspection, then
restarted through Capture. Its enabled configuration and privacy gates remain
unchanged. Owner foreground-fixture confirmation is pending; background UI
inspection is not proof of what the capture pipeline actually saw. Do not reuse
the prior artifact's successful event proof as verification of this one.

## September 6 Safety And Usefulness Integration

**Previous installed artifact: `2e5fc82`**, since replaced by `224466d` above.
The app and DMG are Developer ID signed, notarized and stapled; strict nested
signature, Gatekeeper and post-copy build-provenance checks passed. Installer:
`/Users/amy/hippo-work/releases/2026-09-06-2e5fc82/Hippocampus-0.1.0.dmg`, SHA-256
`c56ef218b4ad30e234164528631dfcf38babb58f50b80fedaa2e91285091a21e`.
Product-source digest:
`eee039c36246b81dde814a9129961da59921c7a3741d8d24cb113ee101eef7b8`.
App notarization: `0897e305-8e12-4fb8-953a-3a1160ee900a`; DMG notarization:
`e29cb64d-c4c9-4a23-897d-c8e7130e26d9`, both Accepted. Prior installation retained
at `/Users/amy/hippo-work/releases/backups/Hippocampus-11194ae-before-2e5fc82.app`.

Code baseline `493befe` adds explicit macOS user-stop handling with a parent
capture-off latch, retired-stream failure isolation, visible stop failures,
read-only quiet-input sampling, source-linked native brief rendering, bounded
extractive drafts and mandatory release advisory/model/launch gates. Details
and remaining work: `docs/audit/2026-09-06-owner-product-ledger.md`.

The integrated `11194ae` app was Developer ID signed, notarized, stapled and
installed at `/Applications/Hippocampus.app`. Strict signature verification,
Gatekeeper and signed build provenance passed. Its installer is
`/Users/amy/hippo-work/releases/2026-09-06-11194ae/Hippocampus-0.1.0.dmg`, SHA-256
`2404ee73a997ba796bb47a74107d707944dbf22ed57829d2e7bc3ef9dce3c42c`.
Ordinary TextEdit synthetic event 1755 reached encrypted storage, native Search,
the authenticated screenshot viewer and the real Codex MCP connection. Proof:
`/Users/amy/hippo-work/releases/2026-09-06-11194ae/installed-textedit-screenshot-proof.jpeg`.
Native version-2 brief source navigation also worked. MCP correctly returned
observations-only/degraded evidence, not a verified answer.

Extended installed use exposed a further failure: after a generic stream stop,
replacement startup reported `noDisplay`, and recovery ended with capture still
enabled but the helper disconnected. Source revision `eff26a3` retries failed
replacement startup with bounded backoff and recovers eligible failed sessions
on workspace wake. It preserves explicit Stop, pause, Quit and revoked access.
It also fixes restored-query loading, debounced typing and stale asynchronous
search results. Finder gallery metadata is omitted from daily drafts without
deleting original memory. These changes are included in installed `2e5fc82`.

Fresh synthetic TextEdit event 1802 reached Codex through the actual MCP
connection. A controlled termination of the owned helper at 00:02:26 UTC on
September 7 (September 6 locally) caused a visible disconnected receipt; a new
helper/agent generation stored event 1803 at 00:02:29.735 UTC. The authenticated
native viewer displayed that event's pixels, OCR, source and timestamp. Search
loaded the restored query on opening and updated to the new fixture without
Enter. A local model-free draft (id 79) excluded gallery metadata and its source
button opened event 1803. Drafts still contain OCR variation, clipped snippets
and repeated evidence; this is not polished generative understanding.
Durable proofs are `installed-recovery-screenshot-proof.jpeg`,
`installed-search-typing-proof.jpeg` and `installed-brief-proof.jpeg` in the
current release directory. A deliberate parent stop for native inspection was
followed by normal Capture-control relaunch; it is not an unexplained outage.
That relaunch saved synthetic TextEdit event 1806 at 00:05:29.400 UTC; actual
Codex retrieval returned it. The final Now view reported 182 stored screen
records / 72 screenshot references, with capture connected. A point-in-time
sample showed about 84 MiB parent RSS, 54 MiB helper, 27 MiB agent and 94 MiB
Recall, with one owned helper/agent generation. These are short-run observations,
not a resource/uptime guarantee.
Real OS Stop, sleep/wake, permission revoke/restore and long-soak qualification
remain separate from this process-failure proof.

Build-only follow-up `8b8598b` isolates the installer's second launch check in
a disposable home, matching assembly. Its regression failed before correction
and the eight-fixture safety suite passes afterward. The already notarized
`2e5fc82` binary was independently rerun with the same clean-home/onboarding
requirements and passed. No shipped executable changed in this follow-up.

The complete Rust workspace passed 1,972 tests, with nine explicitly ignored,
across 130 test groups. Its earlier concurrent-build timing failures remain
recorded; the completed serial recheck passed. The release-mode tier2 test
attempt was refused by the intentional test-key-wrap guard, which was not
disabled. Optimized capture has 674 passing tests, Recall 409 XCTest plus three
handoff tests; the complete optimized parent suite passed 323 tests. A separate
code reviewer found four recovery/state issues, reproduced before correction,
and reported no remaining actionable findings in the corrected recovery diff.
This is a scoped code review, not an independent whole-product security audit.
Strict Clippy for brief/eval, Rust formatting, eight release-safety fixtures,
16 audit fixtures and 224 release-contract checks passed. The ten-case synthetic
brief rubric remains 10/10 versus its recorded 2/10 baseline; the separate
extractive regression suite now has 15 cases. This is not semantic truth or
universal prompt-injection qualification.

Neither measured work time, reviewable commitments, trusted answers, normal/
private-browser and owner-controlled permission qualification, second-Mac
continuity nor public release is newly claimed. The model release manifest
remains UNPROVISIONED. No permissions, keys or user memory were reset.

## Installed Product Repair

The September 5 owner audit found that the installed e7be6f0 app had no
production screenshot blobs and drained thousands of frames with zero stored
screen events. Earlier isolated capture qualification used a special app
allowlist; it did not establish usable capture under the owner's normal
configuration. The historical component qualifications below are not an
end-to-end claim for the repaired installed product.

Current repair implementation and focused tests cover:

- Ordinary identifiable applications are admitted after global capture consent,
  with secure-input, AX uncertainty, explicit exclusions, sensitive-source
  defaults, OCR secret checks, and focused-window generation checks retained.
  Browser pixels require a positively classified normal window with matching
  identity, geometry, and URL. Unsupported/private/ambiguous browser windows
  remain excluded. Live browser qualification is still pending.
- Production binds the desktop-independent focused window at startup, rebind,
  and permission recovery. The previous first-display include filter could
  return blank pixels for a window on another display. Visual evidence now
  requires full-window OCR before the secret gate; dirty-region OCR cannot
  authorize a whole-window screenshot. System consent/security dialogs are
  excluded in addition to the memory application's own windows.
- Fresh AX focused-process queries replace cached NSWorkspace foreground reads.
  A background-timer reproduction showed the cache remaining on the prior app
  after a real foreground switch. Queries now fail closed after 50 ms, allow
  only one outstanding OS request, and never reuse a timed-out result. Focused
  screenshot canvases follow window geometry and are bounded to 1920 pixels
  on the long edge. Installed event 1629 and its native image viewer prove the
  window-sized canvas. Contending focus readers now wait for their own fresh
  query within the same deadline; they do not falsely invalidate focus merely
  because another reader is active. Installed event 1646 reached real Codex MCP
  after this correction.
- Committed capture receipts distinguish saved records/screenshots, suppression,
  disconnected helpers, and storage failures. Imports have separate acquisition
  provenance; unknown historical rows are not guessed to be screen captures.
- New installs default to 90-day retention. Unversioned finite policies require
  review before automatic deletion. The owner's existing seven-day file was
  backed up and explicitly changed to a reviewed 90-day policy.
- Recall opens a light Today workspace with real screenshot references, date
  navigation, screenshot search, visual episodes, an authenticated image viewer,
  source/time details, refresh, and bounded cited exports. Observed spans are
  not measured active time.
- Today generates a model-free cited draft after useful current-day evidence
  arrives. Checks run each minute; subsequent changed-evidence rebuilds are
  limited to once per five minutes. The morning brief owns yesterday's local
  calendar date. Neither unattended path loads Qwen. Optional Qwen NER now
  requires the exact explicit opt-in `MCI_QWEN_NER_ENABLED=1` before model load.
- The old menu process was sampled at roughly 40 GB physical footprint in a
  SwiftUI menu-update loop. Its animated periodic icon was removed and image
  construction bounded. A separate orphan agent was blocked in Core ML while
  Tokio waited for blocking workers; daemon EOF shutdown now has a bounded
  runtime teardown. A 24-minute installed sample used about 56 MB menu RSS,
  35 MB helper RSS, 16 MB agent RSS and 75 MB Recall RSS. This is a point-in-time
  sanity check, not a complete resource/lifecycle qualification.
- Claude SessionStart context and Codex instruction integration are explicit,
  ownership-safe opt-ins. They preserve bounded canonical citations and do not
  install themselves into unrelated client configuration.
- The Recall workspace now links directly to capture, privacy, and AI-context
  preferences. Parent-owned preferences dependencies exist before URL delivery.
  Sources and Settings no longer show an irrelevant screenshot filmstrip.
  A live cold-parent test exposed Launch Services routing these links back to
  Recall, whose bundle identity is shared. The new router targets the exact
  parent executable, acknowledges pane opening, and prevents duplicate parent
  processes with a lifetime lock. Release binaries are built; installed routing
  qualification initially failed because the main-bundle executable lookup
  resolved Recall itself. The named-sibling lookup correction is now verified
  in the installed app: a cold launch opens AI Context, receives its
  acknowledgement and starts one parent without an extra Recall window.
- macOS TCC logs confirmed browser Automation prompts were prohibited because
  the signed parent lacked the Apple Events entitlement. Parent and capture
  helper now receive that capability through both signing paths; other children
  do not. Four signing tests include actual disposable signature readback.
  OS consent is still required. Browser AppleScript execution now permits only
  one outstanding OS request, discards timed-out work instead of accumulating
  it, and never reuses an old answer for a newer request. A behavioral regression
  failed before this change and 34 focused tests pass afterward. Real normal
  and private browser qualification is pending the corrected installed build.

All six repaired release executables built successfully. The first repair app
and DMG were signed, notarized, stapled and installed, but the positive fixture
capture did not pass. One stored screenshot was a system consent dialog, which
exposed the new exclusion requirement; it is not useful-work capture proof.
The subsequent focused-window/full-OCR repair (`17a5fdd`) was signed,
notarized, stapled and installed. Production event 1626 contains the synthetic focused
window token and an encrypted screenshot. The installed native viewer decrypted
and displayed those pixels; native Search returned that event. A normal restart
saved event 1627, which the real Hippocampus MCP connection in Codex returned
with its `screen_ocr` citation. This is observed evidence, not a verified answer.
The native image proof is `/tmp/hippocampus-production-image-proof-20260905.jpeg`.

The automated production proof remains incomplete: its bounded negative query
hit the 100-candidate limit and it has no authenticated-image tool. Native image
verification supplements it, but does not turn that script into a passing test.
The first images revealed fixed-canvas black margins. The geometry/focus/hook
repair (`bea62b3`) was signed, notarized, stapled and installed; event 1629's
authenticated native viewer shows the corrected canvas without black margins.
Proof: `/tmp/hippocampus-focus-repair-image-proof-20260905.jpeg`.
The browser-capability build `81e0cb6` was signed, notarized, stapled and installed.
Its 79 MB DMG is `/tmp/hippocampus-release-20260905-browser-routing/Hippocampus-0.1.0.dmg`,
SHA-256 `6ca2ddff5abf47c15c3d23c25cc13be8aac057925acc4c63ce65654c3ee11c78`.
The September 5 installed app was repair artifact `fe285ee`, Developer ID
signed, notarized and stapled. Installed provenance, deep/strict codesign,
stapler validation and Gatekeeper assessment passed. The durable installer is
`/Users/amy/hippo-work/releases/2026-09-05-fe285ee/Hippocampus-0.1.0.dmg`,
SHA-256 `b29eaee8058bb5671d17038fb5d2e48c333904212b98281f8ee3fe0361ed74a5`.
Its product-source digest is
`07e27a1c7abf88f92d9af58bb617550a994e68054aa9f39a08a39fd5f58c05fa`.
The preceding validation app is preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-routing-validation-2726eaf.app`.
Pause/resume was exercised in that validation app: the receipt recorded
`capture_disabled` while off and cleared that reason after restart. Both cold
and warm Sources-to-AI-Context routing acknowledged successfully in the final
installed app, without duplicate parent or Recall processes.
Normal/private-browser live proof and permission-revocation recovery remain
unqualified. A macOS security dialog interrupted browser qualification; only
the owner may handle that consent. Subsequent ordinary-window capture resumed.
No access has been granted or reset by automation.

The latest preview correction strips the complete indexing header before the
timeline's 80-character budget. Search-derived cards normalize the same body
contract; views do not strip a second time. Stored text, search indexing,
citations and detail-hit wire semantics are unchanged. All 109 Rust bridge
tests and the full optimized Recall suite (396 XCTest plus three handoff tests)
pass. The final native Today previews show OCR rather than indexing metadata.
The final installed build captured event 1679 at `2026-09-05T12:50:07.106Z`
under the ordinary production policy. Codex's live `mci_events_since` returned
its synthetic marker, and the native authenticated viewer displayed the same
event's stored pixels, OCR, source and timestamp. The committed receipt then
reported 55 screen records and 15 screenshot references. Proof:
`/Users/amy/hippo-work/releases/2026-09-05-fe285ee/hippocampus-final-fresh-screen-proof-20260905.jpeg`.
This proves the positive installed screen-to-memory loop, not all-app coverage
or the separate negative privacy and permission-recovery gates.

A real Claude SessionStart invocation exposed an oversized-packet failure even
though direct MCP worked. The hook now requests 600 tokens/four citations and
retries only oversized output at 256 tokens/one citation, preserving the same
focus and total deadline. Regression tests pass, including full citations and
failure isolation. The repaired installed hook returned a complete 2,564-byte
packet with the fixture, its canonical citation and the untrusted-memory warning.
The native consent controls enabled the owner's Claude SessionStart hook and
Codex instruction block without replacing unrelated configuration. An actual
Claude Code process, with tools and MCP disabled, emitted a successful
SessionStart hook response containing the fixture. Its remote model request
then retried until the bounded test ended; no final model answer is claimed.
Codex's real MCP connection has independently returned the fresh screen event.

The 36-task synthetic benchmark passes retrieval/handoff gates on both arms.
Hybrid recall@3 and handoff-task success are 100%; top-one hit rate is 96.8%.
The benchmark's source seeder was corrected to preserve explicit `screen://`
acquisition metadata. Corpus, answers and thresholds are unchanged. These are
synthetic retrieval results, not live capture or generated-answer qualification.
The expanded optimized capture suite passed 654 tests with zero failures,
including the newest AppleScript change.
Eighteen focused release workspace/date/receipt tests also pass.
The earlier debug suite's 107-microsecond
timing result versus its 100-microsecond gate remains recorded, not hidden.
The remaining browser checks must pass installed verification before browser
capture can be called qualified. Final installed preview readback passed.

## Product Boundary

The launchable V1 is a local evidence-memory product. It captures permitted
work context, preserves source and time, retrieves and displays related
evidence, produces citation-preserving extractive briefs, and hands bounded
context to Claude Code and Codex. It does not generate or advertise verified
answers. Production labels unverified semantic candidates as degraded related
context, while `Matched` remains unreachable without a separately qualified
verifier.

The task-trained claim/evidence verifier is a V2 capability gate. It must pass
the blind qualification below before Hippocampus may present a generated claim
or answer as trusted. This boundary does not weaken abstention or citation
requirements; it prevents an untrained model artifact from blocking a useful,
truthfully scoped evidence product.

## What Works

- The local memory ledger works: SQLCipher storage, FTS5 search, typed recall,
  timeline reads, episode derivation, briefs storage, export, deletion/wipe,
  authenticated encrypted keyframe reads, and stdio MCP.
- `mci_context` compiles a bounded handoff with typed outcomes, abstentions,
  source priority, and canonical event citations. Claude Code and Codex
  registration is structural, idempotent, ownership-safe, and records only a
  database path plus Keychain service/account references. Daemon startup now
  repairs only existing Hippocampus registrations, migrating stale packaged
  paths and legacy plaintext-key fields without creating an unsolicited
  registration or changing unrelated and malformed client configuration.
- The app and packaged `mci-agent` now share the `0.1.0` release identity.
  The agent derives its displayed version from Cargo package metadata, and a
  regression test compares it with the shipping app's Info.plist.
- Focused `mci_context` handoffs preserve the retrieval truth state all the
  way to Claude and Codex. Packets now say whether focus retrieval matched,
  contradicted, abstained, or returned degraded related context, including the
  stable degradation reason; unqualified ranking is no longer silently
  flattened into an ordinary observation-only packet.
- The same canonical context compiler is now directly usable outside MCP.
  `mci-agent context` opens the encrypted brain read-only, uses the production
  hybrid-or-lexical retrieval path, enforces the shared token and citation
  limits, and prints prompt-ready Markdown or typed JSON. Recall exposes this
  as an explicit clipboard action beside search and on the primary Now screen.
  Production resolves only the app-bundled sibling agent; an external agent
  path is accepted only in the build-gated development key mode. The UI runner
  now has a hard 15-second deadline, requests graceful termination, and kills a
  wedged child after a bounded grace period instead of leaving the interface
  spinning forever. Exported Markdown labels observations as unverified
  reference data and retains exact canonical event citations.
- Both AI-tool connection surfaces now impose a hard 15-second deadline,
  concurrently drain child output while retaining at most 8 KiB, request
  graceful termination, and force-kill a child that ignores the grace period.
  User-visible failures are sanitized instead of exposing raw stderr or local
  filesystem details. Executable fixtures prove timeout cleanup, output
  bounding, and diagnostic redaction without XCTest.
- Temporal handoff no longer treats recency as truth. A current-state query can
  remove an older raw observation only when a newer source explicitly declares
  that it supersedes or replaces a source labeled as previous or old. Competing
  observations without that marker remain visible. Exact repeated screen OCR
  consumes one packet citation, keeping the newest canonical observation while
  leaving the lossless event ledger unchanged.
- First-run onboarding now treats Screen Recording and Accessibility as required
  capture permissions, starts the supervised capture generation after the user
  finishes onboarding, and keeps one commandable Recall process available from
  the menu app. The global Recall shortcut opens that process, and search can
  deep-link to one exact canonical event instead of silently reusing stale
  popup results.
- Recall's global refresh command now publishes one content-free local signal
  and the visible filmstrip, Now, Search, Timeline, Episodes, Briefs, Sources,
  and Privacy surfaces execute their real `BrainReader` reloads. The old timed
  simulation and false "Brain refreshed" success claim are gone. A no-XCTest
  executable behavior check verifies signal delivery, active-query rerun, and
  observed-source refresh on this host.
- The unshipped canned Chat preview, fake assistant response model, and
  `?tab=chat` route have been removed from the compiled product. V1 uses the
  agents people already have through bounded handoff instead of presenting a
  mock chat surface as future functionality.
- The supervisor preserves one database-key authority across capture, Recall,
  onboarding, and AI-tool connection children. The packaged demo gives
  Foundation an isolated `HOME` and `CFFIXED_USER_HOME`, and its seeder and
  app share the exact fixed development-key path, so demo runs cannot touch
  the user's real brain or silently exercise a different key. Recall launch
  now uses the prepared-environment validator: source and demo builds retain
  only the fixed file-key marker/path while production remains Keychain-only;
  the ambient scrubber can no longer remove the authority immediately before
  the child starts.
- The supervised capture topology now has a kernel-enforced parent-lifetime
  lease. If the visible app quits, crashes, is force-quit, or receives
  `SIGKILL`, the helper observes EOF, drains capture, exits, and closes the
  existing helper-to-agent pipe so the agent releases its clean-run marker and
  exits too. Ad-hoc app assembly runs this owner-death proof against the real
  packaged process tree in a disposable home. The launch verifier allows a
  20-second cold-start window before judging onboarding missing, covering clean
  Swift package and Rust cache starts without weakening the liveness checks.
- The read-only `mci-brain` development fallback now normalizes a
  newline-terminated `dev.key` before validating it, matching the file emitted
  by the canonical demo while leaving production Keychain resolution
  unchanged and fail-closed.
- Daily briefs work without a model download. The deterministic extractive
  author removes capture headers and duplicate OCR churn, prioritizes explicit
  changes and open loops, caps output at nine bullets, and cites the exact
  canonical event behind every bullet. Stored author provenance distinguishes
  this path from optional experimental model output.
- Event, range, retention, and full-brain deletion remove last-reference
  encrypted keyframe blobs. Every retention cycle also reconciles canonical
  crash orphans and stale managed temporary files after a one-hour grace
  period, without following symlinks or deleting unknown entries. A missing
  retention file receives the fresh-install 90-day default; an existing
  unreadable, malformed, or unknown-value file fails closed and skips both
  expiry and reconciliation instead of silently changing policy.
- A process-lifetime operating-system writer lease now covers the daemon,
  every one-shot writer command, and Recall delete/wipe. The `.running` crash
  marker is separate, private, owner-checked, and opened without following
  symlinks. Existing brains pass a read-only integrity preflight before any
  writer open or schema migration; stale shutdowns require two successful
  passes. Integrity failure blocks the mutation with a dedicated exit path.
- The persisted recording setting now reaches every production ingest
  boundary. The helper receives `--capture` only when enabled; the Rust agent
  receives an explicit `MCI_CAPTURE_ENABLED` value and keeps stdin, browser
  sockets, deep hooks, and MCP collection inert while off. Safari additionally
  requires an enabled App Group authority owned by the live container process,
  binds that authority to the container's exact process-start identity, stamps
  each payload with the committed supervisor generation, and rejects stale or
  missing generations before socket delivery. Chromium performs a content-free
  native authorization handshake before reading the page DOM. A dead agent
  socket terminates the native host so the browser cannot retain a stale port
  across pause or restart. User pause stops the helper and agent process tree;
  resume starts a fresh supervised generation. Consent revocation and topology
  shutdown are independent attempts, so a failed authority-file removal cannot
  skip helper and agent termination during quit, pause, or reconfiguration.
- The production capture session now owns a live TCC monitor. A permission
  denied before helper startup is applied as an immediate fail-closed pause and
  emits the same content-free, actionable app status as a mid-run revoke.
  Restoration remains direction-asymmetric, requires two granted samples, and
  resets its grant evidence after a failed reconstruction attempt.
- Focused-window capture now binds every callback to the immutable generation
  of the `SCStream` that produced it. Focus changes build a replacement stream;
  public AX geometry must resolve twice to one unique WindowServer identity, so
  ambiguous same-bounds surfaces and same-application focus races fail closed.
  Stale generations fail closed before pixel admission, and terminal stream
  loss or failed teardown stops the helper instead of leaving a falsely healthy
  process. The live verifier preserves that nonzero status and its diagnostics
  expose only fixed outcomes, presence bits, booleans, and counts. OCR queue
  eviction, timeout, and empty recognition explicitly reopen only that exact
  frame's visual baseline. A complete later static frame can then receive one
  full-frame retry without disabling the normal no-dirty-rectangle energy gate
  or crossing a focused-window generation. The standalone 2026-09-04 M4 third
  lift enables production OCR by default after the live qualification below;
  the emergency switch remains tested and the debug qualification capability
  remains absent from release binaries.
- Semantic recall works when the Arctic Embed S Core ML artifact is present
  and backfill has run. The macOS runtime explicitly permits CPU plus Neural
  Engine for inference and uses a Rust cosine scan over vectors stored inside
  SQLCipher; there is no separate vector service or shipped sqlite-vec
  retrieval path. The shipping FP16 graph has app-owned provenance and a
  compiled-MIL contract that traces its finite `-10000` mask into every
  softmax. All 50 pinned reference sentences produce finite, normalized
  embeddings with cosine similarity at least `0.999` under both CPU-only and
  CPU-plus-Neural-Engine policies. The measured averages on this Mac were
  26.00 ms and 10.35 ms per embedding, respectively.
- Empty or whitespace-only observations no longer enter the embedding queue.
  One-shot backfill now stops when the current batch makes no progress, and the
  long-running worker waits on its normal idle interval before retrying a
  rejected batch. A live capture audit previously drove one empty row through
  hundreds of thousands of immediate retries; the fixed packaged agent drains
  the same retained encrypted brain with zero pending batches and no retry
  storm.
- Explicit person, count, duration, and date questions now pass a
  relation-grounded negative guard before retrieval can be called a match. The
  guard strips capture headers, keeps values within sentence and topic
  boundaries, passes all 14 disjoint calibration/validation cases, and rejects
  all eight adversarial cases containing an unrelated name, number, date, or
  duration. This guard can veto evidence but cannot promote it by itself.
- Hybrid recall now separates ranking from semantic evidence verification.
  The verifier contract returns source-attributed `Supported`, `Contradicted`,
  or `Insufficient` judgments; malformed confidence, invented event IDs, model
  failure, and an absent verifier all fail closed as the typed
  `EvidenceVerifierUnavailable` degradation. Supported and contradictory
  outputs retain only the exact canonical events cited by the verifier. The
  verifier receives a bounded internal set of up to eight ranked events before
  the caller's display limit is applied to untrusted fallback context, so a
  one-result UI request cannot discard any event required by a trusted support
  or contradiction verdict. The
  retired score critic remains available to tests but is no longer installed
  by production construction.
- The claim-verifier boundary now has a host-owned v3 evidence contract. A
  proposed claim is a normalized subject/predicate/object tuple; at most eight
  bounded evidence spans are cut from canonical events with UTF-8-safe byte
  ranges, exact text, and digests binding event bytes to brain, scope, and
  source identity. One call cannot mix brains or cross the claim's exact scope.
  The model can select only host-assigned slot indices. The host rejects
  non-finite confidence, duplicate or unknown slots, stale or modified
  citations, and policy-threshold uncertainty, so model output cannot invent
  provenance or disguise abstention as model-predicted insufficiency.
- The selected task-trained MobileBERT claim-set architecture now has a native
  Core ML runtime boundary. It requires exact Int32 `[1, 384]` inputs, fixed
  floating `[1, 3]` judgment and `[1, 8]` citation outputs, paired one-token
  evidence markers, and fully retained evidence slots. Startup requires a
  manifest whose SHA-256 is compiled into the signed binary, binding model and
  tokenizer hashes, class order, tensor schema, thresholds, blind-dataset
  identity, and Core ML parity. Artifacts are checked before and after load.
  The boundary fails closed on truncation, split markers, artifact drift,
  extra or flexible tensors, schema drift, an unauthorized brain, event ID
  zero, or an unqualified manifest. No task-trained artifact or qualified
  manifest exists yet, and this verifier is not installed in production.
- The first compact native verifier candidate has a reproducible Core ML
  conversion and a memory-safe Rust inference adapter. MobileBERT SQuAD2 FP32
  matches its PyTorch logits within `0.00014687` and runs in 23.49 ms median,
  but it is intentionally not installed in production: at a calibration
  threshold preserving every validation positive, it falsely accepts 16.7%
  of validation negatives against the 5% ceiling.
- The menu app, onboarding, Recall workspace, icon, installer art, extensions,
  and documented product captures use one light native visual system. Native
  macOS material supplies the translucent top surfaces, dark system appearance
  does not turn the product black, including the native Preferences panel and
  toolbar, and the retired turquoise identity is not present in the release
  asset set. The asset contract now runs in the unified gate. The Recall product
  capture is generated from a disposable SQLCipher brain and visibly proves
  three authenticated encrypted keyframes, 20 synthetic events, and one current
  synthetic brief. Recall's recent-evidence strip now shows sharp 16:9 source
  previews, an untruncated section label, cleaned two-line evidence summaries,
  source/time context, and an
  inspectable detail popover instead of blurred passive thumbnails. It compacts
  to screenshot plus summary cards in short windows instead of expanding the
  root view behind the title bar; fresh windows default to `1024x700`. The Now
  screen exposes the bounded, citation-preserving agent handoff as its stable
  primary action, and the repository thumbnail is regenerated from that exact
  packaged surface. The demo
  opts out of saved query/filter state and its automated screenshot path treats
  denied Screen Recording as an explicit nonfatal result rather than aborting
  or accepting a stale temporary image. Demo boot now hands the packaged app to
  LaunchServices, records the resulting application PID, and verifies that it
  remains alive before reporting success, so a short-lived invoking shell
  cannot orphan onboarding or falsely claim that the menu app is running.
- Runlog remains an audited research input rather than a runtime dependency.
  It does use 768-dimensional Gemini vectors and Firestore cosine search; its
  useful hypothesis is hybrid candidate generation plus source-region
  provenance. Hippocampus will evaluate those ideas locally without adopting
  Runlog's cloud store, uncited agent-written claims, query-time general
  knowledge injection, or eventual-deletion semantics.
- The app, capture helper, Recall, and onboarding Swift packages compile on
  this host through the constrained SwiftPM wrapper. The complete Rust gate
  passes formatting, all-target workspace Clippy, every workspace test, and
  dependency audit. The shell and executable behavior lanes pass, including
  capture/privacy, release identity, model integrity, product truth, clean-home,
  app launch, and visual contracts. The current verified matrix reports 52
  passing lanes, zero failures, and one unavailable SwiftFormat skip. Full
  Xcode 26.6 is selected, so all Swift package tests and executable fixtures run
  locally through the repository's manifest-compatibility wrapper.
- Installer subprocesses run in isolated POSIX process groups with bounded
  TERM/KILL escalation. Executable fixtures prove ordinary descendants and
  descendants created by TERM handlers are gone before timeout returns. Failed
  builds remove incomplete canonical DMGs and sidecars; successful cleanup
  preserves completed artifacts. The DMG stages the generated canonical terms
  as a visible `License.rtf`; the removed macOS unflatten/Rez/flatten flow is no
  longer treated as an optional success path.
- The capture stream's active-work ceiling is 2 fps and the 1 Hz privacy
  cascade floor remains independent. A Developer ID-signed current-source
  helper passed a 20-second live overlap proof with two distinct application
  identities: 38 frames, one focused OCR event, one retained authenticated
  keyframe, no background token, no foreign event, and no ingest drop or
  failure. This used an isolated qualification allowlist, not the owner's
  production configuration. The separate 1,800-second soak delivered 3,610 frames, exercised 37
  fail-closed focus-race drops (`1.0249%`), retained 38 OCR events and 37
  keyframes, and measured helper CPU p95 `3.7%`, RSS p95 `92,012,544` bytes,
  and projected storage `3,222,844` bytes/hour. The exact report and limitations
  are in `docs/audit/2026-09-04-focused-window-live-qualification.md`.
- The current-source Developer ID qualification app at
  `/tmp/hippocampus-signed-qualification/Hippocampus.app` includes Arctic Embed
  S as its only bundled model, passes signed App Group and model validation,
  survives the disposable-home first-launch gate, and carries the stable Team
  identifier `BV6KGKFKP4`. It is a debug qualification artifact, not the
  distributable release. It does not qualify the September 5 repair.
- A throwaway-home E2E installs the engine, starts with capture disabled,
  imports 20 synthetic events, injects one shared-encoder `OCREvent` through
  production `--drain-stdin --strict`, derives episodes, persists and reads
  back a brief, verifies MCP recall/timeline/episodes/cited context, registers
  both supported clients without key material, deletes the injected event,
  and uninstalls without isolated product residue.
- The disposable visual demo now runs the production enrichment pipeline over
  its 20 synthetic events before launch, producing 13 entity mentions, 20
  embeddings, and 20 inspectable work episodes on the audited Mac. An isolated
  `HOME` no longer hides the verified repository-local Arctic artifact: the demo
  resolves and exports its explicit path before enrichment when no caller
  override is present. Semantic mode now fails unless the production pipeline
  reports all 20 synthetic events embedded; an absent artifact is disclosed as
  degraded lexical-only mode. Canonical captures are stripped of EXIF and text
  metadata, and their OCR contract rejects personal home paths, email addresses,
  and common credential shapes. Its MCP
  trace exercises recall, cited context, stats, and episodes. MCP copy says
  capture begins only after opt-in and distinguishes the absence of a
  Hippocampus cloud copy from the policy of whichever AI client receives a
  user-requested handoff.

## What Is Not Yet Proven

- The production-wired TCC revocation monitor is not yet proven by a live
  grant/revoke/restore run. macOS exposes no qualified public signal that a
  different app has started sharing or recording the screen, so Hippocampus
  does not claim or simulate one; explicit pause, screen lock, TCC loss,
  denylisting, secure input, and browser-private-mode exclusion are the enforced
  controls. Delete and wipe operations
  separate committed SQL deletion from post-commit storage-cleanup warnings and
  now quiesce against every other writer through the shared operating-system
  lease.
- Production key custody targets the non-synchronizable macOS file-Keychain
  item `ai.hippocampus.brain` / `database-key-v1`. Migration is fail-closed and
  removes a legacy plaintext key only after Keychain reread plus read-only
  database validation. Ad-hoc development bundles carry a build-injected
  capability that permits the fixed user-owned `dev.key` path, and pass child
  processes only that path plus an explicit development marker, never raw key
  bytes. Developer ID bundles omit the capability and remain Keychain-only.
  A Developer ID release has completed signing and notarization on this Mac;
  second-Mac clean-install and cross-version ACL continuity remain unqualified.
- Full Xcode 26.6 is installed and selected. The Developer ID Application
  identity and its private key are installed, `notarytool-profile` authenticates
  successfully, and the Sparkle private/public key pair matches the public key
  in the shipping Info.plist. The pre-lift app and DMG completed Developer ID
  signing, Apple notarization, stapling, and verification. The production
  focused-window repair also completed that pipeline and is installed. The
  final focus/canvas/preferences/hook repair is also notarized and installed;
  its positive capture, stored-image and MCP readbacks are recorded above.
- A verified local Arctic Embed S Core ML bundle is present in the gitignored
  development model directory and is included by debug ad-hoc assembly, so that
  artifact supports semantic recall. It is the sole required release model.
  Tier-1 entity extraction remains active. This owner's custom local model
  directory contains Qwen3; that presence no longer starts unattended Qwen
  inference. Evidence-cited extractive briefs remain active. Qwen is an
  optional custom-build experiment, not a shipped download or release gate.
  A local archive containing only that compiled Arctic bundle was created and
  reconstructed through `scripts/prepare-release-models.sh`; its SHA-256 is
  `31da35fffb853a9442cef582f3319206496a00808da1ab3cbeca711b11a766f3`.
  It is not hosted, and `release-models.json` deliberately remains
  `UNPROVISIONED`, so a public updater release cannot yet be reconstructed or
  published from immutable model inputs.
- Multi-device sync and Windows are outside the verified v1 path.

## Benchmark Status

The accepted `agent-handoff-v1` evaluation runs 36 tasks through both the
production hybrid and lexical-only `LiveBrainReader::recall` plus
`LiveBrainReader::context` paths, for 72 arm-task combinations over disposable
SQLCipher brains. Both fixed quality gates pass. Hybrid scores 96.8% Hit@1,
100% Hit@3/5, 98.4% MRR, semantic relevance, temporal currency, superseded exclusion,
contradiction visibility, duplicate suppression, exact provenance,
abstention, handoff utility, fact coverage, bounded packets, and capability
pass rate; its recall is 69.4% at rank one and 100% at ranks three and five.
Lexical-only scores 100% Hit@3/5, temporal currency, superseded
exclusion, contradiction visibility, duplicate suppression, exact provenance,
abstention, and bounded packets; its capability pass rate is 35/36, handoff
task success is 75%, and fact coverage is 43/44. This qualifies retrieval and
bounded handoff only.
`trusted_answer_qualified` remains structurally false until a source-attributed
answer verifier passes its separate held-out gate. The checksummed report is
`docs/eval/agent-handoff-v1-result.json`.

The shipping extractive brief author passes all eight committed synthetic
workdays: 37/37 required facts, 69/69 valid citations, zero unresolved
citations, zero forbidden terms, and 3.20 ms total measured author time on the
audit Mac. This is a source-preservation baseline, not a human usefulness
claim; the corpus does not yet score importance, personal/work separation,
contradiction resolution, or repeated-OCR suppression. The reproducible result
and limitations are in `docs/eval/brief-extractive-baseline.md`.

The accepted, reproducible 24-case synthetic work-memory retrieval artifact is
`docs/eval/work-memory-baseline.json`. It covers 21 answerable and three
intentionally unanswerable cases across GitHub, terminal, browser, Slack,
Linear, and files. It measures retrieval and provenance, not answer generation,
and is not comparable to LoCoMo or LongMemEval.

A clean clone at `b845c59` reproduced the accepted quality exactly: hybrid
Hit@1 95.2%, Recall@1 88.1%, Recall@3 100%, MRR 0.976, exact provenance, and
zero unanswerable false positives. Two warm scenario runs measured 46.0 ms and
52.2 ms p95; one cold run measured 156.9 ms. This timer includes disposable
brain creation, seeding, document embedding, retrieval, and index measurement,
so it is a load-sensitive scenario latency rather than a pure query timer. The
same clean clone reproduced the accepted agent-handoff result and remained
`trusted_answer_qualified: false`.

| Arm | Answerable outcome | Hit rate @1 | Recall @1 / @3 | MRR | Unanswerable outcome | p95 latency |
|---|---:|---:|---:|---:|---:|---:|
| Lexical | 7/21 ranked; 14 missed | 33.3% | 33.3% / 33.3% | 0.333 | 3/3 abstained; 0 false positives | 22.15 ms |
| Hybrid | 21/21 ranked; 0 missed | 95.2% | 88.1% / 100% | 0.976 | 3/3 abstained; 0 false positives | 72.06 ms |

The artifact is complete and publishable but explicitly
`"launch_qualified": false`. Retrieval abstention passes the three
unanswerable cases, but all 21 answerable hybrid rankings are deliberately
recorded as `degradedEvidenceVerifierUnavailable`, not trusted matches. The
explicit relation guard is qualified on its narrow person/count/duration/date
corpus, leaving the missing semantic verifier as the single quality failure.
The prior score critic reached only 83.3% positive coverage with 33.3% false
positives on its tiny held-out split; a fast MiniLM SQuAD2 spike produced the
same held-out rates and was rejected. A reproducible FP32 Core ML MobileBERT
candidate improved validation positive coverage to 100% and measured 23.49 ms
median / 25.17 ms p95, but still produced 16.7% validation false positives.
Its committed evaluator exits nonzero and its artifact remains unbundled. The
fixture has only six validation scenarios and lacks contradiction, temporal,
synthesis, provenance, and order-metamorphic coverage. Evidence calibration is
a product gate, not benchmark fine print.

A DeBERTa-v3-xsmall NLI spike correctly separated several hand-authored support
and contradiction examples in PyTorch, but its relative-position attention
graph did not convert through the repository's pinned Core ML toolchain. It is
not a release dependency. The next production candidate reuses the already
convertible fixed-shape MobileBERT encoder architecture with a task-trained
three-way claim/evidence-set classifier and citation-slot head. That candidate
does not exist in the app yet and cannot qualify without blind claim-level
evaluation, Core ML parity, latency, and signed-runtime proof.

The public v2 semantic-verifier fixture is
`eval/evidence-verifier/v2-corpus.json` with SHA-256
`d612bf537fbaa8453cd0a83075722f4e7fe8ff30afab86c5a2c33e4ea42041e4`.
It has 48 cases across 24 short synthetic scenarios and usefully fails closed
on malformed or invented provenance. A fresh audit found that its answer key
is public, its partitions repeat templates, and it never scores a proposed
answer. The scorer now labels success `fixture_passed`, sets
`evaluation_scope` to `public_regression_smoke`, and always keeps
`release_qualified` false. A blind claim-level corpus executed against the
immutable signed runtime is required before a production verifier can qualify.

## Release Gates

- Run `scripts/check.sh`, `scripts/e2e-clean-home.sh`, every Swift package test,
  strict workspace Clippy, and the full workspace test suite on the release
  commit. Full Xcode is now available; the 2026-09-04 post-review matrix passed
  all 52 invoked lanes with only optional `swiftformat` absent.
- Keep the committed 30-minute capture-soak and current-source cross-app overlap
  evidence reproducible from the release commit. Prove the independent live TCC
  revocation/restoration path before calling permission recovery qualified.
- Upload the verified immutable Arctic retrieval archive, replace the explicit
  `UNPROVISIONED` manifest fields only after its stable URL exists, and repeat
  reconstruction, integrity, and completeness checks from the release commit.
- Before shipping trusted-answer or evidence-backed-claim features, train and
  qualify the claim/evidence-set verifier on a blind, scenario-disjoint corpus;
  prove citation binding, Core ML parity, calibrated abstention, and
  signed-runtime latency before adding it to the release manifest. The
  evidence-memory V1 keeps this artifact absent and semantic candidates typed
  as degraded related context.
- Rebuild the post-M4 app and DMG with the canonical installer, then inspect the
  retained signing, notarization, staple, Gatekeeper, and checksum evidence. Do
  not record secret values.
- Build, sign, notarize, staple, install, and launch on a clean second Mac;
  verify Keychain continuity across an update before publishing.
- Keep capture off by default. Keep trusted-answer presentation unavailable
  until the separate evidence-verifier gate passes.

## Owner Actions

The exact non-secret setup is in `docs/release/OWNER_SIGNING.md`. The required
protected GitHub environment secret names are:

- `APPLE_CERTIFICATE_P12`
- `APPLE_CERTIFICATE_PASSWORD`
- `NOTARYTOOL_APPLE_ID`
- `NOTARYTOOL_TEAM_ID`
- `NOTARYTOOL_PASSWORD`
- `SPARKLE_PRIVATE_KEY`

No secret value belongs in source, Markdown, shell history, app child-process
arguments, or client MCP configuration.
