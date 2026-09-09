# Work Memory Checkpoint

Date: 2026-09-09. Source baseline before implementation: `560199a`.
Canonical branch: `codex/hippocampus-v1`, draft PR25 in
`amyjainberkeley/hippocampus`. No public release is implied.

## What Changed

Today, Search and History now have different jobs. Today begins with measured
input-state distribution and foreground-app totals, followed by source-linked
resume points. A longest measured stretch opens the intervals behind it.
Search begins empty and lexical excerpts center on matching words. History is
chronological; Sessions is nested within it. Daily handoff remains a previewed,
revalidated action rather than another duplicate destination. The default
native window is 920 by 620, with a narrower sidebar and preserved keyboard focus.

Review caught a second search presentation defect: an excerpt could contain the
query while preceding newlines pushed it below the visible three lines. Literal
excerpts now begin on the matching line with at most 32 leading Unicode scalars.
Three visibility regressions failed first, then all 13 excerpt tests and the
171-case FFI suite passed. Full evidence readback and history formatting are
unchanged. The character bound is not a promise that every possible query fits
every window; full source remains available.

Activity uses a separate end-to-end path:

```text
consented capture session
  -> adjacent privacy-admitted focus/input observations
  -> bounded version-9 activity message
  -> validated, encrypted measured_activity rows
  -> bounded FFI page
  -> reconciled Today distribution and interval drill-down
```

An interval is at most five seconds; the normal sample cadence is four seconds.
Two observations must agree about attribution. Permission/session uncertainty,
focus changes, clock discontinuities, suspension and missing observations lose
attribution. These intervals are not events and never inflate screenshot or
OCR counters. They do not establish productivity, attention or task completion.

A backward clock step could previously make the sampler emit an overlapping
interval after rejecting only one discontinuous pair. A content-free emitted
time boundary now prevents that within a generation. Six clock/recovery
regressions cover the boundary and identity behavior. Across process/generation
restarts, the store still rejects overlaps without changing or clipping saved
rows. A specific, payload-free overlap error lets ingestion count that rejection
and continue unrelated OCR/health processing. Other store, validation and
corruption failures remain fatal. A reopened-store regression exercises conflict,
OCR, health and a later valid measurement in the same stream; one constant notice
per drain and separate counters avoid leaking identity or flooding the log.

The encrypted store records deletion barriers so queued pre-deletion activity
cannot be reinserted after deletion or retention. All writes pass through a
serialized, bounded helper transport: eight admitted buffers, a one-second
queue-plus-write deadline and a one-MiB wire payload cap. Interrupted partial
frames retire the transport; no later frame can be appended to an incomplete one.

Memory corrections now preserve project and authority boundaries. A correction
cannot retire a claim outside the scope that correction covers. The sequential
evaluation compares stateless, simple-context and governed-memory policies on
versioned synthetic tasks. See [evaluation instructions](../../core/brief-eval/SEQUENTIAL_EVALUATION.md).
Deterministic policy scores are not evidence that a real agent learns better.

## Evidence And Limits

The final full Rust workspace run passed 2,130 tests with nine ignored cases across
139 completed targets, using locked, offline dependencies and default features.
Strict workspace Clippy (all targets, warnings denied) and formatting passed.
The optimized Recall suite passed 526 XCTest and three Swift Testing cases.
The earlier debug run passed 527 XCTest before two further stretch regressions;
three preview-only tests are excluded from optimized builds. The full parent
suite passed 334 tests. Release-contract checks passed 230 assertions,
release-safety checks passed 16 tests, and release-identity checks passed nine.
The screen-proof headless checks passed all four suites.

The supply-chain gate scanned both tracked Cargo lockfiles with cargo-audit
0.22.2 against RustSec revision `bf25f6575a93a35f30796c65c0ed91bee7fa19fd`
(updated September 8). Both passed under the existing policy, which retains
the explicitly reported `RUSTSEC-2024-0436` waiver. This does not certify an
absence of unknown vulnerabilities, malicious dependencies or application bugs.

The release contract now watches helper, ingestion, wire, store and FFI changes
on both supported workflow events. Six regression checks failed with the old
path filters, then passed after the missing paths were added. The product
visual contract was updated to the actual three-destination navigation and
measured view; native inspection remains separate from source-shape checks.

Contacts and Calendar attribution tests now use injected stores. Construction
and unauthorized lookups cannot create an operating-system store or request
access. Nineteen fake-store cases passed twice. Production authorization still
requires the existing explicit start path. Regular-file helper output is
supported only by a bounded, counter-only one-shot health fixture. Six tests
cover that CLI path and rejection of regular-file capture/streaming output;
live transport keeps its existing bounded nonblocking path.

The sequential fixture has 14 ordered tasks. Stateless selection passed 5,
simple recent context passed 10, and governed memory passed 14. Harmful reuse
was 0, 4 and 0 respectively; the fixture privacy checks reported zero violations
in all three arms. Serialized request sizes were 6,824, 16,553 and 11,008 bytes.
These are deterministic policy results with zero model calls. Provider cost,
token cost, actual-client learning and statistical generalization are unmeasured.

Native synthetic preview checks exercised empty Search, typed-query results,
chronological History and nested Sessions. The data is explicitly synthetic,
and the preview never opens the personal brain, Keychain or capture pipeline.
This visual check cannot qualify real screenshot readback or an installed build.

## Static Screen Recovery

The existing retained-pixel retry ran immediately after a recognition timeout.
Vision can still be finishing the cancelled attempt at that point, so its serial
lane correctly rejects more work. The immediate retry could therefore be spent
without running OCR. ScreenCaptureKit need not supply another image for a static
window. A regression using the real runner's quarantine, the capture emitter,
wire encoding and encrypted retention reproduced one perform and zero saved blobs.

The worker now delivers the timed-out completion, then waits at most one worker
timeout for the lane to become available before consuming another queued job.
There is still one retry, one Vision execution lane, a four-job queue and a
one-second recognition deadline. Cancellation interrupts the bounded wait;
permanently hung work cannot create extra recognition threads. This can add up
to one second of recovery waiting after an attempt, not extend that attempt's
deadline. The original privacy snapshot, pixel identity and post-OCR checks remain
in the existing emitter path.

The focused 55-case headless suite passed; the five new cases passed five repeated
runs. The positive case requires exact OCR wire content and a nonzero keyframe
hash matching one encrypted blob from the same retained pixel buffer. Negative
cases cover late-first-result rejection, secret suppression without retention,
stop during recovery and a permanently occupied lane. The synchronous recognition
work in these tests is controlled, not Apple text recognition. This establishes
the recovery mechanism, not a live screen-origin capture or general OCR quality.

## OCR Qualification

The final optimized helper suite passed all 817 tests twice in separate test
processes, after all concurrent builds had finished. This includes actual Apple
Vision recognition, with the unchanged one-second per-attempt budget. Dense
candidate scans returned the baseline's 81 lines in 501-887 ms across the two
runs; small-label fixtures recovered all four exact labels at both image sizes.
These are local fixture results, not general OCR accuracy or supported-hardware
certification. Background OS load was not controlled.

An earlier full optimized helper run failed 30 assertions across 804 tests, all in
OCR completeness. The initial debug run failed 29 assertions across 784 tests.
An isolated optimized OCR rerun failed one assertion in 13 tests: a dense scan
exceeded the unchanged one-second deadline. Its frozen accurate single-pass
baseline took 827-1,113 ms, and candidate scans took 815-1,049 ms. Low Power Mode
was enabled. In the full run, even the baseline required 1,936-2,123 ms.
Those observations localize the dense-screen failure to baseline recognition
cost, not only optional supplemental regions. They do not prove a root cause,
qualify cold starts, or establish reliability under arbitrary load. The failures
remain in the audit history. The quality tests now drain their isolated Vision
lanes between attempts, so unfinished work cannot contaminate later cases. A
separate deterministic region-loop fixture verifies deadline/late-result safety
without depending on an optional supplement being admitted before a 500 ms timer.
No quality assertion, recognition deadline or privacy rule was relaxed.

A separate controlled synthetic experiment alternated three scheduling classes
and automatic-language detection on/off. All 30 warmed scans returned the same
ordered text, taking 484-774 ms; higher scheduling priority did not materially
improve median latency. The first process-cold invocation took 1,769 ms.
This was not the production dispatch/deadline path and did not control all OS
load. It does not identify the cause of the earlier warmed misses or justify
changing the user's power settings, recognition language or scheduler priority.

The screen-only fixture now creates an exclusive, no-follow, mode-0600 receipt
file, containing a phrase hash and numeric foreground observations, never its
phrase. Two automated attempts did not generate a phrase. In the second attempt
a macOS system notification owned the foreground while the fixture remained
inactive. No phrase, screenshot or restart-readback claim is made. The system
dialog was not bypassed, and no permissions, exclusions or private data were reset.

The active-console check uses public console/login/owner signals and display
sleep, with a supplementary lock-state denial signal when present. The latter
is not a public lock-state guarantee. Real lock, sleep, fast-user-switch and
permission-loss qualification remain required.

Activity schema version 10 is additive, but an older application does not know
its deletion rules. Keeping an old application bundle alone is not a data-safe
rollback plan. A candidate installation requires a consistent encrypted
pre-upgrade backup and a deliberate recovery procedure; restoring older data
must never silently resurrect memory the owner deleted after that backup.

## Remaining Gates

### Candidate Delivery

Source checkpoint `fb73f77` is published on the canonical branch and draft
PR25. All Rust release targets and the four Swift release packages built with
an allowlisted environment. The assembled app passed the disposable-home
20-second startup and onboarding check. The app and 79 MiB private DMG are
Developer-ID signed, notarized and stapled. A read-only mount of the completed
DMG passed nested signing, Gatekeeper, ticket and complete source/payload
provenance verification. A separate candidate app copy also passed provenance.
The verification mount was detached afterward.

The exact artifact and Apple receipts are recorded in [STATUS](../STATUS.md).
No public release, website change or installation is implied. The installed
manifest still names `fe90a3d`; the owner must quit it before the quiescent
encrypted backup and controlled upgrade in the
[owner procedure](../release/OWNER_UPGRADE_2026-09-09.md). Native UI control
timed out, so no quit or migration was forced.

The new hosted capture run also retains failures:
[GitHub job](https://github.com/amyjainberkeley/hippocampus/actions/runs/34332650723/job/102404628853).
All 59 assertion failures across 817 tests are in OCR completeness. Dense
baseline scans take 3,620-3,773 ms; candidate deadlines expire at 1,009-1,093 ms.
The five controlled static-screen recovery tests pass, but that does not repair
the runner's real-recognition throughput. The local optimized passes and hosted
failure are separate evidence. The source checkpoint is not universally
OCR-qualified or ready for a public release.

### Unmet Acceptance

1. Generate a fresh phrase in the real foreground, then prove screen-origin
   text, authenticated linked image, restart readback and actual client retrieval.
2. Qualify exclusion, lock, pause, permission loss, crash, deletion and storage
   failure on the installed candidate, not only injected tests.
3. Measure an actual day and validate its totals against independent observations.
4. Run the sequential evaluation through a supported real client under explicit
   provider configuration; keep synthetic policy scores separate.
5. Improve semantic understanding, confirmed commitments, storage-budget policy,
   OCR qualification on every supported Mac and second-Mac update continuity.

Website and icon redesign are not included in this source checkpoint. The
optional corner companion remains deferred. `docs/STATUS.md` is the authority
for the installed revision, publication state and exact completed qualification.
