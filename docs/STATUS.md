# Hippocampus Status

_Audited on 2026-09-02._

Audited code baseline: `30c7580`

This SHA is the immediate committed baseline before this status refresh. The
release assembler requires it to be an ancestor of `HEAD` and no more than
three commits behind. This file is the repository's canonical product and
release truth; README, design docs, release notes, and UI copy must not claim
more than this page.

## What Works

- The local memory ledger works: SQLCipher storage, FTS5 search, typed recall,
  timeline reads, episode derivation, briefs storage, export, deletion/wipe,
  authenticated encrypted keyframe reads, and stdio MCP.
- `mci_context` compiles a bounded handoff with typed outcomes, abstentions,
  source priority, and canonical event citations. Claude Code and Codex
  registration is structural, idempotent, ownership-safe, and records only a
  database path plus Keychain service/account references.
- Daily briefs work without a model download. The deterministic extractive
  author removes capture headers and duplicate OCR churn, prioritizes explicit
  changes and open loops, caps output at nine bullets, and cites the exact
  canonical event behind every bullet. Stored author provenance distinguishes
  this path from optional experimental model output.
- Event, range, retention, and full-brain deletion remove last-reference
  encrypted keyframe blobs. Every retention cycle also reconciles canonical
  crash orphans and stale managed temporary files after a one-hour grace
  period, without following symlinks or deleting unknown entries. A missing
  retention file receives the fresh-install `forever` default; an existing
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
  stamps each payload with the committed supervisor generation, and rejects
  stale or missing generations before socket delivery.
- The production capture session now owns a live TCC monitor. A permission
  denied before helper startup is applied as an immediate fail-closed pause and
  emits the same content-free, actionable app status as a mid-run revoke;
  restoration remains direction-asymmetric and requires two granted samples.
- Semantic recall works when the Arctic Embed S Core ML artifact is present
  and backfill has run. The macOS runtime uses CPU Core ML for inference and a
  Rust cosine scan over vectors stored inside SQLCipher; there is no separate
  vector service or shipped sqlite-vec retrieval path.
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
  retired score critic remains available to tests but is no longer installed
  by production construction.
- The menu app, onboarding, Recall workspace, icon, installer art, extensions,
  and documented product captures use one light native visual system. Native
  macOS material supplies the translucent top surfaces, dark system appearance
  does not turn the product black, and the retired turquoise identity is not
  present in the release asset set.
- The app, capture helper, Recall, and onboarding Swift packages compile on
  this host through the constrained SwiftPM wrapper. The complete Rust gate
  passes formatting, all-target workspace Clippy, every workspace test, and
  dependency audit. The shell and executable behavior lanes pass, including
  capture/privacy, release identity, model integrity, product truth, clean-home,
  app launch, and visual contracts. This host's current Command Line Tools
  installation does not include XCTest, so full Swift package test execution
  requires full Xcode or CI; production package builds and executable fixtures
  remain locally runnable.
- A `178 MB` debug ad-hoc app assembled from the audited code with Arctic Embed
  S as its only bundled model, passed model validation, and survived the
  disposable-home first-launch gate with onboarding attached. This proves a
  runnable development bundle, not a distributable Apple release.
- A throwaway-home E2E installs the engine, starts with capture disabled,
  imports 20 synthetic events, injects one shared-encoder `OCREvent` through
  production `--drain-stdin --strict`, derives episodes, persists and reads
  back a brief, verifies MCP recall/timeline/episodes/cited context, registers
  both supported clients without key material, deletes the injected event,
  and uninstalls without isolated product residue.

## What Is Not Yet Proven

- Real `ScreenCaptureKit` capture remains off by default. The executable
  `scripts/run-live-capture-overlap.sh` gate now assembles an exact ad-hoc app,
  requires Screen Recording and Accessibility for that helper, foregrounds a
  synthetic overlapping-window corpus, captures through the bundled helper and
  agent, and proves focused-window recall plus background-window abstention.
  Its contract is tested and the unlocked-session preflight passes. The first
  two of three live attempts reached the ScreenCaptureKit first-sample callback,
  focused-window filter installation, encrypted brain open, and Arctic model
  load. The third, against `130e5f1`, proved the new startup
  `tcc_revoked=accessibility` signal and a healthy short page-content socket.
  All correctly retained no OCR because Accessibility was denied to the exact
  ad-hoc helper; the privacy cascade paused or suppressed instead of guessing.
  User Notification Center, WhatsApp, and Codex separately stole focus, so
  focused-token recall and background-token absence are not yet proven. The
  harness now uses a short `/tmp` root so its isolated Unix socket remains below
  Darwin's 104-byte path limit. A fresh run with Accessibility granted, an
  uninterrupted foreground corpus, and the required 30-minute soak remain open.
- OCR is therefore not yet launch-qualified against cross-window leakage. Ambient
  ScreenCaptureKit OCR excludes browser windows entirely; Safari and Chromium
  use separate structured capture paths that reject private contexts before
  reading page content, with executable release tests. Automatic OCR enablement
  remains blocked until the overlapping-window corpus and live soak pass.
- The now-production-wired TCC and screen-sharing revocation monitors are not
  yet proven by a live grant/revoke/restore run. Delete and wipe operations
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
  Signed clean-install and cross-version ACL continuity cannot be accepted
  until a stable Developer ID bundle is available.
- This machine has Command Line Tools rather than full Xcode, zero valid code
  signing identities, and no `notarytool-profile`. It cannot produce or claim a
  Developer ID-signed, notarized public release.
- A verified local Arctic Embed S Core ML bundle is present in the gitignored
  development model directory and is included by debug ad-hoc assembly, so that
  artifact supports semantic recall. It is the sole required release model.
  BERT NER is absent and Tier-1 entity extraction remains active. Qwen3 is
  absent and evidence-cited extractive briefs remain active. Qwen is an
  optional custom-build experiment, not a shipped download or release gate.
  The immutable Arctic release archive is still unprovisioned, and the debug
  app is not distributable.
- Multi-device sync and Windows are outside the verified v1 path.

## Benchmark Status

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

| Arm | Answerable outcome | Hit rate @1 | Recall @1 / @3 | MRR | Unanswerable outcome | p95 latency |
|---|---:|---:|---:|---:|---:|---:|
| Lexical | 7/21 ranked; 14 missed | 33.3% | 33.3% / 33.3% | 0.333 | 3/3 abstained; 0 false positives | 10.00 ms |
| Hybrid | 21/21 ranked; 0 missed | 95.2% | 88.1% / 100% | 0.976 | 3/3 abstained; 0 false positives | 62.32 ms |

The artifact is complete and publishable but explicitly
`"launch_qualified": false`. Retrieval abstention passes the three
unanswerable cases, but all 21 answerable hybrid rankings are deliberately
recorded as `degradedEvidenceVerifierUnavailable`, not trusted matches. The
explicit relation guard is qualified on its narrow person/count/duration/date
corpus, leaving the missing semantic verifier as the single quality failure.
The prior score critic reached only 83.3% positive coverage with 33.3% false
positives on its tiny held-out split; a fast MiniLM SQuAD2 spike produced the
same held-out rates and was rejected. The benchmark exits nonzero even though
ranking and typed abstention pass. Evidence calibration is a product gate, not
benchmark fine print.

## Release Gates

- Run `scripts/check.sh`, `scripts/e2e-clean-home.sh`, every Swift package test,
  strict workspace Clippy, and the full workspace test suite on the release
  commit. Full XCTest remains a full-Xcode gate on this host.
- Complete a real 30-minute capture soak with frame, OCR, retained-keyframe,
  CPU, memory, disk, pause, and protected-surface observations.
- Run the focused-window overlap gate on an unlocked Mac, prove live TCC
  revocation behavior, then complete the 30-minute resource and privacy soak.
- Provision and reconstruct the immutable Arctic retrieval archive named by
  `release-models.json`, then pass its integrity and completeness checks.
- Install full Xcode, a Developer ID Application identity with private key,
  and the `notarytool-profile`; verify the Sparkle private/public pair without
  recording secret values.
- Build, sign, notarize, staple, install, and launch on a clean second Mac;
  verify Keychain continuity across an update before publishing.
- Keep capture off by default and hybrid recall unqualified until their
  respective measured gates pass.

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
