# Hippocampus Owner Signing Setup

This document covers the account-controlled prerequisites for distributing
Hippocampus outside the Mac App Store. It does not contain credentials. The
interactive Sparkle helper can create and export that one update key after
explicit confirmation; no repository script creates Apple credentials or
uploads any secret.

Apple requires directly distributed macOS software to use a Developer ID
Application certificate, hardened runtime, a secure timestamp, and
notarization. An Apple Developer Program membership alone does not install
Xcode, place a signing identity and private key in this Mac's Keychain, or
create a notarization profile.

Primary Apple references:

- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## Current Machine Snapshot

Measured again on 2026-09-02:

```text
xcode-select -p
/Library/Developer/CommandLineTools

xcodebuild -version
error: active developer directory is a Command Line Tools instance

find /Applications -maxdepth 2 -name 'Xcode*.app' -print
(no result)

security find-identity -v -p codesigning
0 valid identities found

xcrun notarytool history --keychain-profile notarytool-profile
No Keychain password item found for profile: notarytool-profile
```

The code can be built and tested with the repository's constrained SwiftPM
wrapper where supported, but this machine cannot yet produce a Developer
ID-signed and notarized public release.

The first Hippocampus Sparkle keypair was generated on this owner machine on
2026-09-01. Its private seed remains outside the repository at mode `0600`; the
matching public key is committed in `Info.plist` and the pair verifier passes.

## 1. Install And Select Full Xcode

Install a current Xcode release from the Mac App Store or Apple Developer
Downloads, open it once, accept its license, and let it install components.
Then select it:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
```

The final command must print an Xcode version rather than the Command Line
Tools error above.

## 2. Install The Developer ID Application Identity

In Xcode, add the Apple account under Settings > Accounts, select the team,
open Manage Certificates, and create or download a Developer ID Application
certificate. The Account Holder can also create it in Certificates,
Identifiers & Profiles using a certificate signing request.

The certificate is usable on this Mac only when Keychain contains both the
certificate and its private key. Verify without exporting either:

```bash
security find-identity -v -p codesigning
```

At least one valid identity containing `Developer ID Application` must appear.
A Developer ID Installer identity is needed for `.pkg` distribution, but not
for the Hippocampus `.dmg` path.

## 3. Store Notarization Credentials

Create an app-specific password for the Apple ID, or use an App Store Connect
API key supported by `notarytool`. Store the credential in Keychain under the
profile name expected by the repository:

```bash
xcrun notarytool store-credentials notarytool-profile \
  --apple-id '<apple-id>' \
  --team-id '<team-id>'
```

Enter the app-specific password only at the secure prompt. Do not place it in
shell history, `.env`, a Markdown file, or git. Verify the stored profile:

```bash
xcrun notarytool history --keychain-profile notarytool-profile
```

## 4. Create The Sparkle Update Key Once

Hippocampus uses Sparkle EdDSA signatures independently of Apple code signing.
Run the repository helper interactively. It uses Sparkle's named Keychain
account `ai.hippocampus.release`, exports the private seed to a mode-0600 file
for owner backup/CI, and writes the public key separately:

```bash
./scripts/sparkle-keygen.sh
```

Keep the private key in the password manager or CI secret store. Put only the
matching public key in `SUPublicEDKey` in
`apps/hippocampus/Resources/Info.plist`. A placeholder or mismatched pair must
block publication.

Verify the pair before adding the CI secret:

```bash
./scripts/verify-sparkle-keypair.sh \
  --private-key ~/.hippocampus-sparkle-private.key \
  --info-plist apps/hippocampus/Resources/Info.plist
```

## 5. Configure The Protected Signing Environment

Create a GitHub environment named `release-signing`. Require owner review,
prevent self-review, disable administrator bypass where the repository plan
allows it, and restrict it to release tags. Store these as environment secrets,
not general repository secrets:

| Secret | Purpose |
|---|---|
| `APPLE_CERTIFICATE_P12` | Base64 of the Developer ID Application certificate plus private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `NOTARYTOOL_APPLE_ID` | Apple ID used for notarization |
| `NOTARYTOOL_TEAM_ID` | Apple Developer Team ID |
| `NOTARYTOOL_PASSWORD` | App-specific password |
| `SPARKLE_PRIVATE_KEY` | Private EdDSA key matching `SUPublicEDKey` |

The signing job has a read-only repository token. A separate job with no
signing secrets creates the draft release using a write token. Never print
secret values, include them in build artifacts, or pass them to Hippocampus
child processes.

## 6. Configure The Immutable Model Bundle

The sole required release model, Arctic Embed S, is intentionally not checked
into git. BERT NER and Qwen3 remain optional experiments and are not release
dependencies. A clean tag runner therefore requires one HTTPS tar archive
whose top-level `models/` directory contains the complete
`ArcticEmbedS_FP16.mlmodelc` bundle named by `release-models.json`. The
immutable URL and digest live in that tagged manifest; mutable GitHub variables
are not release authority.

Create the archive without AppleDouble metadata where possible and calculate
the digest from the final bytes:

```bash
COPYFILE_DISABLE=1 tar -czf release-models-v1.tar.gz models
shasum -a 256 release-models-v1.tar.gz
./scripts/prepare-release-models.sh \
  --archive release-models-v1.tar.gz \
  --sha256 '<digest>' \
  --output /tmp/hippocampus-release-models-check
./scripts/release_models_manifest.py \
  --manifest release-models.json \
  --release-version 0.1.0
```

Upload the final bytes as
`release-models-0.1.0.tar.gz` in a versioned GitHub release asset, then replace
both `UNPROVISIONED` values in `release-models.json` with that exact URL and
lowercase digest before creating the app tag. The prebuild identity gate blocks
until this tag-owned manifest is valid.

## 7. Configure GitHub Pages Publication

In repository Settings > Pages, select **GitHub Actions** as the source. The
shipped feed URL is
`https://amyjainberkeley.github.io/hippocampus/appcast.xml`. Configure the
`github-pages` environment with the same owner-review protections. Publication
still requires the manual workflow input `PUBLISH`; a rerun may safely finish a
failed Pages deployment after release promotion because every artifact is
re-downloaded and cryptographically reverified first.

## 8. Verify Without Publishing

From the repository root:

```bash
./scripts/check-signing-prereqs.sh --release
```

The command must report zero blockers before a tag is created. The final
release checklist remains authoritative for the signed artifact gates.
