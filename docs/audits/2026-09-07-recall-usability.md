# Recall Usability Review

This review follows the owner's September 7 foreground-document exercise and
native-app feedback. Source publication, website deployment, local installation,
and public release are separate. Current qualification is in [STATUS](../STATUS.md).

## Findings And Changes

| Observed problem | Root cause | Correction |
| --- | --- | --- |
| Unrelated results for a precise phrase | Human search always used hybrid retrieval when an embedder existed | Text search is the default; Related remains an explicit, unverified-context mode |
| App/date search could miss a matching event | Lexical ranking applied its result cap before the filters | Apply constraints in SQL before ranking and limiting, including typed alias alternatives |
| Opening a result still showed only a fragment | Lists and detail used the same 280-character payload | Fetch selected-event text separately, capped at 128 KiB with an explicit truncation flag |
| Screenshot copy remained incomplete | Its inspector had a separate snippet-only export path | Reuse the bounded full-text reader and preserve the event citation in copy/export |
| Every destination started with the same content | A shared filmstrip preceded every page | Each destination owns its content; Now, Search, Timeline, Episodes and Briefs no longer repeat that header |
| A text match displayed 0.0% | Uncalibrated BM25 ranks were formatted as confidence percentages | Remove numeric confidence claims from evidence presentation |
| Storage size was misleading | Only the main database file was counted | Explicitly measure database, WAL, SHM and managed screenshot files, with partial/unavailable outcomes |
| Filtered browsing could omit older matching history | A recent-event candidate pool was narrowed in the UI | Explicit browse applies date, source union and URL constraints before its chronological limit |
| Next-midnight events appeared in yesterday | Calendar end bounds were passed to an inclusive endpoint | Convert the half-open calendar interval at the FFI boundary |
| Agent sources could not be selected | A new source-ID validator assumed only native bundle-ID characters | Preserve exact bounded UTF-8 source IDs, including MCP tags; bind every SQL value |
| Too many selected sources caused an avoidable query error | The picker allowed more selections than the wire contract | Cap new selections at 32; preserve and visibly explain oversized saved selections |

The review also identified inherited event-ID reuse after deletion. Full-text
responses must match the selected event's timestamp and app identity, not merely
its numeric ID. This is a guarded read, not a migration to globally unique event
identity. Final integrated qualification is recorded in STATUS before any
installed-app claim.
An event replaced with the same numeric ID, timestamp and app still cannot be
distinguished by this tuple. Durable generation/content identity remains an
inherited gap; the regression does not prove globally unique event identity.

## What The Live Check Established

The owner's synthetic foreground marker reached durable storage, recall and
agent context. The existing bounded proof found the same event across those
surfaces. It did not establish exhaustive absence of a background marker because
one query reached its result cap. Its current interface also cannot authenticate
the stored screenshot. This is positive text-ingestion evidence, not a complete
capture/privacy qualification. No permissions, keys or personal memories were reset.

A separate disposable, synthetic store exercised the native app. A Text query
found the expected fixture; a nonexistent marker returned no matches. Selecting
a result displayed its complete stored text rather than the list preview.
Privacy's explicit refresh measured 807 KB of managed logical files, compared
with 365 KB for the main database alone. These are fixture sizes, not a claim
about typical monthly growth. Initial UI inspection exposed a compact-window
layout problem and a snippet-only screenshot inspector. A fresh post-fix native
pass verified full stored text in the inspector; search, selection, no-match,
Timeline, Episodes and Briefs remained visible and distinct. At a 725-by-492
window the selected detail replaces the result list with a back action instead
of forcing the window to grow. The no-match transition no longer produced the
observed blank navigation/layout cycle. This is a synthetic UI check, not an
overnight reliability or live OCR benchmark.
Later inspection still emitted AttributeGraph cycle warnings during the broader
navigation/sheet session. The blank no-match failure did not recur, but a clean
runtime-log claim is not supported by that pass.
Narrowing the root and command-overlay subscriptions to visibility changes
removed those warnings in a fresh search/detail/no-match, resize and help pass.
The optimized build's palette also received keyboard focus immediately and
dismissed with Escape after deferred focus replaced its early on-appear write.

## Installed Checkpoint

Commit `c5a8774` was built, Developer ID signed, notarized, stapled and installed
without replacing the memory store or resetting permissions. Post-copy source
provenance and Gatekeeper acceptance pass. Its read-only agent can still read
the owner's earlier foreground fixture across storage, recall and context.
The capture receipt advanced after installation, including a new screenshot.
An additional automated TextEdit fixture did not establish a fresh match across
all surfaces; this is recorded as inconclusive, not a passed capture test.
Actual foreground state was not independently established by background app
control. Screenshot readback is still outside the current proof interface.

The real production window could not be inspected through the GUI tool because
the call timed out. Native interaction evidence in this report is from the
optimized binary against a disposable synthetic store. The public product image
uses that same synthetic interface, not the owner's data. No overnight or
second-Mac claim follows from installation or screenshot inspection.

Hosted CI at `f3a689c` passes parent, onboarding, Recall, installer, Rust tests,
formatting, strict Clippy and cargo audit. Capture reports 56 failures across
691 tests on the hosted Mac, while the retention-contract process exits 137.
Both remain release blockers despite the passing local suites.

## Safety Boundaries

- Full text is read for one selected admitted event through the existing
  read-only store. Missing, deleted, suppressed and invalid IDs do not return
  text. UTF-8 boundaries, byte limits, cancellation and stale selection are tested.
- Copying a memory does not qualify its contents as instructions or truth.
  Screenshot context retains source provenance and fences the literal text.
- Storage accounting reads metadata, not decrypted content. It refuses symlink
  traversal, has path/entry/time budgets, and runs off the UI actor only on
  explicit refresh. The deadline cannot interrupt an individual OS call.
- Screenshot counts and episode spans are not active work duration. No pie chart
  or judgment about distractions is inferred from those counts.
- No broader screen-capture permission or hidden-tab collection was introduced.
  Better access to stored text cannot recover text that OCR never recognized.
- No cloud inference service or automatic paid model usage was introduced.

## Writer-Lock Investigation

The first integrated Rust run failed an existing immediate-reacquisition test:
the command had ended, but the kernel still reported a held writer lease. An
isolated rerun passed. A deterministic duplicate-descriptor test then reproduced
the same condition: closing one descriptor does not unlock a lock while another
reference remains. This proves the duplicate-descriptor mechanism, not that a
specific fork caused the original intermittent failure.

Clean release now explicitly unlocks after removing the crash marker. The
long-running agent's process-exit lease remains held through runtime teardown;
unclean-drop behavior is unchanged. The regression also checks that closing an
old descriptor cannot release the next owner's independent lock.

The implementation follows the documented shared-lock semantics in
[Apple's flock manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html),
[Linux man-pages](https://man7.org/linux/man-pages/man2/flock.2.html), and
[FreeBSD's manual](https://man.freebsd.org/cgi/man.cgi?query=flock&sektion=2).

## Remaining Product Work

Measured activity intervals, trustworthy commitment extraction, richer semantic
briefs, sustained capture qualification, second-Mac qualification, a user-chosen
byte budget, and redistributable release-model provisioning remain distinct work.
An extractive daily draft is not a completed understanding engine. Episode
linking is not storage compression. The website must not imply otherwise.
