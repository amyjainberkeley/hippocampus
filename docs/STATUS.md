# Hippocampus Status

_Audited on 2026-09-01 against commit `774a1ad`._

This file is the canonical shipped-status page for the repository. `README.md`,
`docs/DESIGN.md`, and release tooling should not claim more than what is listed
here.

## Working Surfaces

- The local recall path works today: SQLCipher storage, FTS5 search, recall UI
  reads, export, delete/wipe actions, and MCP over stdio.
- Semantic recall works when the operator provides the Arctic Embed S Core ML
  artifact and runs backfill. The current runtime is Core ML on macOS with
  compute units pinned to CPU, and retrieval is a Rust-side cosine scan over
  stored vectors.
- `mci-agent mcp-sync` is wired and loopback-tested against local MCP servers.
- Mail and Messages deep-hook ingest can persist allowed rows after their
  cascade checks when the operator has enabled those paths and granted Full Disk
  Access where required.
- The app bundle now carries a committed `CHANGELOG.md` and the pinned
  `models.json` manifest as release inputs for the bundled What's New and model
  flows.

## Disabled Or Unverified Surfaces

- Live screen capture ships off by default. The current lift is a boot-time
  opt-in via `HIPPOCAMPUS_ENABLE_V2P1=1`; all-day soak verification and release
  ratification are still owed.
- Key custody is still the interim `~/Library/Application Support/MCI/dev.key`
  file path. Keychain-backed custody is the target state, not the shipped one.
- Delete is local row deletion plus `VACUUM`. Crypto-shredded range deletion is
  still design intent, not current behavior.
- Multi-device sync, clean-install release verification, and Windows remain
  unverified for v1.

## Release Gates

- Focused Rust and Swift suites must pass on a host with the required Apple
  toolchain.
- A clean Mac install must cover initialize, optional capture opt-in, evidence
  creation, search, episodes, briefs, and MCP.
- Live capture needs a real-machine soak and release-signoff before the default
  can change.
- Release docs and product copy must continue to avoid Secure Enclave, Neural
  Engine, sqlite-vec runtime, zero-knowledge sync, or crypto-shred claims until
  those paths are actually shipped.
- Owner-only signing and publishing credentials must be present without
  modifying source files.

## Benchmark Status

- No committed synthetic work-memory baseline exists yet for the Task 3 dataset
  and thresholds.
- Current evidence is narrower: embedder quality regression tests, retrieval
  logic tests, and ad hoc recall examples in the docs.

## Clean-Clone Release Inputs

Committed inputs:

- `CHANGELOG.md`
- `apps/hippocampus/Sources/HippocampusKit/Resources/models.json`

Local model inputs required before building a release bundle:

```bash
python scripts/convert_embedder.py --output models/ArcticEmbedS_INT8.mlpackage --verify
python scripts/convert_ner.py --verify --compile
mkdir -p models && curl -L "https://huggingface.co/amyjainberkeley/mci-coreml-models/resolve/main/Qwen3-1.7B-FP16.mlmodelc.tar.gz" -o /tmp/Qwen3-1.7B-FP16.mlmodelc.tar.gz && tar -xzf /tmp/Qwen3-1.7B-FP16.mlmodelc.tar.gz -C models
./scripts/gen-changelog.sh --output CHANGELOG.md
```

## Owner-Only Credential Actions

- Create or install a `Developer ID Application` certificate in the login
  keychain for signed macOS release builds.
- Store the notarization profile with
  `xcrun notarytool store-credentials notarytool-profile ...`.
- Keep the Sparkle EdDSA private key outside the repo and provide it only at
  appcast publication time.
