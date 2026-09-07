# Observable Product Gates

This is the owner's ordered acceptance contract, not a completion estimate.
No higher product gate can compensate for a failed lower one. Test counts,
commits, imported transcripts and growing storage counters are not end-to-end
screen-memory evidence. [STATUS](../STATUS.md) remains the release authority.

## Gate Ledger

| Gate | Required observation | Current evidence |
| --- | --- | --- |
| 0. Establish the build | Identify source, installed binaries, running processes, effective policy, database and capture generation. | Runtime identity established for signed, notarized installed `48251bd`, including process mappings, shared writer/Recall database, helper/writer pipe and matching capture generation. Later CI source changes are not part of the installed artifact. |
| 1. Screen to disk to Recall | A new phrase created only in a real window becomes a screen-origin event with its linked encrypted image; text and image reopen after restart; the approved client retrieves the same evidence. | **Open.** A fresh standalone window generated a random phrase without an import or plaintext export and recorded twenty seconds of sampled active/key/visible/text-focus observations. It has not been found in captured memory. The recorder reports fail-safe suppression. Prior fixed-token checks and foreground observations do not qualify this gate. |
| 2. Privacy and recovery | Exclusions, pause, lock, permission loss, crashes, deletion and storage failure behave correctly and visibly. | **Not qualified.** Existing unit/contract tests are supporting evidence only; the full installed lifecycle matrix is not passed. |
| 3. Agent use | A supported real client obtains fresh scoped context and resolves its citations, then each additional claimed client is qualified. | **Not qualified.** This Codex session can query the installed MCP server. That alone does not establish fresh fixture recall, image identity, citation expansion or all client lifecycles. |
| 4. Daily view | Real episodes, interval-based activity totals, valid images and honest coverage gaps. | **Not qualified.** Episode linking and extractive briefs exist; measured active intervals do not. No time chart is inferred from screenshot counts. |
| 5. Commitments and distribution | Attribution-preserving confirmed intentions and final signed installation/update/live qualification. | **Not qualified.** Commitment work, second-Mac qualification, public release-model provisioning and hosted failures remain. |

## Gate 0 Record

The installed bundle's provenance verifies source
`48251bdb8c13e7d708a7d8f7a5f22192fcbabe5e` and product digest
`ee47ab36cda1bf2a015e0220e6bfa1dc930294bba116e222039fb4447ef74668`.
Developer ID signature is `Amy Jain (BV6KGKFKP4)` with a stapled ticket.
The checked parent, Recall, helper and writer executable mappings all belong to
`/Applications/Hippocampus.app/Contents/MacOS/`.
Recall and the writer have the same database inode open, and the helper's output
pipe is the writer's input pipe. These are topology observations, not successful
memory ingestion assertions. The previous live bundle is preserved as an owner
rollback copy; its location and notarization records are in STATUS. The new
installation did not reset capture consent, permissions, policy, keys or data.

The writer uses the existing `~/Library/Application Support/MCI/mci.sqlite`.
Capture is enabled in `~/.config/hippocampus/runtime.toml`. The helper's current
generation argument matches its startup receipt and that receipt reports
capture enabled. The helper loads the signed known-app catalogue. The actual
production admission mode is `ordinaryApplications`, with mandatory sensitive
source exclusions and affirmative Accessibility checks; the catalogue alone
does not describe effective capture permission. User denylist and allowlist
files were absent in the inspected default location. No policy was loosened.

Historical MCP processes from earlier launches still exist. They were not
terminated indiscriminately. Their paths alone do not establish their loaded
revision. This session's newly launched MCP reader and the current parent-owned
writer are distinct processes; all-client refresh remains Gate 3 work.

## Gate 1 Procedure

The [screen-only fixture](../../scripts/live-capture/screen-proof-window.md)
creates its phrase inside a native test window only after an explicit click.
It emits a SHA-256 commitment and generation timestamp, never the words.
The original fixed token and any UI preview seeded by an import are ineligible.

The phrase must first appear in an event newer than the generation boundary,
attributed to the fixture and classified as screen OCR. That event must resolve
to an encrypted blob that authenticates and contains the same visible phrase.
After closing the fixture and restarting Recall, the same event and correct
image must reopen. A new read by the approved client must resolve the same
source, timestamp and citation. Missing images, placeholders, mixed identities,
caps, unavailable inspection or a screenshot of another app leave the gate open.

The current GUI-control interface can inspect the separate test window but
times out when addressing the installed shell, and cannot separately address
its bare Recall child. Background inspection is not proof of sustained real
foreground state. The improved fixture records its own foreground observations;
twenty observed seconds still produced no retrieved fixture event. This leaves
the recorder's focus/privacy decision to diagnose; no old exercise was silently
substituted. The current MCP surface cannot return an
authenticated screenshot readback, so a text-only MCP check is insufficient.

## Hosted Failures

The retention job's `swift run` diagnostic confounded build and fixture
execution: SwiftPM replaces its process with the product. Exit 137 therefore
does not establish an out-of-memory compiler failure. The revised runner
separates build, executable lookup, fixture execution and the Rust consumer.
Regression tests require errors and SIGKILL to remain failures with no retries
or execution of later gates. At `347b1b9`, the hosted retention fixtures and
Rust consumer passed. This run does not identify the earlier SIGKILL cause.
The subsequently exposed clean-home failure was reproduced as a collision with
the worker's existing daily brief. Its synthetic seed now uses a separate date;
local regression and end-to-end checks pass. Hosted clean-home verification
passed at `1c32747` and `48251bd`. The next assembly step failed because required
executables had not been built. The workflow now explicitly builds those inputs;
fifteen local safety tests pass. The complete hosted release-contract workflow
passed at `31f6736`, including assembly and clean-home checks. The separate
Recall test race was reproduced as initialization debounce colliding with
direct test calls; the test now controls ordering without a production change.
Twelve focused local Recall tests pass; its hosted rerun remains pending.

OCR diagnostics distinguish the original accurate pass from supplemental
passes and report the production budget and test environment. Timed-out text
must stay discarded; a cancellation-insensitive request must retain its lane
until it exits. The deadline and privacy assertions are not relaxed to make a
virtual Mac green. Local hardware performance does not qualify all supported
Macs.

## Product Direction

Hippocampus remembers work on a Mac, helps people find where they left off,
and shares selected context with the agents they choose. Visual evidence of
actual work is the product's center, not a general chat screen.

Keep the genuine native-app character: restrained hierarchy, compact controls,
legible images and source detail. The owner's design concerns remain open;
this qualification pass does not make another broad visual redesign.
`usehippocampus.com` is the intended later domain. No DNS, domain access,
website audience or public-download state is changed by this pass.
