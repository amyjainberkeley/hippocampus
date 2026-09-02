# Hippocampus Status

_Audited on 2026-09-02._

Audited code baseline: `1de21f0`

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
- Event, range, retention, and full-brain deletion remove last-reference
  encrypted keyframe blobs. Every retention cycle also reconciles canonical
  crash orphans and stale managed temporary files after a one-hour grace
  period, without following symlinks or deleting unknown entries. A missing
  retention file receives the fresh-install `forever` default; an existing
  unreadable, malformed, or unknown-value file fails closed and skips both
  expiry and reconciliation instead of silently changing policy.
- The persisted recording setting now reaches every production ingest
  boundary. The helper receives `--capture` only when enabled; the Rust agent
  receives an explicit `MCI_CAPTURE_ENABLED` value and keeps stdin, browser
  sockets, deep hooks, and MCP collection inert while off. Safari additionally
  requires an enabled App Group authority owned by the live container process,
  stamps each payload with the committed supervisor generation, and rejects
  stale or missing generations before socket delivery.
- Semantic recall works when the Arctic Embed S Core ML artifact is present
  and backfill has run. The macOS runtime uses CPU Core ML for inference and a
  Rust cosine scan over vectors stored inside SQLCipher; there is no separate
  vector service or shipped sqlite-vec retrieval path.
- The app, capture helper, Recall, and onboarding Swift packages compile on
  this host through the constrained SwiftPM wrapper. The capture-consent
  behavior fixture, Rust formatting, strict agent Clippy, all 337 agent-library
  tests, agent binary tests, agent integration tests, and current release
  contracts pass. Full Hippocampus XCTest execution still requires Xcode on
  this host; CI now owns an explicit app-test job instead of only compiling it.
- A throwaway-home E2E installs the engine, starts with capture disabled,
  imports 20 synthetic events, injects one shared-encoder `OCREvent` through
  production `--drain-stdin --strict`, derives episodes, persists and reads
  back a brief, verifies MCP recall/timeline/episodes/cited context, registers
  both supported clients without key material, deletes the injected event,
  and uninstalls without isolated product residue.

## What Is Not Yet Proven

- Real `ScreenCaptureKit` capture remains off by default. Enable commits only
  after the expected helper generation reports successful startup, and all
  secondary ingest paths now inherit that decision. The synthetic wire E2E
  proves the capture-to-memory path, not a real all-day screen capture. The
  required 30-minute soak and release-machine permission walkthrough remain
  open.
- OCR is not yet launch-qualified against cross-window leakage. Ambient
  ScreenCaptureKit OCR excludes browser windows entirely; Safari and Chromium
  use separate structured capture paths that reject private contexts before
  reading page content, with executable release tests. Automatic OCR enablement
  remains blocked until the overlapping-window corpus and live soak pass.
- The TCC and screen-sharing revocation monitors exist but are not yet proven
  by a live permission-revocation run. Delete and wipe operations now separate
  committed SQL deletion from post-commit storage-cleanup warnings, but still
  need a generation-bound writer-quiescence lease for seamless in-app use.
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
- The three release Core ML bundles are absent from this worktree. Release
  assembly must continue to fail without the complete Arctic Embed S, BERT NER,
  and Qwen3 plus tokenizer artifacts. A debug-only ad-hoc lite bundle may omit
  them for local UI verification, but it is not distributable and generated
  briefs/semantic recall remain unavailable in that artifact.
- Multi-device sync and Windows are outside the verified v1 path.

## Benchmark Status

The accepted, reproducible 24-case synthetic work-memory retrieval artifact is
`docs/eval/work-memory-baseline.json`. It covers 21 answerable and three
intentionally unanswerable cases across GitHub, terminal, browser, Slack,
Linear, and files. It measures retrieval and provenance, not answer generation,
and is not comparable to LoCoMo or LongMemEval.

| Arm | Answerable outcome | Hit rate @1 | Recall @1 / @3 | MRR | Unanswerable outcome | p95 latency |
|---|---:|---:|---:|---:|---:|---:|
| Lexical | 7/21 matched; 14 missed | 33.3% | 33.3% / 33.3% | 0.333 | 3/3 abstained; 0 false positives | 4.04 ms |
| Hybrid | 21/21 matched; 0 missed | 95.2% | 88.1% / 100% | 0.976 | 0/3 abstained; 3/3 false positives | 50.62 ms |

The artifact is complete and publishable but explicitly
`"launch_qualified": false`: hybrid retrieval returns a result for every
unanswerable query. The production evidence-sufficiency policy is also
explicitly unqualified, and the benchmark quality gate now fails whenever that
policy is unqualified even if ranking metrics improve. Abstention/calibration
is a product gate, not benchmark fine print.

## Release Gates

- Run `scripts/check.sh`, `scripts/e2e-clean-home.sh`, every Swift package test,
  strict workspace Clippy, and the full workspace test suite on the release
  commit. Full XCTest remains a full-Xcode gate on this host.
- Complete a real 30-minute capture soak with frame, OCR, retained-keyframe,
  CPU, memory, disk, pause, and protected-surface observations.
- Prove cross-window and private-browser exclusion, wire the TCC monitors into
  the production composition root, and make destructive operations quiesce the
  writer before claiming completion.
- Reconstruct the immutable model archive named by `release-models.json` and
  pass every model integrity/completeness check.
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
