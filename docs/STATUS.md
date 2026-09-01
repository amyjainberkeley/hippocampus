# Hippocampus Status

_Audited on 2026-09-01._

Audited code baseline: `460d610cc314708ceec47dcafb87ccb1dde3aeda`

This SHA names the immediate committed code baseline that preceded the Task 1
documentation repair. It does not claim that this document's eventual commit
can refer to itself. Release builds require the baseline to exist locally, be
an ancestor of `HEAD`, and be no more than **3 commits** behind `HEAD`. The
three-commit window covers this documentation repair plus at most two adjacent
sprint repair commits; Task 8 must refresh the audit at final integration.

This file is the canonical release-status page for the repository. `README.md`,
`docs/DESIGN.md`, release notes, and release tooling must not claim more than
what is listed here.

## Working Surfaces

- The local recall path works today: SQLCipher storage, FTS5 search, recall UI
  reads, export, delete/wipe actions, and MCP over stdio.
- Semantic recall works when the Arctic Embed S Core ML artifact is present and
  backfill has run. The current runtime is Core ML on macOS with compute units
  pinned to CPU, and retrieval is a Rust-side cosine scan over stored vectors.
- `mci-agent mcp-sync` is wired and loopback-tested against local MCP servers.
- Mail and Messages deep-hook ingest can persist allowed rows after their
  cascade checks when those paths are enabled and Full Disk Access is granted
  where required.
- The app bundle consumes committed `CHANGELOG.md` and `models.json` sources;
  release preflight rejects a missing current-version note, a stale status
  audit, or missing local model artifacts.

## Disabled Or Unverified Surfaces

- Live screen capture is off by default. The current lift is a boot-time opt-in
  via `HIPPOCAMPUS_ENABLE_V2P1=1`; all-day soak verification and release
  ratification are still owed.
- Task 2 is migrating default database-key custody from the legacy
  `~/Library/Application Support/MCI/dev.key` file to the macOS Keychain item
  with service `ai.hippocampus.brain` and account `database-key-v1`. That task
  is under repair; end-to-end migration and clean-install release verification
  are pending, so the Keychain path is not yet accepted as shipped.
- Delete is local row deletion plus `VACUUM`. Crypto-shredded range deletion is
  still design intent, not current behavior.
- Multi-device sync, clean-install release verification, and Windows remain
  unverified for v1.

## Release Gates

- Focused Rust and Swift suites must pass on a host with the required Apple
  toolchain.
- A clean Mac install must cover key initialization or migration, optional
  capture opt-in, evidence creation, search, episodes, briefs, and MCP.
- Live capture needs a real-machine soak and release sign-off before the default
  can change.
- Task 2 key migration and Task 3 benchmark reviews must pass before either is
  described as accepted release behavior.
- Release docs and product copy must continue to avoid Secure Enclave, Neural
  Engine, sqlite-vec runtime, zero-knowledge sync, or crypto-shred claims until
  those paths are actually shipped.
- Owner-only signing and publishing credentials must be present without
  modifying source files.

## Benchmark Status

A committed synthetic retrieval baseline now exists at
`docs/eval/work-memory-baseline.json`, landed by Task 3 commit `235107e`. It is
a current measured artifact under review, not an accepted Task 3 result. The
run contains 24 cases: 21 answerable and 3 intentionally unanswerable.

| Arm | Answerable outcome | Hit rate @1 | Recall @1 / @3 | MRR | Unanswerable outcome | p95 latency |
|---|---:|---:|---:|---:|---:|---:|
| Lexical | 7/21 matched; 14 missed | 33.3% | 33.3% / 33.3% | 0.333 | 3/3 abstained; 0 false positives | 7.66 ms |
| Hybrid | 21/21 matched; 0 missed | 100% | 92.9% / 100% | 1.000 | 0/3 abstained; 3/3 false positives | 57.82 ms |

The hybrid arm retrieved every answerable case but also returned a result for
all three unanswerable cases. The artifact measures retrieval and provenance;
answer generation was not run or measured.

## Clean-Clone Release Inputs

Committed inputs:

- `CHANGELOG.md`, including nonempty notes for the
  `CFBundleShortVersionString` in `apps/hippocampus/Resources/Info.plist`
- `docs/STATUS.md`, with an existing ancestor audit SHA no more than 3 commits
  behind `HEAD`
- `apps/hippocampus/Sources/HippocampusKit/Resources/models.json`

Local model inputs required before building a release bundle:

```bash
python scripts/convert_embedder.py --output models/ArcticEmbedS_INT8.mlpackage --verify
python scripts/convert_ner.py --verify --compile
mkdir -p models && curl -L "https://huggingface.co/amyjainberkeley/mci-coreml-models/resolve/main/Qwen3-1.7B-FP16.mlmodelc.tar.gz" -o /tmp/Qwen3-1.7B-FP16.mlmodelc.tar.gz && tar -xzf /tmp/Qwen3-1.7B-FP16.mlmodelc.tar.gz -C models
```

For a missing committed changelog, restore it with `git restore CHANGELOG.md`.
Maintainers may use `./scripts/gen-changelog.sh --output CHANGELOG.md` only as a
starting point; the generated commit inventory must be curated into a nonempty
section for the current bundle version before release.

## Owner-Only Credential Actions

- Create or install a `Developer ID Application` certificate in the login
  keychain for signed macOS release builds.
- Store the notarization profile with
  `xcrun notarytool store-credentials notarytool-profile ...`.
- Keep the Sparkle EdDSA private key outside the repo and provide it only at
  appcast publication time.
