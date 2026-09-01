# Hippocampus Release Checklist

This is the blocking checklist for a public Hippocampus macOS release. A local
ad-hoc build is a development artifact, never a distributable release.

## Source And Version

- [ ] Worktree is clean and the release commit is recorded.
- [ ] Tag, `CFBundleShortVersionString`, changelog, DMG name, appcast version,
      and download URL agree.
- [ ] `docs/STATUS.md` names the tested commit and contains no stale shipped
      claim.
- [ ] Required models are reconstructed and pass hash/completeness checks.
- [ ] The committed synthetic benchmark and frozen calibration artifact pass
      provenance checks; the report states whether launch qualification passed.

## Privacy And Memory

- [ ] A pre-existing legacy brain migrates to Keychain without data loss.
- [ ] Every migration failure leaves the legacy key available for recovery.
- [ ] A successful migration removes the reusable legacy plaintext key only
      after Keychain reread and read-only database validation.
- [ ] Capture-off starts no `SCStream`, OCR, context provider, or keyframe
      writer and requests no screen-recording permission.
- [ ] Capture-on is shown only after the expected helper generation reports
      successful stream startup.
- [ ] Protected surfaces never reach condensation, OCR, or persistence.
- [ ] Screenshot blobs authenticate and decrypt for evidence thumbnails;
      plaintext, wrong-key, missing, legacy, and corrupt inputs fail neutral.
- [ ] Retrieval uses typed matched, nothing-matched, and degraded outcomes.
- [ ] Claims retain source event IDs, confidence/provenance, supersession, and
      retraction behavior.
- [ ] Claude and Codex configuration contains Keychain references only, never a
      database key or legacy-key path.

## Automated Gates

Run on a quiet host and retain command logs:

```bash
./scripts/check.sh
./scripts/test-swift-package.sh
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

- [ ] All functional suites pass.
- [ ] Performance tests are rerun without competing compilers or benchmark
      processes; measured failures are not relabeled as passes.
- [ ] The release-profile insecure-keywrap compile guard fails as designed.
- [ ] Isolated-home E2E covers init, synthetic import, capture-off, injected
      capture, search, timeline, episode, brief, MCP context, deletion, and
      uninstall.

## Unsigned Artifact

- [ ] Full Xcode is selected and every Swift package compiles/tests.
- [ ] Release Rust FFI is rebuilt deterministically; no stale debug archive is
      linked into Recall.
- [ ] App bundle launches from a clean home with required models/resources.
- [ ] App icon, installer background, volume icon, and drag direction pass.
- [ ] Light and dark screenshots pass at 1440x900, 1024x700, and 760x520.

## Owner Signing

Complete `OWNER_SIGNING.md`, then verify:

```bash
./scripts/check-signing-prereqs.sh --release
```

- [ ] Full Xcode is active.
- [ ] A valid Developer ID Application identity with private key is present.
- [ ] `notarytool-profile` authenticates successfully.
- [ ] Sparkle private/public keys match.
- [ ] GitHub release secrets exist and are scoped to the release environment.

## Signed Artifact

- [ ] Every nested executable/framework is signed before its parent.
- [ ] Hardened runtime and secure timestamp are present.
- [ ] `codesign --verify --deep --strict` passes.
- [ ] `syspolicy_check distribution` passes where available.
- [ ] The app and outer DMG are notarized as required by the release pipeline.
- [ ] `stapler validate` passes for every stapled artifact.
- [ ] Gatekeeper accepts a freshly downloaded/quarantined copy on a second Mac.
- [ ] DMG checksum sidecar verifies.
- [ ] Sparkle appcast XML validates and the enclosure signature verifies.
- [ ] Update from the previous public version succeeds without losing the
      Keychain-held database key or capture preference.

## Publication

- [ ] Review the notary log even when Apple returns Accepted.
- [ ] Create a draft release first; inspect artifacts before making it public.
- [ ] Publish the DMG and appcast only after every gate above is checked.
- [ ] Record release commit, checksum, notarization submission ID, and smoke-test
      machine/OS in the release record. Never record secret values.
