# Task 8b Release Contract Final Review

**Reviewed release changes:** `accb1a21c62464489cea4a48bb778a1326e2fb8c` plus follow-up `778c0bc41f17f967368e6e23218e928a74e93258`

**Verdict:** **FAIL**

## Findings

No P0 finding was identified.

### P1 - A clean tag cannot satisfy the repository's release gates

`docs/STATUS.md:3-12` records audited baseline `460d610...` with a maximum distance of three commits. At follow-up `778c0bc`, that baseline is 26 commits behind. `apps/hippocampus/Resources/build-app.sh:95-131` enforces the baseline and distance, and the release build reaches that check at `apps/hippocampus/Resources/build-app.sh:273-287`. By contrast, the workflow's early identity check at `scripts/verify_release_identity.py:66-96` does not inspect status provenance, so `.github/workflows/release.yml:43-44` reports a successful identity freeze before the later app build fails. Follow-up `778c0bc` does not change any of these files or this result.

The second blocking gate also fails: `cargo clippy --workspace --all-targets -- -D warnings` exits 101 with 34 denied warnings, including `core/src/capture.rs:295`, `core/src/ipc/wire.rs:138-144`, and `core/src/ipc/mod.rs:266-328`. This is a required release gate at `.github/workflows/cargo.yml:50-66` and `docs/release/RELEASE_CHECKLIST.md:48-50`. `rust-toolchain.toml:1-8` selects floating `stable`, while `Cargo.toml:9-11` describes the toolchain as pinned; that mismatch permits toolchain drift to change the release gate.

**Required repair:** refresh and review `docs/STATUS.md` for the exact release commit, make the prebuild identity phase enforce the same provenance rule as the app build, clear all Clippy failures, and pin the Rust release toolchain to an exact version with one authoritative declaration.

### P1 - Sparkle archive authenticity is not established

`apps/hippocampus/Resources/Info.plist:56-57` still contains the same public-key bytes that the parent commit explicitly labeled a placeholder. The reviewed commit changes the comment but does not rotate the bytes. `docs/release/OWNER_SIGNING.md:93-115` tells the owner to generate and verify a keypair, but no generated owner public key is committed and the current remote has no corresponding repository/environment secrets available to establish a match.

More importantly, `scripts/verify_release_identity.py:141-151` only checks that `sparkle:edSignature` decodes to 64 bytes. It never verifies the Ed25519 signature over the exact DMG bytes against `SUPublicEDKey`. `scripts/test-release-identity.sh:67-85` demonstrates the gap by using an all-zero 64-byte signature and expecting staged verification to pass. That does not meet `docs/release/RELEASE_CHECKLIST.md:95-96`, which requires the signature to verify, or Sparkle's requirement that downloadable archives be cryptographically signed.

A draft release is still mutable. Shape-only validation therefore permits a replaced DMG, stale signature, wrong signing key, or fabricated signature to reach publication.

**Required repair:** provision the real owner key, commit its public half in `SUPublicEDKey`, scope the private half to the protected signing environment, and perform real Ed25519 verification over the downloaded DMG before promotion. Add negative tests for a zero signature, a one-byte DMG mutation, and a mismatched public key.

### P1 - Tag pushes expose high-value signing material without a protected release boundary

`.github/workflows/release.yml:11-12` grants `contents: write` to the entire tag-triggered job. The job imports Apple signing material and stores notarization credentials at `.github/workflows/release.yml:90-119`, materializes the Sparkle private key at `.github/workflows/release.yml:131-139`, and has no `environment:` approval boundary. Any actor able to create a matching `v*` tag can trigger this secret-bearing path.

The workflow also uses mutable action tags at `.github/workflows/release.yml:19`, `:47`, `:50`, `:60`, and `:185`. In particular, `softprops/action-gh-release@v2` runs after the signing identities, unlocked keychain, and Sparkle private key have been installed, while retaining a write-capable `GITHUB_TOKEN`. GitHub documents that actions may access `github.token` even when it is not passed explicitly, recommends least-privilege permissions, and recommends pinning third-party actions to full commit SHAs.

`docs/release/RELEASE_CHECKLIST.md:81-82` requires secrets scoped to the release environment, but `docs/release/OWNER_SIGNING.md:119-132` instead instructs repository-secret provisioning. At review time the remote had no configured environments, secrets, variables, or Pages site, so there is also no external reviewer or deployment protection presently completing this contract.

**Required repair:** create a protected release-signing environment with owner approval, prevent self-review, disable administrator bypass where available, and restrict deployment branches/tags. Store signing secrets only there. Split checkout/build from secret-bearing signing and from draft creation, use `persist-credentials: false`, grant each job only the permissions it needs, and pin every action to a reviewed full commit SHA.

### P2 - The model archive is mutable release input rather than tag-bound identity

`.github/workflows/release.yml:31-32` and `:70-80` take the model URL and digest from mutable repository variables. A changed URL and digest can therefore produce different bundled model bytes for a rerun of the same tag, and neither value is committed to the tag nor recorded in the draft/release identity. `docs/release/OWNER_SIGNING.md:134-160` also describes this as owner-side provisioning rather than a tag-owned manifest.

The extractor itself has worthwhile defenses: `scripts/prepare_release_models.py:42-47` rejects traversal/absolute paths, `:75-100` rejects links and special entries, and `:101-109` uses bounded extraction and an atomic rename. However, completeness is only filename and non-empty-weight validation at `scripts/prepare_release_models.py:55-62`; `scripts/test-prepare-release-models.sh:32-58` exercises tiny dummy files rather than a loadable model or a committed manifest.

**Required repair:** commit a model manifest containing the immutable URL, SHA-256, expected files, and model identity to the release tag; validate the workflow inputs against it; record it in release metadata; and add a lightweight load/identity test for the exact bundled model.

### P2 - Publication is ordered correctly but cannot recover from a partial failure

The draft-before-public sequence is correct: `.github/workflows/release.yml:184-194` creates a draft, and `.github/workflows/publish-release.yml:75-79` promotes it only after staged checks. The recovery contract is not correct. `.github/workflows/publish-release.yml:37-45` refuses to run unless the release is still a draft, but Pages deployment occurs afterward at `.github/workflows/publish-release.yml:81-83`. If promotion succeeds and Pages deployment fails, a rerun is rejected, leaving a public release with a stale or missing appcast and no supported repair path.

The feed URL itself, `apps/hippocampus/Resources/Info.plist:54-55`, has the correct GitHub project-site shape. The `github-pages` environment named at `.github/workflows/publish-release.yml:26-30` is not proof of manual approval: required reviewers, self-review prevention, and bypass rules are external settings, and none were configured at review time. Pages itself was also not enabled; `actions/configure-pages` does not enable it by default with `GITHUB_TOKEN`.

**Required repair:** make publication idempotently resumable after promotion by verifying the exact public asset/signature/digest before redeploying the feed, or ensure feed deployment is complete before the irreversible public transition. Configure Pages and a protected `github-pages` environment, then document and verify those repository settings as release prerequisites.

### P2 - Notarization handling can disclose credentials and omits required provenance logs

`scripts/build-installer.sh:472-479` and `:722-729` construct fallback notarization arguments containing the literal app-specific password. Failure messages at `scripts/build-installer.sh:508-512` and `:740-744` interpolate the complete argument arrays, which can disclose that password in local or CI logs. GitHub's masking is defense in depth and is not a guarantee against transformed or inadvertently printed secrets.

The script submits and waits at `scripts/build-installer.sh:482` and `:732`, but does not retain the submission ID or retrieve the notarization log. That conflicts with the review/record requirement at `docs/release/RELEASE_CHECKLIST.md:102` and `:110-111`, and Apple's recommendation to inspect the log even after a successful submission.

**Required repair:** never include secret-bearing argument arrays in diagnostics, prefer keychain-profile authentication exclusively in CI, capture both submission IDs, fetch both notarization logs, fail on unexpected findings, and retain the logs as non-secret release provenance.

### P2 - Contract coverage misses release-critical files and mostly validates strings

The `pull_request` path filters at `.github/workflows/release-contract.yml:6-22` do not match `.github/workflows/publish-release.yml`, `scripts/build-installer.sh`, `apps/hippocampus/Resources/build-app.sh`, `CHANGELOG.md`, `docs/STATUS.md`, or `apps/hippocampus/Package.resolved`. Release-critical changes to those files can therefore bypass this workflow entirely.

`scripts/test-release-contract.sh:27-52` defines regex/literal/order helpers, and its assertions at `:54-137` inspect source strings rather than run workflow commands or validate release behavior. Follow-up `778c0bc` adds useful regression assertions at `scripts/test-release-contract.sh:97-98` and `:116-117`; they fail on the original corruption and pass after the workflow repair, but they still do not execute the multiline commands. The model and keypair tests do execute useful behavior, while the identity test's acceptance of an all-zero signature shows that its security assertion is not meaningful.

**Required repair:** widen the trigger paths to all release inputs, execute extracted shell bodies or move them into independently tested scripts, add an end-to-end fixture for tag/draft/download/verify/publish identity, and make failure-path tests assert cryptographic and provenance behavior rather than token presence.

### P3 - Sparkle configuration and owner documentation contain contract drift

`apps/hippocampus/Resources/Info.plist:60-61` uses `SUEnableInstallerLauncher`, but Sparkle 2's key is `SUEnableInstallerLauncherService`. The application is not sandboxed (`apps/hippocampus/Resources/Hippocampus.entitlements:4-15`), so Sparkle's launcher service is not required; the inert key should be removed rather than silently suggesting it is active.

`docs/release/OWNER_SIGNING.md:3-5` says no repository script creates or exports signing secrets, while `scripts/sparkle-keygen.sh:212-262` does exactly that for the Sparkle key. The release identity check also requires only a positive `CFBundleVersion` at `scripts/verify_release_identity.py:75-83`; it does not enforce monotonicity against the previously published appcast, although Sparkle uses that value for update ordering.

**Required repair:** remove or correct the launcher-service key according to the actual sandbox model, reconcile the signing guide with the key-generation script, and compare `CFBundleVersion` with the current public appcast before publishing future releases.

## Verified Contracts

The review found several correctly implemented pieces that should be preserved:

- Follow-up `778c0bc` replaces every corrupted standalone `+` with valid shell continuations at `.github/workflows/release.yml:75-80`, `:101-107`, `:116-119`, `:137-139`, and `:171-182`, plus `.github/workflows/publish-release.yml:53-61`; the added regression assertions pass 48/48 and the repaired workflows pass `actionlint` 1.7.7.
- `scripts/build-installer.sh:328-437` signs Sparkle nested code inside-out with hardened runtime and secure timestamps.
- `scripts/build-installer.sh:707-739` signs the outer DMG with Developer ID Application, notarizes it, staples it, validates the staple, verifies the signature, and uses Gatekeeper's `open` assessment with `context:primary-signature`.
- `.github/workflows/release.yml:146-163` repeats DMG and mounted-app signature, staple, and Gatekeeper checks before draft creation.
- `scripts/verify_release_identity.py:66-140` consistently checks tag, bundle version, changelog heading, DMG filename, and appcast URL/version/length identity, apart from the cryptographic gap above.
- `scripts/verify-sparkle-keypair.sh` behaviorally accepts a matching keypair and rejects a mismatch.
- The model extractor rejects traversal, links, duplicate/oversized archives, malformed layout, and digest mismatch.
- `.github/workflows/publish-release.yml:19-22` declares the documented minimum Pages permissions (`pages: write`, `id-token: write`) plus the `contents: write` needed for release promotion.

These behaviors align in substantial part with Apple's [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization guidance](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), and [Mac distribution packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution); Sparkle's [publishing](https://sparkle-project.org/documentation/publishing/) and [sandboxing/code-signing](https://sparkle-project.org/documentation/sandboxing/) contracts; and GitHub's [secure-use](https://docs.github.com/en/actions/reference/security/secure-use), [workflow token](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token), [environment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments), and [Pages custom-workflow](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages) contracts.

## Exact Unverified Owner Gates

The following owner-controlled gates were not configured or could not be exercised during this review and must not be represented as passing:

- No GitHub `release-signing` environment exists with required owner reviewers, self-review prevention, administrator-bypass policy, and tag restrictions. The tag workflow itself declares no signing environment at `.github/workflows/release.yml:14-194`.
- No GitHub `github-pages` environment protection was configured, so `.github/workflows/publish-release.yml:26-30` does not currently establish manual approval.
- GitHub Pages was not enabled for the repository; the feed URL shape is correct, but a real Pages deployment and retrieval of `https://amyjainberkeley.github.io/hippocampus/appcast.xml` were not verified.
- Required release variables `RELEASE_MODELS_URL` and `RELEASE_MODELS_SHA256` were not configured, and their tag-bound immutability was not established.
- Required Apple certificate/notarization and Sparkle private-key secrets were not configured in an owner-protected environment. A real Developer ID identity, Apple notarization submission, staple, Gatekeeper assessment, and matching owner Sparkle signature were therefore not exercised.
- A clean macOS owner machine with full Xcode, the real model archive, and signing credentials was not available. Focused `BuildAppScriptTests`, full clean-tag app assembly, signed outer-DMG verification, draft creation, manual promotion, and post-publish Sparkle update discovery remain unverified.

## Reproduction Evidence

The original focused suite was run from a fresh `git archive` of `accb1a2`, avoiding unrelated working-tree changes. After `778c0bc`, every changed release file was inspected and the affected tests and linter were rerun:

- `scripts/test-release-contract.sh` at `778c0bc`: **PASS, 48/48**
- `scripts/test-release-identity.sh`: **PASS, 4/4**
- `scripts/test-prepare-release-models.sh`: **PASS, 8/8**
- `scripts/test-sparkle-keygen.sh`: **PASS**
- `scripts/test-sparkle-keypair.sh`: **PASS**, including mismatch rejection
- `actionlint` 1.7.7 over `.github/workflows/*.yml` at `778c0bc`: **PASS**, no diagnostics
- `bash -n` over the focused shell scripts: **PASS**
- `cargo fmt --check`: **PASS**
- `cargo clippy --workspace --all-targets -- -D warnings` at `accb1a2`: **FAIL**, 34 denied warnings. No Rust or toolchain file changed in `778c0bc`; an exact-tip rerun was stopped at the owner's request and is not claimed as a fresh passing result.
- `scripts/test-swift-package.sh`: **PASS, 25/25**
- `scripts/test-installer-brand.sh`: **PASS, 2/2**
- Focused `BuildAppScriptTests`: **NOT RUNNABLE on this host** because only Command Line Tools are selected and the package test target cannot import `XCTest`; this is an environment limitation, not a passing result.

Direct probes reproduced the original literal-`+` failures, review of `778c0bc` confirmed their removal, and the audited status baseline measured 26 commits behind the follow-up tip.

## Required Repairs Before Release

1. Refresh and enforce status provenance before build; clear Clippy; pin Rust exactly.
2. Provision the real Sparkle key and cryptographically verify every staged DMG signature against it.
3. Put all signing secrets behind protected, owner-approved environments; split job permissions and pin actions by full SHA.
4. Bind model URL, digest, contents, and identity to the release tag.
5. Make public-release/Pages publication recoverable and configure the required Pages/environment settings.
6. Redact notarization failures and retain reviewed notarization logs and submission IDs.
7. Expand CI path coverage and supplement the new corruption regressions with executable negative tests.
8. Remove the inert Sparkle plist key, fix signing documentation, and enforce monotonic build numbers.

**FAIL** - the reviewed release changes cannot complete their clean-tag workflow and do not yet establish a protected, cryptographically verified, reproducible release chain.
