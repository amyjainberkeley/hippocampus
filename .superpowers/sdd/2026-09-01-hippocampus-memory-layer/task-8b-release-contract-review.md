# Task 8b Release Contract Review

**Verdict: FAIL**

Reviewed commits:

- `f5824e267c5a81c7d9ffb8cbc912f936b1e9f481`
- `210259991c6c41b1879be17fea7c310db3f8b6ca`
- accepted brand guard `506276c` where it participates in release preflight

Reviewed the requested release docs, shell contracts, Cargo workflow, and tag
release workflow. Unrelated dirty Task 2 and Task 5 files were ignored.

## Findings

### [P1] The tag workflow cannot assemble an app from a clean checkout

`.github/workflows/release.yml:59-63` builds only the Hippocampus package, the
capture helper, and the Cargo workspace. The invoked assembler requires
`apps/recall-ui/.build/release/recall-ui` and
`apps/onboarding/.build/release/onboarding`, but neither Swift package is built.
Those artifacts are not tracked, so `build-app.sh` exits at its binary gate
before a DMG exists.

The same clean checkout also lacks all three mandatory, gitignored model
bundles, and the workflow contains no reconstruction/download step. Even after
adding the missing Swift builds, `build-app.sh`/`build-installer.sh` will reject
the absent Arctic Embed S, BERT NER, and Qwen3 artifacts. Finally,
`docs/STATUS.md` records `460d610...`, 17 commits behind `2102599`, while the
assembler permits at most three; default `actions/checkout` depth also does not
guarantee that ancestor is present. This contradicts
`RELEASE_CHECKLIST.md:11-13` and means the release job has no successful clean
path.

### [P1] The newly blocking Clippy job fails on the reviewed commit

From a clean archive of `2102599`, `cargo fmt --check` passed, but the exact
`.github/workflows/cargo.yml:66` command failed:

```text
cargo clippy --workspace --all-targets -- -D warnings
```

Clippy reported five denied warnings in
`adapters/macos/mci-keychain/src/lib.rs`: three `borrow_as_ptr` findings and two
`ptr_cast_constness` findings. Because the workflow file itself is in the path
filter, this release-hardening change cannot pass its own PR CI gate.

### [P1] Publication happens before the promised draft inspection gate

`.github/workflows/release.yml:143-176` signs the appcast and pushes both the
appcast and DMG to a public Pages repository before
`.github/workflows/release.yml:178-188` creates the draft GitHub release. A tag
therefore exposes release artifacts and a live update feed before an owner can
inspect the draft. This directly reverses `RELEASE_CHECKLIST.md:95-97`, which
requires the draft and inspection first and publication only after every gate
is checked.

### [P1] The update channel is internally inconsistent and cannot deploy as documented

The workflow publishes a `ghpages` appcast whose enclosure points at
`amyjainberkeley.github.io/hippocampus-appcast`, while the shipped
`SUFeedURL` is `https://hippocampus-swart.vercel.app/appcast.xml`. Existing
installs will not read the feed this job publishes.

The deploy step also authenticates to the separate `hippocampus-appcast`
repository with this repository's `${{ secrets.GITHUB_TOKEN }}`. A workflow
`GITHUB_TOKEN` is repository-scoped and cannot push to a sibling repository;
an explicitly scoped GitHub App token, deploy key, or fine-grained token is
required. The runbook says Pages uses `main`, while the workflow hard-requires
and pushes `gh-pages`. Following the documentation therefore makes the job fail
at `git ls-remote` even before the token problem.

### [P1] Version identity and Sparkle trust are assertions, not gates

The trigger accepts any `v*` tag, but no step compares that tag with
`CFBundleShortVersionString`, `CHANGELOG.md`, the DMG filename, the appcast
version, or enclosure URL. A `v0.2.0` tag can publish a `0.1.0` bundle and
appcast. This violates `RELEASE_CHECKLIST.md:9-10`.

Likewise, the secret gate proves only that `SPARKLE_PRIVATE_KEY` is nonempty.
Neither `check-signing-prereqs.sh` nor the workflow derives its public key and
compares it with the app bundle's `SUPublicEDKey`, despite
`OWNER_SIGNING.md:102-105` and `RELEASE_CHECKLIST.md:76` saying a placeholder or
mismatch must block publication. A wrong but nonempty key produces an appcast
that shipped clients reject.

### [P2] The release contract test is both incomplete and unwired

`scripts/test-release-contract.sh` reports `14 passed, 0 failed` while every P1
above remains present. It tests string presence, not the release graph or
artifact identity. It has no assertions for required Swift packages, model
reconstruction, status provenance, tag/version/feed agreement, Sparkle key
matching, cross-repository credentials, or publication order.

No workflow and no `scripts/check.sh` lane invokes this script, so even its
current guards are not automatic CI gates.

### [P2] Outer-DMG distribution verification is incomplete

The workflow validates the app with `codesign` and `spctl`, and validates
staples on the app and DMG. It does not verify a Developer ID signature on the
outer DMG or run Gatekeeper's open assessment for it. The called installer
notarizes and staples the DMG but does not `codesign` the final DMG. The release
path should either sign and verify the outer image, or explicitly document and
test an unsigned-container policy. As written, the step's “Signature and
notarization tickets valid” message overstates what was checked.

## Passing Evidence

- `actionlint v1.7.7` accepted both workflow files with no diagnostics.
- `bash -n` accepted all reviewed and transitively called shell scripts.
- `git diff --check f5824e2^..2102599` passed for the review scope.
- `scripts/test-release-contract.sh` completed with `14 passed, 0 failed`.
- `scripts/check-signing-prereqs.sh --release` failed closed on this Mac with
  three real blockers: Command Line Tools instead of full Xcode, no notary
  profile, and no Developer ID Application identity. Unknown arguments return
  exit code 2.
- The release workflow no longer contains optional/ad-hoc signing branches.
- The installer brand regression suite passed `2 passed, 0 failed`; canonical
  and volume icons are byte-identical, and `build-installer.sh --verify-assets`
  passes.
- No direct secret-value echo or committed credential was found in the reviewed
  files. Secrets are mapped through step-local environments. This does not cure
  the missing cross-repository credential or Sparkle key-match gate above.

## Required Repair Order

1. Make a clean tag checkout reproducibly build every required binary and
   reconstruct/hash every required model; fetch sufficient history and refresh
   the status baseline.
2. Make the exact blocking Clippy command pass.
3. Freeze and enforce one release identity: tag, bundle, changelog, DMG,
   appcast, feed URL, and download URL.
4. Verify the Sparkle private/public key pair and define a working, documented
   cross-repository publication credential and branch.
5. Create and inspect the draft artifact before any public appcast/DMG update.
6. Sign/verify or explicitly govern the outer DMG, then extend and wire the
   release contract test so all of these regressions fail in CI.

No production files were edited during this review.
