# Sparkle Release And Appcast Runbook

How an installed Hippocampus learns about a new version, and how a release
publishes one.

- Each GitHub release carries the signed, notarized DMG, its SHA-256 sidecar,
  and an `appcast.xml` that describes that DMG.
- `SUFeedURL` is
  `https://github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml`.
  GitHub redirects it to the `appcast.xml` of the newest published release
  that is neither a draft nor a prerelease.
- So publishing a release as Latest is what publishes its update. A draft or a
  prerelease changes nothing for installed copies.

There is no Pages site, sibling repository or other host to keep in step.
Until the first release is published the feed address returns 404, and Check
for Updates reports that it could not check.

Sparkle 2.9.2, the version the app ships, follows this address's redirects
(github.com, then the release download, then GitHub's asset host).
`scripts/sparkle_feed_probe.swift` shows what Sparkle makes of any feed; run
against a public app that uses the same kind of address, it found that app's
update through the same redirects.

## Trust Boundaries

- Apple Developer ID signing and notarization establish who published the app
  and that Apple scanned it.
- Sparkle's Ed25519 key signs the DMG's bytes. The signature sits in the
  appcast's `<enclosure>`, and the installed app checks it against
  `SUPublicEDKey` before installing.
- The same key signs `appcast.xml` itself: `sign_update` appends a
  `sparkle-signatures` comment over every byte before it. 0.3.0 does not
  require a signed feed, so today the release tooling checks it. An app that
  also sets `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` refuses
  an unsigned or edited feed; `scripts/test-sparkle-publish.sh` shows Sparkle
  doing so.
- GitHub hosting is a delivery surface, not a signing authority.

`scripts/sparkle-publish.sh` writes the appcast. It signs the DMG with
`sign_update`, embeds that version's `CHANGELOG.md` section as Markdown
release notes (or the notes you pass), signs the feed, and verifies that
signature before writing the file. `scripts/verify-release-identity.sh --phase
staged` then checks the tag, version, build, minimum macOS, enclosure URL and
length, checksum, and both signatures against `SUPublicEDKey`.

## Release From This Mac

1. `scripts/release-0.3.0.sh --check`, then `scripts/release-0.3.0.sh`. It
   builds, signs, notarizes and verifies the DMG, writes `appcast.xml` with the
   Sparkle key file (`~/.hippocampus-sparkle-private.key`), and runs the staged
   identity gate. It uploads nothing, and prints the files and commands for
   the next steps.
2. Push the release commit. Create a **draft** release at that commit with
   every file the script lists: `Hippocampus-<version>.dmg` and its `.sha256`,
   `Hippocampus.dmg` and its `.sha256`, `appcast.xml`, and `install.sh`.
3. Inspect the draft (below).
4. Publish it as Latest: `gh release edit v<version> --draft=false --latest`,
   or run **Publish inspected release** from GitHub Actions with the exact tag
   and `PUBLISH`. The workflow first re-verifies the draft's files on a clean
   Mac, and afterwards checks that the feed address serves the inspected
   `appcast.xml`.

## Release From CI

A `v*` tag runs `.github/workflows/release.yml`. With no release secret set it
builds nothing. With all six it builds every binary, signs, notarizes and
verifies the app and DMG, writes and signs the appcast with
`sparkle-publish.sh`, runs the staged identity gate, and creates a **draft**
release. Publication is step 4 above.

One-time owner setup for CI releases:

1. Add the Developer ID, notarization and Sparkle secrets that
   `.github/workflows/release.yml` reads to the `release-signing` environment.
2. Create protected `release-signing` and `release-publish` environments.
   Require owner review, prevent self-review, disable bypass where available,
   and restrict the signing environment to release tags.
3. Provision the immutable model archive and commit its URL/digest in
   `release-models.json`.
4. Confirm `SUPublicEDKey` matches the Sparkle key without printing either key:

   ```bash
   ./scripts/verify-sparkle-keypair.sh \
     --private-key ~/.hippocampus-sparkle-private.key \
     --info-plist apps/hippocampus/Resources/Info.plist
   ```

## Inspect

Before publication:

1. Review the release notes and Apple's notary logs.
2. Download the draft DMG and verify its sidecar.
3. Mount it on a second Mac, drag the app to Applications, launch it from a
   quarantined download, and run the clean-install and upgrade smoke tests.
4. Inspect `appcast.xml`; its enclosure must point to the same tag and DMG
   name in this repository's GitHub Releases URL.
5. Confirm the Keychain-held database key and capture preference survive an
   upgrade from the prior public version.

Do not replace assets after inspection, and never edit `appcast.xml` by hand:
its signature covers its bytes. Rebuild from a new commit and tag when bytes
change.

## Verify Public State

```bash
curl --fail --silent --show-error --location \
  https://github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml \
  | xmllint --noout -

gh release view --repo amyjainberkeley/hippocampus
```

The appcast has no system-profile reporting, analytics endpoint, or download
counter. `SUEnableSystemProfiling` remains false.

## Key Rotation

Sparkle key rotation is a compatibility migration, not a routine secret edit.
Follow Sparkle's documented rotation rules: ship a bridge update signed by the
old trusted key that changes only the Sparkle key, then use the new key for
later updates. Never rotate the Developer ID identity and Sparkle key in the
same bridge release.

Primary references:

- [Sparkle documentation](https://sparkle-project.org/documentation/)
- [Linking to the latest release asset](https://docs.github.com/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub deployment environments](https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments)
- [Apple code signing in depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
